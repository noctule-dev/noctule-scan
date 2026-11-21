// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleMockScanner
@testable import NoctuleKit

// Crash lease and cross-process lock (Plan 3 Task 5). Every file store here lives in a fresh
// temporary directory; none touches the real `FileRTSPCooldownStore.defaultURL`.

private struct TimedOut: Error {}

/// Runs `body`, failing with `TimedOut` after `limit` so no test can hang.
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

private func temporaryStoreURL() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-lease-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("rtsp-cooldown.json")
}

private func removeStoreDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// The pid of a child that has already exited (and been reaped). Pid reuse before the test
/// reads it is astronomically unlikely.
private func exitedPID() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

/// A long-running child standing in for "another live process". Always `stop()` it.
private final class LiveChild: @unchecked Sendable {
    let process = Process()
    init() throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
    }
    var pid: Int32 { process.processIdentifier }
    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

/// The store file's JSON entry for `host`, in the new format.
private func entry(_ url: URL, _ host: String) throws -> [String: Any]? {
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return json?[host] as? [String: Any]
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

// MARK: Brief tests

@Test func deadLeaseForcesCooldown() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let deadPID = try exitedPID()
    let store = FileRTSPCooldownStore(url: url)
    // A crashed process: its last recorded close is long past, and its lease never cleared.
    await store.recordClosed(host: "127.0.0.1", at: Date(timeIntervalSinceNow: -3_600))
    await store.recordOpened(host: "127.0.0.1", at: Date(timeIntervalSinceNow: -60), pid: deadPID)

    let server = FakeRTSPServer()
    let port = try await server.start()
    let cooldown: Duration = .seconds(30)
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: cooldown, cooldownStore: FileRTSPCooldownStore(url: url),
                            closeLinger: .zero)
    let before = Date()
    do {
        try await within(.seconds(5)) {
            do {
                try await client.connect()
                Issue.record("connect with a dead lease succeeded")
            } catch RTSPError.cooldown(let remaining) {
                #expect(remaining >= cooldown - .seconds(1), "\(remaining)")
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.acceptedConnections == 0)
        }
    } catch {
        await server.stop()
        throw error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    // The discovery was persisted: close = discovery time, lease gone.
    let reread = await FileRTSPCooldownStore(url: url).lastClosed(host: "127.0.0.1")
    #expect(reread.map { $0 >= before.addingTimeInterval(-1) && $0 <= Date() } == true)
    let saved = try entry(url, "127.0.0.1")
    #expect(saved?["lease"] == nil)
    #expect(saved?["lastClosed"] is String)
}

@Test func liveLeaseFromOtherProcessBlocks() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let other = try LiveChild(); defer { other.stop() }
    let store = FileRTSPCooldownStore(url: url)
    await store.recordOpened(host: "127.0.0.1", at: Date(timeIntervalSinceNow: -600), pid: other.pid)

    let server = FakeRTSPServer()
    let port = try await server.start()
    let cooldown: Duration = .seconds(30)
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: cooldown, cooldownStore: FileRTSPCooldownStore(url: url),
                            closeLinger: .zero)
    do {
        try await within(.seconds(5)) {
            do {
                try await client.connect()
                Issue.record("connect while another live process holds the lease succeeded")
            } catch RTSPError.cooldown(let remaining) {
                #expect(remaining >= cooldown - .seconds(1), "\(remaining)")
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.acceptedConnections == 0)
        }
    } catch {
        await server.stop()
        throw error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    // The other process's lease is left alone.
    let lease = try entry(url, "127.0.0.1")?["lease"] as? [String: Any]
    #expect((lease?["pid"] as? NSNumber)?.int32Value == other.pid)
}

@Test func concurrentWritersDontLoseUpdates() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let a = FileRTSPCooldownStore(url: url), b = FileRTSPCooldownStore(url: url)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let writes = 50
    try await within(.seconds(20)) {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<writes {
                    await a.recordClosed(host: "192.0.2.1", at: start.addingTimeInterval(Double(i)))
                }
            }
            group.addTask {
                for i in 0..<writes {
                    await b.recordClosed(host: "192.0.2.2", at: start.addingTimeInterval(Double(i)))
                }
            }
        }
    }
    let final = start.addingTimeInterval(Double(writes - 1))
    let reader = FileRTSPCooldownStore(url: url)
    #expect(await reader.lastClosed(host: "192.0.2.1") == final)
    #expect(await reader.lastClosed(host: "192.0.2.2") == final)
    #expect(await a.lastWriteError == nil)
    #expect(await b.lastWriteError == nil)
}

@Test func writeFailureIsSurfaced() async throws {
    let url = try temporaryStoreURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        removeStoreDirectory(url)
    }
    let store = FileRTSPCooldownStore(url: url)
    await store.recordClosed(host: "192.0.2.1", at: Date())
    #expect(await store.lastWriteError != nil)
    await store.recordOpened(host: "192.0.2.1", at: Date(), pid: getpid())
    #expect(await store.lastWriteError != nil)
    // The next successful write clears it.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    await store.recordClosed(host: "192.0.2.1", at: Date())
    #expect(await store.lastWriteError == nil)
}

// MARK: Lease semantics

