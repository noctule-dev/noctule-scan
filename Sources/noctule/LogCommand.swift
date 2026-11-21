// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Dispatch
import Foundation
import Synchronization
import NoctuleCLICore
import NoctuleKit
import NoctuleStore

// `noctule log`: runs one station (`StationRunner`) and prints its hits as they happen. A USB
// station has no RTSP audio: no cooldown wait and no cooldown record read or written. With a
// line-in (Plan 19) the runner records its hits from that input, as a network station's from RTSP;
// without one there are no recordings. When a USB station's scanner goes away the runner waits for
// it and `log` says so, or (when the runner won't resume) `log` stops and exits 1.
// Everything here is nonisolated on purpose: the signal handlers run on a global queue, and
// anything they touch must be Sendable and passed in, never a main.swift global (those are
// @MainActor; see LESSONS.md).

/// `fputs` (a closed pipe is just an error; SIGPIPE is ignored in main.swift), flushed so lines
/// appear as hits happen even when stdout is a pipe.
private func logOut(_ text: String) {
    fputs(text + "\n", stdout)
    fflush(stdout)
}

private func logErr(_ text: String) {
    fputs(text + "\n", stderr)
}

struct LogOptions: Sendable {
    var station: String?
    var seconds: Int?
    var settingsDirectory: URL
    var recordingsRoot: URL
    /// The full reconnect cooldown (after an unclean close): 120 s, or the mock-only
    /// `--cooldown-seconds`. The station's own setting is the clean-close value.
    var cooldown: Duration
    var cooldownStoreURL: URL
    /// The shell's one USB port listing (`USBDetection`): a USB station with no saved port uses
    /// "the only Uniden port" in it (a saved port that isn't there never falls back to it).
    var ports: any SerialPortListing
    /// `NOCTULE_TEST_KEEPALIVE_SECONDS` (`KeepAliveOverride`): the interval of a USB scanner's push
    /// keep-alive in place of its model's; nil keeps the model's (always so unless
    /// `NOCTULE_NO_USB_DETECTION` is set).
    var keepAliveInterval: Duration?
    /// How a USB station's saved audio input is opened (`LineInSupport.factory`): the system's, a
    /// refusing source under the kill-switch, or the test stream.
    var lineInSources: LineInSourceFactory
    /// The kill-switch turned audio inputs off (`LineInSelection.disabled`): a line-in station's
    /// input won't be opened, and the runner's warning says so in place of `audio: line-in …`.
    var lineInDisabled: Bool
}

