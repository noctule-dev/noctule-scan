// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Network
import Testing
import NoctuleKitTestSupport
import NoctuleMockScanner
@testable import NoctuleKit

private struct TimedOut: Error {}

/// Runs `body`, failing with `TimedOut` after `limit` so no test can hang on the network.
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

/// Starts a fake RTSP server, runs `body` against a client for it (bounded by `limit`), then
/// always closes the client (which tears down any session) and stops the server.
private func withFake(
    _ script: FakeRTSPServer.Script = .scannerLike,
    requestTimeout: Duration = .seconds(1),
    limit: Duration = .seconds(5),
    _ body: @escaping @Sendable (FakeRTSPServer, RTSPClient, UInt16) async throws -> Void
) async throws {
    let server = FakeRTSPServer(script: script)
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: requestTimeout,
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    var failure: (any Error)?
    do {
        try await within(limit) { try await body(server, client, port) }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    if let failure { throw failure }
}

private let base = "rtsp://127.0.0.1/au:scanner.au/"

@Test func fullHandshake() async throws {
    try await withFake { server, client, port in
        try await client.connect()
        let (gotBase, sdp) = try await client.describe()
        #expect(gotBase == base)
        #expect(sdp.payloadType == 0)
        #expect(sdp.control == "trackID=1")
        let id = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        #expect(id == "1234ABCD")
        #expect(await client.sessionID == "1234ABCD")
        try await client.play()
        try await client.keepalive()
        await client.teardown()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "GET_PARAMETER", "TEARDOWN"])
        #expect(await client.sessionID == nil)

        let requests = await server.receivedRequests
        try #require(requests.count == 6)
        #expect(requests[0].hasPrefix("OPTIONS rtsp://127.0.0.1:\(port)/au:scanner.au RTSP/1.0\r\nCSeq: 1\r\n"))
        #expect(requests[1].hasPrefix("DESCRIBE rtsp://127.0.0.1:\(port)/au:scanner.au RTSP/1.0\r\nCSeq: 2\r\n"))
        #expect(requests[1].contains("\r\nAccept: application/sdp\r\n"))
        #expect(requests[2].hasPrefix("SETUP \(base)trackID=1 RTSP/1.0\r\nCSeq: 3\r\n"))
        #expect(requests[2].contains("\r\nTransport: RTP/AVP;unicast;client_port=50000\r\n"))
        #expect(requests[3].hasPrefix("PLAY \(base) RTSP/1.0\r\nCSeq: 4\r\n"))
        #expect(requests[3].contains("\r\nSession: 1234ABCD\r\n"))
        #expect(requests[3].contains("\r\nRange: npt=0.000-\r\n"))
        #expect(requests[4].hasPrefix("GET_PARAMETER \(base) RTSP/1.0\r\nCSeq: 5\r\n"))
        #expect(requests[4].contains("\r\nSession: 1234ABCD\r\n"))
        #expect(requests[5].hasPrefix("TEARDOWN \(base) RTSP/1.0\r\nCSeq: 6\r\n"))
        #expect(requests[5].contains("\r\nSession: 1234ABCD\r\n"))
    }
}

@Test func non200Throws() async throws {
    try await withFake(.scannerLike.status(method: "SETUP", code: 454)) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        await #expect(throws: RTSPError.unexpectedStatus(454, "Session Not Found")) {
            _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        }
        #expect(await client.sessionID == nil)
        // A non-2xx reply is a normal answer: the connection stays usable.
        _ = try await client.describe()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "DESCRIBE"])
    }
}

/// A late wakeup (the CI runner's: LESSONS.md 2026-11-20, 2026-11-21) can only lengthen a timed
/// wait, so a timeout is held to its own duration from below, and from above only to that duration
/// plus this margin: enough to tell "gave up at its timeout" from "waited for something else"
/// (another timeout, or never), not a measure of how promptly this machine wakes.
private let lateWakeMargin = Duration.seconds(3)

@Test func silentServerTimesOut() async throws {
    let timeout = Duration.milliseconds(200)
    try await withFake(.scannerLike.silence(method: "PLAY"), requestTimeout: timeout, limit: .seconds(15)) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        let start = ContinuousClock.now
        await #expect(throws: RTSPError.timeout(method: "PLAY")) { try await client.play() }
        let waited = ContinuousClock.now - start
        #expect(waited >= timeout && waited < timeout + lateWakeMargin, "PLAY gave up after \(waited)")
        // A timeout doesn't kill the connection, so the session can still be torn down.
        await client.teardown()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "TEARDOWN"])
        #expect(await client.sessionID == nil)
    }
}

@Test func closeMidRequestThrowsClosed() async throws {
    try await withFake(.scannerLike.closeOn(method: "PLAY")) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        await #expect(throws: RTSPError.closed) { try await client.play() }
        await #expect(throws: RTSPError.closed) { try await client.keepalive() }
        await #expect(throws: RTSPError.closed) { _ = try await client.describe() }
        await client.teardown()
        #expect(await client.sessionID == nil)
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "TEARDOWN"])  // teardown reconnects to end the session
    }
}

@Test func cseqMismatchThrows() async throws {
    try await withFake(.scannerLike.wrongCSeq(method: "DESCRIBE")) { server, client, _ in
        try await client.connect()
        await #expect(throws: RTSPError.cseqMismatch(expected: 2, got: 102)) { _ = try await client.describe() }
        // A protocol error leaves the connection unusable.
        await #expect(throws: RTSPError.closed) {
            _ = try await client.setup(controlURL: base + "trackID=1", clientPort: 50000)
        }
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE"])
    }
}

@Test func teardownWithoutSessionSendsNothing() async throws {
    try await withFake { server, client, _ in
        try await client.connect()
        await client.teardown()
        // TCP keeps order, so a TEARDOWN would have arrived before this DESCRIBE.
        _ = try await client.describe()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE"])
    }
}

@Test func closeTearsDownOnce() async throws {
    try await withFake { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        await client.close()
        await client.close()
        await client.teardown()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN"])
        #expect(await client.sessionID == nil)
        await #expect(throws: RTSPError.closed) { _ = try await client.describe() }
    }
}

