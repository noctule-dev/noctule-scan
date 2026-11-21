// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Sends synthetic PCMU RTP over loopback UDP the way the SDS200 does (protocol notes §6):
/// 25 packets per second, 320-byte payloads (40 ms at 8 kHz), timestamp step 320, payload type 0,
/// marker never set, one SSRC per stream. It sends from a plain BSD socket on 127.0.0.1, so the
/// source address is the loopback "scanner".
///
/// The payload is a fixed synthetic pattern (`payload(sequence:)`), never recorded audio, so a
/// test can check the decoded samples of any packet by its sequence number. `MockSDS200` swaps in
/// a synthetic tone with `setPayloadSource(_:)`.
///
/// Usually attached to a `FakeRTSPServer`, which calls `start(toPort:)` on PLAY and `stop()` on
/// TEARDOWN. Tests control it with `pause()`, `resume()`, `skip(_:)`, `reorderNext()`, `sendNow(offsets:)`, `changeSSRC()`, `sendGarbage()`, and
/// `setPayloadType(_:)`. Always call `shutdown()` when done.
public actor FakeRTPSender {
    public let host: String
    public let payloadBytes: Int
    public let interval: Duration

    /// The SSRC of the current stream (a new random one per `start(toPort:)` and `changeSSRC()`).
    public private(set) var ssrc: UInt32 = 0
    /// The port packets go to, while streaming.
    public private(set) var destinationPort: UInt16?
    public private(set) var packetsSent = 0
    /// How many times `start(toPort:)` has begun a stream.
    public private(set) var streamsStarted = 0
    public private(set) var isPaused = false
    public private(set) var payloadType: UInt8 = 0

    private var fd: Int32 = -1
    private var loop: Task<Void, Never>?
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var packetIndex = 0
    private var payloadSource: (@Sendable (Int) -> Data)?
    private enum Swap { case none, armed, holding }
    private var swap = Swap.none

    public init(host: String = "127.0.0.1", payloadBytes: Int = 320, interval: Duration = .milliseconds(40)) {
        self.host = host
        self.payloadBytes = payloadBytes
        self.interval = interval
    }

    /// The payload of the packet with this sequence number: byte `i` is `(sequence + i) & 0xFF`.
    public static func payload(sequence: UInt16, bytes: Int = 320) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: Int(sequence) + $0) })
    }

    /// Starts a new stream to `port` (replacing any current one). `ssrc`, `sequence`, and
    /// `timestamp` default to new random values (a real SETUP reply advertises the SSRC, so a
    /// server can pass the one it announced). Clears `pause()`.
    public func start(toPort port: UInt16, ssrc: UInt32? = nil, sequence: UInt16? = nil, timestamp: UInt32? = nil) {
        loop?.cancel()
        openSocketIfNeeded()
        destinationPort = port
        self.ssrc = ssrc ?? UInt32.random(in: 1...UInt32.max)
        self.sequence = sequence ?? UInt16.random(in: 0...UInt16.max)
        self.timestamp = timestamp ?? UInt32.random(in: 0...UInt32.max)
        packetIndex = 0
        isPaused = false
        streamsStarted += 1
        let interval = self.interval
        loop = Task { [weak self] in
            var next = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                next += interval
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }

    /// Replaces the fixed test pattern with `source(packetIndex)`, where `packetIndex` counts
    /// packets from 0 for each stream. nil restores `payload(sequence:)`. The data should be
    /// `payloadBytes` long.
    public func setPayloadSource(_ source: (@Sendable (Int) -> Data)?) {
        payloadSource = source
    }

    /// Stops streaming (the socket stays open for a later `start`).
    public func stop() {
        loop?.cancel()
        loop = nil
        destinationPort = nil
    }

    /// Stops streaming and closes the socket.
    public func shutdown() {
        stop()
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Stops sending without advancing the sequence or timestamp (like a squelch-gated pause).
    public func pause() { isPaused = true }
    public func resume() { isPaused = false }

    /// Sends one packet at once for each offset from the next sequence number s (sequence
    /// s + offset, timestamp advanced to match; negative offsets are late packets), then moves
    /// s past the largest offset. Call `pause()` first so the regular stream doesn't interleave.
    /// Returns s. Sends nothing while not streaming.
    @discardableResult
    public func sendNow(offsets: [Int]) -> UInt16 {
        let base = sequence
        guard let port = destinationPort else { return base }
        for offset in offsets {
            send(packet(sequence: base &+ UInt16(truncatingIfNeeded: offset),
                        timestamp: timestamp &+ UInt32(truncatingIfNeeded: offset) &* UInt32(payloadBytes)),
                 to: port)
            packetsSent += 1
            packetIndex += 1
        }
        if let last = offsets.max(), last >= 0 {
            sequence &+= UInt16(truncatingIfNeeded: last + 1)
            timestamp &+= UInt32(truncatingIfNeeded: last + 1) &* UInt32(payloadBytes)
        }
        return base
    }

    /// Swaps the next two packets: with the next sequence number s, it sends s+1, then s, then
    /// carries on from s+2 (one packet arriving late, as after network reordering).
    public func reorderNext() { swap = .armed }

    /// Skips `n` sequence numbers, as if those packets were lost in transit.
    /// The timestamp advances too, as it would for real loss.
    public func skip(_ n: Int) {
        guard n > 0 else { return }
        sequence &+= UInt16(truncatingIfNeeded: n)
        timestamp &+= UInt32(truncatingIfNeeded: n) &* UInt32(payloadBytes)
    }

    /// Continues the stream under a new random SSRC and sequence.
    public func changeSSRC() {
        ssrc = UInt32.random(in: 1...UInt32.max)
        sequence = UInt16.random(in: 0...UInt16.max)
    }

    /// Payload type for later packets (0 is PCMU).
    public func setPayloadType(_ type: UInt8) { payloadType = type & 0x7F }

    /// Sends one datagram that isn't valid RTP (version 0, too short) to the current port.
    public func sendGarbage() {
        guard let port = destinationPort else { return }
        send(Data([0x00, 0x01, 0x02, 0x03]), to: port)
    }

    // MARK: Private

    private func tick() {
        guard !isPaused, let port = destinationPort else { return }
        switch swap {
        case .none:
            send(packet(sequence: sequence, timestamp: timestamp), to: port)
            sequence &+= 1
            timestamp &+= UInt32(payloadBytes)
        case .armed:
            send(packet(sequence: sequence &+ 1, timestamp: timestamp &+ UInt32(payloadBytes)), to: port)
            swap = .holding
        case .holding:
            send(packet(sequence: sequence, timestamp: timestamp), to: port)
            sequence &+= 2
            timestamp &+= 2 * UInt32(payloadBytes)
            swap = .none
        }
        packetsSent += 1
        packetIndex += 1
    }

    private func packet(sequence: UInt16, timestamp: UInt32) -> Data {
        var bytes: [UInt8] = [0x80, payloadType, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        bytes += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: ssrc.bigEndian, Array.init)
        if let payloadSource {
            bytes += payloadSource(packetIndex)
        } else {
            bytes += Self.payload(sequence: sequence, bytes: payloadBytes)
        }
        return Data(bytes)
    }

    private func openSocketIfNeeded() {
        guard fd < 0 else { return }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd >= 0 {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }
    }

    /// Best effort: errors (e.g. ECONNREFUSED from an earlier ICMP) are ignored.
    private func send(_ data: Data, to port: UInt16) {
        openSocketIfNeeded()
        guard fd >= 0 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let fd = self.fd
        _ = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