/// Stop requests and signal bookkeeping, shared with the signal handlers.
final class LogControl: Sendable {
    private struct State {
        var interrupts = 0
        /// The first stop signal received (SIGINT, SIGTERM, or SIGHUP).
        var signal: Int32?
        var closing = false
        /// A USB station's scanner went away and the runner won't resume by itself.
        var scannerGone = false
    }
    private let state = Mutex(State())
    private let runner: StationRunner
    /// One element per stop request (`--seconds` elapsed, or the first signal).
    let stops: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(runner: StationRunner) {
        self.runner = runner
        (stops, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func requestStop() { continuation.yield(()) }

    var isInterrupted: Bool { state.withLock { $0.interrupts > 0 } }

    /// 128 + the first signal's number (130 for SIGINT, 143 for SIGTERM, 129 for SIGHUP).
    var interruptExitCode: Int32 { 128 + (state.withLock { $0.signal } ?? SIGINT) }

    func beginClosing() { state.withLock { $0.closing = true } }

    /// The scanner went away for good: stop as `--seconds` would, and exit 1.
    func scannerWontComeBack() {
        state.withLock { $0.scannerGone = true }
        requestStop()
    }

    var isScannerGone: Bool { state.withLock { $0.scannerGone } }

    /// Called from a signal handler. The first signal asks for an orderly stop through
    /// `runner.stop()` (which also cancels a start still in flight); any later signal, or a signal
    /// once closing has begun, only reports progress. It never exits the process.
    func interrupt(signal: Int32) {
        let (first, closing) = state.withLock { s -> (Bool, Bool) in
            s.interrupts += 1
            if s.signal == nil { s.signal = signal }
            return (s.interrupts == 1, s.closing)
        }
        if first, !closing {
            requestStop()
            let runner = self.runner
            Task { await runner.stop() }
        } else {
            logErr(StationCLI.stillClosingLine)
        }
    }
}

/// Ignores the stop signals' default action and routes each to `control`. Nonisolated, capturing
/// only the Sendable `control`, so libdispatch can run the handlers off the main queue.
func installLogSignalHandlers(control: LogControl) -> [DispatchSourceSignal] {
    stopSignals.map { signo in
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
        source.setEventHandler { @Sendable in control.interrupt(signal: signo) }
        source.resume()
        return source
    }
}

enum LogCommand {
    /// Runs `noctule log` and returns the exit status. Every path that built the runner ends with
    /// `runner.stop()` finished (`PSI,0`, TEARDOWN, hits closed and logged) before this returns.
    static func run(_ options: LogOptions) async -> Int32 {
        let settings = LocalSettingsStore(directory: options.settingsDirectory)
        let station: Station
        do {
            let stations = try await settings.stations()
            switch StationCLI.resolve(name: options.station, stations: stations, lastID: await settings.lastStationID()) {
            case .success(let s): station = s
            case .failure(let error):
                logErr("log: \(error)")
                return 1
            }
        } catch let error as SettingsStoreError {
            logErr("log: \(error)")  // names the file; nothing was written
            return 1
        } catch {
            logErr("log: can't read the stations: \(error)")
            return 1
        }
        // Only a network station has audio, and so a reconnect cooldown.
        let isNetwork = station.connection.transport == .network
        // One runner per station across processes (the app, another `noctule log`): take the lock
        // before the cooldown wait and before any scanner traffic. Held until this returns.
        let lock: StationLock
        do {
            lock = try StationLock.acquire(stationID: station.id, settingsDirectory: options.settingsDirectory)
        } catch {
            logErr(StationCLI.lockErrorLine(error, stationName: station.name))
            return 1
        }
        defer { lock.release() }

        let device: StationDeviceSettings
        do {
            device = try await settings.deviceSettings(for: station.id)
        } catch {
            logErr("log: \(error)")  // e.g. device.json unreadable; nothing was written
            return 1
        }

        let logURL = StationCLI.hitLogURL(settingsDirectory: options.settingsDirectory, stationID: station.id)
        let hitLog: HitLog
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            hitLog = try HitLog(url: logURL)
        } catch {
            logErr("log: can't open the hit log at \(logURL.path): \(error)")
            return 1
        }
        await settings.setLastStationID(station.id)

        // A USB station never reads, waits on or writes the cooldown record: no file store and no
        // policy for it (the runner, which never calls its store for one, gets an in-memory one).
        let fileStore = isNetwork ? FileRTSPCooldownStore(url: options.cooldownStoreURL) : nil
        let cooldownStore: any RTSPCooldownStore = fileStore ?? InMemoryRTSPCooldownStore()
        let policy = station.connection.reconnectCooldownPolicy(full: options.cooldown)
        let runner = StationRunner(
            station: station, device: device, log: hitLog, recordingsRoot: options.recordingsRoot,
            cooldownStore: cooldownStore, transportFactory: StationTransportFactory(ports: options.ports),
            audioConfig: isNetwork ? AudioSessionConfig(cooldownPolicy: policy) : AudioSessionConfig(),
            keepAliveInterval: options.keepAliveInterval, lineInSources: options.lineInSources)
        let control = LogControl(runner: runner)
        let signalSources = installLogSignalHandlers(control: control)
        defer { signalSources.forEach { $0.cancel() } }

        // The runner opens a line-in only for a USB station that has one saved.
        let lineInConfig = isNetwork ? nil : device.lineIn
        let events = runner.events
        let printer = Task {
            var connectedBefore = false
            for await event in events {
                switch StationCLI.eventOutput(event, reconnect: connectedBefore) {
                case .stdout(let line): logOut(line)
                case .stderr(let line): logErr(line)
                case nil: break
                }
                switch event {
                case .connected:
                    if !connectedBefore, !isNetwork,
                       let line = StationCLI.usbAudioLine(lineIn: lineInConfig, lineInDisabled: options.lineInDisabled) {
                        logErr(line)
                    }
                    connectedBefore = true
                case .disconnected:
                    // Set before the event was emitted. When the runner won't resume, its warning
                    // follows this event; it is printed while the stop below runs.
                    if await runner.willResume {
                        logErr(StationCLI.waitingForScannerLine)
                    } else {
                        control.scannerWontComeBack()
                    }
                default:
                    break
                }
            }
        }

        // Wait out the reconnect cooldown first, as `listen` does, so the runner's audio start is
        // never refused (it would log without audio). Nothing is sent to the scanner until the
        // wait is over; a stop signal during it exits 128 + signo. Not needed without audio, and a
        // USB station has none.
        let host = (station.connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let fileStore, station.recording.saveAudio != .never,
           let remaining = await RTSPCooldownGate.remaining(store: fileStore, host: host, policy: policy) {
            logErr(ListenFormat.waitingLine(remaining: remaining))
            if !(await RTSPCooldownGate.waitOut(remaining, isInterrupted: { control.isInterrupted })) {
                control.beginClosing()
                await runner.stop()  // never started: sends nothing
                await printer.value
                await hitLog.close()
                return control.interruptExitCode
            }
        }

        var code: Int32 = 0
        do {
            try await runner.start()
            let timer = options.seconds.map { seconds in
                Task {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    control.requestStop()
                }
            }
            for await _ in control.stops { break }
            timer?.cancel()
        } catch {
            // A stop signal during the start cancels it (`StationRunnerError.stopped`); that is a
            // normal stop, reported by the exit code alone.
            // A USB station whose port is busy or isn't there fails here, at once: the wait is
            // only for a scanner that was connected and went away.
            if !control.isInterrupted {
                logErr(StationCLI.startFailureLine(error, stationName: station.name))
                code = 1
            }
        }

        // Shutdown: never cut short. stop() is idempotent and shared with a signal's call.
        control.beginClosing()
        await runner.stop()
        await printer.value
        if let error = await fileStore?.lastWriteError {
            logErr(StationCLI.warningLine("couldn't update the cooldown record \(options.cooldownStoreURL.path): \(error)"))
        }
        await hitLog.close()
        // A stop signal at any point reports as an interrupt (as `listen` and `watch` do); a USB
        // scanner that went away for good is a failure.
        if control.isInterrupted { return control.interruptExitCode }
        return control.isScannerGone ? 1 : code
    }
}