/// An unanswered TEARDOWN never throws and stays bounded, but it is not counted as done: the id
/// goes to `unreleasedSessions` (for a later connection to retry), and it is not resent on the
/// same connection.
@Test func teardownNeverThrowsEvenIfServerSilent() async throws {
    let timeout = Duration.milliseconds(300)
    try await withFake(.scannerLike.silence(method: "TEARDOWN"), requestTimeout: timeout) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        let id = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        let start = ContinuousClock.now
        await client.teardown()
        #expect(ContinuousClock.now - start < timeout + .milliseconds(500))
        #expect(await client.sessionID == nil)
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN"])
        #expect(await client.unreleasedSessions == [id])
    }
}

/// `close()` after an unanswered TEARDOWN on an open connection leaves the id unreleased (not
/// silently released), and sends TEARDOWN only once.
@Test func closeWithSilentTeardownLeavesSessionUnreleased() async throws {
    try await withFake(.scannerLike.silence(method: "TEARDOWN"), requestTimeout: .milliseconds(300)) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        let id = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        await client.close()
        #expect(await client.unreleasedSessions == [id])
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN"])
        #expect(await client.teardownStatuses.isEmpty)
    }
}

@Test func teardownFromCancelledTaskStillSends() async throws {
    try await withFake { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await client.teardown()
        }
        await task.value
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN"])
        #expect(await client.sessionID == nil)
    }
}

@Test func connectToClosedPortTimesOut() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    await server.stop()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .milliseconds(300),
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    let start = ContinuousClock.now
    _ = try await within(.seconds(3)) {
        await #expect(throws: RTSPError.self) { try await client.connect() }
    }
    #expect(ContinuousClock.now - start < .seconds(1))
    await client.close()
}

@Test func requestsBeforeConnectThrowClosed() async throws {
    let client = RTSPClient(host: "127.0.0.1", port: 9, requestTimeout: .milliseconds(200),
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    try await within(.seconds(2)) {
        await #expect(throws: RTSPError.closed) { _ = try await client.describe() }
        await #expect(throws: RTSPError.closed) { try await client.play() }
    }
}

@Test func describeURLOmitsDefaultPort() {
    #expect(RTSPClient.requestURL(host: "192.0.2.10", port: 554, path: "/au:scanner.au") == "rtsp://192.0.2.10/au:scanner.au")
    #expect(RTSPClient.requestURL(host: "192.0.2.10", port: 8554, path: "/au:scanner.au") == "rtsp://192.0.2.10:8554/au:scanner.au")
}

@Test func fakeServerAcceptsSequentialSessions() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    do {
        try await within(.seconds(5)) {
            for _ in 0..<2 {
                let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
                try await client.connect()
                let (gotBase, _) = try await client.describe()
                _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
                await client.close()
            }
        }
    } catch {
        await server.stop()
        throw error
    }
    #expect(await server.acceptedConnections == 2)
    #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN", "OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN"])
    await server.stop()
}

@Test func teardownAfterServerClosedReconnectsAndTearsDown() async throws {
    try await withFake(.scannerLike.closeOn(method: "PLAY")) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        await #expect(throws: RTSPError.closed) { try await client.play() }
        let start = ContinuousClock.now
        await client.teardown()
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await client.sessionID == nil)
        #expect(await server.acceptedConnections == 2)
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "PLAY", "TEARDOWN"])
        let last = await server.receivedRequests.last ?? ""
        #expect(last.hasPrefix("TEARDOWN \(base) RTSP/1.0\r\n"))
        #expect(last.contains("\r\nSession: 1234ABCD\r\n"))
        // The client is still unusable for ordinary requests afterwards.
        await #expect(throws: RTSPError.closed) { try await client.keepalive() }
    }
}

@Test func teardownPreemptsSilentInFlightRequest() async throws {
    try await withFake(.scannerLike.silence(method: "GET_PARAMETER"), requestTimeout: .seconds(3)) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        let keepalive = Task { try await client.keepalive() }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        await client.teardown()
        let teardownTook = ContinuousClock.now - start
        // teardown() returns once the server has answered, so the TEARDOWN arrived by then.
        #expect(teardownTook < .milliseconds(500))
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "GET_PARAMETER", "TEARDOWN"])
        let result = await keepalive.result
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(throws: RTSPError.preempted) { try result.get() }
        #expect(await client.sessionID == nil)
    }
}

/// Starts a fake, connects, describes, and sets up (session `1234ABCD`). The caller must stop
/// the server and close the client.
private func setUpSession(
    _ script: FakeRTSPServer.Script, requestTimeout: Duration = .seconds(1)
) async throws -> (FakeRTSPServer, RTSPClient) {
    let server = FakeRTSPServer(script: script)
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: requestTimeout,
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    try await client.connect()
    let (gotBase, _) = try await client.describe()
    _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
    return (server, client)
}

@Test func teardownSurvivesServerClosingDuringOpenPathTeardown() async throws {
    // The server closes TCP on GET_PARAMETER; teardown() races that close. Whether teardown
    // sees the connection open or dead, the session must still be torn down.
    for trial in 0..<150 {
        let (server, client) = try await setUpSession(.scannerLike.closeOn(method: "GET_PARAMETER"))
        let keepalive = Task { try await client.keepalive() }
        // Aim teardown() at the moment the server closes: just after it sees GET_PARAMETER.
        _ = try? await within(.seconds(2)) {
            while await !server.receivedMethods.contains("GET_PARAMETER") { await Task.yield() }
        }
        try await Task.sleep(for: .microseconds(Int.random(in: 0...300)))
        _ = try? await within(.seconds(5)) { await client.teardown() }
        _ = await keepalive.result
        let methods = await server.receivedMethods
        #expect(methods.contains("TEARDOWN"), "trial \(trial): \(methods)")
        #expect(await client.sessionID == nil)
        _ = try? await within(.seconds(5)) { await client.close() }
        await server.stop()
    }
}

@Test func lateSetupReplyAfterTimeoutIsTornDown() async throws {
    try await withFake(.scannerLike.delay(method: "SETUP", seconds: 0.3), requestTimeout: .milliseconds(250)) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        await #expect(throws: RTSPError.timeout(method: "SETUP")) {
            _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        }
        await client.close()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN"])
        let last = await server.receivedRequests.last ?? ""
        #expect(last.hasPrefix("TEARDOWN "))
        #expect(last.contains("\r\nSession: 1234ABCD\r\n"))
    }
}

