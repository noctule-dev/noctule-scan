// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
@testable import NoctuleKit

private struct TimedOut: Error {}
private struct SocketSetupFailed: Error { var call: String; var code: Int32 }

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

private func milliseconds(_ duration: Duration) -> Int32 {
    Int32(max(0, duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000))
}

private func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

private func boundPort(_ fd: Int32) -> UInt16 {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}

/// How one read on a raw test socket ended.
private enum ReadOutcome: Equatable {
    case data(Data)
    /// read() returned 0: the peer sent FIN.
    case eof
    /// read() failed with this errno (ECONNRESET means the peer sent RST).
    case error(Int32)
    case timeout
}

/// One bounded read on a blocking test socket (poll, then read), off the cooperative pool.
/// Runs a blocking `body` on a dispatch thread, never a cooperative one: a `Task.detached` that
/// blocks in `poll` holds one of the pool's few threads (three on the CI runner) for the whole
/// wait (LESSONS.md 2026-11-21).
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}

private func readOnce(_ fd: Int32, timeout: Duration = .seconds(2)) async -> ReadOutcome {
    await offThePool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, milliseconds(timeout))
        if ready == 0 { return .timeout }
        if ready < 0 { return .error(errno) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 { return .data(Data(buffer[0..<count])) }
        if count == 0 { return .eof }
        return .error(errno)
    }
}

/// Reads until the stream ends (or `timeout` passes with nothing arriving); returns the data
/// and how it ended.
private func readToEnd(_ fd: Int32, timeout: Duration = .seconds(2)) async -> (Data, ReadOutcome) {
    var collected = Data()
    while true {
        let outcome = await readOnce(fd, timeout: timeout)
        guard case .data(let chunk) = outcome else { return (collected, outcome) }
        collected.append(chunk)
    }
}

private func writeAll(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
}

/// A blocking BSD TCP listener on 127.0.0.1 for tests. Every wait is bounded.
private final class LoopbackListener: Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketSetupFailed(call: "socket", code: errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketSetupFailed(call: "bind/listen", code: code)
        }
        self.fd = fd
        port = boundPort(fd)
    }

    /// Accepts one connection, or throws `TimedOut`.
    func accept(timeout: Duration = .seconds(2)) async throws -> Int32 {
        let fd = self.fd
        let accepted: Int32 = await offThePool {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, milliseconds(timeout)) == 1 else { return -1 }
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 {
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            }
            return client
        }
        guard accepted >= 0 else { throw TimedOut() }
        return accepted
    }

    func close() { Darwin.close(fd) }
}

/// Sends one UDP datagram from a fresh loopback socket.
private func sendDatagram(_ data: Data, to port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return }
    defer { Darwin.close(fd) }
    var address = loopbackAddress(port: port)
    _ = data.withUnsafeBytes { bytes in
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// Polls `condition` every 10 ms until it holds, or throws `TimedOut` after `limit`.
private func eventually(_ limit: Duration = .seconds(2),
                        _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await within(limit) {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }
}

// MARK: TCP

@Test func tcpConnectToClosedPortFailsFastWithRefused() async throws {
    let listener = try LoopbackListener()
    let port = listener.port
    listener.close()
    let start = ContinuousClock.now
    _ = try await within(.seconds(3)) {
        await #expect(throws: POSIXSocketError.connectFailed(ECONNREFUSED)) {
            _ = try await TCPStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(2))
        }
    }
    // Fast means before the connect's own 2 s timeout, not after it: a thread that wakes late (the
    // CI runner took 0.585 s against a 0.5 s bound here; LESSONS.md 2026-11-20) can't reach it.
    #expect(ContinuousClock.now - start < .seconds(2), "the refusal waited for the connect timeout")
}

