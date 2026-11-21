// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleMockScanner
@testable import NoctuleKit

// AudioSession against a loopback FakeRTSPServer with an attached FakeRTPSender (25 packets/s of
// 320-byte PCMU, like the SDS200). Every wait is bounded; every test stops the session, the
// sender, and the server on every path.

private struct TimedOut: Error {}

/// Runs `body`, failing with `TimedOut` after `limit` so no test can hang.
private func within<T: Sendable>(
    _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimedOut()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimedOut() }
        return first
    }
}

/// Polls `condition` every 10 ms until it holds, or throws `TimedOut` after `limit`.
private func eventually(_ limit: Duration = .seconds(3),
                        _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await within(limit) {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Takes the next `count` chunks from `iterator` (bounded by `limit`).
private func take(_ count: Int, from chunks: AsyncStream<AudioChunk>, limit: Duration = .seconds(3)) async throws -> [AudioChunk] {
    try await within(limit) {
        var out: [AudioChunk] = []
        for await chunk in chunks {
            out.append(chunk)
            if out.count == count { break }
        }
        return out
    }
}

/// Drains `chunks` until it finishes (bounded by `limit`); returns how many arrived.
private func drainToEnd(_ chunks: AsyncStream<AudioChunk>, limit: Duration = .seconds(3)) async throws -> Int {
    try await within(limit) {
        var count = 0
        for await _ in chunks { count += 1 }
        return count
    }
}

/// Records every state the session publishes.
private final class StateLog: Sendable {
    private let log = Mutex<[AudioSessionState]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ session: AudioSession) {
        let states = session.states
        task.withLock { $0 = Task { [self] in for await state in states { self.append(state) } } }
    }

    private func append(_ state: AudioSessionState) {
        log.withLock { $0.append(state) }
    }

    var all: [AudioSessionState] { log.withLock { $0 } }
    func cancel() { task.withLock { $0?.cancel() } }
}

/// Every RTSPClient the session builds (closeLinger zero, for fast tests).
private final class Clients: Sendable {
    private let list = Mutex<[RTSPClient]>([])
    var all: [RTSPClient] { list.withLock { $0 } }

    var factory: @Sendable (RTSPClientOptions) -> RTSPClient {
        { [self] options in
            let client = RTSPClient(host: options.host, port: options.port, requestTimeout: options.requestTimeout,
                                    cooldownPolicy: options.cooldownPolicy,
                                    cooldownStore: options.cooldownStore, closeLinger: .zero)
            self.list.withLock { $0.append(client) }
            return client
        }
    }
}

private let cooldown: Duration = .milliseconds(300)

private func testConfig(keepalive: Duration = .seconds(15), stall: Duration? = nil,
                        maxAttempts: Int = 2, reconnectCooldown: Duration = cooldown,
                        rtpCloseDelay: Duration = .milliseconds(50)) -> AudioSessionConfig {
    AudioSessionConfig(keepaliveInterval: keepalive, stallTimeout: stall, maxRecoveryAttempts: maxAttempts,
                       reconnectCooldown: reconnectCooldown, requestTimeout: .seconds(1),
                       cooldownStore: InMemoryRTSPCooldownStore(), rtpCloseDelay: rtpCloseDelay)
}

private struct Rig: Sendable {
    let server: FakeRTSPServer
    let sender: FakeRTPSender
    let session: AudioSession
    let clients: Clients
    let states: StateLog
}

/// Starts a fake server with an attached sender and an AudioSession for it, runs `body`
/// (bounded by `limit`), then always stops the session, sender, and server.
private func withSession(
    _ script: FakeRTSPServer.Script = .scannerLike,
    config: AudioSessionConfig = testConfig(),
    sdp: String = FakeRTSPServer.describeSDP,
    limit: Duration = .seconds(8),
    senderInterval: Duration = .milliseconds(40),
    _ body: @escaping @Sendable (Rig) async throws -> Void
) async throws {
    let server = FakeRTSPServer(script: script, uniqueSessionIDs: true, sdp: sdp)
    let sender = FakeRTPSender(interval: senderInterval)
    await server.attach(sender)
    let port = try await server.start()
    let clients = Clients()
    let session = AudioSession(host: "127.0.0.1", rtspPort: port, config: config, makeRTSP: clients.factory)
    let states = StateLog(session)
    var failure: (any Error)?
    do {
        try await within(limit) { try await body(Rig(server: server, sender: sender, session: session,
                                                      clients: clients, states: states)) }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await session.stop() }
    states.cancel()
    await sender.shutdown()
    await server.stop()
    if let failure { throw failure }
}

private func isRecovering(_ state: AudioSessionState) -> Bool {
    if case .recovering = state { return true }
    return false
}

// MARK: Tests

@Test func streamsDecodedAudio() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()
        #expect(await rig.session.state == .streaming)
        let got = try await take(5, from: chunks)
        try #require(got.count == 5)
        for chunk in got {
            #expect(chunk.samples.count == 320)
            let payload = FakeRTPSender.payload(sequence: chunk.sequence)
            #expect(chunk.samples.first == MuLaw.decode(payload[0]))
            #expect(chunk.samples == MuLaw.decode(payload))
        }
        #expect(got[1].sequence == got[0].sequence &+ 1)
        #expect(got[1].rtpTimestamp == got[0].rtpTimestamp &+ 320)
        let stats = await rig.session.stats
        #expect(stats.packets >= 5)
        #expect(stats.lost == 0)

        await rig.session.stop()
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
        #expect(await rig.server.receivedMethods.prefix(4) == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY"])
        #expect(await rig.session.state == .stopped)
        _ = try await drainToEnd(chunks)
        try await eventually { rig.states.all.contains(.stopped) }
        #expect(rig.states.all.contains(.starting))
        #expect(rig.states.all.last == .stopped)
    }
}

