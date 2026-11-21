// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing

/// The built `noctule` executable, which sits in the build products directory next to the .xctest bundle.
func noctuleBinary() throws -> URL { try builtBinary("noctule") }

/// A built executable product (`noctule`, `noctule-mock-scanner`) in the build products directory.
func builtBinary(_ name: String) throws -> URL {
    var candidates = Bundle.allBundles.map(\.bundleURL) + [Bundle.main.bundleURL]
    candidates += CommandLine.arguments.map { URL(fileURLWithPath: $0) }
    for url in candidates {
        var dir = url
        while dir.pathComponents.count > 1 {
            if dir.pathExtension == "xctest" || dir.lastPathComponent == "debug" || dir.lastPathComponent == "release" {
                let binary = (dir.pathExtension == "xctest" ? dir.deletingLastPathComponent() : dir).appending(path: name)
                if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
            }
            dir = dir.deletingLastPathComponent()
        }
    }
    throw CocoaError(.fileNoSuchFile)
}

// Waiting in these tests: never block a thread.
//
// Swift Testing runs every test, synchronous or not, on Swift concurrency's cooperative pool, which
// has one thread per core and never grows: three on the CI runner. A test that waits by blocking its
// thread (`Thread.sleep`, `usleep`, `Process.waitUntilExit()`, `readDataToEndOfFile()`, a semaphore)
// takes one of those threads away from every other test in the process for as long as it waits,
// and with three such tests at once nothing else runs at all: not the in-process fakes
// (`FakeRTSPServer` is an actor), not another test's `await`, not even the time limits. On the
// runner that froze `NoctuleCLIIntegrationTests` for 35–44 s at the start of every run, and for
// 97–113 s on the slower runners of 2026-11-21, failing every real-time test (LESSONS.md
// 2026-11-21). So every wait here suspends: `Task.sleep` between polls, never a blocking call.
// `CooperativePoolTests` checks it. A blocking loop belongs on a thread of its own (a fake's loop,
// a dispatch queue), marked on its line `// off the cooperative pool`.
//
// The suites that run many tools (cut-release, the CI workflow's git repositories, the signing
// keychain, the icon and branding builds, and the disk images) are `.serialized`: once their waits
// stopped queueing them behind the pool's threads, all of them would otherwise start their tools at
// once, on three cores, beside the tests that time `noctule` and the mocks.

/// Polls `condition` every 20 ms for at most `seconds`, suspending (not blocking) between polls.
func waitFor(_ seconds: Double, _ condition: () throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try condition() { return true }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { break }  // cancelled: one last look
    }
    return try condition()
}

// Subprocess helpers shared by the tests that launch `noctule` and `noctule-mock-scanner`.

/// Collected output, kept as bytes until read (a pipe can split a character between two reads),
/// and whether each pipe has reached end of file. (`Mutex` is noncopyable, so closures capture
/// this box, not the Mutex.)
final class OutputBox: Sendable {
    private let bytes = Mutex<(out: Data, err: Data)>((Data(), Data()))
    private let ended = Mutex(0)
    func append(out data: Data) { bytes.withLock { $0.out.append(data) } }
    func append(err data: Data) { bytes.withLock { $0.err.append(data) } }
    var out: String { String(decoding: bytes.withLock { $0.out }, as: UTF8.self) }
    var err: String { String(decoding: bytes.withLock { $0.err }, as: UTF8.self) }
    func pipeEnded() { ended.withLock { $0 += 1 } }
    /// Both pipes have reached end of file: every process that held them (a script's own children
    /// included) has closed them, and all their output is in.
    var bothPipesEnded: Bool { ended.withLock { $0 >= 2 } }
}

/// A subprocess whose output is collected as it arrives.
final class Subprocess: @unchecked Sendable {
    let process: Process
    private let output = OutputBox()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    /// `environment` entries are added to (and override) this process's environment.
    /// `currentDirectory` is the child's working directory; nil inherits this process's (the
    /// repository root under `swift test`, where `config/dev-scanner.env` names the real scanner).
    init(_ binary: URL, _ arguments: [String], environment: [String: String] = [:],
         currentDirectory: URL? = nil, input: String? = nil) throws {
        process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let input {
            // Written whole and closed at once, so a script that reads finds the text, then end of file.
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        // At EOF a readability handler is called again and again with empty data, a busy loop
        // per pipe until it is removed; remove it at the first EOF (see LESSONS.md).
        // The handlers run on dispatch's own threads, not the cooperative pool, and the last call
        // (empty data) marks the end of the pipe, so `finish()` never has to read to the end itself.
        outPipe.fileHandleForReading.readabilityHandler = { [output] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; output.pipeEnded(); return }
            output.append(out: data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [output] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; output.pipeEnded(); return }
            output.append(err: data)
        }
        try process.run()
    }