@Test func clientRecordsLeaseOnConnectAndClearsItOnClose() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let server = FakeRTSPServer()
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .milliseconds(200), cooldownStore: FileRTSPCooldownStore(url: url),
                            closeLinger: .zero)
    do {
        try await within(.seconds(5)) {
            try await client.connect()
            let lease = try entry(url, "127.0.0.1")?["lease"] as? [String: Any]
            #expect((lease?["pid"] as? NSNumber)?.int32Value == getpid())
            #expect(lease?["openedAt"] is String)
            _ = try await client.describe()
            await client.close()
            let saved = try entry(url, "127.0.0.1")
            #expect(saved?["lease"] == nil)
            #expect(saved?["lastClosed"] is String)
        }
    } catch {
        _ = try? await within(.seconds(5)) { await client.close() }
        await server.stop()
        throw error
    }
    await server.stop()
}

@Test func ownLeaseLeavesLastClosedUnchanged() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let closed = Date(timeIntervalSince1970: 1_800_000_000)
    for store in [FileRTSPCooldownStore(url: url) as any RTSPCooldownStore, InMemoryRTSPCooldownStore()] {
        await store.recordClosed(host: "192.0.2.1", at: closed)
        await store.recordOpened(host: "192.0.2.1", at: Date(), pid: getpid())
        #expect(await store.lastClosed(host: "192.0.2.1") == closed)
        await store.recordOpened(host: "192.0.2.9", at: Date(), pid: getpid())
        #expect(await store.lastClosed(host: "192.0.2.9") == nil)
    }
}

@Test func inMemoryLeaseSemantics() async throws {
    let store = InMemoryRTSPCooldownStore()
    let old = Date(timeIntervalSince1970: 1_000)
    // Dead owner: forced to "closed at discovery", persisted (a second read returns the same time).
    let deadPID = try exitedPID()
    await store.recordClosed(host: "192.0.2.1", at: old)
    await store.recordOpened(host: "192.0.2.1", at: Date(), pid: deadPID)
    let before = Date()
    let discovered = await store.lastClosed(host: "192.0.2.1")
    #expect(discovered.map { $0 >= before } == true)
    #expect(await store.lastClosed(host: "192.0.2.1") == discovered)
    // Live owner elsewhere: "open right now".
    let other = try LiveChild(); defer { other.stop() }
    await store.recordClosed(host: "192.0.2.2", at: old)
    await store.recordOpened(host: "192.0.2.2", at: Date(), pid: other.pid)
    let first = await store.lastClosed(host: "192.0.2.2")
    #expect(first.map { $0 >= before } == true)
    // This process's close leaves another process's lease alone (final review I1)...
    await store.recordClosed(host: "192.0.2.2", at: Date(timeIntervalSince1970: 500))
    #expect((await store.lastClosed(host: "192.0.2.2")).map { $0 >= before } == true)
    // ...but clears its own, even with an older time than the stored one.
    await store.recordClosed(host: "192.0.2.4", at: old)
    await store.recordOpened(host: "192.0.2.4", at: Date(), pid: getpid())
    await store.recordClosed(host: "192.0.2.4", at: Date(timeIntervalSince1970: 500))
    #expect(await store.lastClosed(host: "192.0.2.4") == old)
    other.stop()
    #expect((await store.lastClosed(host: "192.0.2.4")) == old)  // no lease left to resolve
    // An invalid pid (never kill(0, 0): that's the process group) counts as dead.
    await store.recordOpened(host: "192.0.2.3", at: Date(), pid: 0)
    #expect((await store.lastClosed(host: "192.0.2.3")).map { $0 >= before } == true)
    #expect(await store.lastWriteError == nil)
}

@Test func fileStoreRecordClosedClearsOnlyItsOwnLease() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let other = try LiveChild(); defer { other.stop() }
    let store = FileRTSPCooldownStore(url: url)
    let closed = Date(timeIntervalSince1970: 1_700_000_000)  // in the past
    // Another process's lease survives this process's close (final review I1): when it is
    // SIGKILLed later, the cooldown must count from its death, not from our close.
    await store.recordClosed(host: "192.0.2.1", at: closed)
    await store.recordOpened(host: "192.0.2.1", at: Date(), pid: other.pid)
    await store.recordClosed(host: "192.0.2.1", at: closed.addingTimeInterval(5))
    let lease = try entry(url, "192.0.2.1")?["lease"] as? [String: Any]
    #expect((lease?["pid"] as? NSNumber)?.int32Value == other.pid)
    #expect((await store.lastClosed(host: "192.0.2.1")).map { $0 > closed } == true)
    // Our own lease: an older close time still clears it, and keeps the later stored close.
    await store.recordClosed(host: "192.0.2.2", at: closed)
    await store.recordOpened(host: "192.0.2.2", at: Date(), pid: getpid())
    await store.recordClosed(host: "192.0.2.2", at: closed.addingTimeInterval(-10))
    #expect(await FileRTSPCooldownStore(url: url).lastClosed(host: "192.0.2.2") == closed)
    #expect(try entry(url, "192.0.2.2")?["lease"] == nil)
}

// MARK: Atomic claim (final review I1)

