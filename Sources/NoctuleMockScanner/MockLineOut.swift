// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import NoctuleKit
import Synchronization

public enum MockLineOutError: Error, Equatable {
    /// A Unix-domain socket path holds fewer than 104 bytes.
    case pathTooLong(String)
    /// Something that isn't a socket is at the path, or a jack is serving it; the mock leaves it alone.
    case pathOccupied(String)
    /// A system call failed, with its name and message.
    case failed(String)
    /// `stop()` has run; a stopped jack can't be started again.
    case stopped
}

/// The serial mock's headphone jack (line-in design §8): the scenario's audio as the SDS150's
/// jack would give it to a line-in cable, served on a Unix-domain **stream** socket at `path` for
/// `PipeLineInSource` and the app's tests to read.
///
/// - **Wire format:** interleaved stereo little-endian Float32 frames at 48 kHz, written in 20 ms
///   blocks paced by `clock` (real time in the executable). One client at a time: a second is
///   accepted and closed at once, so it reads end of file. While no client is connected the audio is
///   discarded, so a client that connects late gets the present moment, never a backlog. A client
///   that stops reading loses blocks (a bounded queue of 8 blocks, 160 ms) rather than slowing the jack.
/// - **During a transmission:** a sine at the transmission's `toneHz`, amplitude `peak(forVolume:)`
///   (`volume / 8`), the sum with the hiss hard-clipped to +-1. So volume 8 and up clips: at 8 the
///   tone reaches full scale, and at the scenarios' tones (440 Hz to 1 kHz at 48 kHz) a crest holds
///   two or more samples above `LineInMeter.clipThreshold` (about five at 440 Hz), which the detector
///   counts as a clip; 9 and up cut the tone flat.
///   **Between transmissions:** white noise at -52 dBFS RMS (the owner's rig's idle floor, design
///   §3a), also under the tone. With the `silent` fault, that noise only, throughout. The tone and
///   the noise go on the channel or channels `channel` names; the other is zero throughout.
/// - The volume is read for every block, through the closure, so `VOL,n` from a client changes the
///   level at once.
///
/// **Assumptions, not hardware** (listed on `MockPersonality`): the level curve (amplitude
/// `volume / 8` with no ceiling before the hard clip, a departure from the plan's
/// `min(1, volume / 8)` so that volume 8 and up clip on the tone alone), the stereo layout, the noise's
/// Gaussian shape and that the jack is silent but for noise between transmissions. The rig measured
/// only the floor and one volume's peak on a mono input.
///
/// The jack runs on its own thread, off the serial mock's queues, and its descriptors, the socket
/// file and that thread are gone when `stop()` returns.
public final class MockLineOut: Sendable {
    public static let sampleRate = 48_000
    /// Frames in one 20 ms block.
    static let blockFrames = 960
    static let blockSeconds = Double(blockFrames) / Double(sampleRate)
    /// The idle floor's RMS: -52 dBFS.
    static let hissRMS = pow(10.0, -52.0 / 20.0)
    /// The most unsent bytes a slow client may hold before blocks are dropped (about 8 blocks).
    static let queueLimit = 8 * blockFrames * 8
    /// How often the thread wakes to accept, check the clock and write.
    static let pollInterval: DispatchTimeInterval = .milliseconds(5)

    /// The tone's amplitude at a scanner volume, `volume / 8`, before the jack's hard clip at +-1: 8
    /// just reaches full scale, and 9 and above (1.125 up to 1.875 at 15) are cut flat. (The plan
    /// said `min(1, volume / 8)`, which could clip only through the hiss; a ruling made during
    /// the build, 2026-11-17, is that high volumes clip the tone itself. The owner hasn't ruled on it.)
    public static func peak(forVolume volume: Int) -> Float {
        max(0, Float(volume) / 8)
    }

    public let path: String
    private let channel: LineInChannel
    private let scenario: MockScenario
    private let clock: MockClock
    private let volume: @Sendable () -> Int
    private let silent: @Sendable () -> Bool

    private struct State {
        var started = false
        var stopRequested = false
    }

    private let state = Mutex(State())
    private let finished = DispatchGroup()

    public init(path: String, channel: LineInChannel, scenario: MockScenario, clock: MockClock,
                volume: @escaping @Sendable () -> Int, silent: @escaping @Sendable () -> Bool) {
        self.path = path; self.channel = channel; self.scenario = scenario; self.clock = clock
        self.volume = volume; self.silent = silent
    }