    var stdout: String { output.out }
    var stderr: String { output.err }
    var isRunning: Bool { process.isRunning }

    /// Waits at most `seconds` for the process to exit, suspending between looks. Returns false if
    /// it's still running.
    func waitForExit(within seconds: Double) async -> Bool {
        await waitFor(seconds) { !process.isRunning }
    }

    /// Waits at most `seconds` for `condition` on the output so far.
    func waitForOutput(within seconds: Double, _ condition: (String) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(stdout) { return true }
            if !process.isRunning { return condition(stdout) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(stdout)
    }

    /// Waits at most `seconds` for `condition` on the stderr output so far.
    func waitForStderr(within seconds: Double, _ condition: (String) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(stderr) { return true }
            if !process.isRunning { return condition(stderr) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(stderr)
    }

    func interrupt() { send(SIGINT) }
    func send(_ signal: Int32) { if process.isRunning { Darwin.kill(process.processIdentifier, signal) } }
    func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    /// After exit: the status and all output. Waits (suspended) at most 10 s for the exit, and
    /// reports -1 if the process is somehow still running; then at most 10 s for both pipes to
    /// reach end of file, which a child the process left behind can hold off (whatever arrived by
    /// then is returned). Neither `Process.waitUntilExit()`, which called from a test's thread
    /// sometimes never returned although the child had exited (LESSONS.md 2026-11-12), nor
    /// `readDataToEndOfFile()` is used: both block a cooperative thread.
    func finish() async -> (status: Int32, stdout: String, stderr: String) {
        guard await waitForExit(within: 10) else {
            Issue.record("process \(process.processIdentifier) still running after SIGKILL")
            return (-1, stdout, stderr)
        }
        _ = await waitFor(10) { output.bothPipesEnded }
        return (process.terminationStatus, stdout, stderr)
    }
}

/// `taskpolicy`, which a test uses to run the mock throttled; part of macOS. A test that needs it
/// is enabled only where it is there.
let taskpolicyPath = "/usr/sbin/taskpolicy"

/// A running `noctule-mock-scanner`, with the ports it printed.
struct MockScanner {
    let process: Subprocess
    let udpPort: UInt16
    let rtspPort: UInt16

    /// `throttled` runs it under `taskpolicy -c utility`, whose timer coalescing wakes its timers
    /// late, as the CI runner does (a 5 ms `usleep` took about 40 ms, a 50 ms timer fired about
    /// every 140 ms). Not `-c background`, which coalesces more but is also starved of the CPU,
    /// not just late, while other work keeps the cores busy (LESSONS.md 2026-11-20).
    static func launch(_ arguments: [String], throttled: Bool = false) async throws -> MockScanner {
        let mock = try builtBinary("noctule-mock-scanner")
        let process = throttled
            ? try Subprocess(URL(fileURLWithPath: taskpolicyPath), ["-c", "utility", mock.path, "--verbose"] + arguments)
            : try Subprocess(mock, ["--verbose"] + arguments)
        let ready = await process.waitForOutput(within: 10) { $0.contains("udp-port=") && $0.contains("rtsp-port=") }
        func port(_ key: String) -> UInt16? {
            process.stdout.components(separatedBy: "\n").first { $0.hasPrefix(key) }
                .flatMap { UInt16($0.dropFirst(key.count)) }
        }
        guard ready, let udp = port("udp-port="), let rtsp = port("rtsp-port=") else {
            process.kill()
            let result = await process.finish()
            Issue.record("mock didn't start: status \(result.status), out \(result.stdout), err \(result.stderr)")
            throw CocoaError(.executableLoad)
        }
        return MockScanner(process: process, udpPort: udp, rtspPort: rtsp)
    }

    /// SIGINT, then wait (at most 10 s), then SIGKILL if needed.
    func shutdown() async -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
        process.interrupt()
        let exited = await process.waitForExit(within: 10)
        process.kill()
        let result = await process.finish()
        return (exited, result.status, result.stdout, result.stderr)
    }
}

/// A running `noctule-mock-scanner --model sds150 --serial` (or another handheld's `model`), with
/// the port it printed: its `--serial-link`, a path in the test's own temporary directory (never a
/// real port).
struct SerialMock {
    let process: Subprocess
    let port: String