/// 192.0.2.1 (TEST-NET-1) is never assigned, so a SYN to it goes unanswered: connect must give up
/// at its timeout. (Without a route at all it fails at once with ENETUNREACH/EHOSTUNREACH,
/// which is also bounded.)
///
/// Bounded means at its timeout give or take late wakeups (3 s of margin; the CI runner took up to
/// 2.2 s here against a 1 s bound, LESSONS.md 2026-11-21), not the kernel's own SYN timeout of
/// about 75 s; and never before the timeout when it times out.
@Test func tcpConnectToUnansweredAddressIsBoundedByTheTimeout() async throws {
    let timeout = Duration.milliseconds(300)
    let start = ContinuousClock.now
    let timedOut = try await within(.seconds(10)) { () -> Bool in
        do {
            _ = try await TCPStream.connect(host: "192.0.2.1", port: 9, timeout: timeout)
            Issue.record("connected to TEST-NET-1")
            return false
        } catch let error as POSIXSocketError {
            let allowed: [POSIXSocketError] = [.connectTimedOut, .connectFailed(ENETUNREACH), .connectFailed(EHOSTUNREACH)]
            #expect(allowed.contains(error), "\(error)")
            return error == .connectTimedOut
        }
    }
    let waited = ContinuousClock.now - start
    #expect(waited < timeout + .seconds(3), "the connect gave up after \(waited)")
    if timedOut { #expect(waited >= timeout, "the connect timed out after \(waited)") }
}

/// A connect waiting for its handshake doesn't hold a cooperative thread. More connects at once
/// than the pool has threads (one per core), each to 127.0.0.2 for 5 s: that address routes to the
/// loopback interface but isn't this Mac's, so the SYN goes unanswered without leaving the machine.
/// Meanwhile this test's 50 ms sleep must end on time. A connect that waited by blocking in
/// `poll` held every pool thread for the 5 s, and on the 3-core CI runner starved the loopback RTSP
/// tests' own connects into `.timeout(method: "CONNECT")` (LESSONS.md 2026-11-21).
@Test func unansweredConnectsLeaveThePoolFree() async throws {
    let connects = ProcessInfo.processInfo.activeProcessorCount + 1
    let timeout = Duration.seconds(5)
    try await within(.seconds(120)) {
        try await withThrowingTaskGroup(of: POSIXSocketError?.self) { group in
            for _ in 0..<connects {
                group.addTask {
                    do {
                        _ = try await TCPStream.connect(host: "127.0.0.2", port: 9, timeout: timeout)
                        return nil
                    } catch let error as POSIXSocketError {
                        return error
                    }
                }
            }
            let asleep = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(50))
            let late = ContinuousClock.now - asleep - .milliseconds(50)
            print("unansweredConnectsLeaveThePoolFree: a 50 ms sleep ended \(late) late while \(connects) connects waited")
            var outcomes: [POSIXSocketError?] = []
            for try await outcome in group { outcomes.append(outcome) }
            // Only a connect left waiting tests anything; where 127.0.0.2 answers (a Mac with it
            // aliased on lo0) the connects end at once and this passes without measuring anything.
            if outcomes.allSatisfy({ $0 == .connectTimedOut }) {
                #expect(late < .seconds(3), "a 50 ms sleep ended \(late) late while \(connects) connects waited (\(connects - 1) cores)")
            } else {
                #expect(!outcomes.contains(nil), "connected to 127.0.0.2: \(outcomes)")
            }
        }
    }
}

// MARK: TCP connect: cancellation and the per-address fallback (review I2, I3)

/// Whether a connect to 127.0.0.2 is left waiting here: that address routes to lo0 but isn't this
/// Mac's, so its SYN goes unanswered without leaving the machine, unless someone aliased it.
private let unansweredLoopbackWaits: Bool = {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.2")
    address.sin_port = UInt16(7).bigEndian
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result != 0, errno == EINPROGRESS else { return false }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    return poll(&descriptor, 1, 200) == 0  // at planning time, before any test runs
}()

/// How many of this process's TCP sockets are connected, or connecting, to `host`:`port` (read
/// from the kernel's per-descriptor socket info, so other tests' sockets don't count).
private func tcpSockets(to host: String, port: UInt16) -> Int {
    let pid = getpid()
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return -1 }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 64)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
    let wanted = inet_addr(host)
    var count = 0
    for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
        var info = socket_fdinfo()
        let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
        guard read == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
        let endpoints = info.psi.soi_proto.pri_tcp.tcpsi_ini
        if endpoints.insi_faddr.ina_46.i46a_addr4.s_addr == wanted,
           UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoints.insi_fport)) == port { count += 1 }
    }
    return count
}

