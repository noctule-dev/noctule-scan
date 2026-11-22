// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

// Plain BSD sockets for the audio path (RTSP over TCP, RTP over UDP).
//
// Network.framework connections (NWConnection for RTSP, NWListener for RTP) sending byte-identical
// requests left the SDS200's whole network service hung, while a Python client on BSD sockets did
// not (LESSONS.md, 2026-11-08). These wrappers mirror that client: default socket options (only
// SO_NOSIGPIPE; no ECN, Fast Open, or keepalive changes), a bounded connect, and a graceful close
// (linger, `shutdown(SHUT_WR)`, drain to EOF, `close()`), never an RST via `SO_LINGER` 0.
//
// Each socket's file descriptor is owned by one dedicated thread, which blocks in `poll` on the
// socket and a wake pipe, and is the only code that ever closes the descriptor. Other threads write
// (TCP only) while holding a lock that also guards the "open" flag, so nothing touches a closed or
// reused descriptor.

/// Errors from the BSD-socket wrappers used by the audio path.
enum POSIXSocketError: Error, Equatable, Sendable {
    case resolveFailed(String)
    case socketFailed(Int32)
    /// `connect` failed with this errno (e.g. ECONNREFUSED).
    case connectFailed(Int32)
    case connectTimedOut
    case sendFailed(Int32)
    case bindFailed(Int32)
    /// The socket was closed (or closing) when the operation ran.
    case closed
}

// MARK: Addresses

/// Address-text helpers shared by `RTSPClient` and `RTPReceiver`.
enum IPAddressText {
    /// Lowercased, without a `%scope` suffix or brackets, and with IPv4-mapped IPv6
    /// (`::ffff:a.b.c.d`) reduced to plain IPv4.
    static func normalized(_ text: String) -> String {
        var text = text.lowercased()
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        let mapped = "::ffff:"
        if text.hasPrefix(mapped) {
            let rest = String(text.dropFirst(mapped.count))
            if isIPv4(rest) { return rest }
        }
        return text
    }

    static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }

    static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, text, &address) == 1
    }

    static func isLiteral(_ text: String) -> Bool { isIPv4(text) || isIPv6(text) }

    /// The numeric host of a socket address, normalized; nil if it can't be formatted.
    static func numericHost(_ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return normalized(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
}

/// A resolved socket address, kept as bytes so it can cross concurrency domains.
struct SocketAddress: Sendable {
    let family: Int32
    private let bytes: [UInt8]

    init(_ address: UnsafePointer<sockaddr>, length: socklen_t) {
        family = Int32(address.pointee.sa_family)
        bytes = Array(UnsafeRawBufferPointer(start: address, count: Int(length)))
    }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        bytes.withUnsafeBytes { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
        }
    }

    /// `getaddrinfo` for `host`, bounded by `limit` (it can't be cancelled, so the loser of the
    /// race is left to finish on its own). Empty if it fails or runs out of time.
    static func resolve(host: String, port: UInt16, socketType: Int32, limit: Duration) async -> [SocketAddress] {
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let once = Mutex(false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: [SocketAddress]) {
                let first = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task.detached { finish(lookUp(host: host, port: port, socketType: socketType)) }
            Task {
                try? await Task.sleep(for: limit)
                finish([])
            }
        }
    }

    private static func lookUp(host: String, port: UInt16, socketType: Int32) -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = socketType
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return [] }
        defer { freeaddrinfo(list) }
        var out: [SocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let info = cursor {
            if let address = info.pointee.ai_addr,
               info.pointee.ai_family == AF_INET || info.pointee.ai_family == AF_INET6 {
                out.append(SocketAddress(address, length: info.pointee.ai_addrlen))
            }
            cursor = info.pointee.ai_next
        }
        return out
    }
}

private func milliseconds(_ duration: Duration) -> Int32 {
    let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    return Int32(clamping: max(0, ms))
}

private func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
}

private func sleep(for duration: Duration) {
    guard duration > .zero else { return }
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    Thread.sleep(forTimeInterval: seconds)
}

// MARK: Socket core