@Test func stopBeforePlayTearsDown() async throws {
    try await withSession(.scannerLike.silence(method: "PLAY")) { rig in
        let starter = Task { try await rig.session.start() }
        try await eventually { await rig.server.receivedMethods.contains("PLAY") }
        #expect(await rig.session.state == .starting)
        let began = ContinuousClock.now
        try await within(.seconds(2)) { await rig.session.stop() }
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
        #expect(await rig.session.state == .stopped)
        let outcome = await starter.result
        #expect(throws: (any Error).self) { try outcome.get() }
    }
}

@Test func recoveryRespectsCooldown() async throws {
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true),
                          config: testConfig(keepalive: .milliseconds(200))) { rig in
        let chunks = try await rig.session.start()  // held: dropping it stops the session
        defer { withExtendedLifetime(chunks) {} }
        try await eventually { await isRecovering(rig.session.state) }
        // The next attempt's time is published while waiting out the cooldown.
        try await eventually {
            let state = await rig.session.state
            return await rig.session.nextAttemptAt != nil || state == .streaming
        }
        try await eventually { await rig.session.state == .streaming && rig.states.all.filter { $0 == .streaming }.count == 2 }
        let accepted = await rig.server.connectionsAcceptedAt
        let ends = await rig.server.connectionEnds
        try #require(accepted.count == 2)
        try #require(ends.count >= 1)
        // The second connection opened at least the cooldown after the first one closed.
        #expect(accepted[1] - ends[0].at >= cooldown - .milliseconds(20))
        #expect(accepted[1] - accepted[0] >= cooldown)
        #expect(await rig.session.nextAttemptAt == nil)
    }
}

@Test func keepaliveFailureRecovers() async throws {
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true),
                          config: testConfig(keepalive: .milliseconds(200))) { rig in
        let chunks = try await rig.session.start()
        _ = try await take(2, from: chunks)
        try await eventually { rig.states.all.filter { $0 == .streaming }.count == 2 }
        let recoveredAt = ContinuousClock.now
        let sequence = rig.states.all.filter { $0 == .streaming || isRecovering($0) }
        #expect(sequence == [.streaming, .recovering(attempt: 1), .streaming])
        let issued = await rig.server.issuedSessionIDs
        try #require(issued.count == 2)
        #expect(await rig.server.teardownSessionIDs == [issued[0]])
        // Chunks continue on the same stream after the recovery.
        let after = try await within(.seconds(3)) {
            for await chunk in chunks where chunk.receivedAt > recoveredAt { return chunk }
            throw TimedOut()
        }
        #expect(after.samples.count == 320)
        #expect(await rig.session.stats.recoveries == 1)
        #expect(await rig.session.unreleasedSessions.isEmpty)
        await rig.session.stop()
        #expect(await rig.server.teardownSessionIDs == issued)
    }
}