/// Two stores on one file, each claiming for a different live process (this one, and a child
/// standing in for another `noctule`), race for the same hosts: exactly one wins each host,
/// and the other is told to wait the full cooldown.
@Test func claimIsAtomicAcrossStores() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let other = try LiveChild(); defer { other.stop() }
    let a = FileRTSPCooldownStore(url: url), b = FileRTSPCooldownStore(url: url)
    let cooldown: Duration = .seconds(30)
    let hosts = (1...20).map { "192.0.2.\($0)" }
    let otherPID = other.pid, ownPID = getpid()
    let results = try await within(.seconds(20)) {
        await withTaskGroup(of: (String, Int32, RTSPCooldownClaim).self) { group in
            for host in hosts {
                group.addTask { (host, otherPID, await a.claim(hosts: [host], pid: otherPID, cooldown: cooldown)) }
                group.addTask { (host, ownPID, await b.claim(hosts: [host], pid: ownPID, cooldown: cooldown)) }
            }
            var all: [(String, Int32, RTSPCooldownClaim)] = []
            for await result in group { all.append(result) }
            return all
        }
    }
    for host in hosts {
        let claims = results.filter { $0.0 == host }
        let winners = claims.filter { $0.2 == .claimed }
        #expect(winners.count == 1, "\(host): \(claims)")
        for loser in claims where loser.2 != .claimed {
            guard case .wait(let remaining) = loser.2 else {
                Issue.record("\(host): \(loser.2)"); continue
            }
            #expect(remaining >= cooldown - .seconds(1), "\(remaining)")
        }
        let lease = try entry(url, host)?["lease"] as? [String: Any]
        #expect((lease?["pid"] as? NSNumber)?.int32Value == winners.first?.1, "\(host)")
        #expect(lease?["processStart"] is String)
    }
}

@Test func claimHonoursTheCooldownAndLeasesEveryHost() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    for store in [FileRTSPCooldownStore(url: url) as any RTSPCooldownStore, InMemoryRTSPCooldownStore()] {
        await store.recordClosed(host: "192.0.2.1", at: Date(timeIntervalSinceNow: -10))
        // Any host still cooling down refuses the whole claim, and nothing is leased.
        let refused = await store.claim(hosts: ["192.0.2.1", "192.0.2.2"], pid: getpid(), cooldown: .seconds(30))
        guard case .wait(let remaining) = refused else { Issue.record("\(refused)"); continue }
        #expect(remaining > .seconds(19) && remaining <= .seconds(20), "\(remaining)")
        #expect(await store.claim(hosts: ["192.0.2.1"], pid: getpid(), cooldown: .seconds(5)) == .claimed)
        #expect(await store.claim(hosts: ["192.0.2.3", "scanner.example.test"], pid: getpid(), cooldown: .seconds(30)) == .claimed)
        // A lease is held by our pid on every claimed host; closing clears them all.
        await store.recordClosed(host: "192.0.2.3", at: Date())
        await store.recordClosed(host: "scanner.example.test", at: Date())
        #expect(await store.lastClosed(host: "192.0.2.3") != nil)
    }
    for host in ["192.0.2.1"] {
        let lease = try entry(url, host)?["lease"] as? [String: Any]
        #expect((lease?["pid"] as? NSNumber)?.int32Value == getpid())
    }
    #expect(try entry(url, "192.0.2.3")?["lease"] == nil)
    #expect(try entry(url, "scanner.example.test")?["lease"] == nil)
}

@Test func claimBlocksOnAnotherLiveProcessLease() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let other = try LiveChild(); defer { other.stop() }
    for store in [FileRTSPCooldownStore(url: url) as any RTSPCooldownStore, InMemoryRTSPCooldownStore()] {
        #expect(await store.claim(hosts: ["192.0.2.7"], pid: other.pid, cooldown: .seconds(30)) == .claimed)
        let second = await store.claim(hosts: ["192.0.2.7"], pid: getpid(), cooldown: .seconds(30))
        guard case .wait(let remaining) = second else { Issue.record("\(second)"); continue }
        #expect(remaining >= .seconds(29), "\(remaining)")
        // Our own lease never blocks our own claim (in-process single-flight governs that).
        #expect(await store.claim(hosts: ["192.0.2.8"], pid: getpid(), cooldown: .seconds(30)) == .claimed)
        #expect(await store.claim(hosts: ["192.0.2.8"], pid: getpid(), cooldown: .seconds(30)) == .claimed)
    }
}

/// A lock file that can't be opened (here a directory in its place) must not mean "unlocked":
/// `claim` refuses, `connect()` opens no socket, and the failure is surfaced.
@Test func lockFailureRefusesToClaim() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    try FileManager.default.createDirectory(atPath: url.path + ".lock", withIntermediateDirectories: false)
    let store = FileRTSPCooldownStore(url: url)
    let claim = await store.claim(hosts: ["127.0.0.1"], pid: getpid(), cooldown: .seconds(30))
    guard case .unavailable(let reason) = claim else {
        Issue.record("claim without a lock: \(claim)"); return
    }
    #expect(reason.contains(".lock"), "\(reason)")
    #expect(!FileManager.default.fileExists(atPath: url.path))  // no lease written

    let server = FakeRTSPServer()
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .seconds(30), cooldownStore: store, closeLinger: .zero)
    do {
        try await within(.seconds(5)) {
            do {
                try await client.connect()
                Issue.record("connect without a cooldown lock succeeded")
            } catch RTSPError.cooldownStoreUnavailable(let why) {
                #expect(why.contains(".lock"), "\(why)")
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.acceptedConnections == 0)
        }
    } catch {
        await server.stop()
        throw error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()

    // A close is still recorded (more cooldown is the safe side), and the lock failure is reported.
    let closedAt = Date(timeIntervalSince1970: 1_800_000_000)  // whole seconds: the file keeps ms
    await store.recordClosed(host: "192.0.2.1", at: closedAt)
    #expect(await store.lastClosed(host: "192.0.2.1") == closedAt)
    #expect((await store.lastWriteError)?.contains(".lock") == true)
}