@Test func cancelledSetupIsTornDownExactlyOnce() async throws {
    var sawSetup = 0
    for trial in 0..<50 {
        let server = FakeRTSPServer()
        let port = try await server.start()
        let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        let setup = Task { try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000) }
        try await Task.sleep(for: .microseconds(Int.random(in: 0...600)))
        setup.cancel()
        _ = await setup.result
        let closeStart = ContinuousClock.now
        _ = try? await within(.seconds(5)) { await client.close() }
        // The fake always replies, so close() never needs to wait out requestTimeout.
        #expect(ContinuousClock.now - closeStart < .milliseconds(500), "trial \(trial)")
        let methods = await server.receivedMethods
        let teardowns = methods.filter { $0 == "TEARDOWN" }.count
        if methods.contains("SETUP") {
            sawSetup += 1
            #expect(teardowns == 1, "trial \(trial): \(methods)")
        } else {
            #expect(teardowns == 0, "trial \(trial): \(methods)")
        }
        await server.stop()
    }
    #expect(sawSetup > 0)
}

@Test func queuedPlayIsNotSentAfterTeardown() async throws {
    try await withFake(.scannerLike.silence(method: "GET_PARAMETER"), requestTimeout: .seconds(3)) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        let keepalive = Task { try await client.keepalive() }
        try await Task.sleep(for: .milliseconds(50))
        let play = Task { try await client.play() }
        try await Task.sleep(for: .milliseconds(50))
        await client.teardown()
        let playResult = await play.result
        _ = await keepalive.result
        #expect(throws: RTSPError.noSession) { try playResult.get() }
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "GET_PARAMETER", "TEARDOWN"])
    }
}

@Test func recordsSessionTimeoutAndTeardownStatus() async throws {
    try await withFake { _, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        #expect(await client.sessionTimeoutSeconds == nil)
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        #expect(await client.sessionTimeoutSeconds == nil)  // like the SDS200: no ;timeout=
        #expect(await client.teardownStatuses == [])
        await client.teardown()
        #expect(await client.teardownStatuses == [200])
    }
}

@Test func recordsNon200TeardownStatus() async throws {
    try await withFake(.scannerLike.status(method: "TEARDOWN", code: 454)) { _, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        await client.teardown()
        #expect(await client.teardownStatuses == [454])
    }
}

@Test func requestURLsUseTheConnectedIPLiteralNotTheHostName() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    let client = RTSPClient(host: "localhost", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    var failure: (any Error)?
    do {
        try await within(.seconds(5)) {
            try await client.connect()
            let address = await client.remoteAddress
            #expect(address == "127.0.0.1" || address == "::1")
            _ = try await client.describe()
            _ = try await client.setup(controlURL: "rtsp://127.0.0.1/au:scanner.au/trackID=1", clientPort: 50000)
            await client.teardown()
            let requests = await server.receivedRequests
            try #require(requests.count >= 2)
            let line = requests[1].components(separatedBy: "\r\n")[0]
            #expect(line == "DESCRIBE rtsp://127.0.0.1:\(port)/au:scanner.au RTSP/1.0"
                || line == "DESCRIBE rtsp://[::1]:\(port)/au:scanner.au RTSP/1.0", "\(line)")
            #expect(requests.allSatisfy { !$0.contains("localhost") })
        }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    if let failure { throw failure }
}

/// The connected peer's address (from `getpeername`) is normalized the same way as RTP sources.
@Test func addressLiteralNormalization() {
    #expect(IPAddressText.normalized("192.0.2.1") == "192.0.2.1")
    #expect(IPAddressText.normalized("2001:DB8::1") == "2001:db8::1")
    #expect(IPAddressText.normalized("::ffff:192.0.2.1") == "192.0.2.1")
    #expect(IPAddressText.normalized("[2001:db8::1]") == "2001:db8::1")
    #expect(IPAddressText.isLiteral("192.0.2.1") && IPAddressText.isLiteral("2001:db8::1"))
    #expect(!IPAddressText.isLiteral("scanner.example.lan"))
    #expect(RTSPClient.requestURL(host: "2001:db8::1", port: 554, path: "/au:scanner.au")
        == "rtsp://[2001:db8::1]/au:scanner.au")
}

/// The exact bytes of the handshake that worked against an SDS200 on firmware 1.26.01
/// (protocol notes §6), with 127.0.0.1 for the scanner.
@Test func handshakeBytesMatchTheWorkingReferenceExchange() async throws {
    try await withFake { server, client, port in
        try await client.connect()
        #expect(try await client.options() == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN", "PLAY", "GET_PARAMETER"])
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        try await client.play()
        try await client.keepalive()
        await client.teardown()

        let ua = "User-Agent: NoctuleScan\r\n"
        let expected = [
            "OPTIONS rtsp://127.0.0.1:\(port)/au:scanner.au RTSP/1.0\r\nCSeq: 1\r\n\(ua)\r\n",
            "DESCRIBE rtsp://127.0.0.1:\(port)/au:scanner.au RTSP/1.0\r\nCSeq: 2\r\n\(ua)Accept: application/sdp\r\n\r\n",
            "SETUP rtsp://127.0.0.1/au:scanner.au/trackID=1 RTSP/1.0\r\nCSeq: 3\r\n\(ua)Transport: RTP/AVP;unicast;client_port=50000\r\n\r\n",
            "PLAY rtsp://127.0.0.1/au:scanner.au/ RTSP/1.0\r\nCSeq: 4\r\n\(ua)Session: 1234ABCD\r\nRange: npt=0.000-\r\n\r\n",
            "GET_PARAMETER rtsp://127.0.0.1/au:scanner.au/ RTSP/1.0\r\nCSeq: 5\r\n\(ua)Session: 1234ABCD\r\n\r\n",
            "TEARDOWN rtsp://127.0.0.1/au:scanner.au/ RTSP/1.0\r\nCSeq: 6\r\n\(ua)Session: 1234ABCD\r\n\r\n",
        ]
        let got = await server.receivedRequests
        #expect(got.count == expected.count, "\(got)")
        for (index, (request, want)) in zip(got, expected).enumerated() {
            #expect(request == want, "request \(index + 1)")
        }
    }
}

// MARK: Reconnect cooldown

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rtsp-cooldown-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Opens one connection on `client` and closes it, so the store records a close.
private func connectAndClose(_ client: RTSPClient) async throws {
    try await client.connect()
    _ = try await client.describe()
    await client.close()
}

