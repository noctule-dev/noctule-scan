// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Testing
import NoctuleMockScanner

/// A running `noctule` subprocess. Every wait is bounded and suspends; `kill()` (SIGKILL) is the
/// cleanup path.
private final class Noctule: Sendable {
    private let process: Subprocess
    let started = Date()

    init(_ arguments: [String]) throws {
        process = try Subprocess(try noctuleBinary(), arguments, environment: noctuleTestEnvironment)
    }

    /// Waits at most `seconds` for the process to exit. Returns false if it's still running.
    func waitForExit(within seconds: Double) async -> Bool { await process.waitForExit(within: seconds) }

    /// Waits at most `seconds` for `condition` on the stderr output so far.
    func waitForStderr(within seconds: Double, _ condition: (String) -> Bool) async -> Bool {
        await process.waitForStderr(within: seconds, condition)
    }

    func interrupt() { process.interrupt() }

    func kill() { process.kill() }

    /// After exit: status and both outputs (`Subprocess.finish()`: suspended, bounded, never
    /// `waitUntilExit()`, which held this suite past its time limit once (LESSONS.md 2026-11-12,
    /// 2026-11-20); -1 if the process is somehow still running).
    func finish() async -> (status: Int32, stdout: String, stderr: String) { await process.finish() }
}

/// A fake scanner audio server (RTSP plus RTP) on loopback, a temp directory, and the arguments
/// that point `noctule listen` at them with a short cooldown and a private cooldown store.
private struct ListenFixture {
    let server: FakeRTSPServer
    let sender: FakeRTPSender
    let rtspPort: UInt16
    let directory: URL
    let controlPort: UInt16

    static func make(running: Bool = true, script: FakeRTSPServer.Script = .scannerLike,
                     behavior: FakeRTSPServer.Behavior = .init()) async throws -> ListenFixture {
        let server = FakeRTSPServer(script: script, behavior: behavior)
        let sender = FakeRTPSender()
        await server.attach(sender)
        let port = try await server.start()
        if !running { await server.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "noctule-listen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ListenFixture(server: server, sender: sender, rtspPort: port, directory: directory,
                             controlPort: try silentUDPPort())
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
        let noctule = try Noctule(fixture.arguments(["--seconds", "4", "--record", wav.path]))
        _ = await noctule.waitForStderr(within: 15) { $0.contains("audio: streaming") }
        let streamingSeen = Date()
        let exited = await noctule.waitForExit(within: 20)
        let exitSeen = Date()
        // `--seconds` runs from when streaming starts. Each time here is seen at or after its
        // event, so the run measured from before the launch can only be longer than the real
        // one (a `listen` that stopped early still fails), and the run measured from when
        // "streaming" was seen can only be shorter, except for the lateness of seeing the exit
        // (a `listen` that ran on past its seconds still fails). The 3.5 s allows about 1 s for
        // listen's own shutdown (TEARDOWN, the 500 ms close linger, the drain) plus late wakeups
        // (up to 1.4 s on the CI runner); a doubled timer exits about 9 s after streaming and
        // still fails.
        let ran = exitSeen.timeIntervalSince(noctule.started)
        let ranSinceStreaming = exitSeen.timeIntervalSince(streamingSeen)
        noctule.kill()
        let result = await noctule.finish()
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
        // The recording holds the packets `listen` received, not a count a fixed window promises:
        // the fake sender paces 25 packets a second with its own sleeps, and a slow machine sends
        // fewer within `--seconds` (CI run 44958491347: 22 packets in 2 s, 14,080 bytes, against a
        // 25,600-byte floor). Each 320-byte μ-law packet records as 640 bytes, every received
        // packet is recorded (none is lost or reordered on loopback, and the shutdown drains the
        // chunks before the WAV is closed), and at least 10 prove a recording, not a stub.
        #expect(ran >= 4, "listen exited \(ran) s after its launch, before its --seconds 4")
        #expect(ranSinceStreaming < 7.5, "listen exited \(ranSinceStreaming) s after streaming began, well past its --seconds 4")
        let packets = result.stdout.split(separator: "\n").first { $0.hasPrefix("packets ") }
            .flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) }
        let received = try #require(packets, "no packets line: \(result.stdout)")
        #expect(received >= 10, "only \(received) packets in 4 s")
        #expect(dataSize == received * 640, "data size \(dataSize) for \(received) packets")
    }

    @Test func listenSigintTearsDown() async throws {
        let fixture = try await ListenFixture.make()
        let noctule = try Noctule(fixture.arguments([]))
        // Interrupted while streaming, which a fixed second after launch doesn't promise on a busy
        // machine (an interrupt before that is "stopped before streaming started", with no stats).
        let streaming = await noctule.waitForStderr(within: 15) { $0.contains("audio: streaming") }
        #expect(streaming)
        noctule.interrupt()
        let exited = await noctule.waitForExit(within: 10)
        noctule.kill()
        let result = await noctule.finish()
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

    /// The second signal must come while the close is under way. A fixed 150 ms after the first came
    /// too late under a one-thread pool, where the test's own sleep woke after the close had ended
    /// (sweep, 2026-11-22). The fake server now sends it the moment the TEARDOWN arrives, from its own
    /// queue, and holds the TEARDOWN's reply a second, so the close is certainly still under way.
    @Test func secondSigintKeepsClosing() async throws {
        let fixture = try await ListenFixture.make(behavior: .init(replyDelays: ["TEARDOWN": .seconds(1)]))
        let noctule = try Noctule(fixture.arguments([]))
        await fixture.server.setEventHandler { event in
            if event == .request(method: "TEARDOWN") { noctule.interrupt() }
        }
        let streaming = await noctule.waitForStderr(within: 15) { $0.contains("audio: streaming") }
        #expect(streaming)
        noctule.interrupt()
        let exited = await noctule.waitForExit(within: 10)
        noctule.kill()
        let result = await noctule.finish()
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
        let result = await noctule.finish()
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
        let result = await noctule.finish()
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
        let firstResult = await first.finish()

        let second = try Noctule(fixture.arguments(["--seconds", "1"], cooldown: "5"))
        let secondExited = await second.waitForExit(within: 20)
        second.kill()
        let secondResult = await second.finish()

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
        let a = await first.finish(), b = await second.finish()
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