@Test func stallRecoversWhenConfigured() async throws {
    try await withSession(config: testConfig(stall: .milliseconds(300))) { rig in
        let chunks = try await rig.session.start()
        _ = try await take(3, from: chunks)
        let firstSSRC = await rig.sender.ssrc
        await rig.sender.pause()
        try await eventually { await isRecovering(rig.session.state) }
        await rig.sender.resume()
        try await eventually { rig.states.all.filter { $0 == .streaming }.count == 2 }
        let recoveredAt = ContinuousClock.now
        #expect(await rig.sender.ssrc != firstSSRC)
        let after = try await within(.seconds(3)) {
            for await chunk in chunks where chunk.receivedAt > recoveredAt { return chunk }
            throw TimedOut()
        }
        #expect(after.samples.count == 320)
        let stats = await rig.session.stats
        #expect(stats.recoveries == 1)
        #expect(stats.lost == 0)
        #expect(await rig.server.teardownSessionIDs.count == 1)
    }
}

@Test func stallIsIgnoredByDefault() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()
        _ = try await take(2, from: chunks)
        await rig.sender.pause()
        try await Task.sleep(for: .milliseconds(800))
        #expect(await rig.session.state == .streaming)
        #expect(await rig.server.acceptedConnections == 1)
    }
}

@Test func gaveUpAfterMaxAttempts() async throws {
    try await withSession(config: testConfig(keepalive: .milliseconds(200))) { rig in
        let chunks = try await rig.session.start()
        _ = try await take(2, from: chunks)
        await rig.server.replaceScript(
            .scannerLike.status(method: "GET_PARAMETER", code: 454, once: true).status(method: "SETUP", code: 503))
        try await eventually(.seconds(6)) { await rig.session.state == .failed(AudioSession.gaveUpMessage) }
        #expect(AudioSession.gaveUpMessage == "Scanner audio isn't responding. Power-cycle the scanner if it doesn't recover.")
        _ = try await drainToEnd(chunks)
        // The StateLog consumer is asynchronous: wait for it to observe the final state.
        try await eventually { rig.states.all.last == .failed(AudioSession.gaveUpMessage) }
        let recoveries = rig.states.all.filter(isRecovering)
        #expect(recoveries == [.recovering(attempt: 1), .recovering(attempt: 2)])
        #expect(rig.states.all.last == .failed(AudioSession.gaveUpMessage))
        #expect(await rig.server.acceptedConnections == 3)
        // Every session the server issued was torn down exactly once.
        let issued = await rig.server.issuedSessionIDs
        #expect(issued.count == 1)
        #expect(await rig.server.teardownSessionIDs == issued)
        #expect(await rig.session.stats.recoveries == 0)
    }
}

@Test func consumerCancellationStops() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()
        let consumer = Task {
            var count = 0
            for await _ in chunks { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(150))
        consumer.cancel()
        try await eventually(.seconds(1)) { await rig.server.receivedMethods.contains("TEARDOWN") }
        try await eventually(.seconds(2)) { await rig.session.state == .stopped }
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
    }
}

@Test func wrongPayloadTypeCounted() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()
        _ = try await take(1, from: chunks)
        await rig.sender.setPayloadType(8)
        try await eventually { await rig.session.stats.droppedWrongPayloadType >= 3 }
        await rig.sender.sendGarbage()
        try await eventually { await rig.session.stats.droppedMalformed >= 1 }
        #expect(await rig.session.state == .streaming)
    }
}