@Test func connectInsideCooldownThrowsWithoutConnecting() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    let store = InMemoryRTSPCooldownStore()
    do {
        try await within(.seconds(5)) {
            let first = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                                   reconnectCooldown: .milliseconds(300), cooldownStore: store, closeLinger: .zero)
            try await connectAndClose(first)
            #expect(await store.lastClosed(host: "127.0.0.1") != nil)
            #expect(await server.acceptedConnections == 1)

            let second = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                                    reconnectCooldown: .milliseconds(300), cooldownStore: store, closeLinger: .zero)
            do {
                try await second.connect()
                Issue.record("connect inside the cooldown succeeded")
            } catch RTSPError.cooldown(let remaining) {
                #expect(remaining > .zero && remaining <= .milliseconds(300), "\(remaining)")
            }
            // The same client reconnecting is held to the cooldown too.
            await #expect(throws: RTSPError.self) { try await first.connect() }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.acceptedConnections == 1)
        }
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

@Test func cooldownElapsesThenConnects() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    let store = InMemoryRTSPCooldownStore()
    do {
        try await within(.seconds(5)) {
            let first = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                                   reconnectCooldown: .milliseconds(300), cooldownStore: store, closeLinger: .zero)
            try await connectAndClose(first)
            try await Task.sleep(for: .milliseconds(350))
            let second = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                                    reconnectCooldown: .milliseconds(300), cooldownStore: store, closeLinger: .zero)
            try await connectAndClose(second)
            #expect(await server.acceptedConnections == 2)
        }
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

@Test func failedConnectStartsTheCooldown() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    await server.stop()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .milliseconds(300),
                            reconnectCooldown: .seconds(5), cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    try await within(.seconds(3)) {
        // BSD sockets report the refusal at once (Network.framework kept retrying until the timeout).
        await #expect(throws: RTSPError.closed) { try await client.connect() }
        do {
            try await client.connect()
            Issue.record("second connect was attempted")
        } catch RTSPError.cooldown {
        }
    }
}

@Test func teardownReconnectRespectsCooldown() async throws {
    let server = FakeRTSPServer(script: .scannerLike.closeOn(method: "PLAY"))
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .seconds(5), cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    do {
        try await within(.seconds(5)) {
            try await client.connect()
            let (gotBase, _) = try await client.describe()
            _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
            await #expect(throws: RTSPError.closed) { try await client.play() }
            let start = ContinuousClock.now
            await client.teardown()
            #expect(ContinuousClock.now - start < .milliseconds(500))
            #expect(await client.sessionID == nil)
            #expect(await client.unreleasedSessions == ["1234ABCD"])
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.acceptedConnections == 1)
            #expect(!(await server.receivedMethods).contains("TEARDOWN"))
        }
    } catch {
        await server.stop()
        throw error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
}

@Test func fileStorePersistsAcrossInstances() async throws {
    let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("nested/rtsp-cooldown.json")
    let when = Date(timeIntervalSince1970: 1_800_000_000.25)
    await FileRTSPCooldownStore(url: url).recordClosed(host: "192.0.2.1", at: when)
    let reread = await FileRTSPCooldownStore(url: url).lastClosed(host: "192.0.2.1")
    #expect(reread.map { abs($0.timeIntervalSince(when)) < 0.002 } == true)
    #expect(await FileRTSPCooldownStore(url: url).lastClosed(host: "192.0.2.2") == nil)
    // Each host is `{"lastClosed": ISO-8601, "lease": {...}?}` (the flat `host: ISO-8601` is still read).
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]]
    #expect((json?["192.0.2.1"]?["lastClosed"] as? String)?.hasPrefix("2027-01-15T") == true)
}

@Test func corruptFileStoreIsIgnored() async throws {
    let dir = try makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("rtsp-cooldown.json")
    try Data("not json {".utf8).write(to: url)
    let store = FileRTSPCooldownStore(url: url)
    #expect(await store.lastClosed(host: "192.0.2.1") == nil)
    let when = Date()
    await store.recordClosed(host: "192.0.2.1", at: when)
    #expect(await FileRTSPCooldownStore(url: url).lastClosed(host: "192.0.2.1") != nil)
}

@Test func inMemoryStoreKeepsTheLatestClose() async {
    let store = InMemoryRTSPCooldownStore()
    let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
    await store.recordClosed(host: "192.0.2.1", at: late)
    await store.recordClosed(host: "192.0.2.1", at: early)
    #expect(await store.lastClosed(host: "192.0.2.1") == late)
}

// MARK: OPTIONS before DESCRIBE

@Test func describeSendsOptionsFirstOncePerConnection() async throws {
    try await withFake { server, client, _ in
        try await client.connect()
        _ = try await client.describe()
        _ = try await client.describe()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "DESCRIBE"])
        let requests = await server.receivedRequests
        try #require(requests.count == 3)
        #expect(requests[0].hasPrefix("OPTIONS "))
        #expect(requests[0].contains("\r\nCSeq: 1\r\n"))
        #expect(requests[1].contains("\r\nCSeq: 2\r\n"))
    }
}

@Test func explicitOptionsIsNotRepeatedByDescribe() async throws {
    try await withFake { server, client, _ in
        try await client.connect()
        _ = try await client.options()
        _ = try await client.describe()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE"])
    }
}

// MARK: BSD sockets (Task 5b)

/// The proven reference client's close: after the TEARDOWN reply, wait 0.5 s, then half-close
/// (the server sees FIN, not RST), and record the close in the cooldown store only after the
/// socket is closed.
@Test func closeAfterTeardownLingersThenSendsFIN() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    let store = InMemoryRTSPCooldownStore()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .zero, cooldownStore: store)
    #expect(await client.closeLinger == .milliseconds(500))
    var failure: (any Error)?
    do {
        try await within(.seconds(5)) {
            try await client.connect()
            let (gotBase, _) = try await client.describe()
            _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
            await client.close()
            let closedAt = ContinuousClock.now
            #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE", "SETUP", "TEARDOWN"])
            let replies = await server.replies
            let ends = await server.connectionEnds
            try #require(ends.count == 1, "\(ends.map(\.end))")
            #expect(ends[0].end == .fin)
            let teardownReply = try #require(replies.last { $0.method == "TEARDOWN" })
            let gap = ends[0].at - teardownReply.at
            #expect(gap >= .milliseconds(480), "FIN \(gap) after the TEARDOWN reply")
            #expect(gap < .milliseconds(1500), "FIN \(gap) after the TEARDOWN reply")
            // close() returns only after the socket closed and the store has the close.
            let recorded = try #require(await store.lastClosed(host: "127.0.0.1"))
            #expect(abs(recorded.timeIntervalSinceNow) < 1)
            #expect(closedAt >= ends[0].at)
        }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    if let failure { throw failure }
}

