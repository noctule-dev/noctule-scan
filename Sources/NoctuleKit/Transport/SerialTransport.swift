// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Darwin
import Foundation
import Synchronization

public enum SerialTransportError: Error, Equatable {
    case notOpen
    /// Nothing at the path (the scanner isn't plugged in, or isn't in serial mode).
    case noSuchPort(String)
    /// Another program, or another transport in this one, has the port open.
    case busy(String)
    case openFailed(String)
    /// The port didn't take the whole command. It is never retried: the scanner may have got part
    /// of it, and only a re-read says what took effect.
    case writeFailed(String)
}

/// A scanner connection over a serial device (an SDS150 in serial mode is
/// `/dev/cu.usbmodem…`, driven by macOS's CDC ACM driver). macOS only.
///
/// `open()` opens the port non-blocking, takes it for exclusive use, sets raw 115200 8-N-1 with no
/// flow control, and discards whatever input was waiting, so a reply half-read by an earlier owner
/// is never taken for an answer. Exclusive use is two locks: `TIOCEXCL`, which makes the driver
/// refuse any other open with `EBUSY` (as for programs that don't lock), and a non-blocking
/// `flock`, which is what refuses a second opener of a pseudo-terminal (ptys ignore `TIOCEXCL`
/// for a non-root opener, LESSONS.md 2026-11-11) and of the same port within this process. Both
/// end with the descriptor. Only a `flock` held elsewhere (`EWOULDBLOCK`) refuses the open; any
/// other `flock` failure (a driver node without advisory locks, say) is ignored, and `TIOCEXCL`
/// alone then holds the port, so an unlockable node can never make the scanner unopenable.
///
/// A thread per `open()` reads the port and feeds a fresh `SerialResponseAssembler`; `responses`
/// is a fresh stream per `open()` and finishes on `close()`, or when the device went away: a read
/// reports end of file or an error other than `EAGAIN`/`EINTR` (`ENXIO`, `EIO`), or `poll` reports
/// a hang-up (`POLLHUP`, `POLLERR`, `POLLNVAL`) while `read` has nothing (`EAGAIN`) on
/// `hangupLimit` (3) polls in a row, `hangupPause` (10 ms) apart; a read that returns bytes, or a
/// poll without a hang-up, starts the count again. (Without that count a device that only
/// reports a hang-up would make `poll` fire at once forever: a spinning thread and a stream that
/// never ends.) The descriptor is then closed at once, and `send` fails with `.writeFailed` until
/// the next `open()`.
///
/// **A requested close lets the output go first.** On `close()` (or the transport's release) the
/// thread waits, before it closes the descriptor, until the tty's output queue is empty
/// (`TIOCOUTQ` reads 0), `TIOCOUTQ` fails, or `drainLimit` (250 ms) has passed, looking every
/// `drainPollInterval` (5 ms), and then waits `drainGrace` (20 ms) more, because `TIOCOUTQ` doesn't
/// count bytes the USB driver has taken but not yet sent. Why: the descriptor is non-blocking, and
/// the last close of a non-blocking tty discards whatever output is still queued, so a `PSI,0`
/// written just before a close could be lost on the real port; a pty the mock keeps open never
/// shows it (LESSONS.md 2026-11-11). So a close takes at most about 0.3 s. Nothing here can block
/// longer: no `tcdrain`, and `O_NONBLOCK` stays set. After the device went away there is no wait:
/// the descriptor is already closed.
///
/// `send` writes the command's bytes with one `write`: anything short of all of them throws
/// `.writeFailed`, and nothing is ever retried (one action sends a command at most once).
public actor SerialTransport: ScannerTransport {
    public let path: String

    /// `TIOCEXCL`, `_IO('t', 13)` in `<sys/ttycom.h>`: a function-like macro Swift doesn't import.
    static let exclusiveUseRequest: UInt = 0x2000_740D
    /// `TIOCOUTQ`, `_IOR('t', 115, int)` in `<sys/ttycom.h>`: the bytes still in the tty's output
    /// queue. Also a function-like macro.
    static let outputQueueRequest: UInt = 0x4004_7473
    static let baudRate: speed_t = 115_200

    /// The longest a requested close waits for the output queue to empty.
    static let drainLimit: Duration = .milliseconds(250)
    /// How often it looks meanwhile.
    static let drainPollInterval: Duration = .milliseconds(5)
    /// The wait after the queue is empty (or the limit passed, or `TIOCOUTQ` failed): the queue
    /// doesn't see what the driver has taken but not yet sent.
    static let drainGrace: Duration = .milliseconds(20)
    /// Hang-ups with nothing to read, on consecutive polls, after which the device is gone.
    static let hangupLimit = 3
    /// The pause after each of them, so the thread doesn't spin.
    static let hangupPause: Duration = .milliseconds(10)

    /// What `open()` does when `flock` fails with `code`.
    enum LockFailure: Equatable {
        /// Someone else holds the port: refuse with `.busy`.
        case busy
        /// The node can't be locked (advisory locks unsupported, or anything else): open anyway,
        /// held by `TIOCEXCL` alone.
        case proceed
    }

    static func lockFailure(errno code: Int32) -> LockFailure {
        code == EWOULDBLOCK ? .busy : .proceed
    }

    private nonisolated let currentResponses: Mutex<AsyncStream<ScannerResponse>>
    private var link: SerialLink?
    /// Links `close()` let go of whose thread may not have closed the descriptor yet.
    private var closing: [SerialLink] = []

    /// Writes bytes to a descriptor, once: the count written (negative on failure) and the
    /// `errno`. Tests substitute it to count the attempts behind one `send`.
    typealias PortWrite = @Sendable (Int32, Data) -> (count: Int, error: Int32)

    static let portWrite: PortWrite = { fd, data in
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return (count, count < 0 ? errno : 0)
    }

    /// Reads into the buffer once: the count read (negative on failure) and the `errno`.
    typealias PortRead = @Sendable (Int32, UnsafeMutableRawBufferPointer) -> (count: Int, error: Int32)

    static let portRead: PortRead = { fd, buffer in
        let count = Darwin.read(fd, buffer.baseAddress, buffer.count)
        return (count, count < 0 ? errno : 0)
    }

    /// `poll` on the descriptors with the timeout (ms): the result and the `errno`.
    typealias PortPoll = @Sendable (inout [pollfd], Int32) -> (ready: Int32, error: Int32)

    static let portPoll: PortPoll = { descriptors, timeout in
        let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), timeout)
        return (ready, ready < 0 ? errno : 0)
    }

    /// The bytes in the descriptor's output queue (`TIOCOUTQ`); nil when the request fails.
    typealias QueuedOutput = @Sendable (Int32) -> Int32?

    static let queuedOutput: QueuedOutput = { fd in
        var count: Int32 = 0
        return ioctl(fd, outputQueueRequest, &count) == 0 ? count : nil
    }

    /// The calls an open port makes: `send`'s write, the reader thread's `poll` and `read`, and the
    /// output-queue check and its waits before a requested close. Tests substitute them: a pty can't
    /// report a hang-up with nothing to read, or an output queue that never empties.
    struct PortCalls: Sendable {
        var write: PortWrite = SerialTransport.portWrite
        var read: PortRead = SerialTransport.portRead
        var poll: PortPoll = SerialTransport.portPoll
        var queuedOutput: QueuedOutput = SerialTransport.queuedOutput
        /// The drain's clock and pause (the reader thread's own). Tests substitute a clock that
        /// only the pause moves, so the drain's waits are counted, not timed.
        var drainNow: @Sendable () -> ContinuousClock.Instant = { .now }
        var drainPause: @Sendable (Duration) -> Void = { pause($0) }
    }

    private let calls: PortCalls

    public init(path: String) {
        self.init(path: path, calls: PortCalls())
    }

    init(path: String, write: @escaping PortWrite) {
        self.init(path: path, calls: PortCalls(write: write))
    }

    init(path: String, calls: PortCalls) {
        self.path = path
        self.calls = calls
        let (finished, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        continuation.finish()
        currentResponses = Mutex(finished)
    }

    deinit {
        link?.requestClose()
    }

    public nonisolated var responses: AsyncStream<ScannerResponse> {
        currentResponses.withLock { $0 }
    }

    /// Closes any earlier link and opens the port. Throws `.noSuchPort` when nothing is at
    /// `path`, `.busy` when another program (or transport) has the port, and `.openFailed`
    /// otherwise. Follows symlinks.
    public func open() async throws {
        await close()
        // A close still running (another task's) holds the port until its thread exits.
        for pending in closing { await pending.waitUntilFinished() }

        let fd = try Self.openPort(path)
        let (responses, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        let link = try SerialLink(fd: fd, continuation: continuation, calls: calls)
        link.start()
        self.link = link
        currentResponses.withLock { $0 = responses }
    }

    /// Writes the command whole, or throws `.writeFailed` (`.notOpen` before `open()`). Never
    /// waits for room and never retries.
    public func send(_ command: ScannerCommand) async throws {
        guard let link else { throw SerialTransportError.notOpen }
        try link.write(command.wireBytes)
    }

    /// Finishes `responses` and returns once the port is closed: after the output queue has emptied
    /// (bounded; see "A requested close lets the output go first"). Idempotent.
    public func close() async {
        guard let link else { return }
        self.link = nil
        closing.append(link)
        link.requestClose()
        await link.waitUntilFinished()
        closing.removeAll { $0 === link }
    }

    /// Takes the advisory lock; nil on success, else the `errno`. Tests substitute it, since a
    /// node that can't be locked isn't available to them.
    typealias AdvisoryLock = @Sendable (Int32) -> Int32?

    static let advisoryLock: AdvisoryLock = { fd in flock(fd, LOCK_EX | LOCK_NB) == 0 ? nil : errno }

    /// Sends a device control request (`ioctl` with no argument); nil on success, else the
    /// `errno`. Tests substitute it to see the requests: a pty can't show `TIOCEXCL` was taken.
    typealias DeviceControl = @Sendable (Int32, UInt) -> Int32?

    static let deviceControl: DeviceControl = { fd, request in ioctl(fd, request) == 0 ? nil : errno }

    /// Opens and configures the port; the descriptor is closed on every failure.
    static func openPort(
        _ path: String, control: DeviceControl = deviceControl, lock: AdvisoryLock = advisoryLock
    ) throws(SerialTransportError) -> Int32 {
        // O_CLOEXEC too, so a child process can't inherit the port and keep it busy.
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ENOENT: throw .noSuchPort(path)
            case EBUSY: throw .busy(path)
            default: throw .openFailed(describe("open", code))
            }
        }
        do {
            try configure(fd, path: path, control: control, lock: lock)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func configure(
        _ fd: Int32, path: String, control: DeviceControl, lock: AdvisoryLock
    ) throws(SerialTransportError) {
        // Exclusive use comes first, so a refused opener never touches the owner's line settings
        // or input.
        if let code = control(fd, exclusiveUseRequest) {
            throw code == EBUSY ? .busy(path) : .openFailed(describe("TIOCEXCL", code))
        }
        if let code = lock(fd), lockFailure(errno: code) == .busy {
            throw .busy(path)
        }

        var line = termios()
        guard tcgetattr(fd, &line) == 0 else { throw .openFailed(describe("tcgetattr", errno)) }
        cfmakeraw(&line)
        line.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS | CDTR_IFLOW | CDSR_OFLOW | CCAR_OFLOW)
        line.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        line.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        // Reads return as soon as one byte is there (O_NONBLOCK makes an empty read EAGAIN, never 0).
        withUnsafeMutableBytes(of: &line.c_cc) {
            $0[Int(VMIN)] = 1
            $0[Int(VTIME)] = 0
        }
        guard cfsetspeed(&line, baudRate) == 0 else { throw .openFailed(describe("cfsetspeed", errno)) }
        guard tcsetattr(fd, TCSANOW, &line) == 0 else { throw .openFailed(describe("tcsetattr", errno)) }
        // Whatever was waiting belongs to an earlier owner of the port.
        guard tcflush(fd, TCIFLUSH) == 0 else { throw .openFailed(describe("tcflush", errno)) }
    }
}