    /// Binds and listens at `path` (a stale socket file there is replaced; anything else is
    /// refused), then starts serving. The socket accepts connections when this returns.
    public func start() throws {
        let alreadyStarted = state.withLock { state -> Bool? in
            if state.stopRequested { return nil }
            defer { state.started = true }
            return state.started
        }
        guard let alreadyStarted else { throw MockLineOutError.stopped }
        guard !alreadyStarted else { return }
        let listener: Listener
        do { listener = try Listener(path: path) } catch {
            state.withLock { $0.started = false }
            throw error
        }
        finished.enter()
        let thread = Thread { [self] in
            serve(listener)
            finished.leave()
        }
        thread.name = "NoctuleMockScanner.MockLineOut"
        thread.start()
    }

    /// Closes the client and the listener, removes the socket file and waits for the thread. Safe
    /// to call twice, or without `start()`.
    public func stop() {
        state.withLock { $0.stopRequested = true }
        finished.wait()
    }

    private var stopRequested: Bool { state.withLock { $0.stopRequested } }

    // MARK: Serving

    /// The listening socket and the file it made.
    private struct Listener {
        let fd: Int32
        let path: String
        let inode: ino_t

        init(path: String) throws {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let bytes = Array(path.utf8)
            guard !bytes.isEmpty, bytes.count < capacity else { throw MockLineOutError.pathTooLong(path) }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            try Self.clearStale(path, address: address, size: size)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw MockLineOutError.failed("socket: \(String(cString: strerror(errno)))") }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let bound = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                throw MockLineOutError.failed("bind \(path): \(message)")
            }
            var info = stat()
            lstat(path, &info)
            self.fd = fd; self.path = path; self.inode = info.st_ino
        }

        /// Removes a socket file nobody serves; refuses anything else, and a socket someone does.
        private static func clearStale(_ path: String, address: sockaddr_un, size: socklen_t) throws {
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw MockLineOutError.pathOccupied(path) }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(probe) }
            let connected = withUnsafePointer(to: address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, size) }
            }
            guard connected != 0 else { throw MockLineOutError.pathOccupied(path) }
            guard unlink(path) == 0 || errno == ENOENT else {
                throw MockLineOutError.failed("unlink \(path): \(String(cString: strerror(errno)))")
            }
        }

        /// Closes the socket and removes the file, if it is still ours.
        func close() {
            Darwin.close(fd)
            var info = stat()
            if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
        }
    }

    /// The jack's thread: accepts, makes a block whenever `clock` has passed its end, and writes.
    private func serve(_ listener: Listener) {
        var client: Int32 = -1
        var unsent: [UInt8] = []
        var noise = Noise(seed: 0x9E37_79B9_7F4A_7C15)
        var blockStart = clock.now
        // The thread's wakeups come from a strict timer, not `usleep`: in a throttled process (the
        // CI runner, `taskpolicy -c background`) a 5 ms sleep took about 200 ms, so the jack wrote
        // its blocks in bursts of that length instead of each as it fell due (LESSONS.md 2026-11-20).
        let tick = DispatchSemaphore(value: 0)
        let ticker = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "NoctuleMockScanner.MockLineOut"))
        ticker.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(1))
        ticker.setEventHandler { tick.signal() }
        ticker.resume()
        defer {
            ticker.cancel()
            if client >= 0 { Darwin.close(client) }
            listener.close()
        }
        while !stopRequested {
            // A new client: one at a time, so a second is closed at once. A client that has gone
            // (closed, then connected again before this thread woke) is let go first, so the new
            // connection isn't taken for a second client.
            while true {
                let accepted = accept(listener.fd, nil, nil)
                if accepted < 0 { break }
                if client >= 0, hasGone(client) {
                    Darwin.close(client)
                    client = -1
                    unsent.removeAll()
                }
                if client >= 0 {
                    Darwin.close(accepted)
                } else {
                    client = accepted
                    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
                    var on: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                    var size: Int32 = 64 * 1024
                    setsockopt(client, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
                    unsent.removeAll()
                }
            }
            // Whatever a client sends is ignored. A client that has closed its sending side only
            // (`nc -U` does that) is still listening; one that has closed the socket no longer has a
            // peer name, and its place is free for the next.
            if client >= 0, hasGone(client) {
                Darwin.close(client)
                client = -1
                unsent.removeAll()
            }
            // Blocks the clock has passed, oldest first; a clock that jumped (a stall, a `set`) is
            // not caught up on.
            let now = clock.now
            if now < blockStart - 0.5 || now - blockStart > 0.5 { blockStart = now - Self.blockSeconds }
            while blockStart + Self.blockSeconds <= now {
                if client >= 0, unsent.count < Self.queueLimit {
                    unsent.append(contentsOf: block(at: blockStart, noise: &noise))
                }
                blockStart += Self.blockSeconds
            }
            if client >= 0, !unsent.isEmpty {
                let written = unsent.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                if written > 0 {
                    unsent.removeFirst(written)
                } else if written < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    Darwin.close(client)
                    client = -1
                    unsent.removeAll()
                }
            }
            tick.wait()
        }
    }

    /// Whether the client on `socket` has gone: reading it (what it sent is ignored) failed, or
    /// found end of file with no peer left. A client that only closed its sending side stays.
    private func hasGone(_ socket: Int32) -> Bool {
        var scratch = [UInt8](repeating: 0, count: 256)
        let count = recv(socket, &scratch, scratch.count, 0)
        let failed = count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR
        return failed || (count == 0 && !hasPeer(socket))
    }

    /// Whether the other end of `socket` still exists.
    private func hasPeer(_ socket: Int32) -> Bool {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        return withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(socket, $0, &length) == 0 }
        }
    }

    // MARK: Making audio

    /// One block starting at scenario time `start`, as bytes.
    private func block(at start: Double, noise: inout Noise) -> [UInt8] {
        let amplitude = Self.peak(forVolume: volume())
        let toneless = silent()
        let leftOn = channel != .right, rightOn = channel != .left
        let begin = toneHz(at: start)
        let end = toneHz(at: start + Self.blockSeconds)
        let rate = Double(Self.sampleRate)
        var bytes = [UInt8](repeating: 0, count: Self.blockFrames * 8)
        // Each channel reads the hiss table from its own random place, so the two are independent.
        let table = Self.hissTable, mask = table.count - 1
        let offsets = (noise.next(), noise.next())
        bytes.withUnsafeMutableBytes { raw in
            for frame in 0..<Self.blockFrames {
                let t = start + Double(frame) / rate
                // A block that straddles a transmission's edge looks each sample up; the rest reuse
                // the block's one answer.
                let hz = begin == end ? begin : toneHz(at: t)
                var tone: Float = 0
                if let hz, !toneless { tone = amplitude * Float(sin(2 * Double.pi * hz * t)) }
                for side in 0..<2 where side == 0 ? leftOn : rightOn {
                    let place = Int((side == 0 ? offsets.0 : offsets.1) & UInt64(mask)) + frame
                    let sample = max(-1, min(1, tone + table[place & mask] * Float(Self.hissRMS)))
                    raw.storeBytes(of: sample.bitPattern.littleEndian, toByteOffset: frame * 8 + side * 4, as: UInt32.self)
                }
            }
        }
        return bytes
    }

    /// The tone of the transmission on air at scenario time `t`, if any.
    private func toneHz(at t: Double) -> Double? {
        if case .transmission(_, let transmission) = scenario.moment(at: t) { return transmission.toneHz }
        return nil
    }

    /// 65,536 Gaussian samples of exactly unit RMS, made once from a fixed seed, so a run is
    /// repeatable and a block costs no logarithms (the debug build made 96,000 a second per jack
    /// too slow beside the other tests). Each block reads it from a random place, one per channel,
    /// so the hiss has no fixed period.
    private static let hissTable: [Float] = {
        var generator = Noise(seed: 0x9E37_79B9_7F4A_7C15)
        var values = (0..<65_536).map { _ in generator.gaussian() }
        let rms = (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
        values = values.map { $0 / rms }
        return values.map { Float($0) }
    }()

    /// Random numbers from a small seeded generator (xorshift64*), and Gaussians from them.
    private struct Noise {
        private var state: UInt64
        private var spare: Double?

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }

        private mutating func uniform() -> Double {
            // The top 53 bits as a number in (0, 1).
            (Double(next() >> 11) + 0.5) / Double(1 << 53)
        }

        /// Standard normal (Box-Muller).
        mutating func gaussian() -> Double {
            if let spare {
                self.spare = nil
                return spare
            }
            let radius = (-2 * log(uniform())).squareRoot()
            let angle = 2 * Double.pi * uniform()
            spare = radius * sin(angle)
            return radius * cos(angle)
        }
    }
}

/// A flag the jack's thread reads while the serial mock's actor sets it.
final class MockLineOutFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set(_ newValue: Bool) { value.withLock { $0 = newValue } }
}