/// Every graceful close of an open connection lingers `closeLinger` before FIN, as the proven
/// reference client does, not only a close after an answered TEARDOWN: here DESCRIBE fails (no
/// session, so no TEARDOWN), and the FIN still comes about 0.5 s after the last reply.
@Test func closeAfterFailedDescribeStillLingers() async throws {
    let server = FakeRTSPServer(script: .scannerLike.status(method: "DESCRIBE", code: 500))
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore())
    var failure: (any Error)?
    do {
        try await within(.seconds(5)) {
            try await client.connect()
            await #expect(throws: RTSPError.self) { _ = try await client.describe() }
            await client.close()
            #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE"])
            let replies = await server.replies
            let ends = await server.connectionEnds
            try #require(ends.count == 1, "\(ends.map(\.end))")
            #expect(ends[0].end == .fin)
            let lastReply = try #require(replies.last)
            #expect(lastReply.method == "DESCRIBE")
            let gap = ends[0].at - lastReply.at
            #expect(gap >= .milliseconds(480), "FIN \(gap) after the last reply")
            #expect(gap < .milliseconds(1500), "FIN \(gap) after the last reply")
        }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    if let failure { throw failure }
}

/// A refused connection fails at once (no waiting out `requestTimeout`) and still starts the
/// cooldown, since the attempt reached the host.
@Test func refusedConnectFailsFastWithClosed() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    await server.stop()
    let store = InMemoryRTSPCooldownStore()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(2),
                            reconnectCooldown: .zero, cooldownStore: store, closeLinger: .zero)
    let start = ContinuousClock.now
    _ = try await within(.seconds(4)) {
        await #expect(throws: RTSPError.closed) { try await client.connect() }
    }
    #expect(ContinuousClock.now - start < .milliseconds(500))
    try await eventually { await store.lastClosed(host: "127.0.0.1") != nil }
}

/// An unanswered SYN (TEST-NET-1 is never assigned) gives up at `requestTimeout`.
/// Bounded by the request timeout (plus `lateWakeMargin`), not the kernel's own SYN timeout of
/// about 75 s.
@Test func unansweredConnectTimesOut() async throws {
    let timeout = Duration.milliseconds(300)
    let client = RTSPClient(host: "192.0.2.1", port: 9, requestTimeout: timeout,
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    let start = ContinuousClock.now
    let timedOut = try await within(.seconds(10)) { () -> Bool in
        do {
            try await client.connect()
            Issue.record("connected to TEST-NET-1")
            return false
        } catch let error as RTSPError {
            // .closed only if this machine has no route at all (ENETUNREACH at once).
            #expect(error == .timeout(method: "CONNECT") || error == .closed, "\(error)")
            return error == .timeout(method: "CONNECT")
        }
    }
    let waited = ContinuousClock.now - start
    #expect(waited < timeout + lateWakeMargin, "the connect gave up after \(waited)")
    if timedOut { #expect(waited >= timeout, "the connect timed out after \(waited)") }
}

/// Polls `condition` every 10 ms until it holds, or throws `TimedOut` after `limit`.
private func eventually(_ limit: Duration = .seconds(2),
                        _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await within(limit) {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }
}

// MARK: Single-flight connect (fix round 1)

/// Two concurrent connect() calls share one attempt: one TCP connection, the same outcome.
@Test func concurrentConnectsOpenOneConnection() async throws {
    for trial in 0..<20 {
        let server = FakeRTSPServer()
        let port = try await server.start()
        let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                                reconnectCooldown: .seconds(5), cooldownStore: InMemoryRTSPCooldownStore(),
                                closeLinger: .zero)
        var failure: (any Error)?
        do {
            try await within(.seconds(5)) {
                async let first: Void = client.connect()
                async let second: Void = client.connect()
                _ = try await (first, second)
                // The server counts a connection when its accept loop gets to it, which a busy
                // process can leave for longer than a fixed 50 ms (0 seen under the background
                // clamp; LESSONS.md 2026-11-21): wait for the first, then give a second a moment.
                for _ in 0..<500 where await server.acceptedConnections == 0 { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(50))
                let accepted = await server.acceptedConnections
                #expect(accepted == 1, "trial \(trial)")
                _ = try await client.describe()  // the shared connection works
            }
        } catch {
            failure = error
        }
        _ = try? await within(.seconds(5)) { await client.close() }
        await server.stop()
        if let failure { throw failure }
    }
}

/// A user connect() racing teardown()'s reconnect opens at most one new connection between
/// them, and the session is still torn down.
@Test func userConnectRacingTeardownReconnectOpensAtMostOneConnection() async throws {
    for trial in 0..<20 {
        let server = FakeRTSPServer(script: .scannerLike.closeOn(method: "PLAY"))
        let port = try await server.start()
        let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                                reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(),
                                closeLinger: .zero)
        var failure: (any Error)?
        do {
            try await within(.seconds(5)) {
                try await client.connect()
                let (gotBase, _) = try await client.describe()
                _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
                await #expect(throws: RTSPError.closed) { try await client.play() }
                async let teardown: Void = client.teardown()
                async let connect: Void = client.connect()
                _ = await teardown
                _ = try? await connect
                try await Task.sleep(for: .milliseconds(50))
                let accepted = await server.acceptedConnections
                #expect(accepted <= 2, "trial \(trial): \(accepted)")
                #expect(await server.receivedMethods.contains("TEARDOWN"), "trial \(trial)")
            }
        } catch {
            failure = error
        }
        _ = try? await within(.seconds(5)) { await client.close() }
        await server.stop()
        if let failure { throw failure }
    }
}

// MARK: Hardening (Task 6 follow-up)

