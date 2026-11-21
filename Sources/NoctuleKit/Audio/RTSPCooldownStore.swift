// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// What `RTSPCooldownStore.claim` decided.
public enum RTSPCooldownClaim: Sendable, Equatable {
    /// The cooldown is over and the lease is now held by the claimant: connect.
    case claimed
    /// Don't connect; the cooldown has this much longer to run (or another process holds the lease).
    case wait(Duration)
    /// The store couldn't lock its record, so it can't vouch that connecting is safe: don't connect.
    case unavailable(String)
}

/// Remembers when the last TCP connection to each RTSP server closed, and whether that close was
/// clean (`RTSPCooldownPolicy`), keyed by IP literal.
///
/// The SDS200's audio server hangs (and needs a power cycle) if a new TCP connection to port 554
/// opens shortly after the previous one closed; 120 s is proven safe (protocol notes §6). How
/// long a claim waits is the policy's: its full value after an unclean close, its clean-close
/// value (the owner's per-station setting) only after a clean one. `RTSPClient` claims the server
/// through the store before every connect (`claim`) and records every close in it, with its flag.
///
/// **Atomic claim.** `claim(hosts:pid:policy:)` checks the cooldown and, if it is over, takes
/// the crash lease, in one step (one `flock` for the file store). Two processes waiting out the
/// same cooldown therefore can't both connect: the first to claim wins, and the other finds a
/// live lease and is told to wait the full cooldown (and then checks again). The latest close
/// and the latest unclean close across the claimed hosts each count (`RTSPCooldownPolicy`): a
/// clean close never hides an unclean one.
///
/// **Crash lease.** The lease records the claimant's pid and start time. `recordClosed` clears it
/// only if it belongs to this process, so one process's close never erases another's lease. A
/// crash or SIGKILL leaves the lease behind, so `closeHistory(host:)` and `claim` read a lease this
/// way:
/// - owned by this process: the connection is open here; the last close is returned unchanged
///   (the client's own single-flight and close logic govern in-process behavior);
/// - owned by another live process: the connection is open right now, so it reads as an unclean
///   close at `Date()` and the full cooldown applies from now. Live means `kill(pid, 0)` reports
///   the pid alive (0 or `EPERM`) AND either that pid's start time (`sysctl`) matches the lease's
///   `processStart` to within 1 s, or (start time unreadable, e.g. iOS, or not recorded by older
///   code) the lease is younger than the store's `leaseMaxAge` (12 h);
/// - otherwise (no such process, a reused pid, a too-old lease, or an invalid pid): the connection
///   closed at the moment of discovery, uncleanly (a crash). The store records an unclean close
///   at now, clears the lease, and returns it.
///
/// A lease owned by the claimant itself never blocks its own claim: within one process,
/// `RTSPClient`'s single-flight connect and close ordering govern.
public protocol RTSPCooldownStore: Sendable {
    /// Checks the cooldown for every host in `hosts` and, only if it is over for all of them,
    /// writes a crash lease for `pid` on each, in one atomic step. The hosts' histories are merged
    /// (`RTSPCloseHistory.merged`) and the wait is `policy.remaining(after:)`: the full cooldown
    /// since the latest unclean close, and the latest close's own wait by its flag.
    func claim(hosts: [String], pid: Int32, policy: RTSPCooldownPolicy) async -> RTSPCooldownClaim
    /// The host's latest close (with its flag) and latest unclean close, with any lease resolved
    /// (see the type's notes: another live process's lease reads as an unclean close now, a dead
    /// one is recorded as an unclean close at the moment of discovery).
    func closeHistory(host: String) async -> RTSPCloseHistory?
    /// Records a close and clears the host's lease if this process holds it (another process's
    /// lease is left alone). Keeps the later of the stored and new close, with its `clean` flag
    /// (at an equal time, an unclean close wins), and the latest unclean close apart from it.
    func recordClosed(host: String, at: Date, clean: Bool) async
    /// Records that `pid` opened a connection to `host` at `at` (the crash lease).
    func recordOpened(host: String, at: Date, pid: Int32) async
    /// Forgets the host's record. Call it only after a scanner restart: the reboot resets the
    /// audio server, so the old close time no longer applies.
    func clear(host: String) async
    /// Why the latest write failed, or nil if it succeeded (or nothing has been written).
    var lastWriteError: String? { get async }
}

