// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization

public enum StationLockError: Error, Equatable {
    /// Another open file description (this process or another) holds the lock; `pid` is the
    /// holder's pid as written in the lock file, nil if unreadable.
    case inUse(pid: Int32?)
    case unavailable(String)
}

/// A per-station lock shared by the app and `noctule log`: a non-blocking `flock` on
/// `Stations/<uuid>/runner.lock` that holds the holder's pid. `flock` locks belong to the open
/// file description and die with the process, so a crash never leaves a stale lock.
public final class StationLock: Sendable {
    private let descriptor: Mutex<Int32?>

    private init(descriptor: Int32) { self.descriptor = Mutex(descriptor) }

    public static func lockURL(stationID: UUID, settingsDirectory: URL) -> URL {
        settingsDirectory.appendingPathComponent("Stations", isDirectory: true)
            .appendingPathComponent(stationID.uuidString, isDirectory: true)
            .appendingPathComponent("runner.lock")
    }

    public static func acquire(stationID: UUID, settingsDirectory: URL) throws(StationLockError) -> StationLock {
        let url = lockURL(stationID: stationID, settingsDirectory: settingsDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw .unavailable("can't create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        // No O_TRUNC: the holder's pid must stay readable until we own the lock.
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw .unavailable("can't open \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let pid = readPID(fd)
            close(fd)
            if code == EWOULDBLOCK { throw .inUse(pid: pid) }
            throw .unavailable("can't lock \(url.path): \(String(cString: strerror(code)))")
        }
        let text = "\(getpid())\n"
        if ftruncate(fd, 0) != 0 || pwrite(fd, text, text.utf8.count, 0) < 0 {
            let code = errno
            close(fd)  // also drops the lock
            throw .unavailable("can't write \(url.path): \(String(cString: strerror(code)))")
        }
        return StationLock(descriptor: fd)
    }

    private static func readPID(_ fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        let text = String(decoding: buffer[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(text), pid > 0 else { return nil }
        return pid
    }

    /// Releases the lock. Idempotent. Closing the descriptor drops the flock.
    public func release() {
        let fd = descriptor.withLock { state -> Int32? in
            defer { state = nil }
            return state
        }
        if let fd { close(fd) }
    }

    deinit { release() }
}
