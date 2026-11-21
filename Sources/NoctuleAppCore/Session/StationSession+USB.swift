// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

// A USB station in the session (SDS150 design §7.2; Plan 8 Task 5): the start that waits for the
// port, and what happens when the scanner goes away. The rules are in the type's documentation
// ("Start of a USB station", "A USB scanner that goes away").

extension StationSession {
    /// How often the port wait looks at the stop flag between two polls.
    static let portWaitTick: Duration = .milliseconds(50)

    // MARK: Start

    /// The USB start (see the type's documentation). Runs inside `startTask`; `stopFlag` is the
    /// run's, and a stop that sets it while this waits or awaits closes what this opened.
    func performUSBStart() async {
        let flag = stopFlag
        // 1. Device settings first: the saved port is the station's identity for the registry.
        guard let device = await readDeviceSettings(flag: flag) else { return }
        // Its input, which only an environment that can make line-in sources runs.
        lineInConfig = environment.lineInSources == nil ? nil : device.lineIn
        // 2. The registry's scanner check (by the port just read) and the station lock.
        guard takeLock() else { return }
        phase = .connecting
        // 3. The hit log.
        guard let log = await openHitLog(flag: flag) else { return }

        // 4. The port, then the runner. No cooldown gate: a USB station has no AudioSession (its
        // audio, if any, is a line-in) and never touches the cooldown store (the runner it builds
        // doesn't either).
        let factory = StationTransportFactory(ports: environment.serialPorts,
                                              makeNetworkTransport: environment.makeTransport)
        while true {
            guard !flag.isSet else { return }
            let port: String
            do {
                // `make` opens nothing and sends nothing; only the resolved path is used here.
                port = try factory.make(station.connection, device: device).address
            } catch StationTransportError.scannerNotFound(let hint) {
                phase = .waitingForScanner(hint: hint)
                guard await Self.waitUnlessStopped(environment.portPollInterval, flag: flag) else { return }
                continue
            } catch {
                // `.notSupportedOnThisDevice` (USB serial on iOS); `.missingHost` can't come from a
                // USB connection.
                await closeResources()
                phase = .noAnswer(Self.notSupportedHereMessage)
                return
            }

            phase = .connecting
            let runner = StationRunner(station: station, device: device, log: log,
                                       recordingsRoot: environment.recordingsRoot,
                                       cooldownStore: environment.cooldownStore,
                                       transportFactory: factory,
                                       portPollInterval: environment.portPollInterval,
                                       audioConfig: environment.audioConfig,
                                       keepAliveInterval: environment.keepAliveInterval,
                                       lineInSources: environment.lineInSources)
            self.runner = runner
            // An input changed while this start waited (`lineInChanged(_:)`): the runner takes it.
            if lineInConfig != device.lineIn { await replaceLineIn(on: runner, with: lineInConfig) }
            startConsumers(runner)
            if loggingPaused { await runner.setLoggingPaused(true) }
            do {
                try await runner.start()
                return
            } catch StationTransportError.scannerNotFound {
                // The port left between its resolution and the runner's open: back to the wait,
                // the log and the lock kept.
                guard !flag.isSet else { return }
                await teardownRunner()
                guard !flag.isSet else { return }
                continue
            } catch {
                guard !flag.isSet else { return }
                await teardownRun()
                // No USB failure is retried by itself after a wake (design §13 Z): over USB a retry
                // would open the port again, which §13 H bounds while the runner waits, and a wake
                // normally finds the port missing (the wait above), not a silent scanner. Only
                // Reconnect opens the port again.
                lastFailureWasNoAnswer = false
                if let path = Self.busyPort(in: error) {
                    // Another program has the port: nothing was sent.
                    phase = .noAnswer(Self.busyPortMessage(path))
                } else if Self.isNoAnswer(error) {
                    phase = .noAnswer(Self.noAnswerUSBMessage(port: port))
                } else {
                    phase = .noAnswer(Self.usbFailureMessage(error))
                }
                return
            }
        }
    }