/// A cancelled connect ends at once with `CancellationError`, long before its deadline, and closes
/// its socket. Cancellation is how a stop, a quit or a sleep cuts short a connect to an unreachable
/// scanner. (Port 7, which no other test connects to, so the socket count is this test's alone.)
@Test(.enabled(if: unansweredLoopbackWaits, "127.0.0.2 answers on this Mac (aliased on lo0)"))
func cancelledConnectsEndAtOnceAndCloseTheirSockets() async throws {
    let connects = 8
    let tasks = (0..<connects).map { _ in
        Task { () -> (any Error)? in
            do {
                _ = try await TCPStream.connect(host: "127.0.0.2", port: 7, timeout: .seconds(5))
                return nil
            } catch {
                return error
            }
        }
    }
    // Every connect is waiting on its socket before the cancel.
    try await eventually(.seconds(4)) { tcpSockets(to: "127.0.0.2", port: 7) == connects }
    let cancelled = ContinuousClock.now
    for task in tasks { task.cancel() }
    for task in tasks {
        let error = await task.value
        #expect(error is CancellationError, "ended with \(String(describing: error))")
    }
    let took = ContinuousClock.now - cancelled
    #expect(took < .seconds(2), "the cancelled connects took \(took) to end (their deadline was 5 s away)")
    #expect(tcpSockets(to: "127.0.0.2", port: 7) == 0, "sockets left open")
}

/// A loopback address for `port`, through the resolver (a numeric host: one address, no lookup).
private func loopback(_ host: String, _ port: UInt16) async throws -> SocketAddress {
    try #require(await SocketAddress.resolve(host: host, port: port, socketType: SOCK_STREAM, limit: .seconds(2)).first)
}

/// A refused first address falls back to the next, which connects.
@Test func aRefusedAddressFallsBackToTheNext() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let closed = try LoopbackListener()
    let closedPort = closed.port
    closed.close()
    let port = listener.port
    try await within(.seconds(10)) {
        let addresses = [try await loopback("127.0.0.1", closedPort), try await loopback("127.0.0.1", port)]
        let stream = try await TCPStream.connect(to: addresses, deadline: .now + .seconds(2))
        let server = try await listener.accept()
        Darwin.close(server)
        #expect(stream.remoteAddress == "127.0.0.1")
        await stream.close()
    }
}

/// A first address that waits out the deadline leaves no time for the next: it isn't tried.
@Test(.enabled(if: unansweredLoopbackWaits, "127.0.0.2 answers on this Mac (aliased on lo0)"))
func anUnansweredAddressThatUsesTheDeadlineLeavesTheNextUntried() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let port = listener.port
    try await within(.seconds(10)) {
        let addresses = [try await loopback("127.0.0.2", 8), try await loopback("127.0.0.1", port)]  // port 8: 7 is the cancel test's
        await #expect(throws: POSIXSocketError.connectTimedOut) {
            _ = try await TCPStream.connect(to: addresses, deadline: .now + .milliseconds(300))
        }
        await #expect(throws: TimedOut.self) { _ = try await listener.accept(timeout: .milliseconds(300)) }
    }
}

/// With the deadline already gone (as when the task resumes late on a busy machine), the first
/// address is still tried and a connection the kernel makes at once is taken, and a refusal is
/// reported as one; a second address isn't tried (the loop then reports the deadline, as it always
/// has). (Round 4's cause 2, which only a load sweep caught before: review N9.)
@Test func aDeadlineAlreadyPastTriesOnlyTheFirstAddress() async throws {
    let first = try LoopbackListener()
    defer { first.close() }
    let second = try LoopbackListener()
    defer { second.close() }
    let closed = try LoopbackListener()
    let closedPort = closed.port
    closed.close()
    let firstPort = first.port, secondPort = second.port
    try await within(.seconds(10)) {
        let past = ContinuousClock.now - .seconds(1)
        let stream = try await TCPStream.connect(
            to: [try await loopback("127.0.0.1", firstPort), try await loopback("127.0.0.1", secondPort)], deadline: past)
        Darwin.close(try await first.accept())
        await stream.close()
        await #expect(throws: POSIXSocketError.connectFailed(ECONNREFUSED)) {
            _ = try await TCPStream.connect(to: [try await loopback("127.0.0.1", closedPort)], deadline: past)
        }
        await #expect(throws: POSIXSocketError.connectTimedOut) {
            _ = try await TCPStream.connect(
                to: [try await loopback("127.0.0.1", closedPort), try await loopback("127.0.0.1", secondPort)], deadline: past)
        }
        await #expect(throws: TimedOut.self) { _ = try await second.accept(timeout: .milliseconds(300)) }
    }
}