    /// `throttled` runs it under `taskpolicy -c utility`, as `MockScanner.launch` does.
    static func launch(link: URL, model: String = "sds150", _ extra: [String] = [],
                       throttled: Bool = false) async throws -> SerialMock {
        let mock = try builtBinary("noctule-mock-scanner")
        let arguments = ["--model", model, "--serial", "--serial-link", link.path, "--verbose"] + extra
        let process = throttled
            ? try Subprocess(URL(fileURLWithPath: taskpolicyPath), ["-c", "utility", mock.path] + arguments)
            : try Subprocess(mock, arguments)
        let ready = await process.waitForOutput(within: 10) { $0.contains("serial-port=") && $0.hasSuffix("\n") }
        let first = process.stdout.components(separatedBy: "\n").first ?? ""
        guard ready, first.hasPrefix("serial-port=") else {
            process.kill()
            let result = await process.finish()
            Issue.record("mock didn't start: status \(result.status), out \(result.stdout), err \(result.stderr)")
            throw CocoaError(.executableLoad)
        }
        let port = String(first.dropFirst("serial-port=".count))
        #expect(port == link.path, "\(first)")
        return SerialMock(process: process, port: port)
    }

    /// Every command the mock has received so far (its `--verbose` log).
    var commands: [String] { Self.commands(in: process.stderr) }

    /// The commands in a `--verbose` log (`control: <command>` lines).
    static func commands(in log: String) -> [String] {
        log.components(separatedBy: "\n").filter { $0.hasPrefix("control: ") }
            .map { String($0.dropFirst("control: ".count)) }
    }

    /// SIGINT, then wait (at most 10 s), then SIGKILL if needed. Checks the mock's exit output:
    /// `serial-port=` first, then `active-subscriptions=0` (no `PSI` left running).
    @discardableResult
    func shutdown(sourceLocation: SourceLocation = #_sourceLocation) async -> (stdout: String, stderr: String) {
        process.interrupt()
        let exited = await process.waitForExit(within: 10)
        process.kill()
        let result = await process.finish()
        #expect(exited && result.status == 0, "\(result.stderr)", sourceLocation: sourceLocation)
        #expect(result.stdout.hasPrefix("serial-port=\(port)\n"), "\(result.stdout)", sourceLocation: sourceLocation)
        #expect(result.stdout.contains("active-subscriptions=0"), "\(result.stdout) \(result.stderr)",
                sourceLocation: sourceLocation)
        return (result.stdout, result.stderr)
    }
}

/// Runs `noctule` to completion (killed after `limit` seconds).
func noctule(_ arguments: [String], limit: Double = 20) async throws
    -> (exited: Bool, status: Int32, stdout: String, stderr: String) {
    let process = try Subprocess(try noctuleBinary(), arguments)
    let exited = await process.waitForExit(within: limit)
    process.kill()
    let result = await process.finish()
    return (exited, result.status, result.stdout, result.stderr)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "noctule-mock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Every read `noctule quick-keys` sends after `MDL` against the mock's default Favorites tree, sorted:
/// `GLT,FL`; for each list with a key its `SQK` and `GLT,SYS`; for each of its systems `GLT,DEPT`, and
/// `GLT,SITE` only for a system that isn't Conventional; and one `DQK` per keyed system of a keyed list.
let expectedQuickKeyReads: [String] = [
    "GLT,FL", "FQK",
    "SQK,0", "SQK,7", "SQK,1", "SQK,3", "SQK,12", "SQK,23", "SQK,41",
    "GLT,SYS,0", "GLT,SYS,1", "GLT,SYS,4", "GLT,SYS,6", "GLT,SYS,8", "GLT,SYS,12", "GLT,SYS,14",
    // Systems 110, 111, 101, 120, 121 are trunked; 112, 102, 122, 130, 140, 160, 170 are Conventional.
    "GLT,DEPT,110", "GLT,DEPT,111", "GLT,DEPT,112", "GLT,DEPT,101", "GLT,DEPT,102", "GLT,DEPT,120",
    "GLT,DEPT,121", "GLT,DEPT,122", "GLT,DEPT,130", "GLT,DEPT,140", "GLT,DEPT,160", "GLT,DEPT,170",
    "GLT,SITE,110", "GLT,SITE,111", "GLT,SITE,101", "GLT,SITE,120", "GLT,SITE,121",
    "DQK,0,0", "DQK,7,0", "DQK,7,1", "DQK,1,0", "DQK,1,1", "DQK,1,2", "DQK,3,0", "DQK,12,0", "DQK,23,4",
].sorted()
