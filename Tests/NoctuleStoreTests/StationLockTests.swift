// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing
@testable import NoctuleStore

private final class Output: Sendable {
    private let value = Mutex("")
    var text: String { value.withLock { $0 } }
    func append(_ s: String) { value.withLock { $0 += s } }
}

/// Serialized (LESSONS.md 2026-11-12): a `flock` released by `close()` can linger for the moment a
/// `Process()` spawned on another thread holds its copy of the descriptor, so these tests don't run
/// beside each other, where one of them is spawning a child that holds a lock.
@Suite(.serialized) struct StationLockTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "noctule-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func secondAcquireIsInUse() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let first = try StationLock.acquire(stationID: id, settingsDirectory: dir)
        defer { first.release() }
        #expect(throws: StationLockError.inUse(pid: getpid())) {
            _ = try StationLock.acquire(stationID: id, settingsDirectory: dir)
        }
        // A different station is independent.
        let other = try StationLock.acquire(stationID: UUID(), settingsDirectory: dir)
        other.release()
    }

    @Test func releaseFreesIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let first = try StationLock.acquire(stationID: id, settingsDirectory: dir)
        first.release()
        first.release()  // idempotent
        let second = try StationLock.acquire(stationID: id, settingsDirectory: dir)
        second.release()
    }

    @Test func deinitReleases() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        do { _ = try StationLock.acquire(stationID: id, settingsDirectory: dir) }
        let again = try StationLock.acquire(stationID: id, settingsDirectory: dir)
        again.release()
    }

    @Test func lockDiesWithProcess() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let folder = dir.appending(path: "Stations").appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "runner.lock")

        // A child takes the same flock (perl ships with macOS), prints "locked", and sleeps (bounded).
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-e", #"use Fcntl ":flock"; open(F, ">>", $ARGV[0]) or die; flock(F, LOCK_EX|LOCK_NB) or die; $|=1; print "locked\n"; sleep 60"#,
            file.path,
        ]
        let pipe = Pipe()
        child.standardOutput = pipe
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        // Wait (bounded) for the child to print "locked"; probing with acquire would briefly
        // hold the flock and could make the child's LOCK_NB fail.
        let output = Output()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData  // off the cooperative pool: a readability handler
            if data.isEmpty { handle.readabilityHandler = nil; return }
            output.append(String(decoding: data, as: UTF8.self))
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        for _ in 0..<200 where !output.text.contains("locked") && child.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(output.text.contains("locked"))
        do {
            _ = try StationLock.acquire(stationID: id, settingsDirectory: dir)
            Issue.record("expected inUse while the child holds the lock")
        } catch {
            guard case .inUse = error else { Issue.record("wrong error \(error)"); return }
        }

        kill(child.processIdentifier, SIGKILL)
        for _ in 0..<200 where child.isRunning { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!child.isRunning)
        let lock = try StationLock.acquire(stationID: id, settingsDirectory: dir)
        lock.release()
    }

    @Test func unwritableDirectoryIsUnavailable() throws {
        let dir = try tempDir()
        defer {
            chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        chmod(dir.path, 0o500)
        do {
            _ = try StationLock.acquire(stationID: UUID(), settingsDirectory: dir)
            Issue.record("expected unavailable")
        } catch {
            guard case .unavailable = error else { Issue.record("wrong error \(error)"); return }
        }
    }
}
