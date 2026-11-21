// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Darwin
import Foundation
import NoctuleKit
import Synchronization

/// A line-in source that reads a Unix-domain stream socket instead of an audio device (line-in
/// design §8): the serial mock's headphone jack (`--line-out PATH`, `MockLineOut`), for tests and for
/// the app under `NOCTULE_TEST_LINE_IN`. It never touches Core Audio.
///
/// - **Wire format:** interleaved stereo little-endian Float32 frames at 48 kHz, whatever size the
///   reads come in; a partial frame waits for the rest. The frames go through a `LineInPipeline`, so
///   the chunks, levels and channel choice are the engine source's.
/// - **Timing:** a read's last frame is taken to be as old as the read, so its first sample is stamped
///   with the read time minus the duration of the frames the read brought. The pipeline starts its
///   count again when that differs from its own by more than 20 ms.
/// - **States:** `.starting`, then `.streaming(deviceName:)` once connected. A socket that isn't
///   there, or that closes (end of file, a read error, a jack that serves another client), is
///   `.missing(deviceName:)`, and the source tries again every second until `stop()`. The first chunk
///   after any connection but a first attempt's is flagged `discontinuity` (the sequence carries on).
///   That includes a source whose socket was missing at the start, which flags its first chunk of
///   all (the brief's choice): `EngineLineInSource` doesn't flag that one, and the recorder ignores
///   the flag, so nothing treats it as an error.
/// - `stop()` returns without waiting for a read or the retry's second: it wakes the reading thread
///   through a pipe, waits for it to finish, closes the socket and finishes the three streams.
///
/// One thread reads, runs the pipeline and yields; the socket is nonblocking and every wait is a
/// `poll` that the wake pipe can end. It assumes a little-endian host, as every Mac is.
public final class PipeLineInSource: LineInSource {
    /// How long a missing socket waits before the next attempt.
    public static let retryInterval: Duration = .seconds(1)
    static let sampleRate = 48_000.0
    static let channels = 2
    static let bytesPerFrame = channels * MemoryLayout<Float>.size

    public let chunks: AsyncStream<AudioChunk>
    public let levels: AsyncStream<LineInLevel>
    public let states: AsyncStream<LineInState>
    private let chunkSink: AsyncStream<AudioChunk>.Continuation
    private let levelSink: AsyncStream<LineInLevel>.Continuation
    private let stateSink: AsyncStream<LineInState>.Continuation

    private let path: String
    private let config: LineInConfig
    /// The read end of a pipe `stop()` writes to; the thread polls it beside the socket.
    private let wakeRead: Int32
    private let wakeWrite: Int32

    private struct Lifecycle {
        var started = false
        var threadRunning = false
        var stopped = false
        var pipeClosed = false
    }
    private let lifecycle = Mutex(Lifecycle())
    private let finished = DispatchGroup()

    public init(path: String, config: LineInConfig) {
        self.path = path
        self.config = config
        (chunks, chunkSink) = AsyncStream.makeStream(of: AudioChunk.self)
        (levels, levelSink) = AsyncStream.makeStream(of: LineInLevel.self)
        (states, stateSink) = AsyncStream.makeStream(of: LineInState.self)
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            for fd in fds {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
        }
        wakeRead = fds[0]
        wakeWrite = fds[1]
    }

    deinit { closePipe() }