/// One open port: its descriptor, a wake pipe, and the reader thread that owns both. Only the
/// thread closes them, under the lock that `write` and `requestClose` hold, so neither can reach
/// a closed (or reused) descriptor number. Once a close is requested `write` refuses, so the
/// thread can wait for the output queue without the lock.
private final class SerialLink: Sendable {
    let fd: Int32
    let wakeRead: Int32
    let wakeWrite: Int32
    let continuation: AsyncStream<ScannerResponse>.Continuation
    private let calls: SerialTransport.PortCalls

    private struct State {
        var descriptorOpen = true
        var closeRequested = false
        /// Why the port stopped working, for `write`'s error.
        var ended: String?
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Takes ownership of `fd`, closing it if the wake pipe can't be made.
    init(
        fd: Int32, continuation: AsyncStream<ScannerResponse>.Continuation, calls: SerialTransport.PortCalls
    ) throws(SerialTransportError) {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let code = errno
            Darwin.close(fd)
            continuation.finish()
            throw .openFailed(describe("pipe", code))
        }
        for end in pipeFDs {
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        self.fd = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        self.continuation = continuation
        self.calls = calls
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "NoctuleKit.SerialTransport"
        thread.start()
    }

    func write(_ data: Data) throws(SerialTransportError) {
        try state.withLock { state throws(SerialTransportError) in
            guard state.descriptorOpen, !state.closeRequested else {
                throw .writeFailed(state.ended ?? "the port is closed")
            }
            // One attempt, whatever it returns: a retry could send the command twice.
            let (count, code) = calls.write(fd, data)
            if count == data.count { return }
            if count < 0 { throw .writeFailed(describe("write", code)) }
            throw .writeFailed("short write: \(count) of \(data.count) bytes")
        }
    }