@Test func chunkReportsGapAndSSRC() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()
        var iterator = chunks.makeAsyncIterator()
        func nextChunk() async throws -> AudioChunk {
            // The session is bounded by withSession's limit; a finished stream is a failure.
            guard let chunk = await iterator.next() else { throw TimedOut() }
            return chunk
        }
        let first = try await nextChunk()
        let ssrc = await rig.sender.ssrc
        #expect(first.ssrc == ssrc)
        #expect(first.ssrc != 0)
        #expect(first.lostBefore == 0)
        #expect(!first.discontinuity)

        await rig.sender.skip(2)
        var previous = first
        var gapChunk: AudioChunk?
        for _ in 0..<50 {
            let chunk = try await nextChunk()
            if chunk.sequence != previous.sequence &+ 1 { gapChunk = chunk; break }
            #expect(chunk.lostBefore == 0)
            previous = chunk
        }
        let gap = try #require(gapChunk)
        #expect(gap.sequence == previous.sequence &+ 3)
        #expect(gap.lostBefore == 2)
        #expect(gap.ssrc == ssrc)

        await rig.sender.changeSSRC()
        var changed: AudioChunk?
        for _ in 0..<50 {
            let chunk = try await nextChunk()
            if chunk.ssrc != ssrc { changed = chunk; break }
        }
        let fresh = try #require(changed)
        #expect(fresh.ssrc == (await rig.sender.ssrc))
        // A new SSRC starts its sequence afresh: a random jump is not loss, but it is a discontinuity.
        #expect(fresh.lostBefore == 0)
        #expect(fresh.discontinuity)
        #expect(await rig.session.stats.lost == 2)
    }
}

@Test func reorderedPacketIsNotYielded() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()
        var iterator = chunks.makeAsyncIterator()
        func nextChunk() async throws -> AudioChunk {
            guard let chunk = await iterator.next() else { throw TimedOut() }
            return chunk
        }
        var previous = try await nextChunk()
        // The sender swaps its next two packets: the receiver sees n, n+2, n+1 (late), n+3.
        await rig.sender.reorderNext()
        var gapChunk: AudioChunk?
        for _ in 0..<50 {
            let chunk = try await nextChunk()
            if chunk.sequence != previous.sequence &+ 1 { gapChunk = chunk; break }
            #expect(chunk.lostBefore == 0)
            previous = chunk
        }
        let gap = try #require(gapChunk)
        #expect(gap.sequence == previous.sequence &+ 2)
        #expect(gap.lostBefore == 1)
        // The late packet (previous + 1) is not yielded: the next chunk is gap + 1.
        let after = try await nextChunk()
        #expect(after.sequence == gap.sequence &+ 1)
        #expect(after.lostBefore == 0)
        let stats = await rig.session.stats
        #expect(stats.reordered == 1)
        #expect(stats.lost == 0)
    }
}

/// Reads chunks until one has sequence `last` (bounded by withSession's limit).
private func chunks(through last: UInt16, from chunks: AsyncStream<AudioChunk>) async -> [AudioChunk] {
    var out: [AudioChunk] = []
    for await chunk in chunks {
        out.append(chunk)
        if chunk.sequence == last { break }
    }
    return out
}

@Test func stalePacketIsNotYielded() async throws {
    try await withSession { rig in
        let stream = try await rig.session.start()
        _ = try await take(1, from: stream)
        await rig.sender.pause()
        // 0...80 in order, then 10 (70 behind the highest), then 81.
        let base = await rig.sender.sendNow(offsets: Array(0...80) + [10, 81])
        let got = await chunks(through: base &+ 81, from: stream)
        let window = got.filter { UInt16(truncatingIfNeeded: Int($0.sequence &- base)) <= 81 }
        #expect(window.count == 82)
        #expect(window.filter { $0.sequence == base &+ 10 }.count == 1)
        let last = try #require(got.last)
        #expect(last.sequence == base &+ 81)
        #expect(last.lostBefore == 0)
        #expect(got.allSatisfy { !$0.discontinuity })
        let stats = await rig.session.stats
        #expect(stats.stale == 1)
        #expect(stats.lost == 0)
        #expect(stats.playoutGaps == 0)
    }
}

