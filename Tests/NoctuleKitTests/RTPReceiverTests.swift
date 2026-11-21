// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Network
import Testing
@testable import NoctuleKit

private struct TimedOut: Error {}
private struct SendFailed: Error {}

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

/// A 12-byte RTP header (V=2, PT=0) plus `payloadBytes` bytes of µ-law silence.
private func rtpDatagram(sequence: UInt16, timestamp: UInt32, ssrc: UInt32 = 0x1234_5678,
                         payloadBytes: Int = 160) -> Data {
    var bytes: [UInt8] = [0x80, 0x00, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
    bytes += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
    bytes += withUnsafeBytes(of: ssrc.bigEndian, Array.init)
    bytes += [UInt8](repeating: 0xFF, count: payloadBytes)
    return Data(bytes)
}

/// A loopback UDP sender. Every wait is bounded.
private final class LoopbackSender: Sendable {
    private let connection: NWConnection

    init(port: UInt16, host: String = "127.0.0.1") throws {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else { throw SendFailed() }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        connection.start(queue: DispatchQueue(label: "RTPReceiverTests.sender"))
    }

    func send(_ datagrams: [Data]) async throws {
        for datagram in datagrams {
            try await within(.seconds(2)) { [connection] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.send(content: datagram, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            }
        }
    }

    func cancel() { connection.cancel() }
}

/// Binds `receiver`, runs `body` with a sender aimed at it (bounded by `limit`), then always
/// cancels the sender and closes the receiver.
private func withReceiver(
    _ receiver: RTPReceiver, limit: Duration = .seconds(5),
    _ body: @escaping @Sendable (UInt16, LoopbackSender) async throws -> Void
) async throws {
    var failure: (any Error)?
    var sender: LoopbackSender?
    do {
        let port = try await within(.seconds(5)) { try await receiver.bind() }
        let made = try LoopbackSender(port: port)
        sender = made
        try await within(limit) { try await body(port, made) }
    } catch {
        failure = error
    }
    sender?.cancel()
    _ = try? await within(.seconds(5)) { await receiver.close() }
    if let failure { throw failure }
}

/// Collects `count` packets from `stream`, or throws `TimedOut` after `limit`.
private func take(_ count: Int, from stream: AsyncStream<ReceivedRTP>,
                  limit: Duration = .seconds(3)) async throws -> [ReceivedRTP] {
    try await within(limit) {
        var out: [ReceivedRTP] = []
        for await packet in stream {
            out.append(packet)
            if out.count == count { break }
        }
        return out
    }
}

/// Polls `condition` every 10 ms until it holds, or throws `TimedOut` after `limit`.
private func eventually(_ limit: Duration = .seconds(3),
                        _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await within(limit) {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@Test func receivesAndStamps() async throws {
    let receiver = RTPReceiver(expectedSourceHost: "127.0.0.1")
    try await withReceiver(receiver) { port, sender in
        #expect(port != 0)
        let stream = receiver.packets
        let before = ContinuousClock.now
        try await sender.send((0..<3).map { rtpDatagram(sequence: 100 + UInt16($0), timestamp: 160 * UInt32($0)) })
        let got = try await take(3, from: stream)
        #expect(got.map(\.packet.sequence) == [100, 101, 102])
        #expect(got.map(\.packet.timestamp) == [0, 160, 320])
        #expect(got.allSatisfy { $0.packet.payloadType == 0 && $0.packet.payload.count == 160 })
        #expect(got.allSatisfy { $0.receivedAt >= before && $0.receivedAt <= ContinuousClock.now })
        #expect(zip(got, got.dropFirst()).allSatisfy { $0.receivedAt <= $1.receivedAt })
        #expect(await receiver.droppedMalformed == 0)
        #expect(await receiver.droppedWrongSource == 0)
    }
}

@Test func dropsMalformed() async throws {
    let receiver = RTPReceiver(expectedSourceHost: nil)
    try await withReceiver(receiver) { _, sender in
        let stream = receiver.packets
        // One sender, so the datagrams are handled in order: the valid one arriving means
        // the 8-byte one before it has already been counted.
        try await sender.send([Data(repeating: 0x80, count: 8), rtpDatagram(sequence: 7, timestamp: 0)])
        let got = try await take(1, from: stream)
        #expect(got.map(\.packet.sequence) == [7])
        #expect(await receiver.droppedMalformed == 1)
        #expect(await receiver.droppedWrongSource == 0)
    }
}

@Test func dropsWrongSource() async throws {
    let receiver = RTPReceiver(expectedSourceHost: "192.0.2.1")
    try await withReceiver(receiver) { _, sender in
        let stream = receiver.packets
        try await sender.send((0..<3).map { rtpDatagram(sequence: UInt16($0), timestamp: 0) })
        try await eventually { await receiver.droppedWrongSource == 3 }
        #expect(await receiver.droppedMalformed == 0)
        await receiver.close()
        // Nothing was yielded before the stream finished.
        let first = try await within(.seconds(2)) { () -> ReceivedRTP? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(first == nil)
    }
}

@Test func acceptsResolvedHostname() async throws {
    let receiver = RTPReceiver(expectedSourceHost: "localhost")
    try await withReceiver(receiver) { _, sender in
        let stream = receiver.packets
        try await sender.send([rtpDatagram(sequence: 1, timestamp: 0)])
        let got = try await take(1, from: stream)
        #expect(got.map(\.packet.sequence) == [1])
        #expect(await receiver.droppedWrongSource == 0)
    }
}

@Test func closeFinishesStreamAndRebindGivesFreshStream() async throws {
    let receiver = RTPReceiver(expectedSourceHost: "127.0.0.1")
    try await withReceiver(receiver) { _, sender in
        let first = receiver.packets
        try await sender.send([rtpDatagram(sequence: 1, timestamp: 0)])
        _ = try await take(1, from: first)
        await receiver.close()
        let ended = try await within(.seconds(2)) { () -> Bool in
            var iterator = first.makeAsyncIterator()
            return await iterator.next() == nil
        }
        #expect(ended)

        let port = try await within(.seconds(5)) { try await receiver.bind() }
        let second = receiver.packets
        let resender = try LoopbackSender(port: port)
        defer { resender.cancel() }
        try await resender.send([rtpDatagram(sequence: 2, timestamp: 160)])
        let got = try await take(1, from: second)
        #expect(got.map(\.packet.sequence) == [2])
    }
}

@Test func closeIsIdempotentAndUnboundStreamIsFinished() async throws {
    let receiver = RTPReceiver(expectedSourceHost: nil)
    await receiver.close()
    let ended = try await within(.seconds(2)) { () -> Bool in
        var iterator = receiver.packets.makeAsyncIterator()
        return await iterator.next() == nil
    }
    #expect(ended)
    _ = try await within(.seconds(5)) { try await receiver.bind() }
    await receiver.close()
    await receiver.close()
}

@Test func normalizesIPv4MappedAndScopedAddresses() {
    #expect(RTPReceiver.normalizedAddress("::ffff:192.0.2.1") == "192.0.2.1")
    #expect(RTPReceiver.normalizedAddress("::FFFF:192.0.2.1") == "192.0.2.1")
    #expect(RTPReceiver.normalizedAddress("192.0.2.1") == "192.0.2.1")
    #expect(RTPReceiver.normalizedAddress("fe80::1%en0") == "fe80::1")
    #expect(RTPReceiver.normalizedAddress("FE80::1") == "fe80::1")
}

/// An IPv6-only expected source gets a dual-stack `::` socket.
@Test func receivesFromAnIPv6Source() async throws {
    let receiver = RTPReceiver(expectedSourceHost: "::1")
    var failure: (any Error)?
    var sender: LoopbackSender?
    do {
        let port = try await within(.seconds(5)) { try await receiver.bind() }
        let stream = receiver.packets
        let made = try LoopbackSender(port: port, host: "::1")
        sender = made
        try await made.send([rtpDatagram(sequence: 9, timestamp: 0)])
        let got = try await take(1, from: stream)
        #expect(got.map(\.packet.sequence) == [9])
        #expect(await receiver.droppedWrongSource == 0)
    } catch {
        failure = error
    }
    sender?.cancel()
    _ = try? await within(.seconds(5)) { await receiver.close() }
    if let failure { throw failure }
}
