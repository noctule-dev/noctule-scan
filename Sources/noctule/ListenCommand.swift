// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Dispatch
import Foundation
import Synchronization
import NoctuleAudioPlayback
import NoctuleCLICore
import NoctuleKit
import NoctuleStore

// `noctule listen`. Everything here is nonisolated on purpose: the signal handlers run on a
// global queue, and anything they touch must be Sendable and passed in, never a main.swift
// global (those are @MainActor; see LESSONS.md).

/// Writes to stderr with `fputs`, which reports a closed pipe as an error (SIGPIPE is ignored;
/// see main.swift) instead of raising, as `FileHandle.write(_: Data)` does.
private func stderrLine(_ text: String) {
    fputs(text + "\n", stderr)
}

/// Why the listen loop stops.
enum ListenStop: Sendable {
    case elapsed, interrupted, streamEnded
    case playbackFailed(String)
    case recordFailed(String)
    /// A line-in that can't be opened (denied, or refused under the kill-switch); its line has been printed.
    case inputFailed
}

/// Stop requests and signal bookkeeping, shared with the signal handlers.
final class ListenControl: Sendable {
    private struct State {
        var interrupts = 0
        /// The first stop signal received (SIGINT, SIGTERM, or SIGHUP).
        var signal: Int32?
        var closing = false
        var session: AudioSession?
    }
    private let state = Mutex(State())
    let stops: AsyncStream<ListenStop>
    private let continuation: AsyncStream<ListenStop>.Continuation
    /// Says that a stop is under way, for a signal that arrives while closing.
    private let stillClosing: @Sendable () -> Void

    init(stillClosing: @escaping @Sendable () -> Void = { stderrLine("audio: still closing the scanner session…") }) {
        (stops, continuation) = AsyncStream.makeStream(of: ListenStop.self)
        self.stillClosing = stillClosing
    }

    func request(_ stop: ListenStop) { continuation.yield(stop) }

    var isInterrupted: Bool { state.withLock { $0.interrupts > 0 } }

    /// The exit status for an interrupted run: 128 + the first signal's number (130 for SIGINT,
    /// 143 for SIGTERM, 129 for SIGHUP).
    var interruptExitCode: Int32 { 128 + (state.withLock { $0.signal } ?? SIGINT) }

    /// The session a stop signal should stop (so an interrupted start returns promptly).
    func setSession(_ session: AudioSession?) { state.withLock { $0.session = session } }

    func beginClosing() { state.withLock { $0.closing = true } }

    /// Called from a signal handler. The first signal asks for an orderly stop (TEARDOWN);
    /// any signal while closing only reports progress. It never exits the process.
    func interrupt(signal: Int32 = SIGINT) {
        let (first, closing, session) = state.withLock { s -> (Bool, Bool, AudioSession?) in
            s.interrupts += 1
            if s.signal == nil { s.signal = signal }
            return (s.interrupts == 1, s.closing, s.session)
        }
        if first, !closing {
            request(.interrupted)
            if let session { Task { await session.stop() } }
        } else {
            stillClosing()
        }
    }
}

/// The signals that stop `listen` (and `watch`) in an orderly way: Ctrl-C, `kill`, and a closed
/// terminal. Their default action would kill the process without a TEARDOWN.
let stopSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

/// Ignores the stop signals' default action and routes each to `control`. Nonisolated, capturing
/// only the Sendable `control`, so libdispatch can run the handlers off the main queue.
func installListenSignalHandlers(control: ListenControl) -> [DispatchSourceSignal] {
    stopSignals.map { signo in
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .global())
        source.setEventHandler { @Sendable in control.interrupt(signal: signo) }
        source.resume()
        return source
    }
}

/// Owns the WAV writer (not Sendable) and serializes access to it.
actor ListenRecorder {
    private let writer: WAVWriter

    init(url: URL) throws {
        writer = try WAVWriter(url: url)
    }

    func append(_ samples: [Int16]) throws { try writer.append(samples) }
    func flush() throws { try writer.flush() }
    func close() throws { try writer.close() }
}

/// What the states consumer saw: the failure (if any) and its restart hint.
private final class FailureNote: Sendable {
    private let value = Mutex<(failed: Bool, hint: RestartHint?)>((false, nil))
    func record(hint: RestartHint?) { value.withLock { $0 = (true, hint) } }
    var snapshot: (failed: Bool, hint: RestartHint?) { value.withLock { $0 } }
}