@Test func playoutGapsCountWhatTheConsumerMissed() async throws {
    try await withSession { rig in
        let stream = try await rig.session.start()
        _ = try await take(1, from: stream)
        await rig.sender.pause()
        // 0, 1, 4 (2 and 3 missing), 2 (late: not yielded), 5, 6.
        let base = await rig.sender.sendNow(offsets: [0, 1, 4, 2, 5, 6])
        let got = await chunks(through: base &+ 6, from: stream)
        let tail = got.suffix(5).map { Int($0.sequence &- base) }
        #expect(tail == [0, 1, 4, 5, 6])
        #expect(got.first { $0.sequence == base &+ 4 }?.lostBefore == 2)
        let stats = await rig.session.stats
        #expect(stats.playoutGaps == 2)  // what the audio is missing: 2 and 3
        #expect(stats.lost == 1)         // net network loss: 2 arrived late
        #expect(stats.reordered == 1)
    }
}

@Test func forwardJumpIsADiscontinuity() async throws {
    try await withSession { rig in
        let stream = try await rig.session.start()
        _ = try await take(1, from: stream)
        await rig.sender.pause()
        let base = await rig.sender.sendNow(offsets: [0, 4000, 4001])
        let got = await chunks(through: base &+ 4001, from: stream)
        let jump = try #require(got.first { $0.sequence == base &+ 4000 })
        #expect(jump.discontinuity)
        #expect(jump.lostBefore == 0)
        #expect(got.last?.discontinuity == false)
        #expect(await rig.session.stats.playoutGaps == 0)
    }
}

@Test func droppedChunksCounted() async throws {
    // 2 ms per packet, so 300 packets take about 0.6 s; nothing consumes the stream.
    try await withSession(senderInterval: .milliseconds(2)) { rig in
        let chunks = try await rig.session.start()  // held but never read
        defer { withExtendedLifetime(chunks) {} }
        try await eventually(.seconds(5)) { await rig.session.stats.packets >= 300 }
        let stats = await rig.session.stats
        #expect(stats.droppedChunks >= 50)
        // bufferingNewest(250) keeps 250 and drops the rest of what was yielded.
        #expect(stats.droppedChunks <= stats.packets - 250)
    }
}

@Test func stopIsIdempotentAndConcurrentSafe() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()
        _ = try await take(1, from: chunks)
        async let first: Void = rig.session.stop()
        async let second: Void = rig.session.stop()
        _ = await (first, second)
        await rig.session.stop()
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
        #expect(await rig.session.state == .stopped)
        try await eventually { rig.states.all.contains(.stopped) }
        #expect(rig.states.all.filter { $0 == .stopped }.count == 1)
    }
}

@Test func preemptedDoesNotTriggerRecovery() async throws {
    try await withSession(.scannerLike.silence(method: "GET_PARAMETER"),
                          config: testConfig(keepalive: .milliseconds(200))) { rig in
        let chunks = try await rig.session.start()  // held: dropping it stops the session
        defer { withExtendedLifetime(chunks) {} }
        try await eventually { await rig.server.receivedMethods.contains("GET_PARAMETER") }
        // Someone tears the session down under the in-flight keepalive: it fails with .preempted.
        let client = try #require(rig.clients.all.first)
        await client.teardown()
        try await eventually { await rig.session.state == .stopped }
        try await Task.sleep(for: cooldown + .milliseconds(200))
        #expect(!rig.states.all.contains(where: isRecovering))
        #expect(await rig.server.acceptedConnections == 1)
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
    }
}

@Test func unreleasedSessionsSurfaceThenAreRetried() async throws {
    // The server drops the connection on a keepalive, so the old session's TEARDOWN would need a
    // reconnect inside the cooldown, which RTSPClient refuses: the id is unreleased. Recovery's
    // next connection (after the cooldown) tears it down first, before OPTIONS.
    try await withSession(.scannerLike.closeOn(method: "GET_PARAMETER", once: true),
                          config: testConfig(keepalive: .milliseconds(200))) { rig in
        let chunks = try await rig.session.start()  // held: dropping it stops the session
        defer { withExtendedLifetime(chunks) {} }
        let issued = try await within(.seconds(3)) { () -> [String] in
            while true {
                let ids = await rig.server.issuedSessionIDs
                if !ids.isEmpty { return ids }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await eventually { await rig.session.unreleasedSessions.count == 1 }
        #expect(await rig.session.unreleasedSessions == [issued[0]])
        try await eventually { rig.states.all.filter { $0 == .streaming }.count == 2 }
        #expect(await rig.server.acceptedConnections == 2)
        #expect(await rig.session.unreleasedSessions.isEmpty)
        let methods = await rig.server.receivedMethods
        // The recovery connection: OPTIONS (exactly once), TEARDOWN <old id>, DESCRIBE, SETUP, PLAY.
        // A TEARDOWN is never the first request on a connection.
        #expect(Array(methods.prefix(10)) == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "GET_PARAMETER",
                                             "OPTIONS", "TEARDOWN", "DESCRIBE", "SETUP", "PLAY"])
        #expect(methods.filter { $0 == "OPTIONS" }.count == 2)  // once per connection
        #expect(await rig.server.teardownSessionIDs == [issued[0]])
    }
}

