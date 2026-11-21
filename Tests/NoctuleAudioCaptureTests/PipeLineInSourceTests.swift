// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import NoctuleKit
import NoctuleKitTestSupport
import Synchronization
import Testing
import NoctuleMockScanner
@testable import NoctuleAudioCapture

/// `PipeLineInSource` on the serial mock's headphone jack (`MockLineOut`) through its Unix-domain
/// socket. The jack paces its blocks in real time, so these tests do too, with generous bounds. Nothing
/// here opens an audio device.
// Serialized: each test runs a real-time jack beside the other suites' real-time tests.
@Suite(.serialized, .timeLimit(.minutes(1))) struct PipeLineInSourceTests {
    static let name = "Mock Jack"
    static let config = LineInConfig(deviceUID: "pipe:jack", deviceName: name, channel: .both)

    // MARK: - Helpers

    /// A scenario with one transmission from the start, lasting past any test.
    static func scenario() -> MockScenario {
        let idle = MockIdle(system: "Riverbend County P25", site: "Riverbend Simulcast", frequencyMHz: 851.0125)
        let transmission = MockTransmission(
            at: 0, duration: 1000, system: "Riverbend County P25", department: "Lakeview Fire",
            channel: "Lakeview Fire Dispatch", tgid: "1201", frequencyMHz: 851.2375, toneHz: 440)
        return MockScenario(loop: false, idle: idle, transmissions: [transmission])
    }

    /// A short socket path in a fresh directory.
    struct SocketPath: Sendable {
        let directory: URL
        var path: String { directory.appending(path: "jack.sock").path }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "pl-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    static func jack(at path: String, volume: @escaping @Sendable () -> Int = { 2 }) -> MockLineOut {
        MockLineOut(path: path, channel: .both, scenario: scenario(), clock: .real(),
                    volume: volume, silent: { false })
    }


    /// A listening Unix-domain socket the test drives byte by byte, with no mock behind it.
    final class RawServer: Sendable {
        let fd: Int32

        init(path: String) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EADDRINUSE)
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        /// The next client's descriptor, with a large send buffer so a block goes out in one piece,
        /// or nil when none connects within `limit`.
        func accept(within limit: Duration) async -> Int32? {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                let client = Darwin.accept(fd, nil, nil)
                if client >= 0 {
                    var size: Int32 = 256 * 1024
                    setsockopt(client, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                    var on: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    return client
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }

        /// Writes all of `bytes` (the client's descriptor is blocking).
        static func send(_ bytes: [UInt8], to client: Int32) {
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes {
                    Darwin.send(client, $0.baseAddress! + offset, bytes.count - offset, 0)
                }
                if written <= 0 { return }
                offset += written
            }
        }

        func close() {
            Darwin.close(fd)
        }
    }

    /// `frames` interleaved stereo little-endian Float32 frames of a constant `left` and `right`.
    static func constantFrames(_ frames: Int, left: Float, right: Float) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(frames * 8)
        for _ in 0..<frames {
            for value in [left, right] {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
        return bytes
    }

    /// Everything a stream yields, collected by a task of its own.
    final class Collected<Element: Sendable>: Sendable {
        private final class Box: Sendable {
            let items = Mutex<[Element]>([])
            let ended = Mutex(false)
        }
        private let box = Box()
        private let task: Task<Void, Never>

        init(_ stream: AsyncStream<Element>) {
            let box = self.box
            task = Task {
                for await item in stream { box.items.withLock { $0.append(item) } }
                box.ended.withLock { $0 = true }
            }
        }

        var items: [Element] { box.items.withLock { $0 } }
        var ended: Bool { box.ended.withLock { $0 } }
        func cancel() { task.cancel() }
    }

    /// The three streams of a source, collected from before `start()`.
    struct Streams {
        let chunks: Collected<AudioChunk>
        let levels: Collected<LineInLevel>
        let states: Collected<LineInState>

        init(_ source: PipeLineInSource) {
            chunks = Collected(source.chunks)
            levels = Collected(source.levels)
            states = Collected(source.states)
        }
    }

    /// Polls `condition` every 20 ms for up to `timeout`; true when it held.
    static func wait(up to: Duration = .seconds(10), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + to
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Runs `body` with a started source on a jack at the given volume, and stops both in every path.
    static func withSource(
        volume: @escaping @Sendable () -> Int = { 2 },
        _ body: (PipeLineInSource, Streams) async throws -> Void
    ) async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let jack = jack(at: socket.path, volume: volume)
        try jack.start()
        let source = PipeLineInSource(path: socket.path, config: config)
        let streams = Streams(source)
        await source.start()
        do { try await body(source, streams) } catch {
            try? await stopWithin(source)
            jack.stop()
            throw error
        }
        try await stopWithin(source)
        jack.stop()
    }

    // MARK: - Tests

    @Test(.skippedOnCIRunner("wall-clock spacing of chunks over about 1 s; a loaded 3-core runner stretches it past the 25 ms tolerance"))
    func streamsChunksFromTheMock() async throws {
        try await Self.withSource { source, streams in
            #expect(await Self.wait { streams.states.items.contains(.streaming(deviceName: Self.name)) })
            #expect(await Self.wait { streams.chunks.items.count >= 20 })
            let count = streams.chunks.items.count
            try await Task.sleep(for: .seconds(1))
            let inASecond = streams.chunks.items.count - count
            // 25 chunks of 40 ms a second; load can only make the stream late, never fast.
            #expect(inASecond >= 20, "\(inASecond) chunks in 1 s")
            #expect(inASecond <= 30, "\(inASecond) chunks in 1 s")
            let chunks = streams.chunks.items
            #expect(chunks.allSatisfy { $0.samples.count == 320 })
            #expect(chunks.allSatisfy { !$0.discontinuity && $0.lostBefore == 0 }, "a gap in a steady stream")
            // The sequence steps by one, and the times follow the chunks: 40 ms each, to within the
            // 20 ms the pipeline allows before it counts again from the read clock.
            for (before, after) in zip(chunks, chunks.dropFirst()) { #expect(after.sequence == before.sequence &+ 1) }
            let span = try #require(chunks.last).receivedAt - chunks[0].receivedAt
            let expected = Duration.milliseconds(40 * (chunks.count - 1))
            #expect(abs((span - expected) / .milliseconds(1)) < 25, "\(chunks.count) chunks over \(span)")
            #expect(!streams.levels.items.isEmpty)
            // The states so far: starting, then streaming, and nothing else.
            #expect(streams.states.items == [.starting, .streaming(deviceName: Self.name)])
        }
    }

    @Test func chunkTimesFollowTheReadClock() async throws {
        try await Self.withSource { _, streams in
            #expect(await Self.wait { streams.chunks.items.count >= 25 })
            // A chunk's time is when its first sample was captured: before now, and by no more than
            // the time since the source started.
            let now = ContinuousClock.now
            let latest = try #require(streams.chunks.items.last)
            let age = (now - latest.receivedAt) / .milliseconds(1)
            #expect(age > 0 && age < 2_000, "the last chunk was captured \(age) ms ago")
        }
    }

    @Test func levelsFollowTheMockVolume() async throws {
        // Volume 2: a tone of amplitude 0.25 (-12 dBFS), the same on both channels.
        try await Self.withSource(volume: { 2 }) { _, streams in
            #expect(await Self.wait { streams.levels.items.count >= 30 })
            try await Task.sleep(for: .milliseconds(300))
            let levels = streams.levels.items
            let peak = try #require(levels.dropFirst(5).map(\.peakDBFS).max())
            #expect(abs(peak - -12.04) < 1, "peak \(peak) dBFS")
            #expect(levels.allSatisfy { !$0.clipped }, "a quiet tone was called clipped")
        }
        // Volume 9: the jack cuts the tone flat.
        try await Self.withSource(volume: { 9 }) { _, streams in
            #expect(await Self.wait { streams.levels.items.contains(where: \.clipped) })
            let peak = try #require(streams.levels.items.map(\.peakDBFS).max())
            #expect(peak > -0.5, "peak \(peak) dBFS")
        }
    }

    @Test func missingThenBack() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let source = PipeLineInSource(path: socket.path, config: Self.config)
        let streams = Streams(source)
        // Nothing is serving the path: missing, not an error, and the call returns.
        await source.start()
        #expect(await Self.wait { streams.states.items == [.starting, .missing(deviceName: Self.name)] })
        #expect(streams.chunks.items.isEmpty)
        // The jack appears: the source finds it by itself (it looks every second).
        let jack = Self.jack(at: socket.path)
        try jack.start()
        #expect(await Self.wait(up: .seconds(10)) { streams.states.items.last == .streaming(deviceName: Self.name) })
        #expect(await Self.wait { streams.chunks.items.count >= 5 })
        // The first chunk after the wait is flagged; the rest are not.
        let chunks = streams.chunks.items
        #expect(chunks.first?.discontinuity == true)
        #expect(chunks.dropFirst().allSatisfy { !$0.discontinuity })
        try await stopWithin(source)
        jack.stop()
    }

    @Test func reconnectsAfterTheJackStopsAndFlagsTheGap() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        var jack = Self.jack(at: socket.path)
        try jack.start()
        let source = PipeLineInSource(path: socket.path, config: Self.config)
        let streams = Streams(source)
        await source.start()
        #expect(await Self.wait { streams.states.items == [.starting, .streaming(deviceName: Self.name)] })
        #expect(await Self.wait { streams.chunks.items.count >= 10 })
        // A first connection's first chunk is not a discontinuity.
        #expect(streams.chunks.items.allSatisfy { !$0.discontinuity })
        // The jack goes away: the source says so, and goes on looking.
        jack.stop()
        #expect(await Self.wait { streams.states.items.last == .missing(deviceName: Self.name) })
        let before = streams.chunks.items.count
        let lastSequence = try #require(streams.chunks.items.last).sequence
        jack = Self.jack(at: socket.path)
        try jack.start()
        #expect(await Self.wait { streams.states.items.last == .streaming(deviceName: Self.name) })
        #expect(await Self.wait { streams.chunks.items.count >= before + 5 })
        let after = Array(streams.chunks.items.dropFirst(before))
        #expect(after.first?.discontinuity == true)
        #expect(after.dropFirst().allSatisfy { !$0.discontinuity })
        // The sequence carries on across the gap.
        #expect(after.first?.sequence == lastSequence &+ 1)
        try await stopWithin(source)
        jack.stop()
    }

    @Test func aBlocksFirstSampleIsStampedBeforeTheRead() async throws {
        // One 100 ms block, written at an instant the test knows: its first sample was captured
        // 100 ms before the write, whatever the chunk count says after that.
        let socket = try SocketPath()
        defer { socket.remove() }
        let server = try RawServer(path: socket.path)
        defer { server.close() }
        let source = PipeLineInSource(path: socket.path, config: Self.config)
        let streams = Streams(source)
        await source.start()
        let client = try #require(await server.accept(within: .seconds(5)))
        defer { Darwin.close(client) }
        RawServer.send(Self.constantFrames(4_800, left: 0.25, right: 0.25), to: client)
        let wrote = ContinuousClock.now
        #expect(await Self.wait { !streams.chunks.items.isEmpty })
        let first = try #require(streams.chunks.items.first)
        let error = (first.receivedAt - (wrote - .milliseconds(100))) / .milliseconds(1)
        #expect(abs(error) < 30, "the first chunk is stamped \(error) ms from where it was captured")
        try await stopWithin(source)
    }

    @Test func framesSplitAcrossReadsAreCarried() async throws {
        // A constant left channel in pieces that cut the 8-byte frames mid-float: if a read's tail
        // were dropped, the frames after it would be misaligned (right for left) and the level wrong.
        let socket = try SocketPath()
        defer { socket.remove() }
        let server = try RawServer(path: socket.path)
        defer { server.close() }
        let source = PipeLineInSource(
            path: socket.path, config: LineInConfig(deviceUID: "pipe:jack", deviceName: Self.name, channel: .left))
        let streams = Streams(source)
        await source.start()
        let client = try #require(await server.accept(within: .seconds(5)))
        defer { Darwin.close(client) }
        // 8 chunks of 1,920 frames, cut as 5, 3, 11, 1, 7, 13 bytes (40 bytes, or five frames, a
        // round). The first 300 pieces wait a millisecond each, so most reads end inside a frame.
        let stream = Self.constantFrames(8 * 1_920, left: 0.5, right: 0)
        let sizes = [5, 3, 11, 1, 7, 13]
        var offset = 0, piece = 0
        while offset < stream.count {
            let size = min(sizes[piece % sizes.count], stream.count - offset)
            RawServer.send(Array(stream[offset..<offset + size]), to: client)
            offset += size
            piece += 1
            if piece < 300 { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(await Self.wait { streams.chunks.items.count >= 6 })
        // Past the resampler's ring-in from silence to the step (the first 32 samples at 8 kHz).
        let samples = streams.chunks.items.prefix(6).flatMap(\.samples).dropFirst(32)
        #expect(samples.count >= 6 * 320 - 32)
        let worst = samples.map { abs(Int($0) - 16_384) }.max() ?? 0
        #expect(worst <= 200, "a sample is \(worst) from half scale")
        try await stopWithin(source)
    }

    @Test func stopFinishesTheStreams() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let jack = Self.jack(at: socket.path)
        try jack.start()
        defer { jack.stop() }
        let source = PipeLineInSource(path: socket.path, config: Self.config)
        let streams = Streams(source)
        await source.start()
        #expect(await Self.wait { streams.chunks.items.count >= 5 })
        let began = ContinuousClock.now
        try await stopWithin(source)
        let took = (ContinuousClock.now - began) / .milliseconds(1)
        #expect(took < 1_000, "stop() took \(took) ms")
        #expect(await Self.wait { streams.chunks.ended && streams.levels.ended && streams.states.ended })
        #expect(streams.states.items.last == .stopped)
        // Stopped means stopped: nothing more comes, and a second stop is harmless.
        let count = streams.chunks.items.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(streams.chunks.items.count == count)
        try await stopWithin(source)
    }

    @Test func stopWhileWaitingForTheSocketReturnsAtOnce() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let source = PipeLineInSource(path: socket.path, config: Self.config)
        let streams = Streams(source)
        await source.start()
        #expect(await Self.wait { streams.states.items.last == .missing(deviceName: Self.name) })
        let began = ContinuousClock.now
        try await stopWithin(source)
        // The one-second retry wait doesn't hold a stop up.
        let took = (ContinuousClock.now - began) / .milliseconds(1)
        #expect(took < 500, "stop() took \(took) ms")
        #expect(await Self.wait { streams.states.ended && streams.chunks.ended && streams.levels.ended })
        #expect(streams.states.items.last == .stopped)
    }

    @Test func stopWithoutStartFinishesTheStreams() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let source = PipeLineInSource(path: socket.path, config: Self.config)
        let streams = Streams(source)
        try await stopWithin(source)
        #expect(await Self.wait { streams.states.ended && streams.chunks.ended && streams.levels.ended })
        // A source that was stopped can't be started: a late `start()` returns and connects to nothing.
        let server = try RawServer(path: socket.path)
        defer { server.close() }
        await source.start()
        #expect(await server.accept(within: .milliseconds(400)) == nil, "a stopped source connected")
        #expect(streams.states.items == [.stopped])
    }

    @Test func aSecondClientGetsEndOfFileAndKeepsLooking() async throws {
        // The jack serves one client at a time and closes a second at once: that source sees end of
        // file, which is `.missing` and a retry every second, never a hang. It streams once the first
        // client has gone.
        let socket = try SocketPath()
        defer { socket.remove() }
        let jack = Self.jack(at: socket.path)
        try jack.start()
        defer { jack.stop() }
        let first = PipeLineInSource(path: socket.path, config: Self.config)
        let firstStreams = Streams(first)
        await first.start()
        #expect(await Self.wait { firstStreams.chunks.items.count >= 5 })
        let second = PipeLineInSource(path: socket.path, config: Self.config)
        let secondStreams = Streams(second)
        await second.start()
        #expect(await Self.wait { secondStreams.states.items.contains(.missing(deviceName: Self.name)) })
        #expect(secondStreams.chunks.items.isEmpty)
        try await stopWithin(first)
        #expect(await Self.wait(up: .seconds(15)) { secondStreams.chunks.items.count >= 5 })
        try await stopWithin(second)
    }
}
