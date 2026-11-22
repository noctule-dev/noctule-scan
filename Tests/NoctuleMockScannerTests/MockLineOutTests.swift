// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing
import NoctuleKit
@testable import NoctuleMockScanner

// The serial mock's headphone jack (`MockLineOut`) through a plain Unix-domain socket client: what a
// `PipeLineInSource` will read. Real-time clocks, since the jack paces its blocks by the clock; every
// wait is a bounded read.

/// A scenario with one transmission at `at` for `duration` seconds (tone 440 Hz), not looping, so a
/// test knows what the jack is playing at each moment; nil gives a scenario with no transmission at all.
private func scenario(transmissionAt at: Double? = 0, duration: Double = 1000) -> MockScenario {
    let idle = MockIdle(system: "Riverbend County P25", site: "Riverbend Simulcast", frequencyMHz: 851.0125)
    guard let at else { return MockScenario(loop: false, idle: idle, transmissions: []) }
    let transmission = MockTransmission(at: at, duration: duration, system: "Riverbend County P25",
                                        department: "Lakeview Fire", channel: "Lakeview Fire Dispatch", tgid: "1201",
                                        frequencyMHz: 851.2375, toneHz: 440)
    return MockScenario(loop: false, idle: idle, transmissions: [transmission])
}

/// A short socket path in a fresh directory; `remove()` deletes the directory.
private struct SocketPath: Sendable {
    let directory: URL
    var path: String { directory.appending(path: "jack.sock").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "nl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// Leaves a socket file at `path` that nobody serves, as a crashed run does.
private func bindAndAbandon(_ path: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { Darwin.close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
}

/// A blocking client of the jack's socket (100 ms receive timeout).
private final class JackClient: Sendable {
    let fd: Int32

    /// Connects to `path`, or throws the errno.
    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ECONNREFUSED)
        }
    }

    func close() { Darwin.close(fd) }

    /// Reads for `duration`, or until the peer closes; returns every byte and whether it closed. It
    /// blocks a dispatch thread, not a cooperative one, so these tests can't starve other suites'.
    /// With `fromFirstByte`, `duration` counts from the first byte, which is waited for at most
    /// `firstByteLimit`: a jack whose thread wakes late (a throttled process, the CI runner) takes
    /// that long to accept and then writes in bursts, so a window counted from the connect can end
    /// before its audio comes (LESSONS.md 2026-11-20).
    func read(for duration: Duration, fromFirstByte: Bool = false,
              firstByteLimit: Duration = .seconds(5)) async -> (bytes: [UInt8], closed: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.blockingRead(
                    for: duration, firstByteLimit: fromFirstByte ? firstByteLimit : nil))
            }
        }
    }

    private func blockingRead(for duration: Duration, firstByteLimit: Duration?) -> (bytes: [UInt8], closed: Bool) {
        var deadline = ContinuousClock.now + (firstByteLimit ?? duration)
        var waitingForFirstByte = firstByteLimit != nil
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while ContinuousClock.now < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)  // off the cooperative pool: a dispatch thread
            if count > 0 {
                if waitingForFirstByte {
                    waitingForFirstByte = false
                    deadline = ContinuousClock.now + duration
                }
                bytes.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return (bytes, true)
            } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                return (bytes, true)
            }
        }
        return (bytes, false)
    }

    /// Reads `duration` of audio as per-channel samples (a trailing partial frame is dropped).
    func capture(for duration: Duration, fromFirstByte: Bool = false) async -> Capture {
        Capture(bytes: await read(for: duration, fromFirstByte: fromFirstByte).bytes)
    }
}

/// Interleaved stereo Float32 little-endian, as the jack writes it.
private struct Capture {
    var left: [Float] = []
    var right: [Float] = []
    var frames: Int { left.count }

    init(bytes: [UInt8]) {
        let frameCount = bytes.count / 8
        bytes.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                left.append(raw.loadUnaligned(fromByteOffset: frame * 8, as: Float.self))
                right.append(raw.loadUnaligned(fromByteOffset: frame * 8 + 4, as: Float.self))
            }
        }
    }
}

private func peak(_ samples: some Collection<Float>) -> Float { samples.map { abs($0) }.max() ?? 0 }

/// The most consecutive samples at exactly +1 or exactly -1.
private func longestRunAtFullScale(_ samples: [Float]) -> Int {
    var longest = 0, run = 0
    var previous: Float = 0
    for sample in samples {
        if abs(sample) == 1, run == 0 || sample == previous { run += 1 } else { run = abs(sample) == 1 ? 1 : 0 }
        previous = sample
        longest = max(longest, run)
    }
    return longest
}