/// A store whose `claim` always says wait, while `closeHistory` says nothing: `connect()` must
/// go by `claim` (the atomic step), not by a separate read.
private actor ClaimRefusingStore: RTSPCooldownStore {
    private(set) var claims: [[String]] = []
    func claim(hosts: [String], pid: Int32, policy: RTSPCooldownPolicy) -> RTSPCooldownClaim {
        claims.append(hosts)
        return .wait(.seconds(7))
    }
    func closeHistory(host: String) -> RTSPCloseHistory? { nil }
    func recordClosed(host: String, at: Date, clean: Bool) {}
    func recordOpened(host: String, at: Date, pid: Int32) {}
    func clear(host: String) {}
    var lastWriteError: String? { nil }
}

@Test func connectGoesThroughClaim() async throws {
    let store = ClaimRefusingStore()
    let server = FakeRTSPServer()
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: .seconds(30), cooldownStore: store, closeLinger: .zero)
    do {
        try await within(.seconds(5)) {
            do {
                try await client.connect()
                Issue.record("connect ignored the claim")
            } catch RTSPError.cooldown(let remaining) {
                #expect(remaining == .seconds(7))
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.acceptedConnections == 0)
        }
    } catch {
        await server.stop()
        throw error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
    #expect(await store.claims == [["127.0.0.1"]])
}

@Test func legacyFlatFormatIsReadAndUpgraded() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let legacy = #"{"192.0.2.1":"2027-01-15T08:00:00.250Z","192.0.2.2":"2027-01-15T09:00:00Z"}"#
    try Data(legacy.utf8).write(to: url)
    let store = FileRTSPCooldownStore(url: url)
    let expected = Date(timeIntervalSince1970: 1_800_000_000.25)
    #expect(await store.lastClosed(host: "192.0.2.1") == expected)
    #expect(await store.lastClosed(host: "192.0.2.2") != nil)
    // A write upgrades the whole file to the new format and keeps every host.
    await store.recordOpened(host: "192.0.2.1", at: Date(), pid: getpid())
    #expect(try entry(url, "192.0.2.1")?["lastClosed"] as? String == "2027-01-15T08:00:00.250Z")
    #expect(try entry(url, "192.0.2.1")?["lease"] is [String: Any])
    #expect(try entry(url, "192.0.2.2")?["lastClosed"] is String)
    #expect(await FileRTSPCooldownStore(url: url).lastClosed(host: "192.0.2.2") != nil)
}

@Test func fileStoreUsesASiblingLockFile() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    await FileRTSPCooldownStore(url: url).recordClosed(host: "192.0.2.1", at: Date())
    #expect(FileManager.default.fileExists(atPath: url.path + ".lock"))
}

// MARK: Pid reuse and lease age (controller ruling)

/// Tries `connect()` against a fresh fake with `store`; expects `.cooldown` of at least
/// `cooldown - 1 s` and no TCP connection to the fake.
private func expectConnectBlocked(store: FileRTSPCooldownStore, cooldown: Duration = .seconds(30)) async throws {
    let server = FakeRTSPServer()
    let port = try await server.start()
    let client = RTSPClient(host: "127.0.0.1", port: port, requestTimeout: .seconds(1),
                            reconnectCooldown: cooldown, cooldownStore: store, closeLinger: .zero)
    do {
        try await within(.seconds(5)) {
            do {
                try await client.connect()
                Issue.record("connect succeeded")
            } catch RTSPError.cooldown(let remaining) {
                #expect(remaining >= cooldown - .seconds(1), "\(remaining)")
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await server.acceptedConnections == 0)
        }
    } catch {
        await server.stop()
        throw error
    }
    _ = try? await within(.seconds(5)) { await client.close() }
    await server.stop()
}

/// Dead-lease handling is visible as: the lease is gone from the file, and a second read
/// returns the same discovery time (a live lease would keep returning a newer "now").
private func expectResolvedAsDead(_ url: URL, host: String = "127.0.0.1", since before: Date) async throws {
    #expect(try entry(url, host)?["lease"] == nil)
    let first = await FileRTSPCooldownStore(url: url).lastClosed(host: host)
    #expect(first.map { $0 >= before.addingTimeInterval(-1) && $0 <= Date() } == true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await FileRTSPCooldownStore(url: url).lastClosed(host: host) == first)
}

@Test func reusedPidLeaseIsDead() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    // The pid is alive, but its start time isn't the lease owner's: the pid was reused.
    let other = try LiveChild(); defer { other.stop() }
    let actualStart = try #require(RTSPCooldownEntry.processStartTime(other.pid))
    let store = FileRTSPCooldownStore(url: url)
    await store.recordClosed(host: "127.0.0.1", at: Date(timeIntervalSinceNow: -3_600))
    await store.recordOpened(host: "127.0.0.1", at: Date(timeIntervalSinceNow: -60), pid: other.pid,
                             processStart: actualStart.addingTimeInterval(-3_600))
    let before = Date()
    try await expectConnectBlocked(store: FileRTSPCooldownStore(url: url))
    try await expectResolvedAsDead(url, since: before)
}

