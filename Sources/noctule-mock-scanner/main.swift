// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import NoctuleKit
import NoctuleMockScanner
import Synchronization

// `noctule-mock-scanner`: a mock SDS200 on loopback, or (`--serial`) a mock scanner on a
// pseudo-terminal, for developing and testing without the real scanner. All the logic is in the
// NoctuleMockScanner library; this is the I/O shell.

@Sendable func printOut(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

@Sendable func printErr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

final class StopOnce: Sendable {
    private let started = Mutex(false)
    /// True for the first caller only.
    func begin() -> Bool { started.withLock { done in defer { done = true }; return !done } }
}

// The handler runs on a global queue, so it must not touch main.swift's top-level globals (they
// are @MainActor under Swift 6; see LESSONS.md). Everything it uses comes in as a parameter.
func installStopHandlers(once: StopOnce, stop: @escaping @Sendable () async -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { @Sendable in
            guard once.begin() else { return }
            Task { @Sendable in
                await stop()
                exit(0)
            }
        }
        source.resume()
        return source
    }
}

/// The UDP and RTSP mock: prints its ports, and `leaked-sessions=N` on Ctrl-C.
func startNetwork(_ arguments: MockScannerArguments, scenario: MockScenario, once: StopOnce) async -> [DispatchSourceSignal] {
    let mock = MockSDS200(scenario: scenario, faults: arguments.faults, options: arguments.options(log: printErr))
    let sources = installStopHandlers(once: once) {
        await mock.stop()
        let leaked = await mock.leakedSessions
        printOut("leaked-sessions=\(leaked.count)")
    }
    do {
        let ports = try await mock.start()
        printOut("noctule-mock-scanner: \(scenario.model) fw \(scenario.firmware), scenario \(arguments.scenario), "
            + "control udp 127.0.0.1:\(ports.udpPort), audio rtsp://127.0.0.1:\(ports.rtspPort)/au:scanner.au")
        printOut("udp-port=\(ports.udpPort)")
        printOut("rtsp-port=\(ports.rtspPort)")
        let after = arguments.cooldownAfter == .unclean ? " after an unclean close" : ""
        printErr("mock: reconnect cooldown \(arguments.cooldownSeconds) s\(after) (a quicker RTSP reconnect wedges the audio server); Ctrl-C to stop")
    } catch {
        printErr("noctule-mock-scanner: couldn't start: \(error)")
        exit(1)
    }
    return sources
}

/// The pseudo-terminal mock: prints `serial-port=PATH` first, and `active-subscriptions=N` on
/// Ctrl-C, after removing its link.
func startSerial(_ arguments: MockScannerArguments, scenario: MockScenario, once: StopOnce) async -> [DispatchSourceSignal] {
    let personality = arguments.personality
    let mock = MockSerialScanner(scenario: scenario, clock: .real(startingAt: arguments.startAt),
                                 personality: personality, linkPath: arguments.serialLink,
                                 lineOut: arguments.lineOut.map { ($0, arguments.lineOutChannel) },
                                 quickKeySetDelay: arguments.quickKeySetDelay,
                                 gltPageSize: arguments.gltPageSize ?? MockFavorites.defaultGLTPageSize)
    if arguments.verbose { await mock.setCommandObserver { printErr("control: \($0)") } }
    await mock.setLog(printErr)
    await mock.setFaults(arguments.faults)
    let sources = installStopHandlers(once: once) {
        await mock.stop()
        let active = await mock.activeSubscribers
        printOut("active-subscriptions=\(active)")
    }
    do {
        let path = try await mock.start()
        printOut("serial-port=\(path)")
        if let lineOut = arguments.lineOut {
            printOut("line-out=\(lineOut)")
            printErr("noctule-mock-scanner: headphone jack on \(lineOut), channel \(arguments.lineOutChannel.rawValue)"
                + (arguments.faults.lineOutSilent ? ", silent (hiss only)" : ""))
        }
        printErr("noctule-mock-scanner: \(personality.reportedModel) \(personality.firmware), scenario "
            + "\(arguments.scenario), serial port \(path); Ctrl-C to stop")
        if personality.pushLifetime != nil, !personality.keepAliveRevivesStoppedPushes {
            printErr("noctule-mock-scanner: a KAL after the pushes stopped is ignored (--kal-after-expiry ignored)")
        }
    } catch {
        printErr("noctule-mock-scanner: couldn't start: \(error)")
        exit(1)
    }
    return sources
}

let arguments: MockScannerArguments
do {
    arguments = try MockScannerArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch MockScannerArgumentsError.usage(let reason) {
    printErr("noctule-mock-scanner: \(reason)")
    exit(2)
} catch {
    printErr("noctule-mock-scanner: \(error)")
    printErr(MockScannerArguments.usage)
    exit(2)
}
if arguments.help {
    printOut(MockScannerArguments.usage)
    exit(0)
}

let scenario: MockScenario
do {
    scenario = try arguments.loadScenario()
} catch {
    printErr("noctule-mock-scanner: can't load scenario \(arguments.scenario): \(error)")
    exit(2)
}

let once = StopOnce()
// Kept for the life of the process: the signal sources stop the mock.
let stopSources = arguments.serial
    ? await startSerial(arguments, scenario: scenario, once: once)
    : await startNetwork(arguments, scenario: scenario, once: once)

while true {
    try? await Task.sleep(for: .seconds(3600))
}