@Test func unansweredTeardownDuringRecoveryIsRetriedOnTheNextConnection() async throws {
    // A keepalive fails, so recovery closes the client; that TEARDOWN times out on the still-open
    // connection. The id must not count as released: the next connection (after the cooldown)
    // sends OPTIONS, TEARDOWN <old id>, then DESCRIBE, SETUP, PLAY, and the id is cleared.
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true)
                            .silence(method: "TEARDOWN", once: true),
                          config: testConfig(keepalive: .milliseconds(200))) { rig in
        let chunks = try await rig.session.start()  // held: dropping it stops the session
        defer { withExtendedLifetime(chunks) {} }
        try await eventually(.seconds(6)) { rig.states.all.filter { $0 == .streaming }.count == 2 }
        let issued = await rig.server.issuedSessionIDs
        try #require(issued.count == 2)
        let first = try #require(rig.clients.all.first)
        #expect(await first.unreleasedSessions == [issued[0]])
        #expect(await rig.session.unreleasedSessions.isEmpty)
        #expect(await rig.server.acceptedConnections == 2)
        let methods = await rig.server.receivedMethods
        #expect(Array(methods.prefix(11)) == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "GET_PARAMETER", "TEARDOWN",
                                             "OPTIONS", "TEARDOWN", "DESCRIBE", "SETUP", "PLAY"], "\(methods)")
        #expect(await rig.server.teardownSessionIDs == [issued[0], issued[0]])
    }
}

@Test func startTwiceThrows() async throws {
    try await withSession { rig in
        let chunks = try await rig.session.start()  // held: dropping it stops the session
        defer { withExtendedLifetime(chunks) {} }
        await #expect(throws: AudioSessionError.alreadyStarted) { _ = try await rig.session.start() }
    }
}

@Test func droppingTheChunkStreamStops() async throws {
    try await withSession { rig in
        do {
            _ = try await rig.session.start()  // not kept: AsyncStream terminates as cancelled
        }
        try await eventually(.seconds(2)) { await rig.session.state == .stopped }
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
    }
}

@Test func rejectsNonPCMUAtDescribe() async throws {
    let pcma = FakeRTSPServer.describeSDP.replacingOccurrences(of: "RTP/AVP 0", with: "RTP/AVP 8")
    try await withSession(sdp: pcma) { rig in
        await #expect(throws: AudioSessionError.unsupportedPayloadType(8)) { _ = try await rig.session.start() }
        guard case .failed = await rig.session.state else {
            Issue.record("state is \(await rig.session.state)")
            return
        }
        #expect(await rig.server.receivedMethods == ["OPTIONS", "DESCRIBE"])
        try await eventually { await rig.server.connectionEnds.count == 1 }
        #expect(await rig.server.acceptedConnections == 1)
    }
}

@Test func stopClosesRTSPBeforeTheReceiver() async throws {
    let delay: Duration = .milliseconds(300)
    try await withSession(config: testConfig(rtpCloseDelay: delay)) { rig in
        let chunks = try await rig.session.start()
        _ = try await take(1, from: chunks)
        await rig.session.stop()
        let stopped = ContinuousClock.now
        let ends = await rig.server.connectionEnds
        try #require(ends.count == 1)
        #expect(stopped - ends[0].at >= delay, "\(stopped - ends[0].at)")
    }
}