@Test func leaseOlderThanMaxAgeWithoutStartTimeIsDead() async throws {
    let other = try LiveChild(); defer { other.stop() }
    // 1. The owner's start time can't be read (as on iOS): age decides.
    do {
        let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
        let store = FileRTSPCooldownStore(url: url, leaseMaxAge: 60, processStartLookup: { _ in nil })
        await store.recordOpened(host: "192.0.2.1", at: Date(timeIntervalSinceNow: -120), pid: other.pid)
        await store.recordOpened(host: "192.0.2.2", at: Date(timeIntervalSinceNow: -10), pid: other.pid)
        let before = Date()
        _ = await store.lastClosed(host: "192.0.2.1")
        try await expectResolvedAsDead(url, host: "192.0.2.1", since: before)
        // Younger than the max age: still live, lease kept.
        #expect((await store.lastClosed(host: "192.0.2.2")).map { $0 >= before } == true)
        #expect(try entry(url, "192.0.2.2")?["lease"] is [String: Any])
    }
    // 2. A lease from older code has no processStart: the same rule, with the real lookup.
    do {
        let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
        let store = FileRTSPCooldownStore(url: url, leaseMaxAge: 60)
        await store.recordOpened(host: "192.0.2.1", at: Date(timeIntervalSinceNow: -120), pid: other.pid,
                                 processStart: nil)
        await store.recordOpened(host: "192.0.2.2", at: Date(timeIntervalSinceNow: -10), pid: other.pid,
                                 processStart: nil)
        let before = Date()
        _ = await store.lastClosed(host: "192.0.2.1")
        try await expectResolvedAsDead(url, host: "192.0.2.1", since: before)
        #expect((await store.lastClosed(host: "192.0.2.2")).map { $0 >= before } == true)
        #expect(try entry(url, "192.0.2.2")?["lease"] is [String: Any])
    }
    // 3. The in-memory store follows the same rule.
    let memory = InMemoryRTSPCooldownStore(leaseMaxAge: 60, processStartLookup: { _ in nil })
    await memory.recordOpened(host: "192.0.2.1", at: Date(timeIntervalSinceNow: -120), pid: other.pid)
    let first = await memory.lastClosed(host: "192.0.2.1")
    try await Task.sleep(for: .milliseconds(20))
    #expect(await memory.lastClosed(host: "192.0.2.1") == first)  // resolved once, as dead
}

@Test func liveLeaseWithMatchingStartBlocks() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let other = try LiveChild(); defer { other.stop() }
    let actualStart = try #require(RTSPCooldownEntry.processStartTime(other.pid))
    // Older than the max age, but the start time matches (within 1 s): start time wins, live.
    let store = FileRTSPCooldownStore(url: url, leaseMaxAge: 60)
    await store.recordOpened(host: "127.0.0.1", at: Date(timeIntervalSinceNow: -3_600), pid: other.pid,
                             processStart: actualStart.addingTimeInterval(0.5))
    try await expectConnectBlocked(store: FileRTSPCooldownStore(url: url, leaseMaxAge: 60))
    let lease = try entry(url, "127.0.0.1")?["lease"] as? [String: Any]
    #expect((lease?["pid"] as? NSNumber)?.int32Value == other.pid)
    #expect(lease?["processStart"] is String)
    // A lease recorded through the protocol stores the owner's real start time.
    let auto = FileRTSPCooldownStore(url: url)
    await auto.recordOpened(host: "192.0.2.5", at: Date(), pid: getpid())
    #expect(try entry(url, "192.0.2.5").flatMap { $0["lease"] as? [String: Any] }?["processStart"] is String)
}

// MARK: Cooldown keys (final review minor 1)

@Test func cooldownKeysMatchTheClient() async {
    #expect(await RTSPClient.cooldownKeys(for: "192.0.2.1") == ["192.0.2.1"])
    let local = await RTSPClient.cooldownKeys(for: "localhost")
    #expect(local.contains("localhost"), "\(local)")
    #expect(local.contains("127.0.0.1"), "\(local)")
}

// MARK: Clean closes and the cooldown policy (Plan 5 Task 1)

/// Both stores, the file one in a fresh temporary directory (removed by the caller via `url`).
private func bothStores(_ url: URL) -> [any RTSPCooldownStore] {
    [InMemoryRTSPCooldownStore(), FileRTSPCooldownStore(url: url)]
}

@Test func cooldownPolicyClampsAndChooses() {
    #expect(RTSPCooldownPolicy.standard == RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(120)))
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(10))
    #expect(policy.required(afterCleanClose: true) == .seconds(10))
    #expect(policy.required(afterCleanClose: false) == .seconds(120))
    // The clean value is clamped to 0…full, and full is never negative.
    #expect(RTSPCooldownPolicy(full: .seconds(20), afterCleanClose: .seconds(300)).afterCleanClose == .seconds(20))
    #expect(RTSPCooldownPolicy(full: .seconds(20), afterCleanClose: .seconds(-5)).afterCleanClose == .zero)
    #expect(RTSPCooldownPolicy(full: .seconds(-1), afterCleanClose: .seconds(5)) == .symmetric(.zero))
    #expect(RTSPCooldownPolicy(afterCleanClose: .zero).full == .seconds(120))
    #expect(RTSPCooldownPolicy.symmetric(.seconds(7)).required(afterCleanClose: true) == .seconds(7))
}

@Test func entryKeepsTheLaterCloseAndItsFlag() {
    let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
    var entry = RTSPCooldownEntry()
    #expect(entry.lastCloseClean == false)
    entry.noteClosed(at: t1, clean: true)
    #expect(entry.lastClosed == t1 && entry.lastCloseClean)
    entry.noteClosed(at: t0, clean: false)  // older: ignored, flag and all
    #expect(entry.lastClosed == t1 && entry.lastCloseClean)
    entry.noteClosed(at: t1.addingTimeInterval(1), clean: false)
    #expect(entry.lastCloseClean == false)
    entry.noteClosed(at: t1.addingTimeInterval(2), clean: true)
    #expect(entry.lastCloseClean)
}