extension RTSPCooldownStore {
    /// `claim(hosts:pid:policy:)` with the same `cooldown` after every close, clean or not.
    public func claim(hosts: [String], pid: Int32, cooldown: Duration) async -> RTSPCooldownClaim {
        await claim(hosts: hosts, pid: pid, policy: .symmetric(cooldown))
    }

    /// The host's latest close of any kind, with its flag (`closeHistory(host:)?.latest`).
    public func lastClose(host: String) async -> RTSPCloseRecord? {
        await closeHistory(host: host)?.latest
    }

    /// When the host's last close happened (`lastClose(host:)` without its `clean` flag).
    public func lastClosed(host: String) async -> Date? {
        await lastClose(host: host)?.at
    }

    /// Records an unclean close (the safe side: the full cooldown follows it).
    public func recordClosed(host: String, at date: Date) async {
        await recordClosed(host: host, at: date, clean: false)
    }
}

/// One close of an RTSP connection, as `RTSPCooldownStore.lastClose(host:)` reports it.
public struct RTSPCloseRecord: Sendable, Equatable {
    public var at: Date
    /// See `RTSPCooldownPolicy` for what makes a close clean.
    public var clean: Bool

    public init(at: Date, clean: Bool) {
        self.at = at; self.clean = clean
    }
}

/// What a cooldown wait is computed from: the latest close of any kind (with its flag) and the
/// latest unclean close. A clean close never hides an unclean one: the wait lasts until the full
/// cooldown has passed since `lastUnclean` and the latest close's own wait has passed.
public struct RTSPCloseHistory: Sendable, Equatable {
    public var latest: RTSPCloseRecord?
    public var lastUnclean: Date?

    public init(latest: RTSPCloseRecord? = nil, lastUnclean: Date? = nil) {
        self.latest = latest; self.lastUnclean = lastUnclean
    }
}

/// One host's record: the last close and, while a connection is open, its lease.
struct RTSPCooldownEntry: Equatable, Sendable {
    struct Lease: Equatable, Sendable {
        var openedAt: Date
        var pid: Int32
        /// The owning process's start time, so a reused pid isn't mistaken for the owner. Nil if
        /// it couldn't be read, or the lease was written by older code.
        var processStart: Date?
    }

    /// How old a lease may be before it counts as dead when the owner's start time can't be
    /// compared (iOS sandboxing, or a lease from older code).
    static let defaultLeaseMaxAge: TimeInterval = 12 * 3_600
    var lastClosed: Date?
    /// Whether the close in `lastClosed` was clean (`RTSPCooldownPolicy`). False when absent.
    var lastCloseClean = false
    /// The latest unclean close (equal to `lastClosed` when that one was unclean), kept apart so a
    /// later clean close can't hide it.
    var lastUncleanClosed: Date?
    var lease: Lease?

    var isEmpty: Bool { lastClosed == nil && lease == nil }

    /// Records a close by process `pid`: clears the lease only if `pid` holds it. (A pid can't be
    /// reused during its own lifetime, so a lease with our pid is either ours or a dead
    /// predecessor's with the same pid; either way it is no longer anyone's open connection.)
    mutating func recordClosed(at date: Date, clean: Bool, by pid: Int32 = getpid()) {
        if lease?.pid == pid { lease = nil }
        noteClosed(at: date, clean: clean)
    }

    /// The last close as a record, or nil if none is stored.
    var lastClose: RTSPCloseRecord? { lastClosed.map { RTSPCloseRecord(at: $0, clean: lastCloseClean) } }

    /// The close history, or nil if no close is stored.
    var history: RTSPCloseHistory? {
        guard lastClose != nil || lastUncleanClosed != nil else { return nil }
        return RTSPCloseHistory(latest: lastClose, lastUnclean: lastUncleanClosed)
    }

    /// Keeps the later of the stored and the new close, with its flag (at an equal time, unclean
    /// wins), and, for an unclean close, the later unclean close.
    mutating func noteClosed(at date: Date, clean: Bool) {
        let merged = RTSPCloseHistory(RTSPCloseRecord(at: date, clean: clean)).merged(with: history)
        lastClosed = merged.latest?.at
        lastCloseClean = merged.latest?.clean ?? false
        lastUncleanClosed = merged.lastUnclean
    }

