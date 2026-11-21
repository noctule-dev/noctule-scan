// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Testing
import NoctuleMockScanner

/// A running `noctule` subprocess. Every wait is bounded; `kill()` (SIGKILL) is the cleanup path.
private final class Noctule: @unchecked Sendable {
    let process = Process()
    private let out = Pipe()
    private let err = Pipe()
    let started = Date()

    init(_ arguments: [String]) throws {
        process.executableURL = try noctuleBinary()
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    /// Waits at most `seconds` for the process to exit. Returns false if it's still running.
    func waitForExit(within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    func interrupt() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGINT) } }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    /// After exit: status and both outputs. Polls `isRunning` for at most 10 s (-1 if it is still
    /// running) instead of `waitUntilExit()`, which, called from a test's cooperative thread, can
    /// hang after the child has exited (LESSONS.md 2026-11-12); it held this suite past its time
    /// limit once in a background-priority sweep (LESSONS.md 2026-11-20).
    func finish() -> (status: Int32, stdout: String, stderr: String) {
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { return (-1, "", "") }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

/// A fake scanner audio server (RTSP plus RTP) on loopback, a temp directory, and the arguments
/// that point `noctule listen` at them with a short cooldown and a private cooldown store.
private struct ListenFixture {
    let server: FakeRTSPServer
    let sender: FakeRTPSender
    let rtspPort: UInt16
    let directory: URL
    let controlPort: UInt16

    static func make(running: Bool = true, script: FakeRTSPServer.Script = .scannerLike) async throws -> ListenFixture {
        let server = FakeRTSPServer(script: script)
        let sender = FakeRTPSender()
        await server.attach(sender)
        let port = try await server.start()
        if !running { await server.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "noctule-listen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ListenFixture(server: server, sender: sender, rtspPort: port, directory: directory,
                             controlPort: try deadPort())
    }

    func arguments(_ extra: [String], cooldown: String = "0.3") -> [String] {
        ["listen", "--no-play", "--host", "127.0.0.1", "--rtsp-port", String(rtspPort),
         // No control server: a failure probe (MDL) must time out, not reach something real.
         "--port", String(controlPort),
         "--cooldown-seconds", cooldown, "--cooldown-store", directory.appending(path: "cooldown.json").path] + extra
    }

    func cleanUp() async {
        await server.stop()
        await sender.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func le32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
}

private func le16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

@Suite(.timeLimit(.minutes(1))) struct ListenIntegrationTests {
    @Test func listenSecondsRecordsAndTearsDown() async throws {
        let fixture = try await ListenFixture.make()
        let wav = fixture.directory.appending(path: "out.wav")
        let noctule = try Noctule(fixture.arguments(["--seconds", "2", "--record", wav.path]))
        let exited = await noctule.waitForExit(within: 15)
        noctule.kill()
        let result = noctule.finish()
        let methods = await fixture.server.receivedMethods
        defer { Task { await fixture.cleanUp() } }
        #expect(exited)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stderr.contains("audio: streaming"))
        #expect(result.stdout.contains("packets "))
        #expect(methods.last == "TEARDOWN", "\(methods)")
        #expect(methods.filter { $0 == "TEARDOWN" }.count == 1)

        let data = try Data(contentsOf: wav)
        try #require(data.count >= 44)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(le16(data, at: 20) == 1 && le16(data, at: 22) == 1)
        #expect(le32(data, at: 24) == 8000 && le16(data, at: 34) == 16)
        let dataSize = Int(le32(data, at: 40))
        #expect(dataSize == data.count - 44)
        #expect(Int(le32(data, at: 4)) == dataSize + 36)
        #expect((25_600...38_400).contains(dataSize), "data size \(dataSize)")
    }

    @Test func listenSigintTearsDown() async throws {
        let fixture = try await ListenFixture.make()
        let noctule = try Noctule(fixture.arguments([]))
        try await Task.sleep(for: .seconds(1))
        noctule.interrupt()
        let exited = await noctule.waitForExit(within: 10)
        noctule.kill()
        let result = noctule.finish()
        let methods = await fixture.server.receivedMethods
        await fixture.cleanUp()
        #expect(exited)
        #expect(result.status == 130, "\(result.stderr)")
        #expect(methods.last == "TEARDOWN", "\(methods)")
        #expect(methods.filter { $0 == "TEARDOWN" }.count == 1)
        let lowered = result.stderr.lowercased()
        #expect(!lowered.contains("error") && !lowered.contains("failed") && !lowered.contains("fatal"), "\(result.stderr)")
        #expect(result.stdout.contains("packets "))
    }

    @Test func secondSigintKeepsClosing() async throws {
        let fixture = try await ListenFixture.make()
        let noctule = try Noctule(fixture.arguments([]))
        try await Task.sleep(for: .seconds(1))
        noctule.interrupt()
        try await Task.sleep(for: .milliseconds(150))
        noctule.interrupt()
        let exited = await noctule.waitForExit(within: 10)
        noctule.kill()
        let result = noctule.finish()
        let methods = await fixture.server.receivedMethods
        await fixture.cleanUp()
        #expect(exited)
        #expect(result.status == 130, "\(result.stderr)")
        #expect(result.stderr.contains("audio: still closing the scanner session…"), "\(result.stderr)")
        #expect(methods.last == "TEARDOWN", "\(methods)")
        #expect(result.stdout.contains("packets "))
    }

    @Test func listenFailsCleanlyWhenRTSPDown() async throws {
        let fixture = try await ListenFixture.make(running: false)
        let noctule = try Noctule(fixture.arguments([]))
        let exited = await noctule.waitForExit(within: 5)
        let seconds = Date().timeIntervalSince(noctule.started)
        noctule.kill()
        let result = noctule.finish()
        await fixture.cleanUp()
        #expect(exited)
        #expect(seconds < 5)
        #expect(result.status == 1, "\(result.stderr)")
        #expect(result.stderr.contains(
            "audio: failed: couldn't connect to the scanner's audio server at 127.0.0.1:\(fixture.rtspPort)"),
            "\(result.stderr)")
        // Control doesn't answer either (nothing on the UDP port), so the probe says power-cycle.
        #expect(result.stderr.contains("audio: Scanner not responding on the network. Power-cycle it."))
        #expect(!result.stderr.contains("Fatal"))
    }

    /// A TEARDOWN the server never answers is reported, not silently counted as done.
    @Test func listenReportsUnansweredTeardown() async throws {
        let fixture = try await ListenFixture.make(script: .scannerLike.silence(method: "TEARDOWN"))
        let noctule = try Noctule(fixture.arguments(["--seconds", "1"]))
        let exited = await noctule.waitForExit(within: 15)
        noctule.kill()
        let result = noctule.finish()
        let methods = await fixture.server.receivedMethods
        await fixture.cleanUp()
        #expect(exited)
        #expect(methods.filter { $0 == "TEARDOWN" }.count == 1, "\(methods)")
        #expect(result.stderr.contains("audio: 1 session(s) could not be closed; the scanner may need a restart"),
                "\(result.stderr)")
    }

    /// The second run starts inside the first's cooldown, waits out what is left of it, and says
    /// so. The cooldown is 5 s, so the second run's start (late on a throttled runner: with 1 s it
    /// once came after the cooldown had passed, LESSONS.md 2026-11-20) always falls inside it.
    @Test func listenWaitsOutCooldown() async throws {
        let fixture = try await ListenFixture.make()
        let first = try Noctule(fixture.arguments(["--seconds", "1"], cooldown: "5"))
        let firstExited = await first.waitForExit(within: 10)
        first.kill()
        let firstResult = first.finish()

        let second = try Noctule(fixture.arguments(["--seconds", "1"], cooldown: "5"))
        let secondExited = await second.waitForExit(within: 20)
        second.kill()
        let secondResult = second.finish()

        let accepted = await fixture.server.connectionsAcceptedAt
        let ends = await fixture.server.connectionEnds
        let methods = await fixture.server.receivedMethods
        await fixture.cleanUp()

        #expect(firstExited && secondExited)
        #expect(firstResult.status == 0, "\(firstResult.stderr)")
        #expect(secondResult.status == 0, "\(secondResult.stderr)")
        #expect(!firstResult.stderr.contains("waiting"))
        // What is left of the 5 s, rounded up.
        #expect(secondResult.stderr.contains(/audio: waiting [1-5] s before reconnecting \(scanner cooldown\)/),
                "\(secondResult.stderr)")
        #expect(methods.filter { $0 == "TEARDOWN" }.count == 2)
        try #require(accepted.count == 2 && !ends.isEmpty, "accepted \(accepted.count), ended \(ends.count)")
        let gap = ends[0].at.duration(to: accepted[1])
        #expect(gap >= .seconds(5), "gap \(gap)")
    }

    /// Two `listen` runs waiting out the same cooldown wake at the same moment. The store's
    /// atomic claim lets only one connect; the other waits until that connection has closed and
    /// the cooldown has passed again (final review I1).
    @Test func twoListensNeverConnectAtOnce() async throws {
        let fixture = try await ListenFixture.make()
        defer { Task { await fixture.cleanUp() } }
        let closed = Date().addingTimeInterval(-1)
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seed = "{\"127.0.0.1\":{\"lastClosed\":\"\(format.string(from: closed))\"}}"
        try Data(seed.utf8).write(to: fixture.directory.appending(path: "cooldown.json"))

        let first = try Noctule(fixture.arguments(["--seconds", "2"], cooldown: "2"))
        let second = try Noctule(fixture.arguments(["--seconds", "2"], cooldown: "2"))
        let exitedA = await first.waitForExit(within: 30)
        let exitedB = await second.waitForExit(within: 30)
        first.kill(); second.kill()
        let a = first.finish(), b = second.finish()
        let accepted = await fixture.server.connectionsAcceptedAt
        let ends = await fixture.server.connectionEnds
        #expect(exitedA && exitedB)
        #expect(a.status == 0, "\(a.stderr)")
        #expect(b.status == 0, "\(b.stderr)")
        try #require(accepted.count == 2, "accepted \(accepted.count): \(a.stderr) | \(b.stderr)")
        // The second connection opened only after the first closed, plus the cooldown.
        let firstEnd = try #require(ends.first?.at)
        #expect(firstEnd < accepted[1], "the connections overlapped")
        let gap = firstEnd.duration(to: accepted[1])
        #expect(gap >= .seconds(1.9), "gap \(gap)")
        #expect(await fixture.server.leakedSessions.isEmpty)
    }
}
