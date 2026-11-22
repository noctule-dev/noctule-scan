// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import NoctuleKit
import NoctuleKitTestSupport
import NoctuleMockScanner

// Every test here opens only a pseudo-terminal it created (or a path that doesn't exist); never
// a real serial port.

private struct TimedOut: Error {}

/// Runs `body`, failing with `TimedOut` after `limit` so no test can hang on a port.
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

/// Polls `condition` every 5 ms, failing with `TimedOut` after `limit`.
private func eventually(_ limit: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Everything the client has written to a `PseudoTerminal`, collected by one reader.
private final class Inbox: Sendable {
    private let data = Mutex(Data())

    init(_ pty: PseudoTerminal) {
        let stream = pty.received
        Task { [weak self] in
            for await chunk in stream { self?.data.withLock { $0.append(chunk) } }
        }
    }

    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
}

/// Opens a transport on `path`, runs `body` within 5 s, and closes the transport whatever happens.
private func withTransport(
    _ path: String, _ body: @escaping @Sendable (SerialTransport) async throws -> Void
) async throws {
    let transport = SerialTransport(path: path)
    do {
        try await within(.seconds(5)) { try await body(transport) }
    } catch {
        await transport.close()
        throw error
    }
    await transport.close()
}

/// A bare pty whose master nobody reads, so the client's output queue fills up.
private final class UndrainedPTY: Sendable {
    let master: Int32
    let slavePath: String

    init() throws {
        // `posix_openpt` can fail with errno -6 while another test opens or closes a pty; retry
        // as `PseudoTerminal` does.
        var opened = posix_openpt(O_RDWR | O_NOCTTY)
        for _ in 0..<100 where opened < 0 && errno == -6 {
            Thread.sleep(forTimeInterval: 0.001)  // off the cooperative pool: a 1 ms retry, by design
            opened = posix_openpt(O_RDWR | O_NOCTTY)
        }
        master = opened
        guard master >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            Darwin.close(master)
            throw POSIXError(.EIO)
        }
        slavePath = String(cString: name)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    }

    deinit { Darwin.close(master) }

    /// Reads everything the client has written so far.
    func drain() -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { return collected }
            collected.append(contentsOf: buffer[0..<count])
        }
    }
}

/// How many of this process's descriptors are open on `path`. Each test's pty has its own path
/// while any descriptor on its slave is open, so tests running in parallel don't disturb the
/// count; once the last one closes, macOS may give the number to the next pty at once.
private func descriptors(on path: String) -> Int {
    let pid = getpid()
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return -1 }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 32)
    let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    var count = 0
    for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride)
    where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
        let open = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if open == path { count += 1 }
    }
    return count
}

/// Events recorded from more than one thread.
private final class EventLog: Sendable {
    private let events = Mutex<[String]>([])
    func append(_ event: String) { events.withLock { $0.append(event) } }
    var all: [String] { events.withLock { $0 } }
}

/// Puts the tty behind `fd` into a cooked 9600 7E2 state with RTS/CTS and XON/XOFF, the opposite
/// of what `SerialTransport` sets.
private func setCooked(_ fd: Int32) throws {
    var cooked = termios()
    try #require(tcgetattr(fd, &cooked) == 0)
    cfsetspeed(&cooked, speed_t(B9600))
    cooked.c_cflag = (cooked.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS7 | PARENB | CSTOPB | CRTSCTS)
    cooked.c_iflag |= tcflag_t(IXON | IXOFF | ICRNL)
    cooked.c_oflag |= tcflag_t(OPOST | ONLCR)
    cooked.c_lflag |= tcflag_t(ICANON | ECHO | ISIG)
    try #require(tcsetattr(fd, TCSANOW, &cooked) == 0)
}

/// Whether the tty behind `fd` still has the settings `setCooked` gave it.
private func isStillCooked(_ fd: Int32) -> Bool {
    var line = termios()
    guard tcgetattr(fd, &line) == 0 else { return false }
    return cfgetospeed(&line) == speed_t(B9600) && line.c_lflag & tcflag_t(ICANON) != 0
}