/// What every `listen` takes: `--record`, `--seconds` and (from `--no-play`) `play`.
struct ListenOptions: Sendable {
    var record: String?
    var seconds: Int?
    var play: Bool
}

/// Where `listen` reaches the scanner's RTSP audio: `--host` and the flags, or a network station.
struct NetworkListenOptions: Sendable {
    var target: AudioTarget
    /// The full value after an unclean close (120 s, or the mock-only `--cooldown-seconds`) and
    /// `--reconnect-cooldown` (or a station's own wait) after a clean one.
    var cooldownPolicy: RTSPCooldownPolicy
    var cooldownStoreURL: URL
}

enum ListenCommand {
    /// Runs `noctule listen` and returns the exit status. On every path that opened a session,
    /// `AudioSession.stop()` (TEARDOWN) has finished, the WAV is closed, and playback is stopped
    /// before this returns.
    static func run(_ options: ListenOptions, network: NetworkListenOptions) async -> Int32 {
        let control = ListenControl()
        let signalSources = installListenSignalHandlers(control: control)
        defer { signalSources.forEach { $0.cancel() } }

        var recorder: ListenRecorder?
        if let path = options.record {
            do {
                recorder = try ListenRecorder(url: URL(fileURLWithPath: path))
            } catch {
                stderrLine("audio: can't write \(path): \(error)")
                return 1
            }
        }

        let target = network.target
        let store = FileRTSPCooldownStore(url: network.cooldownStoreURL)
        let config = AudioSessionConfig(
            cooldownPolicy: network.cooldownPolicy, cooldownStore: store,
            probe: {
                // Control channel only (UDP MDL on a fresh client); never RTSP port 554.
                await ScannerRestartMonitor.isAnswering(host: target.host, port: target.controlPort, timeout: .seconds(2))
            })

        // Start, waiting out the scanner's reconnect cooldown first if needed.
        var session: AudioSession
        var chunks: AsyncStream<AudioChunk>
        var cooldownRetries = 0
        while true {
            if control.isInterrupted { return await closeRecorder(recorder, code: control.interruptExitCode) }
            // Check the shared store first, so a wait doesn't cost a refused start (and its probe).
            if let remaining = await RTSPCooldownGate.remaining(store: store, host: target.host, policy: network.cooldownPolicy) {
                stderrLine(ListenFormat.waitingLine(remaining: remaining))
                guard await RTSPCooldownGate.waitOut(remaining, isInterrupted: { control.isInterrupted }) else { return await closeRecorder(recorder, code: control.interruptExitCode) }
                continue
            }
            session = AudioSession(host: target.host, rtspPort: target.rtspPort, config: config)
            control.setSession(session)
            do {
                chunks = try await session.start()
                break
            } catch RTSPError.cooldown(let remaining) where cooldownRetries < 3 {
                // Another process claimed the scanner between the check above and the connect
                // (the claim is atomic, so it lost the race safely): wait and check again.
                cooldownRetries += 1
                await session.stop()
                stderrLine(ListenFormat.waitingLine(remaining: remaining))
                guard await RTSPCooldownGate.waitOut(remaining, isInterrupted: { control.isInterrupted }) else { return await closeRecorder(recorder, code: control.interruptExitCode) }
            } catch {
                let hint = await session.restartHint
                await session.stop()   // TEARDOWN if a session id was issued
                let unreleased = await session.unreleasedSessions.count
                if control.isInterrupted {
                    stderrLine("audio: stopped before streaming started")
                } else {
                    stderrLine(ListenFormat.startFailure(error, host: target.host, port: target.rtspPort))
                    if let hint { stderrLine(ListenFormat.hintLine(hint)) }
                }
                if unreleased > 0 { stderrLine(ListenFormat.unreleasedLine(count: unreleased)) }
                return await closeRecorder(recorder, code: control.isInterrupted ? control.interruptExitCode : 1)
            }
        }

        // Streaming. Report state changes; a failure ends the run.
        let failure = FailureNote()
        let statesTask = Task { [session] in
            for await state in session.states {
                if case .failed = state { failure.record(hint: await session.restartHint) }
                if let line = ListenFormat.stateLine(state) { stderrLine(line) }
                if case .failed = state { control.request(.streamEnded) }
            }
        }

        // Fan the chunks out to the recorder and the player.
        let (playChunks, playContinuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(250))
        let play = options.play
        let pumpTask = Task { [chunks, recorder] in
            var recording = recorder != nil
            for await chunk in chunks {
                if recording, let recorder {
                    do { try await recorder.append(chunk.samples) } catch {
                        recording = false
                        control.request(.recordFailed("\(error)"))
                    }
                }
                if play { playContinuation.yield(chunk) }
            }
            playContinuation.finish()
            control.request(.streamEnded)
        }

        var player: AudioPlayer?
        var playTask: Task<Void, Never>?
        if play {
            let p = AudioPlayer()
            player = p
            playTask = Task {
                do { try await p.play(playChunks) } catch {
                    control.request(.playbackFailed("\(error)"))
                }
            }
        } else {
            playContinuation.finish()
        }

        let flushTask = recorder.map { recorder in
            Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    do { try await recorder.flush() } catch {
                        control.request(.recordFailed("\(error)"))
                        return
                    }
                }
            }
        }
        let timerTask = options.seconds.map { seconds in
            Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                control.request(.elapsed)
            }
        }

        var reason = ListenStop.streamEnded
        for await stop in control.stops {
            reason = stop
            break
        }

        // Shutdown, in order: stop the session (TEARDOWN, then the RTP receiver; may take seconds,
        // never cut short), drain the state and chunk tasks, stop the player, then (below, after
        // the exit code is settled) close the WAV.
        control.beginClosing()
        timerTask?.cancel()
        flushTask?.cancel()
        await session.stop()
        await statesTask.value
        await pumpTask.value
        await flushTask?.value
        player?.stop()
        await playTask?.value
        withExtendedLifetime(chunks) {}

        var code: Int32
        switch reason {
        case .elapsed: code = 0
        case .interrupted: code = control.interruptExitCode
        case .streamEnded:
            code = 1
            if !failure.snapshot.failed, !control.isInterrupted { stderrLine("audio: the stream ended unexpectedly") }
        case .playbackFailed(let message):
            code = 1
            stderrLine("audio: playback failed: \(message)")
        case .recordFailed(let message):
            code = 1
            stderrLine("audio: recording failed: \(message)")
        case .inputFailed:
            code = 1  // a line-in's; never an RTSP session's
        }
        if let recorder {
            do { try await recorder.close() } catch {
                stderrLine("audio: couldn't finish \(options.record ?? "the recording"): \(error)")
                code = 1
            }
        }
        print(ListenFormat.statsLine(await session.stats))
        let note = failure.snapshot
        if note.failed, let hint = note.hint { stderrLine(ListenFormat.hintLine(hint)) }
        let unreleased = await session.unreleasedSessions.count
        if unreleased > 0 { stderrLine(ListenFormat.unreleasedLine(count: unreleased)) }
        // A stop signal at any point reports as an interrupt (as `watch` does).
        return control.isInterrupted ? control.interruptExitCode : code
    }

    private static func closeRecorder(_ recorder: ListenRecorder?, code: Int32) async -> Int32 {
        do { try await recorder?.close() } catch {
            stderrLine("audio: couldn't finish the recording: \(error)")
        }
        return code
    }
}