    /// Whether `error` is the scanner not answering on an open port: the `MDL` or `VER` timing
    /// out, or the client gone before it answered.
    private static func isNoAnswer(_ error: any Error) -> Bool {
        switch error as? ScannerClientError {
        case .timeout, .notConnected: return true
        default: return false
        }
    }

    /// The copy for a USB start that failed otherwise than by silence, a busy port or a missing
    /// one: the scanner answered but refused or garbled a command (as the station editor's Test
    /// Connection words it), or something before or after the scanner failed (the hit log, the
    /// runner), named as it is.
    static func usbFailureMessage(_ error: any Error) -> String {
        switch error {
        case ScannerClientError.rejected(let command, _):
            return "The scanner refused \(command)."
        case ScannerClientError.unexpectedResponse(let command):
            return "The scanner answered but didn't understand \(command)."
        default:
            return "Couldn't start the station: \(String(describing: error))"
        }
    }

    /// The port another program holds, when `error` is `SerialTransportError.busy` (macOS only:
    /// there is no serial transport elsewhere).
    private static func busyPort(in error: any Error) -> String? {
        #if os(macOS)
        if case SerialTransportError.busy(let path) = error { return path }
        #endif
        return nil
    }

    /// Sleeps `duration` in `portWaitTick` slices, looking at `flag` between them. False (at once)
    /// when a stop set the flag.
    private static func waitUnlessStopped(_ duration: Duration, flag: StopFlag) async -> Bool {
        let until = ContinuousClock.now + duration
        while ContinuousClock.now < until {
            if flag.isSet { return false }
            try? await Task.sleep(for: min(portWaitTick, ContinuousClock.now.duration(to: until)))
        }
        return !flag.isSet
    }

    // MARK: The scanner goes away

    /// Applies the current runner's `.disconnected(hint:)` (see the type's documentation). A
    /// line-in's relay, meter and playback are left running: they end only with the run. Awaited
    /// in place by the events consumer, so the `.connected` of a resume is applied only after the
    /// lost connection's loops have ended. One from a stale runner, or after a stop began, is
    /// ignored: the stop's teardown covers it.
    func scannerWentAway(hint: String, from source: StationRunner) async {
        guard let runner, source === runner, !stopFlag.isSet, isConnected else { return }
        let willResume = await runner.willResume
        guard self.runner === runner, !stopFlag.isSet, isConnected else { return }
        // First, before any await: no queued key or pending level change goes out, now or to the
        // scanner that comes back.
        stopKeyQueue()
        cancelPendingLevels()
        displayTask?.cancel()
        batteryTask?.cancel()
        await displayTask?.value  // no `STS` to a port that is gone, nor to the next connection's client
        displayTask = nil
        await stopBatteryLoop()  // nor a `GCS`
        guard self.runner === runner, !stopFlag.isSet, isConnected else { return }
        info = nil
        display = nil
        displayDirty = false
        lastKeyReply = nil
        if willResume {
            // Recent hits, warnings and the detected model stay; the menu and the quick keys detach
            // with the phase (the quick keys keep their lists and trees, read-only).
            phase = .waitingForScanner(hint: hint)
            // Nor a quick-key read: awaited here, in the events consumer, so the resume's `.connected`
            // (which attaches again) comes only after the lost connection's read has ended.
            await quickKeys.quiesce()
            await menu.quiesce()  // nor a menu read
        } else {
            // The connection never delivered a push (a rejected `PSI`): the runner idles until
            // stopped, so stop it. Not from this consumer, which the teardown drains: a task of
            // its own, which `performStop` awaits as it does a start in flight.
            phase = .stopping
            lossTask = Task { await self.loseScanner(hint: hint) }
        }
    }

    /// Tears the run down after a disconnect the runner won't resume from, and ends in
    /// `.noAnswer(hint)` unless a stop came in meanwhile (then that stop ends in `.stopped`).
    private func loseScanner(hint: String) async {
        await teardownRun()
        lossTask = nil
        guard !stopFlag.isSet else { return }
        lastFailureWasNoAnswer = false
        phase = .noAnswer(hint)
    }
}
