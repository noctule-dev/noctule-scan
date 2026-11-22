// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
@testable import NoctuleMockScanner

// MockSDS200 against Plan 1/2's real client stack (AudioSession, RTSPClient, RTPReceiver,
// ScannerClient over UDPTransport) on loopback. Every wait is bounded; every test stops the mock.

private let mockCooldown: Duration = .milliseconds(300)

private struct MockRig: Sendable {
    let mock: MockSDS200
    let udpPort: UInt16
    let rtspPort: UInt16

    var clock: MockClock { mock.clock }

    func controlClient(timeout: Duration = .seconds(1)) -> ScannerClient {
        ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: udpPort), commandTimeout: timeout)
    }

    /// A raw RTSPClient with its own cooldown settings (closeLinger zero, for fast tests).
    func rtspClient(cooldown: Duration, store: any RTSPCooldownStore = InMemoryRTSPCooldownStore(),
                    timeout: Duration = .milliseconds(500)) -> RTSPClient {
        RTSPClient(host: "127.0.0.1", port: rtspPort, requestTimeout: timeout, reconnectCooldown: cooldown,
                   cooldownStore: store, closeLinger: .zero)
    }

    func session(cooldown: Duration = mockCooldown, store: any RTSPCooldownStore = InMemoryRTSPCooldownStore(),
                 keepalive: Duration = .seconds(15), stall: Duration? = nil, maxAttempts: Int = 2,
                 requestTimeout: Duration = .seconds(1)) -> AudioSession {
        session(policy: .symmetric(cooldown), store: store, keepalive: keepalive, stall: stall,
                maxAttempts: maxAttempts, requestTimeout: requestTimeout)
    }

    func session(policy: RTSPCooldownPolicy, store: any RTSPCooldownStore = InMemoryRTSPCooldownStore(),
                 keepalive: Duration = .seconds(15), stall: Duration? = nil, maxAttempts: Int = 2,
                 requestTimeout: Duration = .seconds(1)) -> AudioSession {
        let config = AudioSessionConfig(
            keepaliveInterval: keepalive, stallTimeout: stall, maxRecoveryAttempts: maxAttempts,
            cooldownPolicy: policy, requestTimeout: requestTimeout, cooldownStore: store,
            rtpCloseDelay: .milliseconds(50))
        return AudioSession(host: "127.0.0.1", rtspPort: rtspPort, config: config) { options in
            RTSPClient(host: options.host, port: options.port, requestTimeout: options.requestTimeout,
                       cooldownPolicy: options.cooldownPolicy, cooldownStore: options.cooldownStore,
                       closeLinger: .zero)
        }
    }
}

/// Starts a mock on a stepped clock, runs `body` (bounded by `limit`), and always stops the mock.
/// Returns the sessions the mock saw leak (no TEARDOWN) by the time it stopped.
@discardableResult
private func withMock(
    at time: Double = 0, scenario: MockScenario = .default, faults: MockFaults = .none,
    cooldown: Duration = mockCooldown, cooldownAfter: MockCooldownAfter = .any, wedgeMode: MockWedgeMode = .timeout,
    rebootDuration: Duration = .milliseconds(500), limit: Duration = .seconds(10),
    _ body: @escaping @Sendable (MockRig) async throws -> Void
) async throws -> [String] {
    let options = MockSDS200.Options(clock: .stepped(at: time), reconnectCooldown: cooldown,
                                     cooldownAfter: cooldownAfter, wedgeMode: wedgeMode,
                                     rebootDuration: rebootDuration)
    let mock = MockSDS200(scenario: scenario, faults: faults, options: options)
    let ports = try await mock.start()
    var failure: (any Error)?
    do {
        try await within(limit) { try await body(MockRig(mock: mock, udpPort: ports.udpPort, rtspPort: ports.rtspPort)) }
    } catch {
        failure = error
    }
    await mock.stop()
    let leaked = await mock.leakedSessions
    if let failure { throw failure }
    return leaked
}

/// Records every state a session publishes.
private final class StateLog: Sendable {
    private let log = Mutex<[AudioSessionState]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ session: AudioSession) {
        let states = session.states
        task.withLock { $0 = Task { [self] in for await state in states { self.log.withLock { $0.append(state) } } } }
    }

    var all: [AudioSessionState] { log.withLock { $0 } }
    func cancel() { task.withLock { $0?.cancel() } }
}