/// One socket descriptor, its wake pipe, and the close handshake between callers and the
/// descriptor's owning thread.
private final class SocketCore: Sendable {
    let fd: Int32
    let wakeRead: Int32
    let wakeWrite: Int32

    private struct State {
        var open = true
        var linger: Duration = .zero
        var drain: Duration = .seconds(1)
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Takes ownership of `fd` (closing it if the wake pipe can't be made).
    init(fd: Int32) throws(POSIXSocketError) {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw .socketFailed(code)
        }
        setNonBlocking(pipeFDs[1])
        self.fd = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
    }

    /// Runs `body` with the descriptor while holding the lock, or returns nil once a close has
    /// been requested.
    func withOpenDescriptor<R: Sendable>(_ body: (Int32) -> R) -> R? {
        state.withLock { state in state.open ? body(fd) : nil }
    }

    /// Asks the owning thread to close. Only the first request's parameters count.
    func requestClose(linger: Duration, drain: Duration) {
        let first = state.withLock { state -> Bool in
            guard state.open else { return false }
            state.open = false
            state.linger = linger
            state.drain = drain
            return true
        }
        if first {
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
    }

    var closeParameters: (linger: Duration, drain: Duration) {
        state.withLock { ($0.linger, $0.drain) }
    }

    /// Called by the owning thread (or by a never-started socket's close) exactly once.
    func finish() {
        Darwin.close(fd)
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = false
            state.finished = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = state.withLock { state -> Bool in
                if state.finished { return true }
                state.waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Blocks until a close has been requested (the wake pipe is readable).
    func waitForCloseRequest() {
        var descriptor = pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
        while poll(&descriptor, 1, -1) <= 0 {}
    }
}

// MARK: TCP

/// A TCP connection over a plain BSD socket.
///
/// `incoming` yields bytes in arrival order and finishes when the peer closes (EOF), the
/// connection fails, or `close` is called. `close(linger:drain:)` mirrors the proven Python
/// client: wait `linger`, `shutdown(SHUT_WR)` (the peer sees FIN), read and discard until EOF or
/// `drain` passes, then `close()`. Closing with unread data would make the kernel send RST, so
/// the drain also keeps the close graceful.
final class TCPStream: Sendable {
    /// The connected peer's IP literal (normalized: no brackets, scope, or IPv4 mapping).
    let remoteAddress: String
    let incoming: AsyncStream<Data>
    private let core: SocketCore

    private init(core: SocketCore, remoteAddress: String) {
        self.core = core
        self.remoteAddress = remoteAddress
        let (incoming, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.incoming = incoming
        let thread = Thread { Self.run(core, continuation) }
        thread.name = "NoctuleKit.TCPStream"
        thread.start()
    }

    deinit { core.requestClose(linger: .zero, drain: .seconds(1)) }

    /// Resolves `host` and connects to each address in turn (a non-blocking `connect` checked
    /// every few milliseconds, suspending in between, so it honours cancellation and holds no
    /// thread while it waits) until one succeeds or `timeout` has passed.
    /// Throws `.connectFailed(errno)` for a refusal or unreachable network, `.connectTimedOut`,
    /// `.resolveFailed`, or `CancellationError`.
    static func connect(host: String, port: UInt16, timeout: Duration) async throws -> TCPStream {
        let deadline = ContinuousClock.now + timeout
        let addresses = await SocketAddress.resolve(
            host: host, port: port, socketType: SOCK_STREAM, limit: min(timeout, .seconds(2)))
        guard !addresses.isEmpty else { throw POSIXSocketError.resolveFailed(host) }
        return try await connect(to: addresses, deadline: deadline)
    }

    /// Connects to each of `addresses` in turn until one succeeds; a `POSIXSocketError` from one
    /// moves on to the next while the deadline lasts. Internal so the fallback can be tested
    /// without a resolver (whose order for a name like `localhost` varies).
    static func connect(to addresses: [SocketAddress], deadline: ContinuousClock.Instant) async throws -> TCPStream {
        var lastError = POSIXSocketError.connectTimedOut
        for (index, address) in addresses.enumerated() {
            // The first address is always tried (its own wait enforces the deadline): a resolve
            // that returned late on a busy machine mustn't time out a connect never attempted.
            guard index == 0 || ContinuousClock.now < deadline else {
                lastError = .connectTimedOut
                break
            }
            do {
                return try await connect(to: address, deadline: deadline)
            } catch let error as POSIXSocketError {
                lastError = error
            }
        }
        throw lastError
    }

    private static func connect(to address: SocketAddress, deadline: ContinuousClock.Instant) async throws -> TCPStream {
        let fd = socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXSocketError.socketFailed(errno) }
        var handedOff = false
        defer { if !handedOff { Darwin.close(fd) } }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd)

        let result = address.withSockaddr { Darwin.connect(fd, $0, $1) }
        if result != 0 {
            let code = errno
            guard code == EINPROGRESS || code == EINTR else { throw POSIXSocketError.connectFailed(code) }
            // Look without waiting, then suspend between looks (as `send` does): a `poll` that
            // waited held a cooperative thread for the whole connect, and a few unanswered connects
            // starved every other task on a 3-core machine (LESSONS.md 2026-11-21). The socket is
            // looked at before the deadline is, and the first look always gets one more slice, so
            // a handshake (or a refusal) the kernel finished at once isn't called a timeout just
            // because this task resumed late on a busy machine.
            var looked = false
            while true {
                try Task.checkCancellation()
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 0)
                if ready > 0 { break }
                if ready < 0, errno != EINTR { throw POSIXSocketError.connectFailed(errno) }
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero || !looked else { throw POSIXSocketError.connectTimedOut }
                looked = true
                try await Task.sleep(for: max(.milliseconds(1), min(remaining, .milliseconds(5))))
            }
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
            if soError != 0 { throw POSIXSocketError.connectFailed(soError) }
        }

        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let literal: String? = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &peerLength) == 0 ? IPAddressText.numericHost($0, peerLength) : nil
            }
        }
        guard let literal else { throw POSIXSocketError.connectFailed(ENOTCONN) }
        handedOff = true  // SocketCore owns (and on failure closes) the descriptor from here
        let core = try SocketCore(fd: fd)
        return TCPStream(core: core, remoteAddress: literal)
    }

    /// Writes all of `data`. Throws `.closed` once a close has been requested, `.sendFailed`
    /// on a socket error, or `CancellationError` while waiting for buffer space.
    func send(_ data: Data) async throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let start = offset
            let outcome: (Int, Int32)? = core.withOpenDescriptor { fd in
                let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + start, $0.count - start, 0) }
                return (count, count < 0 ? errno : 0)
            }
            guard let (count, code) = outcome else { throw POSIXSocketError.closed }
            if count > 0 {
                offset += count
            } else if code == EAGAIN || code == ENOBUFS {
                try await Task.sleep(for: .milliseconds(5))
            } else if code != EINTR {
                throw POSIXSocketError.sendFailed(code)
            }
        }
    }

    /// Closes gracefully (see the type's notes) and returns once the descriptor is closed.
    /// Idempotent; only the first call's `linger` and `drain` apply.
    func close(linger: Duration = .zero, drain: Duration = .seconds(1)) async {
        core.requestClose(linger: linger, drain: drain)
        await core.waitUntilFinished()
    }

    /// The descriptor's owning thread: read until a close is requested, then close gracefully.
    private static func run(_ core: SocketCore, _ continuation: AsyncStream<Data>.Continuation) {
        let fd = core.fd
        var buffer = [UInt8](repeating: 0, count: 65536)
        var peerEnded = false
        reading: while true {
            var descriptors = [
                pollfd(fd: peerEnded ? -1 : fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: core.wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break reading
            }
            if descriptors[1].revents != 0 { break reading }
            guard descriptors[0].revents != 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
            } else if count == 0 {
                peerEnded = true
                continuation.finish()
            } else if errno != EAGAIN && errno != EINTR {
                peerEnded = true
                continuation.finish()
            }
        }
        continuation.finish()
        core.waitForCloseRequest()

        let (linger, drain) = core.closeParameters
        sleep(for: linger)
        shutdown(fd, SHUT_WR)
        if !peerEnded {
            let deadline = ContinuousClock.now + drain
            draining: while true {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { break draining }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, max(1, milliseconds(remaining)))
                if ready == 0 { break draining }
                if ready < 0 {
                    if errno == EINTR { continue }
                    break draining
                }
                let count = read(fd, &buffer, buffer.count)
                if count == 0 { break draining }
                if count < 0, errno != EAGAIN, errno != EINTR { break draining }
            }
        }
        core.finish()
    }
}