    /// What a lease means for the cooldown (see `RTSPCooldownStore`): the close to count, and
    /// whether it was clean. Another live process's lease reads as an unclean close now (the full
    /// cooldown from now); a dead one is recorded as an unclean close at `now`, since a crash is
    /// never a clean close. `changed` is true when the entry was rewritten (a dead lease) and
    /// needs saving. `selfPID` is whose lease counts as "this process" (the claimant, for `claim`).
    mutating func resolve(
        now: Date = Date(), maxAge: TimeInterval = defaultLeaseMaxAge,
        startTime: (Int32) -> Date? = processStartTime, selfPID: Int32 = getpid()
    ) -> (history: RTSPCloseHistory?, changed: Bool) {
        guard let lease else { return (history, false) }
        switch Self.owner(of: lease, now: now, maxAge: maxAge, startTime: startTime, selfPID: selfPID) {
        case .thisProcess:
            return (history, false)
        case .otherLiveProcess:
            var open = self
            open.noteClosed(at: now, clean: false)
            return (open.history, false)
        case .gone:
            self.lease = nil
            noteClosed(at: now, clean: false)
            return (history, true)
        }
    }

    enum Owner { case thisProcess, otherLiveProcess, gone }

    static func owner(
        of lease: Lease, now: Date, maxAge: TimeInterval, startTime: (Int32) -> Date?,
        selfPID: Int32 = getpid()
    ) -> Owner {
        let pid = lease.pid
        // Never kill(0 or negative, 0): that addresses a process group, not one process.
        guard pid > 0 else { return .gone }
        if pid == selfPID { return .thisProcess }
        // EPERM: it exists but isn't ours. Anything but ESRCH is treated as alive (the safe side).
        guard kill(pid, 0) == 0 || errno != ESRCH else { return .gone }
        // The pid exists; is it still the process that took the lease?
        if let recorded = lease.processStart, let actual = startTime(pid) {
            return abs(actual.timeIntervalSince(recorded)) <= 1 ? .otherLiveProcess : .gone  // else reused
        }
        // Start time unreadable (iOS, EPERM) or not recorded (older code): trust only a young lease.
        return now.timeIntervalSince(lease.openedAt) < maxAge ? .otherLiveProcess : .gone
    }

    /// The atomic check-and-lease behind `RTSPCooldownStore.claim`, over a whole map (the caller
    /// holds the lock). Resolves each host's lease as `claimant` sees it (another live process's
    /// lease counts as an unclean close now) and merges the hosts' histories. If
    /// `policy.remaining(after:)` that history is still running, returns `.wait` and leases
    /// nothing. Otherwise leases every host to `claimant`. `changed` is true when `entries` was
    /// modified and needs saving.
    static func claim(
        _ entries: inout [String: RTSPCooldownEntry], hosts: [String], claimant: Int32,
        claimantStart: Date?, policy: RTSPCooldownPolicy, now: Date = Date(), maxAge: TimeInterval,
        startTime: (Int32) -> Date?
    ) -> (claim: RTSPCooldownClaim, changed: Bool) {
        let hosts = Array(Set(hosts)).sorted()
        var changed = false
        var merged: RTSPCloseHistory?
        for host in hosts {
            guard var entry = entries[host] else { continue }
            let (history, rewritten) = entry.resolve(now: now, maxAge: maxAge, startTime: startTime, selfPID: claimant)
            if rewritten { entries[host] = entry; changed = true }
            merged = RTSPCloseHistory.merged(merged, history)
        }
        if let merged, let remaining = policy.remaining(after: merged, now: now) {
            return (.wait(remaining), changed)
        }
        for host in hosts {
            entries[host, default: RTSPCooldownEntry()].lease =
                .init(openedAt: now, pid: claimant, processStart: claimantStart)
        }
        return (.claimed, changed || !hosts.isEmpty)
    }

    /// When process `pid` started (`sysctl` `KERN_PROC_PID`, `kp_proc.p_starttime`), or nil if
    /// it can't be read (no such process, or not permitted, e.g. the iOS sandbox).
    static func processStartTime(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }
}