/// `teardown(sessionIDs:)` on a fresh connection sends OPTIONS first (a TEARDOWN is never the
/// first request on a connection), then TEARDOWN for each id; any status counts as done, an
/// unanswered one (timeout) doesn't. `describe()` then doesn't repeat OPTIONS.
@Test func teardownOfLeftoverSessionIDs() async throws {
    try await withFake(.scannerLike.status(method: "TEARDOWN", code: 454, once: true)
                        .silence(method: "TEARDOWN", once: true),
                       requestTimeout: .milliseconds(300)) { server, client, _ in
        try await client.connect()
        let start = ContinuousClock.now
        let done = await client.teardown(sessionIDs: ["0000000A", "0000000B", "0000000C"])
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(done == ["0000000A", "0000000C"])
        #expect(await server.receivedMethods == ["OPTIONS", "TEARDOWN", "TEARDOWN", "TEARDOWN"])
        #expect(await server.teardownSessionIDs == ["0000000A", "0000000B", "0000000C"])
        #expect(await client.teardownStatuses == [454, 200])
        // The connection is still usable, and DESCRIBE doesn't repeat OPTIONS.
        _ = try await client.describe()
        #expect(await server.receivedMethods == ["OPTIONS", "TEARDOWN", "TEARDOWN", "TEARDOWN", "DESCRIBE"])
    }
}

/// If OPTIONS isn't answered, no TEARDOWN goes out on that connection.
@Test func teardownOfLeftoverSessionIDsNeedsOptionsFirst() async throws {
    try await withFake(.scannerLike.status(method: "OPTIONS", code: 500, once: true),
                       requestTimeout: .milliseconds(300)) { server, client, _ in
        try await client.connect()
        let done = await client.teardown(sessionIDs: ["0000000A"])
        #expect(done.isEmpty)
        #expect(await server.receivedMethods == ["OPTIONS"])
    }
}

@Test func teardownOfLeftoverSessionIDsWithoutConnectionDoesNothing() async throws {
    let client = RTSPClient(host: "127.0.0.1", port: 9, requestTimeout: .milliseconds(200),
                            reconnectCooldown: .zero, cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    let done = try await within(.seconds(2)) { await client.teardown(sessionIDs: ["0000000A"]) }
    #expect(done.isEmpty)
}

/// `close()` waits for the whole teardown worker, even past `teardown()`'s own 4 × timeout
/// bound, so `unreleasedSessions` is final when it returns.
@Test(.skippedOnCIRunner("250 ms TEARDOWN replies against a 300 ms timeout; too tight on the CI runner"))
func closeWaitsForTheTeardownWorker() async throws {
    // Six slow (answered) TEARDOWNs take longer than 4 × requestTimeout, then the server drops the
    // connection on the seventh; the cooldown forbids the reconnect, so that id is unreleased.
    var script = FakeRTSPServer.Script.scannerLike
    for _ in 0..<6 { script = script.delay(method: "TEARDOWN", seconds: 0.25, once: true) }
    script = script.closeOn(method: "TEARDOWN", once: true)
    let server = FakeRTSPServer(script: script, uniqueSessionIDs: true)
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .milliseconds(300),
                            reconnectCooldown: .seconds(30), cooldownStore: InMemoryRTSPCooldownStore(),
                            closeLinger: .zero)
    var failure: (any Error)?
    do {
        try await within(.seconds(8)) {
            try await client.connect()
            let (gotBase, _) = try await client.describe()
            for _ in 0..<7 { _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000) }
            let issued = await server.issuedSessionIDs
            try #require(issued.count == 7)
            let start = ContinuousClock.now
            await client.close()
            #expect(ContinuousClock.now - start > .milliseconds(1200))
            #expect(await client.unreleasedSessions == [issued[6]])
            #expect(await server.teardownSessionIDs == issued)
        }
    } catch {
        failure = error
    }
    await server.stop()
    if let failure { throw failure }
}

// MARK: Clean and unclean closes (Plan 5 Task 1)

/// The owner's kind of policy, scaled down: a long full cooldown and none after a clean close.
private let cleanZero = RTSPCooldownPolicy(full: .seconds(30), afterCleanClose: .zero)

/// Starts a fake server with `script`, runs `body` against a client with `policy` on `store`
/// (bounded by `limit`), then always closes the client and stops the server.
private func withPolicyFake(
    _ script: FakeRTSPServer.Script = .scannerLike, policy: RTSPCooldownPolicy = cleanZero,
    store: InMemoryRTSPCooldownStore = InMemoryRTSPCooldownStore(), requestTimeout: Duration = .seconds(1),
    _ body: @escaping @Sendable (FakeRTSPServer, RTSPClient, UInt16) async throws -> Void
) async throws {
    let server = FakeRTSPServer(script: script)
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: requestTimeout,
                            cooldownPolicy: policy, cooldownStore: store, closeLinger: .zero)
    var failure: (any Error)?
    do {
        try await within(.seconds(8)) { try await body(server, client, port) }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    if let failure { throw failure }
}

/// OPTIONS, DESCRIBE, SETUP, PLAY on `client`.
private func play(_ client: RTSPClient) async throws {
    try await client.connect()
    let (gotBase, _) = try await client.describe()
    _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
    try await client.play()
}

/// A second client on the same store, with the same 30 s / 0 policy, must be refused (an
/// unclean close) without opening a connection.
private func expectFullCooldown(port: UInt16, store: InMemoryRTSPCooldownStore, server: FakeRTSPServer) async {
    let accepted = await server.acceptedConnections
    let next = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                          cooldownPolicy: cleanZero, cooldownStore: store, closeLinger: .zero)
    do {
        try await next.connect()
        Issue.record("connected right after an unclean close")
        await next.close()
    } catch RTSPError.cooldown(let remaining) {
        #expect(remaining > .seconds(25), "\(remaining)")
    } catch {
        Issue.record("\(error)")
    }
    #expect(await server.acceptedConnections == accepted)
}

@Test func closeAfterAnsweredTeardownIsClean() async throws {
    let store = InMemoryRTSPCooldownStore()
    try await withPolicyFake(store: store) { server, client, port in
        #expect(await client.lastCloseWasClean == nil)
        try await play(client)
        await client.close()
        #expect(await client.teardownStatuses == [200])
        #expect(await client.lastCloseWasClean == true)
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == true)
        // Another client on the same store connects at once: the clean value is zero.
        let next = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                              cooldownPolicy: cleanZero, cooldownStore: store, closeLinger: .zero)
        try await next.connect()
        // The server's count can lag the client's connect by a moment.
        try await eventually { await server.acceptedConnections == 2 }
        await next.close()
    }
}