    /// Finishes `responses` at once and asks the thread to close the port. Idempotent.
    func requestClose() {
        continuation.finish()
        state.withLock { state in
            guard !state.closeRequested else { return }
            state.closeRequested = true
            // The thread closes the pipe only after it sees the request, under this lock.
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
        }
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

    private func run() {
        var assembler = SerialResponseAssembler()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var ended: String?
        /// Consecutive polls that reported a hang-up while `read` had nothing.
        var hangups = 0
        let hangupEvents = Int16(POLLHUP | POLLERR | POLLNVAL)
        reading: while true {
            var descriptors = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let (ready, pollError) = calls.poll(&descriptors, -1)
            if ready < 0 {
                if pollError == EINTR { continue }
                ended = describe("poll", pollError)
                break reading
            }
            if descriptors[1].revents != 0 { break reading }
            let events = descriptors[0].revents
            guard events != 0 else { continue }
            let (count, readError) = buffer.withUnsafeMutableBytes { calls.read(fd, $0) }
            if count > 0 {
                hangups = 0
                for response in assembler.ingest(Data(buffer[0..<count])) { continuation.yield(response) }
            } else if count == 0 {
                ended = "the device went away"
                break reading
            } else if readError != EAGAIN && readError != EINTR {
                ended = "the device went away (\(describe("read", readError)))"
                break reading
            } else if events & hangupEvents != 0 {
                // A hang-up with nothing to read: the next poll would fire at once, forever.
                hangups += 1
                if hangups >= SerialTransport.hangupLimit {
                    ended = "the device went away (it reported a hang-up \(hangups) times with nothing to read)"
                    break reading
                }
                pause(SerialTransport.hangupPause)
            } else {
                hangups = 0
            }
        }
        // A requested close: give what was written (a last `PSI,0`) its chance to leave first.
        if ended == nil { drainOutput() }
        // Close before finishing, so the port is free by the time a reader sees the end.
        state.withLock { state in
            state.descriptorOpen = false
            state.ended = ended
            Darwin.close(fd)
        }
        continuation.finish()
        // After the device went away, the link stays until its owner closes it.
        var wake = pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
        while !state.withLock({ $0.closeRequested }) { _ = poll(&wake, 1, -1) }
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
            state.finished = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until the output queue is empty, `TIOCOUTQ` fails, or `drainLimit` has passed; then
    /// `drainGrace`. Only after a requested close, when `write` already refuses.
    private func drainOutput() {
        let deadline = calls.drainNow() + SerialTransport.drainLimit
        while let queued = calls.queuedOutput(fd), queued > 0, calls.drainNow() < deadline {
            calls.drainPause(SerialTransport.drainPollInterval)
        }
        calls.drainPause(SerialTransport.drainGrace)
    }
}

/// Blocks the calling thread (the reader's own) for `duration`.
private func pause(_ duration: Duration) {
    usleep(useconds_t(max(0, duration / .microseconds(1))))
}

private func describe(_ operation: String, _ code: Int32) -> String {
    "\(operation): \(String(cString: strerror(code))) (errno \(code))"
}
#endif