extension ListenCommand {
    /// `listen --station NAME`: reads the station (and its device settings) from `settingsDirectory`
    /// and listens to what it gives (`ListenStation.plan`): a network station's RTSP audio, or a USB
    /// station's line-in alone (`LineInListen`; no serial port, station lock or scanner traffic).
    /// Nothing is written to the settings.
    static func runStation(named name: String, options: ListenOptions, meter: Bool, invocation: CLIInvocation,
                           settingsDirectory: URL, cooldownStoreURL: URL,
                           lineInSources: LineInSourceFactory) async -> Int32 {
        let settings = LocalSettingsStore(directory: settingsDirectory)
        let station: Station
        let device: StationDeviceSettings
        do {
            switch StationCLI.resolve(name: name, stations: try await settings.stations(), lastID: nil) {
            case .success(let s): station = s
            case .failure(let error):
                stderrLine("listen: \(error)")
                return 1
            }
            device = try await settings.deviceSettings(for: station.id)
        } catch {
            stderrLine("listen: \(error)")  // names the file; nothing was written
            return 1
        }
        switch ListenStation.plan(station: station, device: device, invocation: invocation) {
        case .refused(let line, let exitCode):
            stderrLine(line)
            return exitCode
        case .network(let target, let policy):
            return await run(options, network: NetworkListenOptions(target: target, cooldownPolicy: policy,
                                                                    cooldownStoreURL: cooldownStoreURL))
        case .lineIn(let config):
            return await LineInListen.run(station: station, config: config, source: lineInSources(config),
                                          options: options, meter: meter)
        }
    }
}