/// A store for one process. `shared` is `RTSPClient`'s default, so every client in the process
/// respects every other client's closes.
public actor InMemoryRTSPCooldownStore: RTSPCooldownStore {
    public static let shared = InMemoryRTSPCooldownStore()
    private var entries: [String: RTSPCooldownEntry] = [:]
    /// See `FileRTSPCooldownStore.leaseMaxAge`.
    public let leaseMaxAge: TimeInterval
    let processStartLookup: @Sendable (Int32) -> Date?

    public init(leaseMaxAge: TimeInterval = 12 * 3_600) {
        self.init(leaseMaxAge: leaseMaxAge, processStartLookup: RTSPCooldownEntry.processStartTime)
    }

    /// For tests: `processStartLookup` replaces the `sysctl` lookup (return nil for "unreadable").
    init(leaseMaxAge: TimeInterval, processStartLookup: @escaping @Sendable (Int32) -> Date?) {
        self.leaseMaxAge = leaseMaxAge
        self.processStartLookup = processStartLookup
    }

    public func claim(hosts: [String], pid: Int32, policy: RTSPCooldownPolicy) -> RTSPCooldownClaim {
        RTSPCooldownEntry.claim(&entries, hosts: hosts, claimant: pid, claimantStart: processStartLookup(pid),
                                policy: policy, maxAge: leaseMaxAge, startTime: processStartLookup).claim
    }

    public func closeHistory(host: String) -> RTSPCloseHistory? {
        guard var entry = entries[host] else { return nil }
        let (history, changed) = entry.resolve(maxAge: leaseMaxAge, startTime: processStartLookup)
        if changed { entries[host] = entry }
        return history
    }

    /// Keeps the later of the stored and the new close, and clears the lease if this process holds it.
    public func recordClosed(host: String, at date: Date, clean: Bool) {
        entries[host, default: RTSPCooldownEntry()].recordClosed(at: date, clean: clean)
    }

    /// Also records `pid`'s start time, so a later reuse of the pid isn't taken for the owner.
    public func recordOpened(host: String, at date: Date, pid: Int32) {
        recordOpened(host: host, at: date, pid: pid, processStart: processStartLookup(pid))
    }

    /// For tests: records a lease with an explicit (possibly wrong or nil) `processStart`.
    func recordOpened(host: String, at date: Date, pid: Int32, processStart: Date?) {
        entries[host, default: RTSPCooldownEntry()].lease = .init(openedAt: date, pid: pid, processStart: processStart)
    }

    public func clear(host: String) { entries[host] = nil }

    /// Always nil: nothing here can fail to write.
    public var lastWriteError: String? { nil }
}