/// The client's own record of its closes (which never waits on the store) keeps the flag too.
@Test func sameClientReconnectsAtOnceAfterACleanClose() async throws {
    try await withPolicyFake { server, client, _ in
        try await play(client)
        await client.close()
        try await client.connect()  // clean: no wait
        try await eventually { await server.acceptedConnections == 2 }
        await client.close()  // no session on that connection: unclean
        #expect(await client.lastCloseWasClean == false)
        do {
            try await client.connect()
            Issue.record("reconnected right after an unclean close")
        } catch RTSPError.cooldown(let remaining) {
            #expect(remaining > .seconds(25), "\(remaining)")
        }
        #expect(await server.acceptedConnections == 2)
    }
}

@Test(arguments: [454, 500])
func closeAfterRejectedTeardownIsUnclean(code: Int) async throws {
    let store = InMemoryRTSPCooldownStore()
    try await withPolicyFake(.scannerLike.status(method: "TEARDOWN", code: code), store: store) { server, client, port in
        try await play(client)
        await client.close()
        #expect(await client.teardownStatuses == [code])
        #expect(await client.lastCloseWasClean == false)
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
        await expectFullCooldown(port: port, store: store, server: server)
    }
}

@Test func closeAfterUnansweredTeardownIsUnclean() async throws {
    let store = InMemoryRTSPCooldownStore()
    try await withPolicyFake(.scannerLike.silence(method: "TEARDOWN"), store: store,
                             requestTimeout: .milliseconds(300)) { server, client, port in
        try await play(client)
        await client.close()
        #expect(await client.unreleasedSessions == ["1234ABCD"])
        #expect(await client.lastCloseWasClean == false)
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
        await expectFullCooldown(port: port, store: store, server: server)
    }
}

/// A connection that never had a session is unclean (the "health-check connection" hang).
@Test func closeWithoutASessionIsUnclean() async throws {
    let store = InMemoryRTSPCooldownStore()
    try await withPolicyFake(store: store) { server, client, port in
        try await client.connect()
        _ = try await client.describe()
        await client.close()
        #expect(await server.receivedMethods == ["OPTIONS", "DESCRIBE"])
        #expect(await client.lastCloseWasClean == false)
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
        await expectFullCooldown(port: port, store: store, server: server)
    }
}

@Test func serverClosedConnectionIsUnclean() async throws {
    let store = InMemoryRTSPCooldownStore()
    try await withPolicyFake(.scannerLike.closeOn(method: "PLAY"), store: store) { server, client, port in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        await #expect(throws: RTSPError.closed) { try await client.play() }
        await client.close()  // the teardown's reconnect is refused: the close was unclean
        #expect(await client.unreleasedSessions == ["1234ABCD"])
        #expect(await client.lastCloseWasClean == false)
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
        #expect(await server.acceptedConnections == 1)
        await expectFullCooldown(port: port, store: store, server: server)
    }
}

/// A TEARDOWN answered 200 on a connection opened only to send it is still unclean: the session's
/// own connection died, and the new one had no session.
@Test func teardownViaReconnectIsUnclean() async throws {
    let store = InMemoryRTSPCooldownStore()
    try await withPolicyFake(.scannerLike.closeOn(method: "PLAY", once: true), policy: .symmetric(.zero),
                             store: store) { server, client, _ in
        try await client.connect()
        let (gotBase, _) = try await client.describe()
        _ = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
        await #expect(throws: RTSPError.closed) { try await client.play() }
        await client.close()
        #expect(await server.acceptedConnections == 2)
        #expect(await server.teardownSessionIDs == ["1234ABCD"])
        #expect(await client.teardownStatuses == [200])
        #expect(await client.unreleasedSessions.isEmpty)
        #expect(await client.lastCloseWasClean == false)
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
    }
}

@Test func failedConnectIsUnclean() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    await server.stop()
    let store = InMemoryRTSPCooldownStore()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            cooldownPolicy: cleanZero, cooldownStore: store, closeLinger: .zero)
    try await within(.seconds(4)) {
        await #expect(throws: RTSPError.closed) { try await client.connect() }
        try await eventually { await store.lastClose(host: "127.0.0.1") != nil }
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
        #expect(await client.lastCloseWasClean == false)
        await #expect(throws: RTSPError.self) { try await client.connect() }  // the full cooldown
    }
}

// MARK: QA fixes (Plan 5 Task 1: M1, M4)

/// QA probe P4: a request on the link that went unanswered makes its close unclean, even when
/// the TEARDOWN is then answered 200.
@Test func unansweredKeepaliveMakesTheCloseUnclean() async throws {
    try await withPolicyFake(.scannerLike.silence(method: "GET_PARAMETER", once: true),
                             requestTimeout: .milliseconds(300)) { _, client, _ in
        try await play(client)
        await #expect(throws: RTSPError.timeout(method: "GET_PARAMETER")) { try await client.keepalive() }
        await client.close()
        #expect(await client.teardownStatuses == [200])
        #expect(await client.lastCloseWasClean == false)
    }
}

/// An answered non-2xx reply to a request other than TEARDOWN (a keepalive 454) doesn't.
@Test func answeredKeepaliveErrorKeepsTheCloseClean() async throws {
    try await withPolicyFake(.scannerLike.status(method: "GET_PARAMETER", code: 454, once: true)) { _, client, _ in
        try await play(client)
        await #expect(throws: RTSPError.self) { try await client.keepalive() }
        await client.close()
        #expect(await client.lastCloseWasClean == true)
    }
}

/// TEARDOWN answered 200, then the server drops the connection before `close()`: unclean.
@Test func serverCloseAfterAnsweredTeardownIsUnclean() async throws {
    let store = InMemoryRTSPCooldownStore()
    try await withPolicyFake(store: store) { server, client, _ in
        try await play(client)
        await client.teardown()
        #expect(await client.teardownStatuses == [200])
        await server.powerDown()
        try await eventually { await client.lastCloseWasClean == false }
        await server.powerUp()
        await client.close()
        #expect(await client.lastCloseWasClean == false)
        #expect(await store.lastClose(host: "127.0.0.1")?.clean == false)
    }
}

