// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

/// One RTP packet and when it arrived.
public struct ReceivedRTP: Sendable {
    public var packet: RTPPacket
    public var receivedAt: ContinuousClock.Instant

    public init(packet: RTPPacket, receivedAt: ContinuousClock.Instant) {
        self.packet = packet
        self.receivedAt = receivedAt
    }
}

public enum RTPReceiverError: Error, Equatable {
    case bindFailed(String)
    case bindTimedOut
}

/// Receives RTP over UDP on an ephemeral local port: one plain BSD socket (`UDPReceiveSocket`)
/// bound to the wildcard address, read by its own thread. It never sends anything.
///
/// `bind()` returns the port to put in the RTSP SETUP `client_port`. Each datagram is stamped with
/// `ContinuousClock.now` when `recvfrom` returns and parsed with `RTPPacket(parsing:)`.
///
/// - When `expectedSourceHost` is set, datagrams from any other address are dropped and counted in
///   `droppedWrongSource`. Addresses are compared after normalizing (IPv4-mapped IPv6 such as
///   `::ffff:192.0.2.1` equals `192.0.2.1`; scope ids and case are ignored). A host name is
///   resolved once per `bind()`, and any of its addresses is accepted. The socket is IPv4
///   (`0.0.0.0`) unless the expected source is IPv6 only, then dual-stack `::`.
/// - Datagrams that aren't valid RTP are dropped and counted in `droppedMalformed`.
/// - `packets` is a fresh stream per `bind()`. It finishes on `close()` or the next `bind()`.
///   It keeps the newest 500 packets (20 s of 40 ms packets) if nobody reads.
/// - Receive errors (e.g. ICMP-reported) never end anything; only `close()` stops the socket.
///
/// **Ordering:** close the receiver only AFTER the RTSP session is torn down and its TCP
/// connection closed (`RTSPClient.close()` has returned), as the proven reference client does,
/// ideally with a short pause (it waits 0.5 s). Closing the RTP port while the scanner is still
/// streaming to it draws ICMP port-unreachable replies.
public actor RTPReceiver {
    public let expectedSourceHost: String?
    public var droppedWrongSource: Int { counters.wrongSource }
    public var droppedMalformed: Int { counters.malformed }

    /// Drop counts, updated on the socket's thread.
    private final class Counters: Sendable {
        private let counts = Mutex((wrongSource: 0, malformed: 0))
        var wrongSource: Int { counts.withLock { $0.wrongSource } }
        var malformed: Int { counts.withLock { $0.malformed } }
        func addWrongSource() { counts.withLock { $0.wrongSource += 1 } }
        func addMalformed() { counts.withLock { $0.malformed += 1 } }
        func reset() { counts.withLock { $0 = (0, 0) } }
    }

    private static let resolveTimeout: Duration = .seconds(2)

    private nonisolated let currentPackets: Mutex<AsyncStream<ReceivedRTP>>
    private let counters = Counters()
    private var socket: UDPReceiveSocket?
    private var continuation: AsyncStream<ReceivedRTP>.Continuation?

    public init(expectedSourceHost: String?) {
        self.expectedSourceHost = expectedSourceHost
        let (finished, continuation) = AsyncStream.makeStream(of: ReceivedRTP.self)
        continuation.finish()
        currentPackets = Mutex(finished)
    }

    /// The packets since the latest `bind()`. Before the first `bind()` it is already finished.
    public nonisolated var packets: AsyncStream<ReceivedRTP> {
        currentPackets.withLock { $0 }
    }

    /// Closes any previous binding, then binds an ephemeral UDP port and returns it.
    public func bind() async throws -> UInt16 {
        await close()
        let allowed: Set<String>? = if let expectedSourceHost {
            await Self.addresses(for: expectedSourceHost)
        } else {
            nil
        }
        let literals = allowed?.filter(IPAddressText.isLiteral) ?? []
        let ipv6 = !literals.isEmpty && literals.allSatisfy(IPAddressText.isIPv6)

        let socket: UDPReceiveSocket
        do {
            socket = try UDPReceiveSocket.bind(ipv6: ipv6)
        } catch {
            throw RTPReceiverError.bindFailed(String(describing: error))
        }
        let (packets, continuation) = AsyncStream.makeStream(
            of: ReceivedRTP.self, bufferingPolicy: .bufferingNewest(500))
        counters.reset()
        let counters = self.counters
        socket.start { datagram, source, receivedAt in
            if let allowed {
                guard let source, allowed.contains(source) else {
                    counters.addWrongSource()
                    return
                }
            }
            guard let packet = try? RTPPacket(parsing: datagram) else {
                counters.addMalformed()
                return
            }
            continuation.yield(ReceivedRTP(packet: packet, receivedAt: receivedAt))
        }
        self.socket = socket
        self.continuation = continuation
        currentPackets.withLock { $0 = packets }
        return socket.port
    }

    /// Stops receiving, closes the socket (no packet is delivered or counted after this
    /// returns), and finishes `packets`. Safe to call repeatedly. See the ordering note above.
    public func close() async {
        let socket = self.socket
        let continuation = self.continuation
        self.socket = nil
        self.continuation = nil
        await socket?.close()
        continuation?.finish()
    }

    // MARK: Addresses

    /// Lowercased, without a `%scope` suffix, and with IPv4-mapped IPv6 (`::ffff:a.b.c.d`)
    /// reduced to plain IPv4.
    nonisolated static func normalizedAddress(_ text: String) -> String {
        IPAddressText.normalized(text)
    }

    /// The normalized addresses `host` stands for: itself if it's an address literal, otherwise
    /// what it resolves to (at most 2 s), plus the name itself as a fallback.
    static func addresses(for host: String) async -> Set<String> {
        let literal = normalizedAddress(host)
        if IPAddressText.isLiteral(literal) { return [literal] }
        // getaddrinfo can't be cancelled, so race it without waiting for the loser.
        let once = Mutex(false)
        let resolved: [String] = await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: [String]) {
                let first = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task.detached { finish(resolve(host)) }
            Task {
                try? await Task.sleep(for: resolveTimeout)
                finish([])
            }
        }
        return Set(resolved).union([literal])
    }

    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return [] }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                out.append(normalizedAddress(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
            }
            cursor = info.pointee.ai_next
        }
        return out
    }
}