/// Collects chunks in the background.
private final class ChunkLog: Sendable {
    private let chunks = Mutex<[AudioChunk]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<AudioChunk>) {
        task.withLock { $0 = Task { [self] in for await chunk in stream { self.chunks.withLock { $0.append(chunk) } } } }
    }

    var count: Int { chunks.withLock { $0.count } }
    func samples(from start: Int) -> [Int16] { chunks.withLock { $0.dropFirst(start).flatMap(\.samples) } }
    func cancel() { task.withLock { $0?.cancel() } }
}

/// The dominant frequency of `samples` (8 kHz), from the zero-crossing count.
private func zeroCrossingHz(_ samples: [Int16]) -> Double {
    guard samples.count > 1 else { return 0 }
    var crossings = 0
    for (a, b) in zip(samples, samples.dropFirst()) where (a < 0) != (b < 0) { crossings += 1 }
    return Double(crossings) / 2 / (Double(samples.count) / 8000)
}

private func isFailed(_ state: AudioSessionState) -> Bool {
    if case .failed = state { return true }
    return false
}

@Suite(.timeLimit(.minutes(1))) struct MockSDS200Tests {
    // MARK: Hardware shape

    @Test func rtspRepliesMatchHardwareShape() async throws {
        let leaked = try await withMock { rig in
            let receiver = RTPReceiver(expectedSourceHost: "127.0.0.1")
            let rtpPort = try await receiver.bind()
            let raw = try RawRTSP(port: rig.rtspPort)
            defer { raw.close() }
            let url = "rtsp://127.0.0.1:\(rig.rtspPort)/au:scanner.au"

            let options = try #require(await raw.exchange("OPTIONS \(url) RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: NoctuleScan\r\n\r\n"))
            #expect(options.hasPrefix("RTSP/1.0 200 OK\r\n"))
            #expect(header("Public", in: options)?.contains("GET_PARAMETER") == true)

            let describe = try #require(await raw.exchange(
                "DESCRIBE \(url) RTSP/1.0\r\nCSeq: 2\r\nUser-Agent: NoctuleScan\r\nAccept: application/sdp\r\n\r\n"))
            #expect(headerNames(describe) == ["Cache-Control", "CSeq", "Server", "Content-Base", "Content-Length", "Content-Type"])
            #expect(header("Server", in: describe) == "Scanner Audio Server 0.0.1")
            #expect(header("Content-Length", in: describe) == "157")
            let body = describe.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            #expect(body.utf8.count == 157)
            #expect(body.contains("m=audio 0 RTP/AVP 0"))
            let base = try #require(header("Content-Base", in: describe))

            let setup = try #require(await raw.exchange(
                "SETUP \(base)trackID=1 RTSP/1.0\r\nCSeq: 3\r\nUser-Agent: NoctuleScan\r\nTransport: RTP/AVP;unicast;client_port=\(rtpPort)\r\n\r\n"))
            let session = try #require(header("Session", in: setup))
            #expect(!session.contains("timeout"))
            #expect(UInt64(session) != nil, "numeric session id, got \(session)")
            let transport = try #require(header("Transport", in: setup))
            #expect(transport.hasPrefix("RTP/AVP;unicast;client_port=\(rtpPort);source=127.0.0.1;server_port="))
            #expect(transport.contains(";ssrc="))

            let play = try #require(await raw.exchange(
                "PLAY \(base) RTSP/1.0\r\nCSeq: 4\r\nUser-Agent: NoctuleScan\r\nSession: \(session)\r\nRange: npt=0.000-\r\n\r\n"))
            #expect(play.hasPrefix("RTSP/1.0 200 OK"))
            #expect(header("RTP-Info", in: play) != nil)

            let keepalive = try #require(await raw.exchange(
                "GET_PARAMETER \(base) RTSP/1.0\r\nCSeq: 5\r\nUser-Agent: NoctuleScan\r\nSession: \(session)\r\n\r\n"))
            #expect(keepalive.hasPrefix("RTSP/1.0 200 OK"))
            let teardown = try #require(await raw.exchange(
                "TEARDOWN \(base) RTSP/1.0\r\nCSeq: 6\r\nUser-Agent: NoctuleScan\r\nSession: \(session)\r\n\r\n"))
            #expect(teardown.hasPrefix("RTSP/1.0 200 OK"))
            // A session the server doesn't know gets 454.
            let unknown = try #require(await raw.exchange(
                "GET_PARAMETER \(base) RTSP/1.0\r\nCSeq: 7\r\nUser-Agent: NoctuleScan\r\nSession: \(session)\r\n\r\n"))
            #expect(unknown.hasPrefix("RTSP/1.0 454"))
            await receiver.close()
        }
        #expect(leaked.isEmpty)
    }

    @Test func rtpMatchesHardwareShapeWithNewSSRCPerSession() async throws {
        let leaked = try await withMock(at: 10) { rig in
            var seen: [(ssrc: UInt32, session: String)] = []
            for round in 0..<2 {
                if round == 1 { try await Task.sleep(for: mockCooldown + .milliseconds(300)) }
                let receiver = RTPReceiver(expectedSourceHost: "127.0.0.1")
                let rtpPort = try await receiver.bind()
                let raw = try RawRTSP(port: rig.rtspPort)
                let url = "rtsp://127.0.0.1:\(rig.rtspPort)/au:scanner.au/"
                _ = await raw.exchange("OPTIONS \(url) RTSP/1.0\r\nCSeq: 1\r\n\r\n")
                let setup = try #require(await raw.exchange(
                    "SETUP \(url)trackID=1 RTSP/1.0\r\nCSeq: 2\r\nTransport: RTP/AVP;unicast;client_port=\(rtpPort)\r\n\r\n"))
                let session = try #require(header("Session", in: setup))
                let transport = try #require(header("Transport", in: setup))
                let advertised = try #require(transport.components(separatedBy: "ssrc=").last.flatMap { UInt32($0) })
                _ = await raw.exchange("PLAY \(url) RTSP/1.0\r\nCSeq: 3\r\nSession: \(session)\r\nRange: npt=0.000-\r\n\r\n")

                let packets = receiver.packets
                let collected = try await within(.seconds(3)) { () -> [RTPPacket] in
                    var out: [RTPPacket] = []
                    let start = ContinuousClock.now
                    for await received in packets {
                        out.append(received.packet)
                        if ContinuousClock.now - start >= .seconds(1) { break }
                    }
                    return out
                }
                _ = await raw.exchange("TEARDOWN \(url) RTSP/1.0\r\nCSeq: 4\r\nSession: \(session)\r\n\r\n")
                raw.close()
                await receiver.close()

                #expect((22...28).contains(collected.count), "\(collected.count) packets in 1 s")
                #expect(collected.allSatisfy { $0.payload.count == 320 && $0.payloadType == 0 && !$0.marker })
                #expect(collected.allSatisfy { $0.ssrc == advertised })
                for (a, b) in zip(collected, collected.dropFirst()) {
                    #expect(b.timestamp &- a.timestamp == 320)
                    #expect(b.sequence &- a.sequence == 1)
                }
                seen.append((advertised, session))
            }
            #expect(seen[0].ssrc != seen[1].ssrc)
            #expect(seen[0].session != seen[1].session)
        }
        #expect(leaked.isEmpty)
    }

    // MARK: Audio

    @Test func audioSessionStreamsToneDuringTransmission() async throws {
        let second = MockScenario.default.transmissions[1]
        let leaked = try await withMock(at: second.at + 0.5) { rig in
            let session = rig.session()
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await eventually { chunks.count >= 20 }
            let hz = zeroCrossingHz(chunks.samples(from: 2))
            #expect(abs(hz - second.toneHz) <= second.toneHz * 0.05, "measured \(hz) Hz, want \(second.toneHz)")

            // Between transmissions: still 25 packets/s (continuous), but silent.
            rig.clock.set(second.end + 0.5)
            let mark = chunks.count + 3
            try await eventually { chunks.count >= mark + 10 }
            let quiet = chunks.samples(from: mark)
            #expect(quiet.allSatisfy { abs(Int($0)) <= 8 }, "max \(quiet.map { abs(Int($0)) }.max() ?? 0)")

            // Another transmission: its own tone.
            let third = MockScenario.default.transmissions[2]
            rig.clock.set(third.at + 0.5)
            let next = chunks.count + 3
            try await eventually { chunks.count >= next + 15 }
            let thirdHz = zeroCrossingHz(chunks.samples(from: next))
            #expect(abs(thirdHz - third.toneHz) <= third.toneHz * 0.05, "measured \(thirdHz) Hz, want \(third.toneHz)")
            await session.stop()
        }
        #expect(leaked.isEmpty)
    }

    @Test func wedgeAudioFailsUntilPowerCycle() async throws {
        let leaked = try await withMock(at: 10, faults: MockFaults(wedgeAudio: true)) { rig in
            let store = InMemoryRTSPCooldownStore()
            let failing = rig.session(store: store)
            let states = StateLog(failing)
            defer { states.cancel() }
            await #expect(throws: RTSPError.unexpectedStatus(503, "Service Unavailable")) {
                _ = try await failing.start()
            }
            #expect(isFailed(await failing.state))
            await failing.stop()

            await rig.mock.powerCycle()
            #expect(await rig.mock.faults.wedgeAudio == false)
            await store.clear(host: "127.0.0.1")  // as after a restart; the power cycle reset the server
            let session = rig.session(store: store)
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await eventually { chunks.count >= 5 }
            #expect(await session.state == .streaming)
            await session.stop()
        }
        #expect(leaked.isEmpty)
    }

    @Test func keepalive454TriggersOneRecovery() async throws {
        let leaked = try await withMock(at: 10, faults: MockFaults(keepaliveStatus: 454)) { rig in
            let session = rig.session(keepalive: .milliseconds(200))
            let states = StateLog(session)
            defer { states.cancel() }
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await eventually(.seconds(4)) { let streaming = await session.state == .streaming; return await session.stats.recoveries == 1 && streaming }
            #expect(states.all.contains(.recovering(attempt: 1)))
            // Later keepalives succeed: no second recovery.
            try await Task.sleep(for: .milliseconds(800))
            #expect(await session.stats.recoveries == 1)
            #expect(await session.state == .streaming)
            #expect(await rig.mock.wedgeCount == 0)
            let before = chunks.count
            try await eventually { chunks.count >= before + 5 }
            await session.stop()
        }
        #expect(leaked.isEmpty)
    }

    @Test func dropAudioAfterStopsPacketsMidSession() async throws {
        let leaked = try await withMock(at: 10, faults: MockFaults(dropAudioAfter: 0.4)) { rig in
            let session = rig.session()
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await Task.sleep(for: .milliseconds(900))
            let count = chunks.count
            #expect((5...14).contains(count), "\(count) chunks")
            try await Task.sleep(for: .milliseconds(300))
            #expect(chunks.count == count)
            #expect(await session.state == .streaming)  // stallTimeout is nil: silence isn't a fault
            await session.stop()
        }
        #expect(leaked.isEmpty)
    }

    @Test func stallPSIAfterStopsPushes() async throws {
        try await withMock(faults: MockFaults(stallPSIAfter: 0.3)) { rig in
            let client = rig.controlClient()
            try await client.connect()
            let stream = try await client.startPush(interval: .milliseconds(50))
            let consumer = Task { for await _ in stream {} }
            defer { consumer.cancel() }
            try await Task.sleep(for: .seconds(1))
            let sent = await rig.mock.control.pushesSent
            #expect((2...8).contains(sent), "\(sent) pushes")
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.mock.control.pushesSent == sent)
            await client.disconnect()
        }
    }

    // MARK: The reconnect hazard

    @Test func quickReconnectWedgesMock() async throws {
        try await withMock { rig in
            let store = InMemoryRTSPCooldownStore()
            let first = rig.rtspClient(cooldown: .zero, store: store)
            try await first.connect()
            _ = try await first.options()
            await first.close()

            // A client that ignores the cooldown reconnects at once: the mock wedges, and in
            // timeout mode the connection gets no answer.
            let careless = rig.rtspClient(cooldown: .zero)
            try await careless.connect()
            await #expect(throws: RTSPError.timeout(method: "OPTIONS")) { _ = try await careless.options() }
            await careless.close()
            #expect(await rig.mock.isAudioWedged)
            #expect(await rig.mock.wedgeCount == 1)

            // A careful client sharing the first one's store refuses on its own.
            let careful = rig.rtspClient(cooldown: .seconds(60), store: store)
            do {
                try await careful.connect()
                Issue.record("expected the careful client to refuse")
            } catch RTSPError.cooldown {
            } catch {
                Issue.record("expected .cooldown, got \(error)")
            }

            // Waiting out the cooldown doesn't help: the wedge persists until a power cycle.
            try await Task.sleep(for: mockCooldown + .milliseconds(200))
            let later = rig.rtspClient(cooldown: mockCooldown)
            try await later.connect()
            await #expect(throws: RTSPError.timeout(method: "OPTIONS")) { _ = try await later.options() }
            await later.close()
            #expect(await rig.mock.isAudioWedged)
            // Control still answers (wedgeTakesControlDown is off).
            let control = rig.controlClient()
            try await control.connect()
            #expect(try await control.modelInfo().model == .sds200)
            await control.disconnect()

            await rig.mock.powerCycle()
            #expect(await !rig.mock.isAudioWedged)
            let fresh = rig.rtspClient(cooldown: .zero)
            try await fresh.connect()
            #expect(try await fresh.options().contains("DESCRIBE"))
            await fresh.close()
        }
    }

    @Test func refuseModeWedgeRefusesConnections() async throws {
        try await withMock(wedgeMode: .refuse) { rig in
            let first = rig.rtspClient(cooldown: .zero)
            try await first.connect()
            _ = try await first.options()
            await first.close()
            let careless = rig.rtspClient(cooldown: .zero)
            do {
                try await careless.connect()
                _ = try await careless.options()
                Issue.record("expected the wedged mock to refuse")
            } catch RTSPError.closed {
            } catch {
                Issue.record("expected .closed, got \(error)")
            }
            await careless.close()
            #expect(await rig.mock.isAudioWedged)
        }
    }

    @Test func msmRebootClearsWedge() async throws {
        let leaked = try await withMock(at: 10, rebootDuration: .milliseconds(600)) { rig in
            let store = InMemoryRTSPCooldownStore()
            let first = rig.rtspClient(cooldown: .zero, store: store)
            try await first.connect()
            _ = try await first.options()
            await first.close()
            let careless = rig.rtspClient(cooldown: .zero)
            try await careless.connect()
            _ = try? await careless.options()
            await careless.close()
            #expect(await rig.mock.isAudioWedged)

            // The real restart flow: MSM,1, wait for MDL (after one silent poll), clear the cooldown.
            let client = rig.controlClient()
            try await client.connect()
            let outcome = await ScannerRestart.perform(
                client: client, host: "127.0.0.1", port: rig.udpPort, cooldownStore: store,
                timeout: .seconds(5), pollInterval: .milliseconds(200), silenceGrace: .seconds(3),
                pollTimeout: .milliseconds(200))
            #expect(outcome == .restarted)
            #expect(await !rig.mock.isAudioWedged)

            let session = rig.session(store: store)
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await eventually { chunks.count >= 5 }
            await session.stop()
        }
        #expect(leaked.isEmpty)
    }

    @Test func wedgeTakesControlDownUntilPowerCycle() async throws {
        try await withMock(faults: MockFaults(wedgeTakesControlDown: true), rebootDuration: .milliseconds(300)) { rig in
            let first = rig.rtspClient(cooldown: .zero)
            try await first.connect()
            _ = try await first.options()
            await first.close()
            let careless = rig.rtspClient(cooldown: .zero)
            try await careless.connect()
            _ = try? await careless.options()
            await careless.close()
            #expect(await rig.mock.isAudioWedged)
            #expect(await !rig.mock.isControlAnswering)

            let probe = rig.controlClient(timeout: .milliseconds(200))
            try await probe.connect()
            await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await probe.modelInfo() }
            // MSM,1 can't get through either; ScannerClient treats silence as "maybe rebooting".
            try await probe.restartScanner()
            try await Task.sleep(for: .milliseconds(500))
            #expect(await rig.mock.isAudioWedged)
            #expect(await !rig.mock.isControlAnswering)

            await rig.mock.powerCycle()
            #expect(await rig.mock.isControlAnswering)
            #expect(await !rig.mock.isAudioWedged)
            let after = rig.controlClient()
            try await after.connect()
            #expect(try await after.modelInfo().model == .sds200)
            await after.disconnect()
        }
    }

    @Test func clientCooldownPreventsWedge() async throws {
        // dropAudioAfter + stallTimeout forces a recovery after every PLAY; each reconnect waits out
        // the session's cooldown, which matches the mock's, so the mock never wedges.
        let leaked = try await withMock(at: 10, faults: MockFaults(dropAudioAfter: 0.3)) { rig in
            let session = rig.session(cooldown: mockCooldown, stall: .milliseconds(200))
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await eventually(.seconds(6)) { await session.stats.recoveries >= 2 }
            #expect(await rig.mock.wedgeCount == 0)
            #expect(await !rig.mock.isAudioWedged)
            let accepted = await rig.mock.rtsp.connectionsAcceptedAt
            let ends = await rig.mock.rtsp.connectionEnds
            for (index, opened) in accepted.enumerated().dropFirst() where index - 1 < ends.count {
                let gap = ends[index - 1].at.duration(to: opened)
                #expect(gap >= mockCooldown, "gap \(gap) before connection \(index)")
            }
            await session.stop()
        }
        #expect(leaked.isEmpty)
    }

    @Test func shortClientCooldownWedgesOnRecovery() async throws {
        try await withMock(at: 10, faults: MockFaults(keepaliveStatus: 454), cooldown: .seconds(2)) { rig in
            let session = rig.session(cooldown: .milliseconds(50), keepalive: .milliseconds(200),
                                      requestTimeout: .milliseconds(500))
            let states = StateLog(session)
            defer { states.cancel() }
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await eventually(.seconds(8)) { isFailed(await session.state) }
            #expect(await session.state == .failed(AudioSession.gaveUpMessage))
            #expect(await rig.mock.isAudioWedged)
            await session.stop()
        }
    }

    @Test func leakedSessionsCountsMissingTeardowns() async throws {
        let leaked = try await withMock { rig in
            let raw = try RawRTSP(port: rig.rtspPort)
            let url = "rtsp://127.0.0.1:\(rig.rtspPort)/au:scanner.au/"
            _ = await raw.exchange("OPTIONS \(url) RTSP/1.0\r\nCSeq: 1\r\n\r\n")
            let setup = try #require(await raw.exchange(
                "SETUP \(url)trackID=1 RTSP/1.0\r\nCSeq: 2\r\nTransport: RTP/AVP;unicast;client_port=9\r\n\r\n"))
            #expect(header("Session", in: setup) != nil)
            raw.close()  // no TEARDOWN
            try await eventually { await rig.mock.rtsp.connectionEnds.count == 1 }
        }
        #expect(leaked.count == 1)
    }

    // MARK: Clean closes (Plan 5 Task 1)

    /// The mock's scanner-like replies make an ordinary stop a clean close; a power cycle under a
    /// live session (the server drops the connection) makes the close unclean.
    @Test func stopIsACleanCloseAndAPowerCycleIsNot() async throws {
        let leaked = try await withMock(at: 10) { rig in
            let store = InMemoryRTSPCooldownStore()
            let session = rig.session(store: store)
            let chunks = ChunkLog(try await session.start())
            defer { chunks.cancel() }
            try await eventually { chunks.count >= 3 }
            await session.stop()
            #expect(await store.lastClose(host: "127.0.0.1")?.clean == true)

            try await Task.sleep(for: mockCooldown + .milliseconds(100))
            let second = rig.session(store: store)
            let more = ChunkLog(try await second.start())
            defer { more.cancel() }
            try await eventually { more.count >= 3 }
            await rig.mock.powerCycle()
            try await eventually { await store.lastClose(host: "127.0.0.1")?.clean == false }
            await second.stop()
            #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
            #expect(await rig.mock.wedgeCount == 0)
        }
        #expect(leaked.isEmpty)
    }

    // MARK: --cooldown-after unclean (Plan 5 Task 4)

    /// The first line of an RTSP reply. (Not `prefix { $0 != "\r" }`: "\r\n" is one `Character`.)
    private static func statusLine(_ reply: String) -> String {
        reply.components(separatedBy: "\r\n").first ?? ""
    }

    /// OPTIONS, SETUP and (if `tearDown`) TEARDOWN over a raw socket; returns the replies' status lines.
    private static func rawSession(port: UInt16, tearDown: Bool) async throws -> [String] {
        let raw = try RawRTSP(port: port)
        defer { raw.close() }
        let url = "rtsp://127.0.0.1:\(port)/au:scanner.au/"
        var statuses: [String] = []
        let options = await raw.exchange("OPTIONS \(url) RTSP/1.0\r\nCSeq: 1\r\n\r\n")
        statuses.append(options.map(statusLine) ?? "none")
        let setup = await raw.exchange(
            "SETUP \(url)trackID=1 RTSP/1.0\r\nCSeq: 2\r\nTransport: RTP/AVP;unicast;client_port=9\r\n\r\n")
        statuses.append(setup.map(statusLine) ?? "none")
        if tearDown, let session = setup.flatMap({ header("Session", in: $0) }) {
            let teardown = await raw.exchange("TEARDOWN \(url) RTSP/1.0\r\nCSeq: 3\r\nSession: \(session)\r\n\r\n")
            statuses.append(teardown.map(statusLine) ?? "none")
        }
        return statuses
    }

    /// With `.unclean`, a connection closed by the client after a 200 TEARDOWN, every request
    /// answered, doesn't arm the hazard: an immediate reconnect is served.
    @Test func cooldownAfterUncleanServesAReconnectAfterACleanClose() async throws {
        let leaked = try await withMock(cooldown: .seconds(5), cooldownAfter: .unclean) { rig in
            let allOK = ["RTSP/1.0 200 OK", "RTSP/1.0 200 OK", "RTSP/1.0 200 OK"]
            #expect(try await Self.rawSession(port: rig.rtspPort, tearDown: true) == allOK)
            try await eventually { await rig.mock.rtsp.connectionEnds.count == 1 }
            #expect(try await Self.rawSession(port: rig.rtspPort, tearDown: true) == allOK)
            #expect(await rig.mock.wedgeCount == 0)
            #expect(await !rig.mock.isAudioWedged)
        }
        #expect(leaked.isEmpty)
    }

    /// With `.unclean`, a close without a TEARDOWN still arms the hazard.
    @Test func cooldownAfterUncleanStillWedgesAfterAnUncleanClose() async throws {
        try await withMock(cooldown: .seconds(5), cooldownAfter: .unclean) { rig in
            _ = try await Self.rawSession(port: rig.rtspPort, tearDown: false)
            try await eventually { await rig.mock.rtsp.connectionEnds.count == 1 }
            let careless = try RawRTSP(port: rig.rtspPort)
            defer { careless.close() }
            try await eventually { await rig.mock.isAudioWedged }
            #expect(await rig.mock.wedgeCount == 1)
        }
    }

    /// With `.unclean`, a clean close doesn't hide an earlier unclean one: two connections open
    /// at once, the first closes uncleanly, the second cleanly, and a reconnect still wedges.
    @Test func cooldownAfterUncleanKeepsAnEarlierUncleanWindow() async throws {
        try await withMock(cooldown: .seconds(5), cooldownAfter: .unclean) { rig in
            let url = "rtsp://127.0.0.1:\(rig.rtspPort)/au:scanner.au/"
            let clean = try RawRTSP(port: rig.rtspPort)
            let unclean = try RawRTSP(port: rig.rtspPort)
            #expect(await unclean.exchange("OPTIONS \(url) RTSP/1.0\r\nCSeq: 1\r\n\r\n") != nil)
            unclean.close()  // no session, no TEARDOWN
            try await eventually { await rig.mock.rtsp.connectionEnds.count == 1 }
            let setup = try #require(await clean.exchange(
                "SETUP \(url)trackID=1 RTSP/1.0\r\nCSeq: 1\r\nTransport: RTP/AVP;unicast;client_port=9\r\n\r\n"))
            let session = try #require(header("Session", in: setup))
            let teardown = await clean.exchange("TEARDOWN \(url) RTSP/1.0\r\nCSeq: 2\r\nSession: \(session)\r\n\r\n")
            #expect(teardown?.hasPrefix("RTSP/1.0 200") == true)
            clean.close()
            try await eventually { await rig.mock.rtsp.connectionEnds.count == 2 }
            #expect(await !rig.mock.isAudioWedged)
            let next = try RawRTSP(port: rig.rtspPort)
            defer { next.close() }
            try await eventually { await rig.mock.isAudioWedged }
        }
    }

    /// With `.unclean`, each way a close after an answered 200 TEARDOWN can still be unclean arms
    /// the hazard: (a) a request still unanswered when the client closes, (b) another TEARDOWN
    /// answered non-2xx (454 for a session the server doesn't hold), (c) a reply with the wrong CSeq.
    @Test(arguments: ["pending", "teardown454", "wrongCSeq"])
    func cooldownAfterUncleanWedgesAfterAFlawedExchange(flaw: String) async throws {
        try await withMock(cooldown: .seconds(5), cooldownAfter: .unclean) { rig in
            let url = "rtsp://127.0.0.1:\(rig.rtspPort)/au:scanner.au/"
            if flaw == "wrongCSeq" { await rig.mock.rtsp.replaceScript(.scannerLike.wrongCSeq(method: "OPTIONS", once: true)) }
            let raw = try RawRTSP(port: rig.rtspPort)
            #expect(await raw.exchange("OPTIONS \(url) RTSP/1.0\r\nCSeq: 1\r\n\r\n") != nil)
            let setup = try #require(await raw.exchange(
                "SETUP \(url)trackID=1 RTSP/1.0\r\nCSeq: 2\r\nTransport: RTP/AVP;unicast;client_port=9\r\n\r\n"))
            let session = try #require(header("Session", in: setup))
            if flaw == "teardown454" {
                let rejected = await raw.exchange("TEARDOWN \(url) RTSP/1.0\r\nCSeq: 3\r\nSession: 99999999\r\n\r\n")
                #expect(rejected?.hasPrefix("RTSP/1.0 454") == true)
            }
            let teardown = await raw.exchange("TEARDOWN \(url) RTSP/1.0\r\nCSeq: 4\r\nSession: \(session)\r\n\r\n")
            #expect(teardown?.hasPrefix("RTSP/1.0 200") == true)
            if flaw == "pending" {
                await rig.mock.rtsp.replaceScript(.scannerLike.silence(method: "DESCRIBE"))
                raw.sendOnly("DESCRIBE \(url) RTSP/1.0\r\nCSeq: 5\r\nAccept: application/sdp\r\n\r\n")
                try await eventually { await rig.mock.rtsp.receivedMethods.last == "DESCRIBE" }
            }
            raw.close()
            try await eventually { await rig.mock.rtsp.connectionEnds.count == 1 }
            #expect(await !rig.mock.isAudioWedged)
            let next = try RawRTSP(port: rig.rtspPort)
            defer { next.close() }
            try await eventually { await rig.mock.isAudioWedged }
        }
    }

    /// The default (`.any`, the hardware as measured) wedges on a quick reconnect even after a
    /// clean close.
    @Test func cooldownAfterAnyWedgesAfterACleanClose() async throws {
        try await withMock(cooldown: .seconds(5)) { rig in
            _ = try await Self.rawSession(port: rig.rtspPort, tearDown: true)
            try await eventually { await rig.mock.rtsp.connectionEnds.count == 1 }
            let next = try RawRTSP(port: rig.rtspPort)
            defer { next.close() }
            try await eventually { await rig.mock.isAudioWedged }
        }
    }

    /// The owner's setting against the mock's model of it: an `AudioSession` with no wait after a
    /// clean close stops and starts again at once, and the mock (`.unclean`) keeps serving.
    @Test func cleanStopAndImmediateRestartAgainstUncleanMock() async throws {
        let leaked = try await withMock(at: 10, cooldown: .seconds(5), cooldownAfter: .unclean) { rig in
            let store = InMemoryRTSPCooldownStore()
            let policy = RTSPCooldownPolicy(full: .seconds(5), afterCleanClose: .zero)
            let first = rig.session(policy: policy, store: store)
            let chunks = ChunkLog(try await first.start())
            defer { chunks.cancel() }
            try await eventually { chunks.count >= 3 }
            await first.stop()
            #expect(await store.lastClose(host: "127.0.0.1")?.clean == true)

            let second = rig.session(policy: policy, store: store)
            let more = ChunkLog(try await second.start())
            defer { more.cancel() }
            try await eventually { more.count >= 3 }
            await second.stop()
            #expect(await rig.mock.wedgeCount == 0)
        }
        #expect(leaked.isEmpty)
    }
}