@Test func tcpRoundTripAndRemoteAddress() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let port = listener.port
    try await within(.seconds(5)) {
        let stream = try await TCPStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(1))
        let server = try await listener.accept()
        #expect(stream.remoteAddress == "127.0.0.1")
        try await stream.send(Data("hello".utf8))
        #expect(await readOnce(server) == .data(Data("hello".utf8)))
        writeAll(server, "world")
        var iterator = stream.incoming.makeAsyncIterator()
        #expect(await iterator.next() == Data("world".utf8))
        Darwin.close(server)
        await stream.close()
    }
}

@Test func tcpIncomingFinishesWhenThePeerCloses() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let port = listener.port
    try await within(.seconds(5)) {
        let stream = try await TCPStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(1))
        let server = try await listener.accept()
        Darwin.close(server)
        var iterator = stream.incoming.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        await stream.close()
    }
}

/// The close sequence the proven Python client uses: wait `linger`, `shutdown(SHUT_WR)` (the
/// server reads EOF, i.e. FIN, not ECONNRESET), drain until the server closes, then `close()`.
@Test func tcpGracefulCloseLingersThenSendsFINAndWaitsForTheServer() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let port = listener.port
    try await within(.seconds(5)) {
        let stream = try await TCPStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(1))
        let server = try await listener.accept()
        let requested = ContinuousClock.now
        let closing = Task { await stream.close(linger: .milliseconds(300), drain: .seconds(1)); return ContinuousClock.now }
        // Data that arrives while the client lingers must be drained, not left unread (which
        // would make close() send RST).
        writeAll(server, "late reply")
        let (_, end) = await readToEnd(server)
        let finAt = ContinuousClock.now
        #expect(end == .eof, "server saw \(end), not FIN")
        #expect(finAt - requested >= .milliseconds(300), "FIN came before the linger")
        try await Task.sleep(for: .milliseconds(50))
        let serverClosedAt = ContinuousClock.now
        Darwin.close(server)
        let closedAt = await closing.value
        #expect(closedAt >= serverClosedAt, "close() returned before the server closed its side")
        await #expect(throws: POSIXSocketError.closed) { try await stream.send(Data("x".utf8)) }
    }
}

/// If the server never closes its side, close() still returns after `drain`, and the server
/// still sees FIN, never RST, even for data it sends during the drain.
@Test func tcpGracefulCloseIsBoundedWhenTheServerNeverCloses() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }
    let port = listener.port
    try await within(.seconds(5)) {
        let stream = try await TCPStream.connect(host: "127.0.0.1", port: port, timeout: .seconds(1))
        let server = try await listener.accept()
        defer { Darwin.close(server) }
        let start = ContinuousClock.now
        let closing = Task { await stream.close(linger: .zero, drain: .milliseconds(300)) }
        #expect(await readOnce(server) == .eof)
        writeAll(server, "unsolicited")  // drained by the client
        await closing.value
        let took = ContinuousClock.now - start
        #expect(took >= .milliseconds(250) && took < .milliseconds(900), "\(took)")
        // A close with unread data would have sent RST, and this read would fail ECONNRESET.
        #expect(await readOnce(server, timeout: .milliseconds(300)) == .eof)
        await stream.close()  // idempotent
    }
}

// MARK: UDP

private final class Received: Sendable {
    private let items = Mutex<[(Data, String?)]>([])
    func append(_ data: Data, _ source: String?) { items.withLock { $0.append((data, source)) } }
    var count: Int { items.withLock { $0.count } }
    var all: [(Data, String?)] { items.withLock { $0 } }
}

@Test func udpBindReceiveAndClose() async throws {
    let socket = try UDPReceiveSocket.bind(ipv6: false)
    let port = socket.port
    #expect(port != 0)
    let received = Received()
    socket.start { data, source, _ in received.append(data, source) }
    sendDatagram(Data("abc".utf8), to: port)
    try await eventually { received.count == 1 }
    #expect(received.all.first?.0 == Data("abc".utf8))
    #expect(received.all.first?.1 == "127.0.0.1")

    let start = ContinuousClock.now
    await socket.close()
    #expect(ContinuousClock.now - start < .milliseconds(300), "close waited out the receive timeout")
    sendDatagram(Data("after".utf8), to: port)
    try await Task.sleep(for: .milliseconds(100))
    #expect(received.count == 1)

    // The port is really released: a new socket can bind it.
    let probe = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer { Darwin.close(probe) }
    var address = loopbackAddress(port: port)
    address.sin_addr.s_addr = INADDR_ANY
    let rebound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(rebound == 0)
    await socket.close()  // idempotent
}