private func rmsDBFS(_ samples: some Collection<Float>) -> Double {
    let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
    return 10 * log10(max(meanSquare, 1e-30))
}

/// The power of `samples` at `frequency` (Goertzel), 48 kHz.
private func power(of samples: [Float], at frequency: Double) -> Double {
    let coefficient = 2 * cos(2 * Double.pi * frequency / Double(MockLineOut.sampleRate))
    var s1 = 0.0, s2 = 0.0
    for sample in samples {
        let s0 = Double(sample) + coefficient * s1 - s2
        s2 = s1
        s1 = s0
    }
    return (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / Double(samples.count * samples.count)
}

/// Starts a jack on a fresh socket path, runs `body` with it, and in every path stops it and removes the directory.
private func withJack(
    channel: LineInChannel = .both, scenario: MockScenario = scenario(), at time: Double = 0,
    volume: @escaping @Sendable () -> Int = { 2 }, silent: @escaping @Sendable () -> Bool = { false },
    _ body: @Sendable (MockLineOut, String) async throws -> Void
) async throws {
    let socket = try SocketPath()
    defer { socket.remove() }
    let jack = MockLineOut(path: socket.path, channel: channel, scenario: scenario, clock: .real(startingAt: time),
                           volume: volume, silent: silent)
    try jack.start()
    do { try await body(jack, socket.path) } catch {
        jack.stop()
        throw error
    }
    jack.stop()
    #expect(!exists(socket.path), "the socket outlived stop()")
}

/// Connects, reads `duration` of audio (counted from the first byte with `fromFirstByte`) and
/// disconnects.
private func capture(_ path: String, for duration: Duration, fromFirstByte: Bool = false) async throws -> Capture {
    let client = try JackClient(path)
    defer { client.close() }
    return await client.capture(for: duration, fromFirstByte: fromFirstByte)
}

// Serialized: each test runs a real-time jack beside the other suites' real-time RTSP and RTP tests,
// and a dozen at once starved those of CPU (an occasional timeout in an unrelated test).
@Suite(.serialized, .timeLimit(.minutes(1))) struct MockLineOutTests {
    @Test func peakFollowsTheVolume() {
        #expect(MockLineOut.peak(forVolume: 0) == 0)
        #expect(MockLineOut.peak(forVolume: 2) == 0.25)
        #expect(MockLineOut.peak(forVolume: 4) == 0.5)
        #expect(MockLineOut.peak(forVolume: 8) == 1)
        // Above 8 the tone's amplitude goes on rising; the jack's hard clip is what stops it at 1.
        #expect(MockLineOut.peak(forVolume: 9) == 1.125)
        #expect(MockLineOut.peak(forVolume: 15) == 1.875)
        #expect(MockLineOut.sampleRate == 48_000)
    }

    @Test func toneDuringATransmission() async throws {
        try await withJack(channel: .left) { _, path in
            // 0.6 s from the first byte: the jack's stream at its own pace, however late its thread
            // woke to accept.
            let audio = try await capture(path, for: .milliseconds(600), fromFirstByte: true)
            #expect(audio.frames > 20_000, "got \(audio.frames) frames in 0.6 s")
            // Volume 2: the tone's peak is 0.25; the noise (0.0025 RMS, so up to about 0.012 at its worst
            // sample) rides on it.
            #expect(abs(peak(audio.left) - MockLineOut.peak(forVolume: 2)) < 0.02, "peak \(peak(audio.left))")
            #expect(audio.right.allSatisfy { $0 == 0 }, "the unchosen channel carried something")
            // The tone is the scenario's 440 Hz.
            let samples = Array(audio.left.dropFirst(2_000).prefix(24_000))
            #expect(power(of: samples, at: 440) > 100 * power(of: samples, at: 1_000))
        }
    }

    @Test func theToneCanBeOnTheRightOrBoth() async throws {
        try await withJack(channel: .right) { _, path in
            let audio = try await capture(path, for: .milliseconds(300))
            #expect(abs(peak(audio.right) - 0.25) < 0.02)
            #expect(audio.left.allSatisfy { $0 == 0 })
        }
        try await withJack(channel: .both) { _, path in
            let audio = try await capture(path, for: .milliseconds(300))
            #expect(abs(peak(audio.left) - 0.25) < 0.02)
            #expect(abs(peak(audio.right) - 0.25) < 0.02)
        }
    }

    @Test func hissBetweenTransmissions() async throws {
        try await withJack(scenario: scenario(transmissionAt: nil)) { _, path in
            let audio = try await capture(path, for: .seconds(1))
            #expect(audio.frames > 30_000)
            // The owner's rig: block RMS about -52 dBFS with the squelch closed (design §3a).
            #expect(abs(rmsDBFS(audio.left) - -52) < 1, "left \(rmsDBFS(audio.left)) dBFS")
            #expect(abs(rmsDBFS(audio.right) - -52) < 1, "right \(rmsDBFS(audio.right)) dBFS")
            #expect(peak(audio.left) < 0.05)
        }
    }

    @Test func theHissIsOnTopOfTheTone() async throws {
        // A 0.5-peak sine is -9.03 dBFS RMS, and hiss at -52 dBFS adds nothing a meter could see to
        // that; its own check is that the tone's peak and level stay what the volume says.
        try await withJack(channel: .left, volume: { 4 }) { _, path in
            let audio = try await capture(path, for: .milliseconds(500))
            #expect(abs(peak(audio.left) - 0.5) < 0.02)
            #expect(abs(rmsDBFS(audio.left) - -9.03) < 0.3, "\(rmsDBFS(audio.left))")
        }
    }

    @Test func volumeNineClips() async throws {
        // Volume 9 is a tone of amplitude 1.125, hard-clipped: flat tops, whatever the hiss does. With
        // the hiss alone at -52 dBFS (and a 1.0 tone) a run of samples at exactly +-1 could not occur.
        try await withJack(channel: .both, volume: { 9 }, silent: { false }) { _, path in
            let audio = try await capture(path, for: .seconds(1))
            for samples in [audio.left, audio.right] {
                #expect(peak(samples) == 1, "a sample went beyond full scale")
                #expect(longestRunAtFullScale(samples) >= 5, "longest flat top: \(longestRunAtFullScale(samples)) samples")
            }
            // At volume 8 the tone only touches full scale: no flat tops of that length (the line-in's
            // detector still counts its crests as a clip, two samples in a row above its threshold).
        }
        try await withJack(channel: .left, volume: { 8 }) { _, path in
            let audio = try await capture(path, for: .milliseconds(500))
            #expect(longestRunAtFullScale(audio.left) < 5)
        }
    }

    @Test func theVolumeIsReadLive() async throws {
        let volume = Mutex(1)
        try await withJack(channel: .left, volume: { volume.withLock { $0 } }) { _, path in
            let client = try JackClient(path)
            defer { client.close() }
            let quiet = await client.capture(for: .milliseconds(400))
            volume.withLock { $0 = 4 }
            _ = await client.read(for: .milliseconds(100))
            let loud = await client.capture(for: .milliseconds(400))
            #expect(abs(peak(quiet.left) - 0.125) < 0.02, "\(peak(quiet.left))")
            #expect(abs(peak(loud.left) - 0.5) < 0.02, "\(peak(loud.left))")
        }
    }

    @Test func silentFaultWritesOnlyHiss() async throws {
        let silent = Mutex(true)
        try await withJack(channel: .both, silent: { silent.withLock { $0 } }) { _, path in
            // A transmission is on (volume 2), and the fault leaves only the hiss.
            let audio = try await capture(path, for: .seconds(1))
            #expect(audio.frames > 30_000)
            #expect(abs(rmsDBFS(audio.left) - -52) < 1, "\(rmsDBFS(audio.left)) dBFS")
            #expect(peak(audio.left) < 0.05)
            #expect(peak(audio.right) < 0.05)
            // Cleared, the tone is back at once.
            silent.withLock { $0 = false }
            let client = try JackClient(path)
            defer { client.close() }
            _ = await client.read(for: .milliseconds(100))
            #expect(peak(await client.capture(for: .milliseconds(300)).left) > 0.2)
        }
    }

    @Test func aClientThatComesBackAtOnceIsServed() async throws {
        // A client that closes and connects again straight away is the only client: the jack must
        // let the closed one go before it judges the new one a second client.
        try await withJack { _, path in
            for round in 1...5 {
                let client = try JackClient(path)
                let read = await client.read(for: .milliseconds(300))
                client.close()
                #expect(!read.closed && read.bytes.count > 0, "round \(round): refused as a second client")
            }
        }
    }

    @Test func secondClientIsRefused() async throws {
        try await withJack { _, path in
            let first = try JackClient(path)
            defer { first.close() }
            #expect(await first.read(for: .milliseconds(200), fromFirstByte: true).bytes.count > 0)
            // The second connects (the kernel completes the handshake), and is closed at once.
            let second = try JackClient(path)
            defer { second.close() }
            #expect(await second.read(for: .seconds(1)).closed, "a second client was served")
            // The first goes on, and once it leaves a new one is taken.
            #expect(await first.read(for: .milliseconds(200), fromFirstByte: true).bytes.count > 0)
            first.close()
            try await Task.sleep(for: .milliseconds(100))
            let third = try JackClient(path)
            defer { third.close() }
            #expect(await third.read(for: .milliseconds(300), fromFirstByte: true).bytes.count > 0)
        }
    }

    @Test func aClientThatOnlyListensStillGetsAudio() async throws {
        // `nc -U` and the like close their sending side when their input ends; that is not a
        // disconnect, the jack never reads anything.
        try await withJack { _, path in
            let client = try JackClient(path)
            defer { client.close() }
            shutdown(client.fd, SHUT_WR)
            #expect(await client.read(for: .milliseconds(300)).bytes.count > 10_000)
        }
    }

    @Test func noClientDiscards() async throws {
        try await withJack { _, path in
            // Audio made while nobody listens is thrown away: a client that comes after 1 s gets
            // the present moment, not a second of backlog.
            try await Task.sleep(for: .seconds(1))
            let audio = try await capture(path, for: .milliseconds(300))
            #expect(audio.frames > 7_200, "got \(audio.frames) frames")
            #expect(audio.frames < 21_600, "got \(audio.frames) frames in 0.3 s: a backlog was kept")
        }
    }

    @Test func stopClosesTheClientAndRemovesTheSocket() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let jack = MockLineOut(path: socket.path, channel: .both, scenario: scenario(), clock: .real(),
                               volume: { 2 }, silent: { false })
        try jack.start()
        #expect(exists(socket.path))
        let client = try JackClient(socket.path)
        defer { client.close() }
        #expect(await client.read(for: .milliseconds(200), fromFirstByte: true).bytes.count > 0)
        jack.stop()
        #expect(!exists(socket.path))
        #expect(await client.read(for: .seconds(1)).closed)
        jack.stop()
        #expect(throws: (any Error).self) { _ = try JackClient(socket.path) }
    }

    @Test func aStaleSocketFileIsReplacedAndAnotherFileIsNot() throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        // A crashed run's socket file: bound, then abandoned with nobody listening.
        try bindAndAbandon(socket.path)
        #expect(exists(socket.path))
        let jack = MockLineOut(path: socket.path, channel: .both, scenario: scenario(), clock: .real(),
                               volume: { 2 }, silent: { false })
        try jack.start()
        jack.stop()
        #expect(!exists(socket.path))
        // Anything else at the path is the user's, and left alone.
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: socket.path))
        let refused = MockLineOut(path: socket.path, channel: .both, scenario: scenario(), clock: .real(),
                                  volume: { 2 }, silent: { false })
        #expect(throws: (any Error).self) { try refused.start() }
        #expect(try String(contentsOfFile: socket.path, encoding: .utf8) == "keep me")
    }

    @Test func aPathTooLongForASocketFailsToStart() throws {
        let jack = MockLineOut(path: "/tmp/" + String(repeating: "x", count: 200), channel: .both,
                               scenario: scenario(), clock: .real(), volume: { 2 }, silent: { false })
        #expect(throws: (any Error).self) { try jack.start() }
    }

    @Test func theSerialMockServesItAndVOLChangesTheLevel() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let mock = MockSerialScanner(scenario: scenario(), clock: .real(), personality: .sds150,
                                     lineOut: (socket.path, .left))
        let port = try await mock.start()
        let client = ScannerClient(transport: SerialTransport(path: port), commandTimeout: .milliseconds(700))
        do {
            try await client.connect()
            try await client.setVolume(2)
            let quiet = try await capture(socket.path, for: .milliseconds(400))
            try await client.setVolume(8)
            try await Task.sleep(for: .milliseconds(100))
            let loud = try await capture(socket.path, for: .milliseconds(400))
            #expect(abs(peak(quiet.left) - 0.25) < 0.02, "\(peak(quiet.left))")
            #expect(abs(peak(loud.left) - 1) < 0.02, "\(peak(loud.left))")
            #expect(peak(loud.right) == 0)
        } catch {
            await client.disconnect()
            await mock.stop()
            throw error
        }
        await client.disconnect()
        await mock.stop()
        #expect(!exists(socket.path), "stop() left the socket behind")
        #expect(await mock.activeSubscribers == 0)
    }

    @Test func theSilentFaultReachesTheSerialMockLive() async throws {
        let socket = try SocketPath()
        defer { socket.remove() }
        let mock = MockSerialScanner(scenario: scenario(), clock: .real(), personality: .sds150,
                                     lineOut: (socket.path, .both))
        _ = try await mock.start()
        let loud = try await capture(socket.path, for: .milliseconds(300))
        await mock.setFaults(MockFaults(lineOutSilent: true))
        try await Task.sleep(for: .milliseconds(100))
        let quiet = try await capture(socket.path, for: .milliseconds(300))
        await mock.stop()
        #expect(peak(loud.left) > 0.2)
        #expect(peak(quiet.left) < 0.05)
    }
}