@Test func entryEqualTimesUncleanWins() {
    let t = Date(timeIntervalSince1970: 1_000)
    var a = RTSPCooldownEntry()
    a.noteClosed(at: t, clean: true)
    a.noteClosed(at: t, clean: false)
    #expect(a.lastClosed == t && a.lastCloseClean == false)
    var b = RTSPCooldownEntry()
    b.noteClosed(at: t, clean: false)
    b.noteClosed(at: t, clean: true)
    #expect(b.lastClosed == t && b.lastCloseClean == false)
}

@Test func storesKeepTheLatestCloseAndItsCleanFlag() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    // Whole seconds: the file keeps milliseconds.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000), t1 = t0.addingTimeInterval(10)
    for store in bothStores(url) {
        let host = "192.0.2.\(store is FileRTSPCooldownStore ? 1 : 2)"
        await store.recordClosed(host: host, at: t1, clean: true)
        #expect(await store.lastClose(host: host) == RTSPCloseRecord(at: t1, clean: true))
        await store.recordClosed(host: host, at: t0, clean: false)
        #expect(await store.lastClose(host: host) == RTSPCloseRecord(at: t1, clean: true))
        await store.recordClosed(host: host, at: t1, clean: false)  // equal time: unclean wins
        #expect(await store.lastClose(host: host) == RTSPCloseRecord(at: t1, clean: false))
        await store.recordClosed(host: host, at: t1, clean: true)
        #expect(await store.lastClose(host: host) == RTSPCloseRecord(at: t1, clean: false))
        let t2 = t1.addingTimeInterval(5)
        await store.recordClosed(host: host, at: t2, clean: true)
        #expect(await store.lastClose(host: host) == RTSPCloseRecord(at: t2, clean: true))
        // The old two-argument form records an unclean close.
        await store.recordClosed(host: host, at: t2.addingTimeInterval(1))
        #expect(await store.lastClose(host: host) == RTSPCloseRecord(at: t2.addingTimeInterval(1), clean: false))
        #expect(await store.lastClosed(host: host) == t2.addingTimeInterval(1))
    }
}

@Test func fileStoreRoundTripsTheCleanFlag() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    await FileRTSPCooldownStore(url: url).recordClosed(host: "192.0.2.1", at: t, clean: true)
    await FileRTSPCooldownStore(url: url).recordClosed(host: "192.0.2.2", at: t, clean: false)
    #expect(try entry(url, "192.0.2.1")?["lastCloseClean"] as? Bool == true)
    #expect(try (entry(url, "192.0.2.2")?["lastCloseClean"] as? Bool ?? false) == false)
    #expect(await FileRTSPCooldownStore(url: url).lastClose(host: "192.0.2.1") == RTSPCloseRecord(at: t, clean: true))
    #expect(await FileRTSPCooldownStore(url: url).lastClose(host: "192.0.2.2") == RTSPCloseRecord(at: t, clean: false))
    // A lease write keeps the flag.
    await FileRTSPCooldownStore(url: url).recordOpened(host: "192.0.2.1", at: Date(), pid: getpid())
    #expect(try entry(url, "192.0.2.1")?["lastCloseClean"] as? Bool == true)
}

@Test func legacyAndFlaglessRecordsReadAsUnclean() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let json = #"{"192.0.2.1":"2023-11-14T22:13:20Z","192.0.2.2":{"lastClosed":"2023-11-14T22:13:20Z"},"#
        + #""192.0.2.3":{"lastClosed":"2023-11-14T22:13:20Z","lastCloseClean":false}}"#
    try Data(json.utf8).write(to: url)
    let store = FileRTSPCooldownStore(url: url)
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    for host in ["192.0.2.1", "192.0.2.2", "192.0.2.3"] {
        #expect(await store.lastClose(host: host) == RTSPCloseRecord(at: t, clean: false), "\(host)")
    }
}

@Test func deadLeaseIsAnUncleanClose() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let deadPID = try exitedPID()
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    for store in bothStores(url) {
        let host = "192.0.2.\(store is FileRTSPCooldownStore ? 1 : 2)"
        // A clean close long ago, then a crash: the dead lease is a close at discovery, unclean.
        await store.recordClosed(host: host, at: Date(timeIntervalSinceNow: -3_600), clean: true)
        await store.recordOpened(host: host, at: Date(timeIntervalSinceNow: -60), pid: deadPID)
        let before = Date()
        let record = try #require(await store.lastClose(host: host))
        #expect(record.at >= before && record.clean == false)
        let claim = await store.claim(hosts: [host], pid: getpid(), policy: policy)
        guard case .wait(let remaining) = claim else { Issue.record("\(claim)"); continue }
        #expect(remaining > .seconds(110), "\(remaining)")
    }
    // The same via claim alone (the lease resolved inside the claim's lock).
    for store in bothStores(url) {
        let host = "192.0.2.\(store is FileRTSPCooldownStore ? 3 : 4)"
        await store.recordClosed(host: host, at: Date(timeIntervalSinceNow: -3_600), clean: true)
        await store.recordOpened(host: host, at: Date(timeIntervalSinceNow: -60), pid: deadPID)
        let claim = await store.claim(hosts: [host], pid: getpid(), policy: policy)
        guard case .wait(let remaining) = claim else { Issue.record("\(claim)"); continue }
        #expect(remaining > .seconds(110), "\(remaining)")
    }
}