// MARK: UDP

/// A UDP socket that only receives: bound to the wildcard address on an ephemeral port. It
/// never sends.
///
/// `start` runs `handler` on the socket's own thread for every datagram, in arrival order, with
/// the sender's normalized IP literal and the time `recvfrom` returned. `close()` stops the thread
/// (no handler call starts after it returns) and closes the socket.
final class UDPReceiveSocket: Sendable {
    let port: UInt16
    private let core: SocketCore
    /// Whether `start` (or a close before any start) has claimed the descriptor's thread.
    private let claimed = Mutex(false)

    private init(core: SocketCore, port: UInt16) {
        self.core = core
        self.port = port
    }

    deinit {
        if claimed.withLock({ $0 }) {
            core.requestClose(linger: .zero, drain: .zero)
        } else {
            core.finish()
        }
    }

    /// Binds `0.0.0.0` (or `::`, dual-stack, when `ipv6`) on port 0 and reads the port back.
    static func bind(ipv6: Bool) throws -> UDPReceiveSocket {
        let family = ipv6 ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXSocketError.socketFailed(errno) }
        var bound: Int32
        if ipv6 {
            var zero: Int32 = 0
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_any
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = INADDR_ANY
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXSocketError.bindFailed(code)
        }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let port: UInt16 = withUnsafeMutablePointer(to: &local) { storage in
            let named = storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            guard named == 0 else { return 0 }
            return ipv6
                ? storage.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
                : storage.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        guard port != 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXSocketError.bindFailed(code)
        }
        setNonBlocking(fd)
        return UDPReceiveSocket(core: try SocketCore(fd: fd), port: port)
    }

    /// Starts the receive thread. Only the first call (before any `close()`) has an effect.
    func start(_ handler: @escaping @Sendable (Data, String?, ContinuousClock.Instant) -> Void) {
        let first = claimed.withLock { claimed -> Bool in
            defer { claimed = true }
            return !claimed
        }
        guard first else { return }
        let core = self.core
        let thread = Thread { Self.run(core, handler) }
        thread.name = "NoctuleKit.UDPReceiveSocket"
        thread.start()
    }

    /// Stops receiving and closes the socket; returns once it is closed. Idempotent.
    func close() async {
        let neverStarted = claimed.withLock { claimed -> Bool in
            defer { claimed = true }
            return !claimed
        }
        if neverStarted {
            core.requestClose(linger: .zero, drain: .zero)
            core.finish()
            return
        }
        core.requestClose(linger: .zero, drain: .zero)
        await core.waitUntilFinished()
    }

    private static func run(_ core: SocketCore,
                            _ handler: @Sendable (Data, String?, ContinuousClock.Instant) -> Void) {
        let fd = core.fd
        var buffer = [UInt8](repeating: 0, count: 65536)
        receiving: while true {
            var descriptors = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: core.wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            // A 0.5 s slice, like the reference client's socket timeout; the wake pipe makes
            // close() prompt regardless.
            let ready = poll(&descriptors, 2, 500)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break receiving
            }
            if descriptors[1].revents != 0 { break receiving }
            guard descriptors[0].revents != 0 else { continue }
            var source = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            let receivedAt = ContinuousClock.now
            if count >= 0 {
                let sender = withUnsafePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { IPAddressText.numericHost($0, length) }
                }
                handler(Data(buffer[0..<count]), sender, receivedAt)
            } else if errno != EAGAIN && errno != EINTR {
                // Transient (e.g. an ICMP-reported error): keep listening without spinning.
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        core.finish()
    }
}