/// Sets up a session that loses its keepalive and is waiting out a 30 s cooldown.
private func recoveringWithLongCooldown(_ body: @escaping @Sendable (Rig) async throws -> Void) async throws {
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true),
                          config: testConfig(keepalive: .milliseconds(200), reconnectCooldown: .seconds(30))) { rig in
        let chunks = try await rig.session.start()
        defer { withExtendedLifetime(chunks) {} }
        try await eventually { await rig.session.nextAttemptAt != nil }
        #expect(await rig.session.state == .recovering(attempt: 1))
        try await body(rig)
    }
}

@Test func stopDuringCooldownWait() async throws {
    try await recoveringWithLongCooldown { rig in
        let start = ContinuousClock.now
        await rig.session.stop()
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await rig.session.state == .stopped)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await rig.server.acceptedConnections == 1)
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
    }
}

@Test func concurrentStopsDuringRecovery() async throws {
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true),
                          config: testConfig(keepalive: .milliseconds(200), reconnectCooldown: .seconds(30))) { rig in
        let chunks = try await rig.session.start()
        defer { withExtendedLifetime(chunks) {} }
        // Stop as soon as recovery begins (likely while it is still closing the old session).
        try await eventually { await isRecovering(rig.session.state) }
        async let first: Void = rig.session.stop()
        async let second: Void = rig.session.stop()
        _ = await (first, second)
        #expect(await rig.session.state == .stopped)
        try await eventually { rig.states.all.contains(.stopped) }
        #expect(rig.states.all.filter { $0 == .stopped }.count == 1)
        #expect(await rig.server.receivedMethods.filter { $0 == "TEARDOWN" }.count == 1)
        #expect(await rig.server.acceptedConnections == 1)
    }
}

// MARK: Restart hint

private func hintConfig(probe: (@Sendable () async -> Bool)?, attempts: Int = 2) -> AudioSessionConfig {
    var config = testConfig(keepalive: .milliseconds(200), maxAttempts: attempts)
    config.probe = probe
    return config
}

private let pcmaSDP = FakeRTSPServer.describeSDP.replacingOccurrences(of: "RTP/AVP 0", with: "RTP/AVP 8")

@Test func failedStartHintsCanRestartWhenControlAnswers() async throws {
    try await withSession(config: hintConfig(probe: { true }), sdp: pcmaSDP) { rig in
        await #expect(throws: AudioSessionError.unsupportedPayloadType(8)) { _ = try await rig.session.start() }
        #expect(await rig.session.restartHint == .canRestart)
    }
}

@Test func failedStartHintsPowerCycleWhenControlIsSilent() async throws {
    try await withSession(config: hintConfig(probe: { false }), sdp: pcmaSDP) { rig in
        await #expect(throws: AudioSessionError.unsupportedPayloadType(8)) { _ = try await rig.session.start() }
        #expect(await rig.session.restartHint == .powerCycleNeeded)
    }
}

@Test func noProbeMeansNoHint() async throws {
    try await withSession(config: hintConfig(probe: nil), sdp: pcmaSDP) { rig in
        await #expect(throws: AudioSessionError.unsupportedPayloadType(8)) { _ = try await rig.session.start() }
        #expect(await rig.session.restartHint == nil)
    }
}

@Test func gaveUpHintIsReadyWhenFailedIsPublished() async throws {
    let calls = Mutex(0)
    let config = hintConfig(probe: { calls.withLock { $0 += 1 }; return true })
    try await withSession(config: config) { rig in
        let chunks = try await rig.session.start()
        _ = try await take(2, from: chunks)
        #expect(await rig.session.restartHint == nil)
        #expect(calls.withLock { $0 } == 0)
        await rig.server.replaceScript(
            .scannerLike.status(method: "GET_PARAMETER", code: 454, once: true).status(method: "SETUP", code: 503))
        try await eventually(.seconds(6)) { await rig.session.state == .failed(AudioSession.gaveUpMessage) }
        #expect(await rig.session.restartHint == .canRestart)
        #expect(calls.withLock { $0 } == 1)
        _ = try await drainToEnd(chunks)
    }
}