@Test func anotherLiveLeaseWaitsTheFullCooldown() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let other = try LiveChild(); defer { other.stop() }
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    for store in bothStores(url) {
        let host = "192.0.2.\(store is FileRTSPCooldownStore ? 1 : 2)"
        await store.recordClosed(host: host, at: Date(timeIntervalSinceNow: -3_600), clean: true)
        #expect(await store.claim(hosts: [host], pid: other.pid, policy: policy) == .claimed)
        let record = try #require(await store.lastClose(host: host))
        #expect(record.clean == false)
        let claim = await store.claim(hosts: [host], pid: getpid(), policy: policy)
        guard case .wait(let remaining) = claim else { Issue.record("\(claim)"); continue }
        #expect(remaining > .seconds(119), "\(remaining)")
    }
}

/// With the owner's 120/0 policy: a clean close allows a connect at once, an unclean one waits 120 s.
@Test func claimWithACleanValueOfZero() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    for store in bothStores(url) {
        await store.recordClosed(host: "192.0.2.1", at: Date(), clean: true)
        #expect(await store.claim(hosts: ["192.0.2.1"], pid: getpid(), policy: policy) == .claimed)
        await store.recordClosed(host: "192.0.2.1", at: Date(), clean: false)
        let claim = await store.claim(hosts: ["192.0.2.1"], pid: getpid(), policy: policy)
        guard case .wait(let remaining) = claim else { Issue.record("\(claim)"); continue }
        #expect(remaining > .seconds(119) && remaining <= .seconds(120), "\(remaining)")
        // A clean value in between: 30 s after a clean close.
        await store.recordClosed(host: "192.0.2.5", at: Date(timeIntervalSinceNow: -10), clean: true)
        let between = await store.claim(hosts: ["192.0.2.5"], pid: getpid(),
                                        policy: RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(30)))
        guard case .wait(let left) = between else { Issue.record("\(between)"); continue }
        #expect(left > .seconds(19) && left <= .seconds(20), "\(left)")
    }
}

@Test func claimUsesTheLatestCloseAcrossHosts() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let policy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)
    let t = Date(timeIntervalSinceNow: -5)
    for store in bothStores(url) {
        // The later close is clean, but an older unclean one still holds the full cooldown
        // (QA I2: a clean close never hides an unclean one)...
        await store.recordClosed(host: "192.0.2.1", at: t.addingTimeInterval(-50), clean: false)
        await store.recordClosed(host: "192.0.2.2", at: t, clean: true)
        if case .claimed = await store.claim(hosts: ["192.0.2.1", "192.0.2.2"], pid: getpid(), policy: policy) {
            Issue.record("a later clean close hid an unclean one")
        }
        // ...until the full cooldown has passed since it; then the clean close's own wait applies.
        await store.recordClosed(host: "192.0.2.7", at: t.addingTimeInterval(-200), clean: false)
        await store.recordClosed(host: "192.0.2.8", at: t, clean: true)
        #expect(await store.claim(hosts: ["192.0.2.7", "192.0.2.8"], pid: getpid(), policy: policy) == .claimed)
        await store.recordClosed(host: "192.0.2.1", at: Date(), clean: true)
        await store.recordClosed(host: "192.0.2.2", at: Date(), clean: true)
        // The later close is unclean.
        await store.recordClosed(host: "192.0.2.3", at: t.addingTimeInterval(-50), clean: true)
        await store.recordClosed(host: "192.0.2.4", at: t, clean: false)
        if case .claimed = await store.claim(hosts: ["192.0.2.3", "192.0.2.4"], pid: getpid(), policy: policy) {
            Issue.record("a later unclean close was ignored")
        }
        // Equal times across hosts: unclean wins.
        await store.recordClosed(host: "192.0.2.5", at: t, clean: true)
        await store.recordClosed(host: "192.0.2.6", at: t, clean: false)
        if case .claimed = await store.claim(hosts: ["192.0.2.5", "192.0.2.6"], pid: getpid(), policy: policy) {
            Issue.record("an unclean close at the same time didn't win")
        }
    }
}

// MARK: A clean close never hides an unclean one (Plan 5 Task 1, QA I1/I2/M2)

private let ownersPolicy = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero)

/// Expects `claim` to refuse with at least `atLeast` left.
private func expectWait(_ claim: RTSPCooldownClaim, atLeast: Duration, _ note: String = "") {
    guard case .wait(let remaining) = claim else { Issue.record("\(note): \(claim)"); return }
    #expect(remaining >= atLeast, "\(note): \(remaining)")
}

@Test func entryKeepsTheLatestUncleanCloseApart() {
    let t0 = Date(timeIntervalSince1970: 1_000), t1 = t0.addingTimeInterval(10), t2 = t0.addingTimeInterval(20)
    var entry = RTSPCooldownEntry()
    entry.noteClosed(at: t0, clean: false)
    entry.noteClosed(at: t1, clean: true)
    #expect(entry.lastClose == RTSPCloseRecord(at: t1, clean: true))
    #expect(entry.lastUncleanClosed == t0)
    entry.noteClosed(at: t0.addingTimeInterval(-5), clean: false)  // older: changes nothing
    #expect(entry.lastUncleanClosed == t0)
    entry.noteClosed(at: t2, clean: false)
    #expect(entry.lastClose == RTSPCloseRecord(at: t2, clean: false))
    #expect(entry.lastUncleanClosed == t2)
}