/// A store in a small JSON file, so the cooldown holds across processes, e.g. one CLI run after
/// another. Each host maps to `{"lastClosed": "<ISO-8601>", "lastCloseClean": true,
/// "lastUncleanClosed": "<ISO-8601>", "lease": {"openedAt": "<ISO-8601>", "pid": <Int32>,
/// "processStart": "<ISO-8601>"}}` (every field may be absent). `lastCloseClean` is written only
/// when true; absent means unclean, so records from older code wait the full cooldown.
/// `lastUncleanClosed` is the latest unclean close; older files lack it, and their `lastClosed`
/// (flagless, so unclean) is read as one. The older flat `{"<ip>": "<ISO-8601>"}` form is still
/// read (as an unclean close), and rewritten in the new form on the next write.
///
/// Every read-modify-write (including `claim`, and the reads behind `closeHistory`, which can
/// rewrite a dead lease) holds an exclusive `flock` on the sibling `<file>.lock`, so stores in
/// different processes don't lose each other's updates and `claim` is atomic across processes.
/// Writes are atomic (temporary file, then rename). An unreadable or corrupt file counts as "no
/// record" and is replaced on the next write. A failed write sets `lastWriteError` (the next
/// successful write clears it).
///
/// **If the lock can't be taken** (the lock file can't be opened or `flock` fails), the store
/// takes the safe side and says so in `lastWriteError`: `claim` returns `.unavailable` (so
/// `RTSPClient` won't connect) unless the policy's full cooldown is zero; `recordClosed` still
/// writes, but always as an unclean close, and `recordOpened` still writes its lease (neither can
/// shorten the wait); `closeHistory` reads but doesn't rewrite a dead lease; `clear` does nothing
/// (the record stays, so the cooldown holds).
public actor FileRTSPCooldownStore: RTSPCooldownStore {
    public let url: URL
    public private(set) var lastWriteError: String?

    /// `~/Library/Caches/NoctuleScan/rtsp-cooldown.json` on macOS (the app's caches directory on iOS).
    public static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("NoctuleScan", isDirectory: true)
            .appendingPathComponent("rtsp-cooldown.json")
    }

    /// Whether two file URLs name the same file: standardized, symlinks resolved (in the folder if
    /// the file doesn't exist yet), compared ignoring case (APFS default). Errs towards "same".
    /// The test-only overrides (the CLI's `--cooldown-seconds`, the app's environment) use it to
    /// refuse `defaultURL` (and the standard settings directory) however the path is spelled.
    public static func samePath(_ a: URL, _ b: URL) -> Bool {
        func canonical(_ url: URL) -> String {
            let url = url.standardizedFileURL
            // An existing file may itself be a symlink; a missing one is named through its folder.
            let resolved = FileManager.default.fileExists(atPath: url.path)
                ? url.resolvingSymlinksInPath()
                : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
            return resolved.standardizedFileURL.path.lowercased()
        }
        return canonical(a) == canonical(b)
    }

    private static let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// Legacy and hand-written times may lack fractional seconds.
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    /// A lease from another live pid whose start time can't be compared (unreadable, or not
    /// recorded by older code) counts as dead once it is this old. Default 12 h.
    public let leaseMaxAge: TimeInterval
    let processStartLookup: @Sendable (Int32) -> Date?

    public init(url: URL, leaseMaxAge: TimeInterval = 12 * 3_600) {
        self.init(url: url, leaseMaxAge: leaseMaxAge, processStartLookup: RTSPCooldownEntry.processStartTime)
    }

    /// For tests: `processStartLookup` replaces the `sysctl` lookup (return nil for "unreadable").
    init(url: URL, leaseMaxAge: TimeInterval, processStartLookup: @escaping @Sendable (Int32) -> Date?) {
        self.url = url
        self.leaseMaxAge = leaseMaxAge
        self.processStartLookup = processStartLookup
    }

    private var lockURL: URL { URL(fileURLWithPath: url.path + ".lock") }

    public func claim(hosts: [String], pid: Int32, policy: RTSPCooldownPolicy) -> RTSPCooldownClaim {
        withLock { lockError in
            if let lockError, policy.full > .zero { return .unavailable(lockError) }
            var map = read()
            let (claim, changed) = RTSPCooldownEntry.claim(
                &map, hosts: hosts, claimant: pid, claimantStart: processStartLookup(pid),
                policy: policy, maxAge: leaseMaxAge, startTime: processStartLookup)
            if changed { write(map) }
            return claim
        }
    }

    public func closeHistory(host: String) -> RTSPCloseHistory? {
        withLock { lockError in
            var map = read()
            guard var entry = map[host] else { return nil }
            let (history, changed) = entry.resolve(maxAge: leaseMaxAge, startTime: processStartLookup)
            if changed, lockError == nil {
                map[host] = entry
                write(map)
            }
            return history
        }
    }

    /// Without the lock the close can't be vouched for, so it is recorded as unclean.
    public func recordClosed(host: String, at date: Date, clean: Bool) {
        update(host) { entry, lockError in entry.recordClosed(at: date, clean: clean && lockError == nil) }
    }

    /// Also records `pid`'s start time, so a later reuse of the pid isn't taken for the owner.
    public func recordOpened(host: String, at date: Date, pid: Int32) {
        recordOpened(host: host, at: date, pid: pid, processStart: processStartLookup(pid))
    }

    /// For tests: records a lease with an explicit (possibly wrong or nil) `processStart`.
    func recordOpened(host: String, at date: Date, pid: Int32, processStart: Date?) {
        update(host) { entry, _ in entry.lease = .init(openedAt: date, pid: pid, processStart: processStart) }
    }

    public func clear(host: String) {
        withLock { lockError in
            guard lockError == nil else { return }  // keep the record: the cooldown still holds
            var map = read()
            guard map.removeValue(forKey: host) != nil else { return }
            write(map)
        }
    }

    /// Writes even without the lock (`change` gets the lock error): a lease, or a close recorded
    /// as unclean (which `recordClosed` does without the lock), never shortens the wait.
    private func update(_ host: String, _ change: (inout RTSPCooldownEntry, _ lockError: String?) -> Void) {
        withLock { lockError in
            var map = read()
            var entry = map[host] ?? RTSPCooldownEntry()
            change(&entry, lockError)
            guard entry != map[host] else { return }
            map[host] = entry.isEmpty ? nil : entry
            write(map)
        }
    }

    // MARK: Lock

    /// Runs `body` holding an exclusive `flock` on the sibling `.lock` file (created if missing).
    /// If the lock can't be taken, `body` gets the reason (and must take the safe side; see the
    /// type's notes), and afterwards `lastWriteError` reports it.
    private func withLock<T>(_ body: (_ lockError: String?) -> T) -> T {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lockError: String?
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        var locked = false
        if fd < 0 {
            lockError = "couldn't open the RTSP cooldown lock \(lockURL.path): \(String(cString: strerror(errno)))"
        } else {
            var result: Int32
            repeat { result = flock(fd, LOCK_EX) } while result != 0 && errno == EINTR
            if result == 0 {
                locked = true
            } else {
                lockError = "couldn't lock the RTSP cooldown lock \(lockURL.path): \(String(cString: strerror(errno)))"
            }
        }
        defer {
            if fd >= 0 {
                if locked { flock(fd, LOCK_UN) }
                Darwin.close(fd)
            }
        }
        let value = body(lockError)
        if let lockError { lastWriteError = lockError }
        return value
    }

    // MARK: File format

    private func read() -> [String: RTSPCooldownEntry] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var map: [String: RTSPCooldownEntry] = [:]
        for (host, value) in json {
            if let legacy = value as? String {
                if let date = Self.parse(legacy) {
                    map[host] = RTSPCooldownEntry(lastClosed: date, lastUncleanClosed: date)
                }
            } else if let object = value as? [String: Any] {
                var entry = RTSPCooldownEntry()
                entry.lastClosed = (object["lastClosed"] as? String).flatMap(Self.parse)
                // Absent (older code) or anything but `true` reads as unclean.
                entry.lastCloseClean = entry.lastClosed != nil && (object["lastCloseClean"] as? Bool) == true
                entry.lastUncleanClosed = (object["lastUncleanClosed"] as? String).flatMap(Self.parse)
                if let closed = entry.lastClosed, !entry.lastCloseClean {
                    // Older files have no `lastUncleanClosed`: an unclean (or flagless) close is one.
                    entry.lastUncleanClosed = max(entry.lastUncleanClosed ?? closed, closed)
                }
                if let lease = object["lease"] as? [String: Any],
                   let openedAt = (lease["openedAt"] as? String).flatMap(Self.parse),
                   let pid = (lease["pid"] as? NSNumber)?.int32Value {
                    entry.lease = .init(openedAt: openedAt, pid: pid,
                                        processStart: (lease["processStart"] as? String).flatMap(Self.parse))
                }
                if !entry.isEmpty { map[host] = entry }
            }
        }
        return map
    }

    private func write(_ map: [String: RTSPCooldownEntry]) {
        var json: [String: Any] = [:]
        for (host, entry) in map where !entry.isEmpty {
            var object: [String: Any] = [:]
            if let closed = entry.lastClosed {
                object["lastClosed"] = Self.format.format(closed)
                if entry.lastCloseClean { object["lastCloseClean"] = true }
            }
            if let unclean = entry.lastUncleanClosed { object["lastUncleanClosed"] = Self.format.format(unclean) }
            if let lease = entry.lease {
                var leaseObject: [String: Any] = ["openedAt": Self.format.format(lease.openedAt), "pid": Int(lease.pid)]
                if let start = lease.processStart { leaseObject["processStart"] = Self.format.format(start) }
                object["lease"] = leaseObject
            }
            json[host] = object
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = "couldn't save the RTSP cooldown record at \(url.path): \(error.localizedDescription)"
        }
    }

    private static func parse(_ string: String) -> Date? {
        (try? format.parse(string)) ?? (try? wholeSeconds.parse(string))
    }
}