    public func start() async {
        let begin = lifecycle.withLock { state -> Bool in
            guard !state.started, !state.stopped else { return false }
            state.started = true
            return true
        }
        guard begin else { return }
        stateSink.yield(.starting)
        let socket = Self.connect(to: path)
        let first: LineInState = socket == nil ? .missing(deviceName: config.deviceName)
            : .streaming(deviceName: config.deviceName)
        stateSink.yield(first)
        let launch = lifecycle.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.threadRunning = true
            finished.enter()
            return true
        }
        guard launch else {
            if let socket { Darwin.close(socket) }
            return
        }
        let thread = Thread { [self] in
            run(firstSocket: socket, firstState: first)
            finished.leave()
        }
        thread.name = "NoctuleAudioCapture.PipeLineInSource"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func stop() async {
        let (running, first) = lifecycle.withLock { state -> (Bool, Bool) in
            defer { state.stopped = true }
            return (state.threadRunning, !state.stopped)
        }
        if running {
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
            await withCheckedContinuation { continuation in
                finished.notify(queue: .global()) { continuation.resume() }
            }
        }
        guard first else { return }
        closePipe()
        stateSink.yield(.stopped)
        chunkSink.finish()
        levelSink.finish()
        stateSink.finish()
    }

    private func closePipe() {
        let close = lifecycle.withLock { state -> Bool in
            defer { state.pipeClosed = true }
            return !state.pipeClosed
        }
        guard close else { return }
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    // MARK: - The reading thread

    /// Reads until `stop()`: serves a connection, and while there is none looks for the socket every
    /// `retryInterval`. The pipeline is the thread's alone.
    private func run(firstSocket: Int32?, firstState: LineInState) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(Self.channels), interleaved: true)
        else { return }
        let pipeline = LineInPipeline(inputFormat: format, channel: config.channel,
                                      ssrc: UInt32.random(in: .min ... .max))
        var lastState = firstState
        func emit(_ state: LineInState) {
            guard state != lastState else { return }
            lastState = state
            stateSink.yield(state)
        }
        // A connection that follows a missing socket, or an earlier connection, is a break in the
        // capture; a first attempt that succeeds is not.
        var gap = firstSocket == nil
        var socket = firstSocket
        while true {
            if let connected = socket {
                if gap { pipeline.markDiscontinuity() }
                gap = true
                let stopped = !serve(connected, format: format, into: pipeline)
                Darwin.close(connected)
                if stopped { return }
                emit(.missing(deviceName: config.deviceName))
            }
            if waitForStop(for: Self.retryInterval) { return }
            socket = Self.connect(to: path)
            if socket != nil { emit(.streaming(deviceName: config.deviceName)) }
        }
    }

    /// Reads `socket` until it closes (true) or `stop()` is called (false); the result is whether
    /// the source goes on.
    private func serve(_ socket: Int32, format: AVAudioFormat, into pipeline: LineInPipeline) -> Bool {
        var raw = [UInt8](repeating: 0, count: 64 * 1024)
        var held: [UInt8] = []
        while true {
            var fds = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return true
            }
            if fds[1].revents != 0 { return false }
            guard fds[0].revents != 0 else { continue }
            let count = recv(socket, &raw, raw.count, 0)
            let readAt = ContinuousClock.now
            if count == 0 { return true }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return true
            }
            held.append(contentsOf: raw[0..<count])
            let frames = held.count / Self.bytesPerFrame
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData else { continue }
            let bytes = frames * Self.bytesPerFrame
            _ = held.withUnsafeBytes { memcpy(data[0], $0.baseAddress!, bytes) }
            held.removeFirst(bytes)
            buffer.frameLength = AVAudioFrameCount(frames)
            // The read's last frame is as old as the read; the first is the frames' duration older.
            let out = pipeline.process(buffer, firstSampleAt: readAt - .seconds(Double(frames) / Self.sampleRate))
            for chunk in out.chunks { chunkSink.yield(chunk) }
            for level in out.levels { levelSink.yield(level) }
        }
    }

    /// Waits up to `interval`; true when `stop()` called in the meantime (or before).
    private func waitForStop(for interval: Duration) -> Bool {
        let milliseconds = Int32(interval / .milliseconds(1))
        var fds = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while true {
            let ready = poll(&fds, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            return ready > 0
        }
    }

    /// A nonblocking connection to the socket at `path`, or nil when nothing is there to connect to.
    private static func connect(to path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