private let mdlReply = ScannerResponse.fields(command: "MDL", fields: ["SDS150"])

/// A stand-in for `TIOCOUTQ`: answers each call with the next of `answers` (the last one again
/// once they run out; nil is a failed request), and counts the calls.
private final class QueueAnswers: Sendable {
    private let answers: [Int32?]
    private let calls = Mutex(0)

    init(_ answers: [Int32?]) { self.answers = answers }

    var count: Int { calls.withLock { $0 } }

    var queuedOutput: SerialTransport.QueuedOutput {
        { [self] _ in
            let index = calls.withLock { n in
                n += 1
                return n - 1
            }
            return answers[min(index, answers.count - 1)]
        }
    }
}

/// How long a close took, once it has ended.
private final class CloseTime: Sendable {
    private let state = Mutex<Duration?>(nil)
    var value: Duration? { state.withLock { $0 } }
    func set(_ duration: Duration) { state.withLock { $0 = duration } }
}

/// The drain's clock, moved only by its pauses: a requested close's waits are counted, not
/// timed, so a thread that wakes late (a throttled process, the CI runner) can't stretch them
/// (LESSONS.md 2026-11-20). The pauses return at once.
private final class DrainClock: Sendable {
    private let start = ContinuousClock.now
    private let state = Mutex<[Duration]>([])

    /// Every pause asked for, in order.
    var pauses: [Duration] { state.withLock { $0 } }
    /// The clock's time since it was made: the pauses' sum.
    var elapsed: Duration { pauses.reduce(.zero, +) }

    var now: @Sendable () -> ContinuousClock.Instant { { [self] in start + elapsed } }
    var pause: @Sendable (Duration) -> Void { { [self] duration in state.withLock { $0.append(duration) } } }
}

/// A device that reports a hang-up to `poll` on every call (on top of what the real `poll` says,
/// which only the first call waits for), and a `read` that follows `script`: `false` says "try
/// again" (`EAGAIN`) without reading, `true` reads for real. The last entry repeats.
private final class HangupDevice: Sendable {
    private let script: [Bool]
    private let reads = Mutex(0)
    private let polls = Mutex(0)

    init(_ script: [Bool]) { self.script = script }

    var readCount: Int { reads.withLock { $0 } }

    var calls: SerialTransport.PortCalls {
        var calls = SerialTransport.PortCalls()
        calls.poll = { [self] descriptors, timeout in
            let first = polls.withLock { n in
                n += 1
                return n == 1
            }
            var (ready, error) = SerialTransport.portPoll(&descriptors, first ? timeout : 0)
            guard ready >= 0 else { return (ready, error) }
            descriptors[0].revents |= Int16(POLLHUP)
            ready = max(ready, 1)
            error = 0
            return (ready, error)
        }
        calls.read = { [self] fd, buffer in
            let index = reads.withLock { n in
                n += 1
                return n - 1
            }
            guard script[min(index, script.count - 1)] else { return (-1, EAGAIN) }
            return SerialTransport.portRead(fd, buffer)
        }
        return calls
    }
}

/// Reads a pty's master on a thread of its own, starting after `delay`, for at most `limit`:
/// a scanner that takes a moment to read what was sent.
private final class LateReader: Sendable {
    private let collected = Mutex(Data())
    private let done = Mutex(false)

    init(_ pty: UndrainedPTY, after delay: Duration, for limit: Duration = .milliseconds(600)) {
        let thread = Thread { [self] in
            Thread.sleep(forTimeInterval: delay / .seconds(1))  // off the cooperative pool: its own Thread
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                let chunk = pty.drain()
                collected.withLock { $0.append(chunk) }
                Thread.sleep(forTimeInterval: 0.005)  // off the cooperative pool: its own Thread
            }
            done.withLock { $0 = true }
        }
        thread.start()
    }

    var isDone: Bool { done.withLock { $0 } }
    var text: String { collected.withLock { String(decoding: $0, as: UTF8.self) } }
}