/// A non-2xx reply to a leftover TEARDOWN (`teardown(sessionIDs:)`) makes the link unclean.
@Test func rejectedLeftoverTeardownIsUnclean() async throws {
    try await withPolicyFake(.scannerLike.status(method: "TEARDOWN", code: 454, once: true)) { _, client, _ in
        try await play(client)
        #expect(await client.teardown(sessionIDs: ["99999999"]) == ["99999999"])
        await client.close()
        #expect(await client.teardownStatuses == [454, 200])
        #expect(await client.unreleasedSessions.isEmpty)
        #expect(await client.lastCloseWasClean == false)
    }
}

/// A session left unreleased by an earlier connection keeps a later, otherwise clean, close unclean.
@Test func staleUnreleasedSessionMakesALaterLinkUnclean() async throws {
    let server = FakeRTSPServer(script: .scannerLike.closeOn(method: "PLAY", once: true), uniqueSessionIDs: true)
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            cooldownPolicy: RTSPCooldownPolicy(full: .milliseconds(300), afterCleanClose: .zero),
                            cooldownStore: InMemoryRTSPCooldownStore(), closeLinger: .zero)
    var failure: (any Error)?
    do {
        try await within(.seconds(8)) {
            try await client.connect()
            let (gotBase, _) = try await client.describe()
            let first = try await client.setup(controlURL: gotBase + "trackID=1", clientPort: 50000)
            await #expect(throws: RTSPError.closed) { try await client.play() }
            await client.teardown()  // the reconnect is inside the cooldown: unreleased
            #expect(await client.unreleasedSessions == [first])
            try await Task.sleep(for: .milliseconds(400))
            try await play(client)
            await client.close()
            #expect(await client.teardownStatuses == [200])
            #expect(await client.unreleasedSessions == [first])
            #expect(await client.lastCloseWasClean == false)
        }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    if let failure { throw failure }
}

/// A SETUP that timed out on a link that already had a session leaves it unclean.
@Test func timedOutSetupOnALinkWithASessionIsUnclean() async throws {
    try await withPolicyFake(requestTimeout: .milliseconds(300)) { server, client, _ in
        try await play(client)
        await server.replaceScript(.scannerLike.silence(method: "SETUP"))
        await #expect(throws: RTSPError.timeout(method: "SETUP")) {
            _ = try await client.setup(controlURL: "rtsp://127.0.0.1/au:scanner.au/trackID=1", clientPort: 50002)
        }
        await client.close()
        #expect(await client.lastCloseWasClean == false)
    }
}

// MARK: Task 1 QA leftovers (Plan 5 Task 2 round)

/// After `play`, the server stops answering `method`; a request for it is sent in a task, and
/// this returns once the server has it.
private func unansweredRequest(_ method: String, on client: RTSPClient, server: FakeRTSPServer)
    async throws -> Task<Void, any Error>
{
    await server.replaceScript(.scannerLike.silence(method: method))
    let before = await server.receivedMethods.count
    let task = Task {
        if method == "DESCRIBE" { _ = try await client.describe() } else if method == "OPTIONS" {
            _ = try await client.options()
        } else { try await client.keepalive() }
    }
    try await eventually { await server.receivedMethods.dropFirst(before).contains(method) }
    return task
}

/// A request whose caller was cancelled before its reply makes the close unclean.
@Test(arguments: ["DESCRIBE", "GET_PARAMETER"])
func cancelledRequestMakesTheCloseUnclean(method: String) async throws {
    try await withPolicyFake(requestTimeout: .seconds(3)) { server, client, _ in
        try await play(client)
        let task = try await unansweredRequest(method, on: client, server: server)
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        await server.replaceScript(.scannerLike)
        await client.close()
        #expect(await client.teardownStatuses == [200])
        #expect(await client.lastCloseWasClean == false)
    }
}

/// A request pre-empted by `teardown()` before its reply makes the close unclean, though the
/// TEARDOWN is answered 200.
@Test func requestPreemptedByTeardownMakesTheCloseUnclean() async throws {
    try await withPolicyFake(requestTimeout: .seconds(3)) { server, client, _ in
        try await play(client)
        let task = try await unansweredRequest("GET_PARAMETER", on: client, server: server)
        await client.teardown()
        await #expect(throws: RTSPError.preempted) { try await task.value }
        await client.close()
        #expect(await client.teardownStatuses == [200])
        #expect(await client.lastCloseWasClean == false)
    }
}

/// A request still waiting for its reply when `close()` runs (after a clean TEARDOWN, so nothing
/// pre-empts it) makes the close unclean.
@Test func requestPendingAtCloseMakesTheCloseUnclean() async throws {
    try await withPolicyFake(requestTimeout: .seconds(3)) { server, client, _ in
        try await play(client)
        await client.teardown()
        #expect(await client.teardownStatuses == [200])
        let task = try await unansweredRequest("OPTIONS", on: client, server: server)
        await client.close()
        await #expect(throws: RTSPError.closed) { try await task.value }
        #expect(await client.lastCloseWasClean == false)
    }
}

/// A store that loses every write (and so knows of no close).
private actor WriteDroppingStore: RTSPCooldownStore {
    func claim(hosts: [String], pid: Int32, policy: RTSPCooldownPolicy) -> RTSPCooldownClaim { .claimed }
    func closeHistory(host: String) -> RTSPCloseHistory? { nil }
    func recordClosed(host: String, at: Date, clean: Bool) {}
    func recordOpened(host: String, at: Date, pid: Int32) {}
    func clear(host: String) {}
    var lastWriteError: String? { "dropped" }
}

/// If the store's write is lost, the client's own record still makes the next connect wait the
/// full cooldown after an unclean close.
@Test func localRecordHoldsTheFullCooldownWhenTheStoreLosesWrites() async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            cooldownPolicy: cleanZero, cooldownStore: WriteDroppingStore(), closeLinger: .zero)
    var failure: (any Error)?
    do {
        try await within(.seconds(5)) {
            try await client.connect()
            _ = try await client.describe()
            await client.close()  // no session: unclean
            do {
                try await client.connect()
                Issue.record("reconnected right after an unclean close")
            } catch RTSPError.cooldown(let remaining) {
                #expect(remaining > .seconds(25), "\(remaining)")
            }
        }
    } catch {
        failure = error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    if let failure { throw failure }
}