/// QA probe P1: a clean close stamped in the future (the clock stepped back) must not hide a
/// later unclean close.
@Test func futureCleanCloseDoesNotHideAnUncleanClose() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    for store in bothStores(url) {
        let name = "\(type(of: store))"
        await store.recordClosed(host: "192.0.2.1", at: Date(timeIntervalSinceNow: 600), clean: true)
        await store.recordClosed(host: "192.0.2.1", at: Date(), clean: false)
        expectWait(await store.claim(hosts: ["192.0.2.1"], pid: getpid(), policy: ownersPolicy),
                   atLeast: .seconds(110), name)
        // A future-stamped clean close on its own counts as an unclean close now.
        await store.recordClosed(host: "192.0.2.2", at: Date(timeIntervalSinceNow: 600), clean: true)
        expectWait(await store.claim(hosts: ["192.0.2.2"], pid: getpid(), policy: ownersPolicy),
                   atLeast: .seconds(110), name)
    }
}

/// QA probe P2: a future-stamped clean close must not hide a dead lease (a crash).
@Test func futureCleanCloseDoesNotHideADeadLease() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let deadPID = try exitedPID()
    for store in bothStores(url) {
        let host = "192.0.2.\(store is FileRTSPCooldownStore ? 1 : 2)"
        await store.recordClosed(host: host, at: Date(timeIntervalSinceNow: 600), clean: true)
        await store.recordOpened(host: host, at: Date(timeIntervalSinceNow: -60), pid: deadPID)
        expectWait(await store.claim(hosts: [host], pid: getpid(), policy: ownersPolicy),
                   atLeast: .seconds(110), "\(type(of: store))")
        #expect(await store.closeHistory(host: host)?.lastUnclean != nil)
    }
}

/// QA probe P3: an unclean close 1 s ago and a clean one now (e.g. two stations whose keys
/// overlap): the unclean one still holds the full cooldown, on one key or across keys.
@Test func laterCleanCloseDoesNotHideAnEarlierUncleanOne() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    for store in bothStores(url) {
        let name = "\(type(of: store))"
        await store.recordClosed(host: "192.0.2.1", at: Date(timeIntervalSinceNow: -1), clean: false)
        await store.recordClosed(host: "192.0.2.1", at: Date(), clean: true)
        #expect(await store.lastClose(host: "192.0.2.1")?.clean == true)
        expectWait(await store.claim(hosts: ["192.0.2.1"], pid: getpid(), policy: ownersPolicy),
                   atLeast: .seconds(115), name)
        await store.recordClosed(host: "192.0.2.3", at: Date(timeIntervalSinceNow: -1), clean: false)
        await store.recordClosed(host: "192.0.2.4", at: Date(), clean: true)
        expectWait(await store.claim(hosts: ["192.0.2.3", "192.0.2.4"], pid: getpid(), policy: ownersPolicy),
                   atLeast: .seconds(115), name)
        // Once the full cooldown has passed since the unclean close, the clean one's own wait applies.
        await store.recordClosed(host: "192.0.2.5", at: Date(timeIntervalSinceNow: -200), clean: false)
        await store.recordClosed(host: "192.0.2.5", at: Date(timeIntervalSinceNow: -10), clean: true)
        #expect(await store.claim(hosts: ["192.0.2.5"], pid: getpid(), policy: ownersPolicy) == .claimed, "\(name)")
    }
}

@Test func fileStoreRoundTripsTheLatestUncleanClose() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000), t1 = t0.addingTimeInterval(10)
    await FileRTSPCooldownStore(url: url).recordClosed(host: "192.0.2.1", at: t0, clean: false)
    await FileRTSPCooldownStore(url: url).recordClosed(host: "192.0.2.1", at: t1, clean: true)
    #expect(try entry(url, "192.0.2.1")?["lastUncleanClosed"] is String)
    #expect(await FileRTSPCooldownStore(url: url).closeHistory(host: "192.0.2.1")
            == RTSPCloseHistory(latest: RTSPCloseRecord(at: t1, clean: true), lastUnclean: t0))
    // Older files have no `lastUncleanClosed`: a flagless or legacy close is itself unclean.
    let json = #"{"192.0.2.2":"2023-11-14T22:13:20Z","192.0.2.3":{"lastClosed":"2023-11-14T22:13:20Z"}}"#
    try Data(json.utf8).write(to: url)
    for host in ["192.0.2.2", "192.0.2.3"] {
        #expect(await FileRTSPCooldownStore(url: url).closeHistory(host: host)
                == RTSPCloseHistory(latest: RTSPCloseRecord(at: t0, clean: false), lastUnclean: t0), "\(host)")
    }
}

/// QA M2: without the lock, a close can't be vouched for, so it is recorded as unclean.
@Test func lockFailureRecordsAnUncleanClose() async throws {
    let url = try temporaryStoreURL(); defer { removeStoreDirectory(url) }
    try FileManager.default.createDirectory(atPath: url.path + ".lock", withIntermediateDirectories: false)
    let store = FileRTSPCooldownStore(url: url)
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    await store.recordClosed(host: "192.0.2.1", at: t, clean: true)
    #expect(await store.lastClose(host: "192.0.2.1") == RTSPCloseRecord(at: t, clean: false))
    #expect((await store.lastWriteError)?.contains(".lock") == true)
}