@Test func hintClearsWhenTheSessionStops() async throws {
    try await withSession(config: hintConfig(probe: { true }), sdp: pcmaSDP) { rig in
        _ = try? await rig.session.start()
        #expect(await rig.session.restartHint == .canRestart)
        await rig.session.stop()
        #expect(await rig.session.restartHint == nil)
    }
}

// MARK: Cooldown policy (Plan 5 Task 1)

private func policyConfig(_ policy: RTSPCooldownPolicy) -> AudioSessionConfig {
    AudioSessionConfig(keepaliveInterval: .milliseconds(200), cooldownPolicy: policy, requestTimeout: .seconds(1),
                       cooldownStore: InMemoryRTSPCooldownStore(), rtpCloseDelay: .milliseconds(50))
}

/// A keepalive 454 then an answered TEARDOWN is a clean close: with a clean value of zero, the
/// recovery connects again without waiting out the 30 s full cooldown.
@Test func recoveryAfterACleanCloseUsesTheCleanCooldown() async throws {
    let policy = RTSPCooldownPolicy(full: .seconds(30), afterCleanClose: .zero)
    #expect(policyConfig(policy).cooldownPolicy == policy)
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true),
                          config: policyConfig(policy)) { rig in
        let chunks = try await rig.session.start()
        defer { withExtendedLifetime(chunks) {} }
        try await eventually(.seconds(4)) {
            await rig.session.state == .streaming && rig.states.all.filter { $0 == .streaming }.count == 2
        }
        let clients = rig.clients.all
        try #require(clients.count == 2)
        #expect(await clients[0].cooldownPolicy == policy)
        #expect(await clients[0].lastCloseWasClean == true)
        #expect(await rig.server.acceptedConnections == 2)
    }
}

/// The same failure with a TEARDOWN answered 500 is unclean: the recovery waits the full 30 s.
@Test func recoveryAfterAnUncleanCloseWaitsTheFullCooldown() async throws {
    let policy = RTSPCooldownPolicy(full: .seconds(30), afterCleanClose: .zero)
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true)
                            .status(method: "TEARDOWN", code: 500, once: true),
                          config: policyConfig(policy)) { rig in
        let chunks = try await rig.session.start()
        defer { withExtendedLifetime(chunks) {} }
        try await eventually { await rig.session.nextAttemptAt != nil }
        let until = try #require(await rig.session.nextAttemptAt)
        #expect(ContinuousClock.now.duration(to: until) > .seconds(25))
        #expect(await rig.clients.all.first?.lastCloseWasClean == false)
        #expect(await rig.server.acceptedConnections == 1)
    }
}

@Test func configReconnectCooldownShimIsSymmetric() {
    var config = AudioSessionConfig(reconnectCooldown: .seconds(7))
    #expect(config.cooldownPolicy == .symmetric(.seconds(7)))
    #expect(AudioSessionConfig().cooldownPolicy == .standard)
    config.reconnectCooldown = .seconds(9)
    #expect(config.cooldownPolicy == .symmetric(.seconds(9)))
    #expect(config.reconnectCooldown == .seconds(9))
}

/// An unclean close by someone else on the same scanner (another station's client) still holds
/// the recovery to the full cooldown, though this session's own close was clean.
@Test func recoveryWaitsOutAnotherUncleanClose() async throws {
    let policy = RTSPCooldownPolicy(full: .seconds(30), afterCleanClose: .zero)
    let store = InMemoryRTSPCooldownStore()
    let config = AudioSessionConfig(keepaliveInterval: .milliseconds(500), cooldownPolicy: policy,
                                    requestTimeout: .seconds(1), cooldownStore: store,
                                    rtpCloseDelay: .milliseconds(50))
    try await withSession(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true), config: config) { rig in
        let chunks = try await rig.session.start()
        defer { withExtendedLifetime(chunks) {} }
        await store.recordClosed(host: "127.0.0.1", at: Date(), clean: false)
        try await eventually { await rig.session.nextAttemptAt != nil }
        let until = try #require(await rig.session.nextAttemptAt)
        #expect(ContinuousClock.now.duration(to: until) > .seconds(25))
        #expect(await rig.clients.all.first?.lastCloseWasClean == true)
    }
}
