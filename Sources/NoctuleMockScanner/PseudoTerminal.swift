// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization

public enum PseudoTerminalError: Error, Equatable {
    case openFailed(String)
}

/// The master side of a pseudo-terminal, standing in for a USB serial scanner: a client opens
/// `slavePath` as it would `/dev/cu.usbmodem…`, and the mock (or a test) talks to it through
/// `write` and `received`.
///
/// - The pty keeps its own descriptor on the slave for its whole life, in raw mode (no echo, no
///   line editing, no CR/LF translation) at 115200 8-N-1. So bytes pass through untouched in
///   both directions before and after a client sets its own settings, `write` before any client
///   opens the port leaves bytes waiting in the port (as a real scanner's half-read reply would),
///   and the master never sees end of file between one client closing and the next opening.
/// - `received` yields what clients write, across any number of clients, and finishes only on
///   `close()`, after yielding whatever a client wrote before it.
/// - `write` hands its bytes to the kernel before it returns when the port has room (a few
///   hundred bytes at least); anything more is written as the client reads. Bytes are never dropped
///   while the pty is open, and `write` never blocks.
/// - `close()` closes both descriptors; the client then reads end of file and its writes fail,
///   as when a USB scanner is unplugged.
///
/// macOS ptys ignore `TIOCEXCL` for a non-root opener (LESSONS.md 2026-11-11), so the slave can't
/// refuse a second client by itself; `SerialTransport` also takes a `flock` on the port.
public final class PseudoTerminal: @unchecked Sendable {
    public let slavePath: String
    private let core: Core

    /// The errno `posix_openpt` reports (not a POSIX code) when it races another thread
    /// opening or closing a pty; trying again succeeds (LESSONS.md 2026-11-11).
    static let ptyRaceErrno: Int32 = -6

    public init() throws {
        let (master, path) = try Self.openMaster()
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        let keeper = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard keeper >= 0 else {
            let code = errno
            Darwin.close(master)
            throw PseudoTerminalError.openFailed(describe("open \(path)", code))
        }
        var line = termios()
        var configured = tcgetattr(keeper, &line) == 0
        if configured {
            cfmakeraw(&line)
            line.c_cflag |= tcflag_t(CLOCAL | CREAD)
            withUnsafeMutableBytes(of: &line.c_cc) {
                $0[Int(VMIN)] = 1
                $0[Int(VTIME)] = 0
            }
            configured = cfsetspeed(&line, 115_200) == 0 && tcsetattr(keeper, TCSANOW, &line) == 0
        }
        var pipeFDs: [Int32] = [-1, -1]
        guard configured, pipe(&pipeFDs) == 0 else {
            let code = errno
            Darwin.close(keeper)
            Darwin.close(master)
            throw PseudoTerminalError.openFailed(describe("pty setup", code))
        }
        for fd in pipeFDs {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        slavePath = path
        core = Core(master: master, keeper: keeper, wakeRead: pipeFDs[0], wakeWrite: pipeFDs[1])
        let core = self.core
        let thread = Thread { core.run() }
        thread.name = "NoctuleMockScanner.PseudoTerminal"
        thread.start()
    }

    deinit { core.close() }

    /// A new master, granted and unlocked, and its slave's path. Retries (at most 100 times,
    /// 1 ms apart) only while `posix_openpt` reports `ptyRaceErrno`; this opens a local pty and
    /// sends nothing anywhere.
    private static func openMaster() throws -> (Int32, String) {
        var attempts = 0
        while true {
            attempts += 1
            let master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0 else {
                let code = errno
                if code == ptyRaceErrno, attempts < 100 {
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }
                throw PseudoTerminalError.openFailed(describe("posix_openpt", code))
            }
            var name = [CChar](repeating: 0, count: 128)
            guard grantpt(master) == 0, unlockpt(master) == 0, ptsname_r(master, &name, name.count) == 0 else {
                let code = errno
                Darwin.close(master)
                throw PseudoTerminalError.openFailed(describe("pty setup", code))
            }
            return (master, String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }

    /// Bytes the client has written, in order. One stream for the pty's life; it finishes on
    /// `close()`, after the bytes a client wrote before the close.
    public var received: AsyncStream<Data> { core.received }

    /// Sends `data` to the client. Does nothing after `close()`.
    public func write(_ data: Data) { core.write(data) }

    /// Closes the pty and returns once its descriptors are closed and `received` has finished.
    /// Idempotent.
    public func close() { core.close() }
}

/// The descriptors and the I/O thread. The thread alone closes the descriptors, under the lock
/// that every other use of them holds, so nothing can touch a closed (or reused) descriptor.
private final class Core: Sendable {
    let master: Int32
    let keeper: Int32
    let wakeRead: Int32
    let wakeWrite: Int32
    let received: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    private struct State {
        var closing = false
        /// Bytes `write` couldn't hand to the kernel yet, written by the thread as room appears.
        var pending: [UInt8] = []
    }

    private let state = Mutex(State())
    private let finished = DispatchSemaphore(value: 0)

    init(master: Int32, keeper: Int32, wakeRead: Int32, wakeWrite: Int32) {
        self.master = master
        self.keeper = keeper
        self.wakeRead = wakeRead
        self.wakeWrite = wakeWrite
        (received, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock { state in
            guard !state.closing else { return }
            if state.pending.isEmpty {
                let count = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
                if count == data.count { return }
                if count < 0, errno != EAGAIN, errno != EINTR { return }
                state.pending.append(contentsOf: data.dropFirst(max(count, 0)))
            } else {
                state.pending.append(contentsOf: data)
            }
            poke()
        }
    }

    func close() {
        state.withLock { state in
            guard !state.closing else { return }
            state.closing = true
            poke()
        }
        finished.wait()
        finished.signal()  // let any other caller of close() through too
    }

    /// Wakes the thread. Call with the lock held and `closing` still false (the pipe is open).
    private func poke() {
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
    }

    /// The I/O thread: reads the master, writes pending bytes, and closes everything on `close()`.
    func run() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        running: while true {
            let wantsOutput = state.withLock { !$0.pending.isEmpty }
            var descriptors = [
                pollfd(fd: master, events: Int16(POLLIN) | (wantsOutput ? Int16(POLLOUT) : 0), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                break running
            }
            if descriptors[1].revents != 0 {
                while read(wakeRead, &buffer, buffer.count) > 0 {}
                if state.withLock({ $0.closing }) { break running }
            }
            let events = descriptors[0].revents
            if events & Int16(POLLOUT) != 0 { writePending() }
            if events & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    continuation.yield(Data(buffer[0..<count]))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    // The keeper holds the slave open, so this shouldn't happen; don't spin if it does.
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        // What a client wrote before the close (say its last `PSI,0`) still counts. The master is
        // non-blocking and the keeper holds the slave open, so this ends with EAGAIN.
        while true {
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { break }
            continuation.yield(Data(buffer[0..<count]))
        }
        state.withLock { state in
            state.closing = true
            state.pending = []
            Darwin.close(master)
            Darwin.close(keeper)
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
        }
        continuation.finish()
        finished.signal()
    }

    private func writePending() {
        state.withLock { state in
            guard !state.pending.isEmpty else { return }
            let count = state.pending.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if count > 0 {
                state.pending.removeFirst(count)
            } else if count < 0, errno != EAGAIN, errno != EINTR {
                state.pending = []
            }
        }
    }
}

private func describe(_ operation: String, _ code: Int32) -> String {
    "\(operation): \(String(cString: strerror(code))) (errno \(code))"
}