@Suite(.timeLimit(.minutes(3))) struct SerialTransportTests {
    @Test func roundTrip() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let inbox = Inbox(pty)
        try await withTransport(pty.slavePath) { transport in
            try await transport.open()
            var responses = transport.responses.makeAsyncIterator()
            try await transport.send(ScannerCommand("MDL"))
            try await eventually { inbox.text == "MDL\r" }
            pty.write(Data("MDL,SDS150\r".utf8))
            #expect(await responses.next() == mdlReply)
            // Nothing was echoed back to the scanner.
            #expect(inbox.text == "MDL\r")
        }
    }

    /// Review Focus 1: a port another program holds fails at once with `.busy`, with no hang and
    /// no sharing, and the holder keeps working. A pty slave ignores `TIOCEXCL` for a non-root
    /// user (LESSONS.md 2026-11-11), so this pins the transport's `flock`.
    @Test func secondOpenIsBusy() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let inbox = Inbox(pty)
        let path = pty.slavePath
        let second = SerialTransport(path: path)
        try await withTransport(path) { first in
            try await first.open()
            await #expect(throws: SerialTransportError.busy(path)) { try await second.open() }
            await #expect(throws: SerialTransportError.notOpen) { try await second.send(ScannerCommand("VOL")) }

            var responses = first.responses.makeAsyncIterator()
            try await first.send(ScannerCommand("MDL"))
            try await eventually { inbox.text == "MDL\r" }
            pty.write(Data("MDL,SDS150\r".utf8))
            #expect(await responses.next() == mdlReply)
            await first.close()

            try await second.open()
            var secondResponses = second.responses.makeAsyncIterator()
            try await second.send(ScannerCommand("MDL"))
            try await eventually { inbox.text == "MDL\rMDL\r" }
            pty.write(Data("MDL,SDS150\r".utf8))
            #expect(await secondResponses.next() == mdlReply)
        }
        await second.close()
    }

    /// A refused opener locks before it touches the line, so it can't discard what the holder
    /// has queued for the scanner.
    @Test func refusedOpenLeavesTheHolderAlone() async throws {
        let pty = try UndrainedPTY()
        let path = pty.slavePath
        let second = SerialTransport(path: path)
        try await withTransport(path) { first in
            try await first.open()
            try await first.send(ScannerCommand("MDL"))
            await #expect(throws: SerialTransportError.busy(path)) { try await second.open() }
            #expect(pty.drain() == Data("MDL\r".utf8))
        }
    }

    /// Only a lock held elsewhere refuses the open. A node that can't be locked at all (the real
    /// `/dev/cu.usbmodem…` driver has never been tried) must still open, held by `TIOCEXCL`.
    @Test func onlyAHeldFlockRefusesTheOpen() {
        #expect(SerialTransport.lockFailure(errno: EWOULDBLOCK) == .busy)
        for code in [ENOTSUP, EOPNOTSUPP, EINVAL, EBADF, ENOLCK, EIO, EPERM] {
            #expect(SerialTransport.lockFailure(errno: code) == .proceed, "errno \(code)")
        }
    }

    /// The same rule as wired into the open: a port whose `flock` fails `ENOTSUP` still opens
    /// and is configured; one whose `flock` is held elsewhere is refused and its descriptor closed.
    @Test func unsupportedFlockStillOpensThePort() throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        let fd = try SerialTransport.openPort(path, lock: { _ in ENOTSUP })
        defer { Darwin.close(fd) }
        var line = termios()
        #expect(tcgetattr(fd, &line) == 0)
        #expect(cfgetospeed(&line) == 115_200)
        #expect(descriptors(on: path) == 2)
        #expect(throws: SerialTransportError.busy(path)) {
            _ = try SerialTransport.openPort(path, lock: { _ in EWOULDBLOCK })
        }
        #expect(descriptors(on: path) == 2)
    }

    /// `TIOCEXCL` (`0x2000740D`; `TIOCNXCL`, `0x2000740E`, would clear exclusive use) is the only
    /// thing that keeps other programs off the real port. A pty ignores it, so the requests are
    /// recorded: exclusive use is asked for first, then the `flock`, both before the line is
    /// touched, and nothing else goes through the control call.
    @Test func exclusiveUseIsTakenFirst() throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let probe = Darwin.open(pty.slavePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        try #require(probe >= 0)
        defer { Darwin.close(probe) }
        try setCooked(probe)

        let log = EventLog()
        let fd = try SerialTransport.openPort(
            pty.slavePath,
            control: { fd, request in
                log.append("ioctl 0x\(String(request, radix: 16, uppercase: true))\(isStillCooked(probe) ? "" : " after line set")")
                return ioctl(fd, request) == 0 ? nil : errno
            },
            lock: { fd in
                log.append("flock\(isStillCooked(probe) ? "" : " after line set")")
                return flock(fd, LOCK_EX | LOCK_NB) == 0 ? nil : errno
            })
        defer { Darwin.close(fd) }
        #expect(log.all == ["ioctl 0x2000740D", "flock"])
        #expect(!isStillCooked(probe))  // and the line was set afterwards

        // The real calls behind the seams `open()` uses do reach the kernel.
        #expect(SerialTransport.exclusiveUseRequest == 0x2000_740D)
        #expect(SerialTransport.deviceControl(-1, SerialTransport.exclusiveUseRequest) == EBADF)
        #expect(SerialTransport.advisoryLock(-1) == EBADF)
    }

    @Test func noSuchPort() async throws {
        let path = "/dev/noctule-no-such-port"
        let transport = SerialTransport(path: path)
        await #expect(throws: SerialTransportError.noSuchPort(path)) { try await transport.open() }
        await #expect(throws: SerialTransportError.notOpen) { try await transport.send(ScannerCommand("MDL")) }
    }

    /// Review Focus 3: a whole reply left in the port before it opened is never delivered.
    @Test func staleInputFlushed() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        pty.write(Data("VOL,9\r".utf8))
        try await withTransport(pty.slavePath) { transport in
            try await transport.open()
            var responses = transport.responses.makeAsyncIterator()
            pty.write(Data("MDL,SDS150\r".utf8))
            #expect(await responses.next() == mdlReply)
        }
    }

    /// Review Focus 3: a partial line and a half-sent document left in the port can't capture the
    /// first answer.
    @Test func partialStaleInputFlushed() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        pty.write(Data("GSI,<XML>,\r<ScannerInfo Mode=\"Stale\">\rVOL,9".utf8))
        try await withTransport(pty.slavePath) { transport in
            try await transport.open()
            var responses = transport.responses.makeAsyncIterator()
            pty.write(Data("MDL,SDS150\r".utf8))
            #expect(await responses.next() == mdlReply)
        }
    }

    @Test func opensWithRawLineSettings() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        // An independent descriptor on the same tty: it sees the line settings the transport sets.
        let probe = Darwin.open(pty.slavePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        try #require(probe >= 0)
        defer { Darwin.close(probe) }
        try setCooked(probe)

        try await withTransport(pty.slavePath) { transport in
            try await transport.open()
            var line = termios()
            #expect(tcgetattr(probe, &line) == 0)
            #expect(cfgetispeed(&line) == 115_200)
            #expect(cfgetospeed(&line) == 115_200)
            #expect(line.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS8))
            #expect(line.c_cflag & tcflag_t(PARENB | CSTOPB | CRTSCTS | CDTR_IFLOW | CDSR_OFLOW | CCAR_OFLOW) == 0)
            #expect(line.c_cflag & tcflag_t(CLOCAL | CREAD) == tcflag_t(CLOCAL | CREAD))
            #expect(line.c_iflag & tcflag_t(IXON | IXOFF | IXANY | ICRNL | INLCR | IGNCR | ISTRIP) == 0)
            #expect(line.c_oflag & tcflag_t(OPOST) == 0)
            #expect(line.c_lflag & tcflag_t(ICANON | ECHO | ECHONL | ISIG | IEXTEN) == 0)
            let (minimum, time) = withUnsafeBytes(of: line.c_cc) { ($0[Int(VMIN)], $0[Int(VTIME)]) }
            #expect(minimum == 1)
            #expect(time == 0)
        }
    }

    @Test func unplugFinishesResponses() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        // macOS hands a freed pty number out again at once, so a parallel test's new pty could
        // take this path and be counted. This descriptor keeps the number ours (the transport
        // still sees end of file when the master closes).
        let holder = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        try #require(holder >= 0)
        defer { Darwin.close(holder) }
        try await withTransport(path) { transport in
            try await transport.open()
            let responses = transport.responses
            #expect(descriptors(on: path) == 3)  // the pty's own, the holder, the transport's
            pty.close()
            try await within(.seconds(2)) { for await _ in responses {} }
            // The port was let go at once, before its owner closed the transport.
            #expect(descriptors(on: path) == 1)
            let error = await #expect(throws: SerialTransportError.self) {
                try await transport.send(ScannerCommand("MDL"))
            }
            guard case .writeFailed(let reason)? = error else {
                Issue.record("expected .writeFailed, got \(String(describing: error))")
                return
            }
            #expect(reason.contains("went away"))
        }
    }

    /// Each open uses one descriptor and each close gives it back; a refused open keeps none.
    @Test func openCloseCyclesLeaveNoDescriptor() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        #expect(descriptors(on: path) == 1)  // the pty's own
        try await withTransport(path) { transport in
            for _ in 0..<20 {
                try await transport.open()
                #expect(descriptors(on: path) == 2)
                await transport.close()
                #expect(descriptors(on: path) == 1)
            }
            try await transport.open()
            let refused = SerialTransport(path: path)
            await #expect(throws: SerialTransportError.busy(path)) { try await refused.open() }
            #expect(descriptors(on: path) == 2)
            // Opening again while open replaces the descriptor rather than adding one.
            try await transport.open()
            #expect(descriptors(on: path) == 2)
        }
        #expect(descriptors(on: path) == 1)
    }

    /// A station may name the port through a symlink (the mock's stable path does); the lock is
    /// on the device, so the real path is busy too.
    @Test func opensThroughSymlink() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let inbox = Inbox(pty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("scanner").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: pty.slavePath)
        let direct = SerialTransport(path: pty.slavePath)
        try await withTransport(link) { transport in
            try await transport.open()
            await #expect(throws: SerialTransportError.busy(pty.slavePath)) { try await direct.open() }
            var responses = transport.responses.makeAsyncIterator()
            try await transport.send(ScannerCommand("MDL"))
            try await eventually { inbox.text == "MDL\r" }
            pty.write(Data("MDL,SDS150\r".utf8))
            #expect(await responses.next() == mdlReply)
        }
        await direct.close()
    }

    @Test func reopenGivesFreshStream() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let inbox = Inbox(pty)
        try await withTransport(pty.slavePath) { transport in
            try await transport.open()
            var first = transport.responses.makeAsyncIterator()
            try await transport.send(ScannerCommand("MDL"))
            try await eventually { inbox.text == "MDL\r" }
            // A complete reply, then the start of another that the close cuts off.
            pty.write(Data("VOL,9\rVOL".utf8))
            #expect(await first.next() == .fields(command: "VOL", fields: ["9"]))
            await transport.close()
            #expect(await first.next() == nil)
            await #expect(throws: SerialTransportError.notOpen) { try await transport.send(ScannerCommand("MDL")) }

            try await transport.open()
            var second = transport.responses.makeAsyncIterator()
            try await transport.send(ScannerCommand("MDL"))
            try await eventually { inbox.text == "MDL\rMDL\r" }
            pty.write(Data("MDL,SDS150\r".utf8))
            // The cut-off "VOL" stayed with the first connection's assembler.
            #expect(await second.next() == mdlReply)
            #expect(await first.next() == nil)
        }
    }

    /// One `send` is one `write(2)`. A failed write (`EAGAIN`, the port full for a moment) or a
    /// short one throws `.writeFailed` after that single attempt, even when the port would take
    /// the bytes a moment later.
    @Test(arguments: [(-1, EAGAIN), (-1, EIO), (2, 0)])
    func aFailedOrShortWriteIsNeverRetried(firstResult: Int, firstError: Int32) async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let inbox = Inbox(pty)
        let attempts = EventLog()
        let transport = SerialTransport(path: pty.slavePath, write: { fd, data in
            attempts.append("write \(data.count)")
            if attempts.all.count == 1 {
                // The scanner side is ready again at once: only a retry would get through.
                if firstResult > 0 { return SerialTransport.portWrite(fd, data.prefix(firstResult)) }
                return (firstResult, firstError)
            }
            return SerialTransport.portWrite(fd, data)
        })
        do {
            try await within(.seconds(5)) {
                try await transport.open()
                let error = await #expect(throws: SerialTransportError.self) {
                    try await transport.send(ScannerCommand("MDL"))
                }
                guard case .writeFailed? = error else {
                    Issue.record("expected .writeFailed, got \(String(describing: error))")
                    return
                }
                #expect(attempts.all == ["write 4"])
                // The next send is a new attempt and goes through.
                try await transport.send(ScannerCommand("VOL"))
                try await eventually { inbox.text.hasSuffix("VOL\r") }
                #expect(attempts.all == ["write 4", "write 4"])
                #expect(inbox.text == String("MDL\r".prefix(max(firstResult, 0))) + "VOL\r")
            }
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
    }

    // MARK: A requested close lets the output go first (final review C1)

    /// The real port's case, on a pty nobody else holds: the transport's close is the last close
    /// of the tty, and a non-blocking last close discards queued output (LESSONS.md 2026-11-11).
    /// The "scanner" reads 40 ms after the close was asked for; the `PSI,0` written just before
    /// the close still reaches it.
    @Test func requestedCloseLetsTheLastWriteLeave() async throws {
        let pty = try UndrainedPTY()
        let transport = SerialTransport(path: pty.slavePath)
        try await within(.seconds(5)) {
            try await transport.open()
            try await transport.send(ScannerCommand("PSI", "0"))
            let reader = LateReader(pty, after: .milliseconds(40))
            await transport.close()
            try await eventually { reader.isDone }
            #expect(reader.text == "PSI,0\r")
        }
        await transport.close()
    }

    /// The real `TIOCOUTQ` (`0x40047473`) counts what the other end hasn't read yet.
    @Test func queuedOutputCountsUnreadBytes() throws {
        let pty = try UndrainedPTY()
        let fd = Darwin.open(pty.slavePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        #expect(SerialTransport.outputQueueRequest == 0x4004_7473)
        #expect(SerialTransport.queuedOutput(fd) == 0)
        #expect(Darwin.write(fd, "PSI,0\r", 6) == 6)
        #expect(SerialTransport.queuedOutput(fd) == 6)
        #expect(pty.drain() == Data("PSI,0\r".utf8))
        #expect(SerialTransport.queuedOutput(fd) == 0)
        #expect(SerialTransport.queuedOutput(-1) == nil)
    }

    /// The wait ends as soon as the queue reads 0 (then the short grace), and on a failed
    /// `TIOCOUTQ` at once; the descriptor is closed either way. Counted on the drain's own clock
    /// (`DrainClock`): one poll interval between looks, then the grace.
    @Test(arguments: [([5, 5, 0] as [Int32?], 3), ([nil], 1), ([0], 1)])
    func drainStopsWhenTheQueueIsEmptyOrUnreadable(answers: [Int32?], expectedCalls: Int) async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        let queue = QueueAnswers(answers)
        let clock = DrainClock()
        let transport = SerialTransport(
            path: path, calls: .init(queuedOutput: queue.queuedOutput, drainNow: clock.now, drainPause: clock.pause))
        try await within(.seconds(5)) {
            try await transport.open()
            #expect(queue.count == 0)  // nothing waits while the port is open
            await transport.close()
            #expect(queue.count == expectedCalls)
            #expect(clock.elapsed < SerialTransport.drainLimit, "close waited \(clock.elapsed)")
            #expect(clock.pauses == Array(repeating: SerialTransport.drainPollInterval, count: expectedCalls - 1)
                        + [SerialTransport.drainGrace], "\(clock.pauses)")
            #expect(descriptors(on: path) == 1)  // the pty's own
        }
        await transport.close()
    }

    /// A queue that never empties (a scanner that has stopped reading) holds the close for the
    /// limit and the grace, 0.27 s, and no longer; then the descriptor is closed. Counted on the
    /// drain's own clock (`DrainClock`): looks a poll interval apart until the limit has passed,
    /// then the grace.
    @Test func drainGivesUpAfterTheLimit() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        let queue = QueueAnswers([100])
        let clock = DrainClock()
        let transport = SerialTransport(
            path: path, calls: .init(queuedOutput: queue.queuedOutput, drainNow: clock.now, drainPause: clock.pause))
        try await within(.seconds(5)) {
            try await transport.open()
            await transport.close()
            #expect(clock.elapsed >= SerialTransport.drainLimit, "close waited \(clock.elapsed)")
            #expect(clock.elapsed == SerialTransport.drainLimit + SerialTransport.drainGrace, "close waited \(clock.elapsed)")
            let looks = Int(SerialTransport.drainLimit / SerialTransport.drainPollInterval)
            #expect(clock.pauses == Array(repeating: SerialTransport.drainPollInterval, count: looks)
                        + [SerialTransport.drainGrace], "\(clock.pauses)")
            #expect(queue.count == looks + 1)
            #expect(descriptors(on: path) == 1)
        }
        await transport.close()
    }

    /// The same on the real clock, the default `PortCalls` drain clock that every port uses: the
    /// close still ends, after at least the limit and the grace, and within 5 s. Lower bounds only,
    /// since a thread that wakes late only makes it longer. (A clock that didn't move would hang the
    /// close, `PSI,0` and all; a pause that didn't wait would skip the grace.)
    @Test func drainOnTheRealClockEndsAfterTheLimitAndTheGrace() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        let queue = QueueAnswers([100])
        let transport = SerialTransport(path: path, calls: .init(queuedOutput: queue.queuedOutput))
        try await within(.seconds(5)) { try await transport.open() }
        let took = CloseTime()
        let began = ContinuousClock.now
        // Unstructured, so a close that never ends fails the test here instead of hanging it.
        Task {
            await transport.close()
            took.set(ContinuousClock.now - began)
        }
        try await eventually(.seconds(5)) { took.value != nil }
        let duration = try #require(took.value)
        #expect(duration >= SerialTransport.drainLimit + SerialTransport.drainGrace, "close took \(duration)")
        #expect(queue.count > 1)
        #expect(descriptors(on: path) == 1)
    }

    /// When the device went away there is nothing to wait for: the descriptor was closed at once,
    /// and neither then nor at the owner's `close()` is the output queue asked.
    /// `queue.count == 0` (the output queue never asked) is the proof that nothing drained; the
    /// time is only a bound against a hang (a 100 ms bound was too tight on the CI runner;
    /// LESSONS.md 2026-11-22).
    @Test func noDrainAfterTheDeviceWentAway() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        // Keeps the pty's number ours after its master closes (see `unplugFinishesResponses`).
        let holder = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        try #require(holder >= 0)
        defer { Darwin.close(holder) }
        let queue = QueueAnswers([100])
        let transport = SerialTransport(path: path, calls: .init(queuedOutput: queue.queuedOutput))
        try await within(.seconds(5)) {
            try await transport.open()
            let responses = transport.responses
            pty.close()
            for await _ in responses {}
            #expect(descriptors(on: path) == 1)  // the holder's
            let began = ContinuousClock.now
            await transport.close()
            #expect(ContinuousClock.now - began < .seconds(2))
            #expect(queue.count == 0)
        }
        await transport.close()
    }

    // MARK: A device that only reports a hang-up (final review I1)

    /// `poll` keeps reporting a hang-up while `read` has nothing: after three such polls the
    /// device counts as gone, the stream finishes and the port is let go, instead of the reader
    /// spinning with the stream open for ever.
    @Test func hangupWithNothingToReadFinishesTheStream() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let path = pty.slavePath
        let device = HangupDevice([false])
        let transport = SerialTransport(path: path, calls: device.calls)
        try await within(.seconds(5)) {
            try await transport.open()
            let responses = transport.responses
            pty.write(Data("X".utf8))  // something for the first poll to see
            try await within(.seconds(2)) { for await _ in responses {} }
            #expect(device.readCount == SerialTransport.hangupLimit)
            #expect(descriptors(on: path) == 1)  // the pty's own
            let error = await #expect(throws: SerialTransportError.self) {
                try await transport.send(ScannerCommand("MDL"))
            }
            guard case .writeFailed(let reason)? = error else {
                Issue.record("expected .writeFailed, got \(String(describing: error))")
                return
            }
            #expect(reason.contains("went away"), "\(reason)")
        }
        await transport.close()
    }

    /// Only hang-ups in a row count: a read that returns bytes starts the count again (two, a
    /// reply, then three more), and the reply is delivered.
    @Test func aSuccessfulReadResetsTheHangupCount() async throws {
        let pty = try PseudoTerminal()
        defer { pty.close() }
        let device = HangupDevice([false, false, true, false])
        let transport = SerialTransport(path: pty.slavePath, calls: device.calls)
        try await within(.seconds(5)) {
            try await transport.open()
            let responses = transport.responses
            pty.write(Data("MDL,SDS150\r".utf8))
            let delivered = try await within(.seconds(2)) {
                var all: [ScannerResponse] = []
                for await response in responses { all.append(response) }
                return all
            }
            #expect(delivered == [mdlReply])
            #expect(device.readCount == 2 + 1 + SerialTransport.hangupLimit)
        }
        await transport.close()
    }

    @Test func sendBeforeOpen() async throws {
        let transport = SerialTransport(path: "/dev/noctule-no-such-port")
        await #expect(throws: SerialTransportError.notOpen) { try await transport.send(ScannerCommand("MDL")) }
    }

    /// A write the port can't take whole is an error to the caller and is never retried: with the
    /// scanner side not reading, the output queue fills, the next send throws `.writeFailed`
    /// promptly, and only the commands that were accepted reach the scanner.
    @Test func fullOutputFailsTheSendWithoutRetry() async throws {
        let pty = try UndrainedPTY()
        let command = try ScannerCommand("STS")
        try await withTransport(pty.slavePath) { transport in
            try await transport.open()
            var accepted = 0
            var failure: (any Error)?
            for _ in 0..<100_000 {
                do {
                    try await transport.send(command)
                    accepted += 1
                } catch {
                    failure = error
                    break
                }
            }
            guard case .writeFailed? = failure as? SerialTransportError else {
                Issue.record("expected .writeFailed, got \(String(describing: failure))")
                return
            }
            #expect(accepted > 0)
            // Read before the transport closes: a non-blocking last close discards unsent output.
            let wire = pty.drain()
            // Whole commands for every accepted send; at most a cut-off part of the failed one.
            #expect(wire.count >= accepted * 4 && wire.count < (accepted + 1) * 4)
            #expect(wire.prefix(accepted * 4) == Data(String(repeating: "STS\r", count: accepted).utf8))
        }
    }
}
#endif
