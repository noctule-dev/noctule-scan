// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import Synchronization
import NoctuleKit
import NoctuleStore

/// One `StationSession` per station in this process, however many windows show it (Review
/// Focus 2), and the app-wide lifecycle: stop everything on quit, suspend and resume on sleep and
/// wake (Review Focus 1).
///
/// - `open(_:)` returns the station's session (refcount +1), or creates one and starts it in the
///   background. Opening records nothing: a station becomes the last one used (`lastStationID`,
///   the one the app reopens at launch) when its session reaches `.connected` (from its current
///   runner, while the registry still holds it), so a station that never connects never becomes
///   the launch station.
/// - `release(_:)` drops one reference; the last one awaits `stop()` (`PSI,0`, TEARDOWN) and
///   forgets the session. An unknown id is a no-op.
/// - A new session for a station whose previous session is still stopping (a quick close and
///   reopen, an edit) starts only after that stop has finished, so the two never contend for the
///   station lock or the scanner. Every start goes through the session's cooldown gate.
/// - `stationsChanged(_:)`: an open station whose name, connection or recording rules changed
///   gets a fresh session with the same refcount, and the old one stops (through the cooldown
///   gate, so audio returns after the station's reconnect wait if its TEARDOWN was answered, 120 s
///   otherwise); a deleted one stops and is forgotten. `deviceSettingsChanged(_:)` replaces an
///   open session the same way when the station's device settings (its saved USB port) changed.
///   A change only to what the session reads live (key map, display color mode, the view toggle,
///   saved filters, counts reset) or at its next start (the reconnect wait) is applied to the
///   running session instead. `stationChanged(_:)`
///   and `stationDeleted(_:)` do the same for one station. `lineInChanged(_:to:)` hands a USB
///   station's new input (or none) to its open session, which swaps its line-in source and keeps
///   the scanner session (line-in design §6.1).
/// - `previewLevels(stationID:config:)`: a line-in meter for the station editor, read from the
///   open session when it runs that input, else from a short-lived source of its own, which never
///   outlives its stream, a sleep or a quit.
/// - `stopAll(deadline:)` stops every session concurrently, forgets them all, and returns false if
///   the deadline passed first (the stops carry on in the background; nothing is cancelled).
/// - `suspendAll()`/`resumeAll()` for sleep and wake. A session opened (or replaced) while
///   suspended starts at `resumeAll()`, not before.
/// - **One session per scanner in this process** (`scannerIdentity(of:usbPort:)`, SDS150 design
///   §4.5). A network station is its address: host, ignoring case and surrounding white space, UDP
///   port and RTSP port; nothing is resolved. A USB station is its saved port as the session read
///   it at its last start (`StationSession.usbPort`); an automatic one (no saved port) may resolve
///   to any port, so it conflicts with every USB station, and two saved ports conflict only when
///   the paths are equal. A network and a USB station never conflict. A session whose scanner
///   another open or still-stopping session holds starts in `.scannerInUse(byStation:)` with
///   nothing opened, at open and on every later start (Try Again). A session opened while another
///   station on its scanner is being retired starts after that stop (a USB session not yet started
///   counts as automatic, so it waits for every retiring USB session). Concurrent sessions on one
///   SDS200 are untested, so they are never made; a serial port takes one client. The per-station
///   `StationLock` still guards against other processes.
/// - A session the registry lets go of (last release, a replacing edit, deletion, `stopAll`) is
///   retired (`StationSession.isRetired`): it stops, and nothing can start it again.
@MainActor @Observable
public final class SessionRegistry {
    @ObservationIgnored let environment: SessionEnvironment

    /// The serial port listing the sessions use (`SessionEnvironment.serialPorts`), for the station
    /// editor's USB rows: the same kill-switch and private-settings rules apply.
    public var serialPorts: any SerialPortListing { environment.serialPorts }

    private struct Entry {
        var session: StationSession
        var count: Int
        /// Its start was held back because the registry was suspended; `resumeAll()` starts it.
        var startDeferred = false
    }

    private var entries: [UUID: Entry] = [:]
    /// Stops in flight for sessions the registry no longer holds (last release, edit, deletion),
    /// by station id. A new session for that id starts only after them; `stopAll` waits for them.
    @ObservationIgnored private var pendingStops: [UUID: Task<Void, Never>] = [:]
    /// Sessions being retired, until their stop finishes: they still hold their scanner.
    @ObservationIgnored private var retiring: [ObjectIdentifier: (session: StationSession, stop: Task<Void, Never>)] = [:]
    @ObservationIgnored private var suspended = false
    /// The meter previews with a source of their own (`previewLevels`), until their stream ends.
    @ObservationIgnored private var previews: [UUID: Preview] = [:]
    /// How many previews with a source of their own are still held (tests).
    var previewCount: Int { previews.count }
    /// The latest `lastStationID` save, so saves land in connect order.
    @ObservationIgnored private var lastStationSave: Task<Void, Never>?

    public init(environment: SessionEnvironment) {
        self.environment = environment
    }

    /// The open sessions, in no particular order.
    public var sessions: [StationSession] { entries.values.map(\.session) }

    /// The open session for a station, if any.
    public func session(for id: UUID) -> StationSession? { entries[id]?.session }

    // MARK: Open and release

    /// The station's shared session (see the type's documentation). Synchronous: the first open
    /// starts the session in the background.
    public func open(_ station: Station) -> StationSession {
        let id = station.id
        if var entry = entries[id] {
            entry.count += 1
            entries[id] = entry
            return entry.session
        }
        let session = makeSession(station)
        entries[id] = Entry(session: session, count: 1)
        launch(session, id: id)
        return session
    }

    /// Drops one reference; the last one stops the session and returns when it has stopped.
    public func release(_ id: UUID) async {
        guard var entry = entries[id] else { return }
        entry.count -= 1
        if entry.count > 0 {
            entries[id] = entry
            return
        }
        entries[id] = nil
        await retire(entry.session, id: id).value
    }

    // MARK: Station edits

    /// Restarts open sessions whose station changed, and stops those whose station is gone.
    public func stationsChanged(_ stations: [Station]) {
        let byID = Dictionary(stations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in entries.keys {
            if let station = byID[id] { stationChanged(station) } else { stationDeleted(id) }
        }
    }

    /// One station's stored value changed: its open session (if any) takes it live, or restarts
    /// if the change is restart-relevant. Other stations are untouched, so a caller that knows
    /// only this station (the store's `update` result) never stops the rest.
    public func stationChanged(_ station: Station) {
        guard let entry = entries[station.id] else { return }
        // Only a change the session uses at run time restarts it; the rest is applied live.
        if entry.session.applyLiveChanges(station) { return }
        replace(entry, station: station)
    }

    /// The station is gone: its open session (if any) stops and is forgotten.
    public func stationDeleted(_ id: UUID) {
        guard let entry = entries[id] else { return }
        entries[id] = nil
        retire(entry.session, id: id)
    }

    /// The station's device settings changed (its saved port): an open session is replaced, as by a
    /// restart-relevant edit (the old one stops, the fresh one starts after that stop and reads the
    /// new settings). No open session: nothing. Call only when the saved port changed; a network
    /// station's session is replaced too.
    public func deviceSettingsChanged(_ stationID: UUID) {
        guard let entry = entries[stationID] else { return }
        replace(entry, station: entry.session.station)
    }

    /// The station's line-in input changed (the editor saved another, or none): its open session,
    /// if any, swaps its source (`StationSession.lineInChanged(_:)`), with no restart and nothing
    /// sent to the scanner. Call after the device settings are saved.
    public func lineInChanged(_ stationID: UUID, to config: LineInConfig?) {
        guard let session = entries[stationID]?.session else { return }
        Task { await session.lineInChanged(config) }
    }

    /// A live line-in meter for `config` (the station editor's, line-in design §6.1): the open
    /// session's own readings when its line-in runs that input (nothing more is opened), else a
    /// source of its own from `environment.lineInSources` (its audio drained, never played or
    /// recorded). With no factory, a stream that is already finished; under the kill-switch the
    /// factory's `DisabledLineInSource` has no readings.
    ///
    /// A source of its own never outlives the meter (ruling R19): it is stopped when the stream
    /// ends (`cancel`, or its reader's task cancelled), at `suspendAll()` (and a fresh one started
    /// on the same stream at `resumeAll()`; none is started while suspended), and at `stopAll()`,
    /// which also ends the stream. Call `cancel` when the meter goes away.
    public func previewLevels(stationID: UUID, config: LineInConfig)
        -> (levels: AsyncStream<LineInLevel>, cancel: @Sendable () -> Void) {
        if let session = entries[stationID]?.session, session.runsLineIn(config) {
            return session.levelPreview()
        }
        let (levels, continuation) = AsyncStream.makeStream(of: LineInLevel.self, bufferingPolicy: .bufferingNewest(8))
        guard let make = environment.lineInSources else {
            continuation.finish()
            return (levels, {})
        }
        let id = UUID()
        let preview = Preview(config: config, make: make, continuation: continuation)
        previews[id] = preview
        // Ended at once, inside `cancel()` itself, so a `resumeAll()` in the same turn starts
        // nothing; the stop is the preview's own, so the source stops even once the registry is gone.
        continuation.onTermination = { [weak self] _ in
            preview.markEnded()
            Task { @MainActor in
                self?.previews[id] = nil
                await preview.stopSource()
            }
        }
        if !suspended { preview.startSource() }
        return (levels, { continuation.finish() })
    }

    /// One meter preview with a source of its own: the input, its stream, and the source feeding
    /// it now (nil while asleep, and once stopped).
    @MainActor
    private final class Preview {
        let config: LineInConfig
        let make: LineInSourceFactory
        let continuation: AsyncStream<LineInLevel>.Continuation
        private var source: (any LineInSource)?
        /// The stop of the last source, which every caller of `stopSource()` awaits.
        private var stopping: Task<Void, Never>?
        /// Its stream ended: no source is started for it again. Set from `onTermination`, on
        /// whatever thread ends the stream.
        private nonisolated let endedFlag = Mutex(false)
        nonisolated var ended: Bool { endedFlag.withLock { $0 } }
        nonisolated func markEnded() { endedFlag.withLock { $0 = true } }

        init(config: LineInConfig, make: @escaping LineInSourceFactory, continuation: AsyncStream<LineInLevel>.Continuation) {
            self.config = config; self.make = make; self.continuation = continuation
        }

        /// Makes a source and starts it, feeding the stream; nothing once ended or while one runs.
        func startSource() {
            guard !ended, source == nil else { return }
            let source = make(config)
            self.source = source
            let chunks = source.chunks, states = source.states, levels = source.levels
            let continuation = self.continuation
            // Nobody reads its audio or states: drained, so they don't pile up. All end at its stop.
            Task {
                for await _ in chunks {}
            }
            Task {
                for await _ in states {}
            }
            Task {
                for await level in levels { continuation.yield(level) }
            }
            // Not awaited by the stop: a source stopped first never starts.
            Task { await source.start() }
        }

        /// Stops the current source, if any, and returns once the last stop has finished: two
        /// callers (the stream's end and `stopAll`) await the same stop.
        func stopSource() async {
            if let source {
                self.source = nil
                stopping = Task { await source.stop() }
            }
            await stopping?.value
        }
    }

    /// The station with what doesn't affect its session's run normalized away, leaving the id,
    /// name, connection and recording rules (what `StationSession.start()` and `StationRunner`
    /// read). The rest is read live by the windows: the key map, appearance (display color mode),
    /// `preferredView` (the Scanner / Mac-style toggle, saved on every switch), saved filters and
    /// the counts reset. The connection's reconnect wait is normalized away too: the session
    /// takes it live and its next start reads it (Plan 5).
    public static func restartRelevant(_ station: Station) -> Station {
        var s = station
        s.keyMap = KeyMap()
        s.appearance = Appearance()
        s.preferredView = .scanner
        s.savedFilters = []
        s.countsResetAt = nil
        // Read at the next start (Plan 5): changing it never restarts an open session.
        s.connection.reconnectCooldownSeconds = StationConnection().reconnectCooldownSeconds
        return s
    }

    /// Whether saving `edited` over `current` restarts an open session for it.
    public static func editRestartsSession(from current: Station, to edited: Station) -> Bool {
        restartRelevant(current) != restartRelevant(edited)
    }

    // MARK: Quit, sleep and wake

    /// Stops every session concurrently and forgets them all. True if every stop (including stops
    /// already in flight) finished within `deadline`; false otherwise, and the stops carry on.
    public func stopAll(deadline: Duration = .seconds(15)) async -> Bool {
        let dropped = entries
        entries.removeAll()
        // Each stop goes through `retire`, so a later open of that station waits for it.
        for (id, entry) in dropped { retire(entry.session, id: id) }
        // Every preview's source stops and its stream ends.
        let ending = Array(previews.values)
        previews.removeAll()
        let previewStops = ending.map { preview in
            preview.markEnded()
            preview.continuation.finish()
            return Task { await preview.stopSource() }
        }
        let stops = Array(pendingStops.values) + previewStops
        let all = Task {
            await withTaskGroup(of: Void.self) { group in
                for stop in stops { group.addTask { await stop.value } }
            }
        }
        return await Self.finished(all, within: deadline)
    }

    /// Before sleep: suspends every session concurrently (each stops, remembering whether it was
    /// running). Sessions opened until `resumeAll()` wait to start.
    public func suspendAll() async {
        suspended = true
        let sessions = entries.values.map(\.session)
        let previews = Array(self.previews.values)
        await withTaskGroup(of: Void.self) { group in
            for session in sessions { group.addTask { await session.suspend() } }
            // A preview's source stops too; its stream stays, for a fresh source at the wake.
            for preview in previews { group.addTask { await preview.stopSource() } }
        }
    }

    /// After wake: resumes every session concurrently (each through its cooldown gate, retrying
    /// in the background while there is no answer), and starts any whose start was held back.
    public func resumeAll() async {
        suspended = false
        for preview in previews.values { preview.startSource() }
        var deferred: [StationSession] = []
        for (id, entry) in entries where entry.startDeferred {
            entries[id]?.startDeferred = false
            deferred.append(entry.session)
        }
        let sessions = entries.values.map(\.session)
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                if deferred.contains(where: { $0 === session }) {
                    group.addTask { await session.start() }
                } else {
                    group.addTask { await session.resume() }
                }
            }
        }
    }

    // MARK: Scanner identities

    /// A scanner as the registry tells them apart (SDS150 design §4.5).
    public enum ScannerIdentity: Sendable, Equatable {
        /// A network scanner: host (lowercased, surrounding white space trimmed), UDP and RTSP port.
        case network(host: String, udpPort: UInt16, rtspPort: UInt16)
        /// A USB scanner: the station's saved port (nil: automatic).
        case usb(port: String?)

        /// Network: equal. USB: either port is nil (automatic may resolve to any port), or the
        /// paths are equal. A network and a USB identity never conflict.
        public func conflicts(with other: ScannerIdentity) -> Bool {
            switch (self, other) {
            case (.network, .network): self == other
            case (.usb(let a), .usb(let b)): a == nil || b == nil || a == b
            case (.network, .usb), (.usb, .network): false
            }
        }
    }

    /// The station's scanner identity, given the saved port of its device settings (`usbPort`,
    /// read only for a USB station). Nil for a network station with no host, and for Bluetooth.
    public static func scannerIdentity(of station: Station, usbPort: String?) -> ScannerIdentity? {
        switch station.connection.transport {
        case .network:
            let host = (station.connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty else { return nil }
            return .network(host: host, udpPort: station.connection.udpPort, rtspPort: station.connection.rtspPort)
        case .usbSerial:
            return .usb(port: usbPort)
        case .bluetooth:
            return nil
        }
    }

    /// The identity of `session`'s scanner as of its last start (a USB session not yet started:
    /// automatic).
    private static func identity(of session: StationSession) -> ScannerIdentity? {
        scannerIdentity(of: session.station, usbPort: session.usbPort)
    }

    /// The name of another session (open or being retired) that holds `session`'s scanner.
    private func conflictingStation(for session: StationSession) -> String? {
        guard let identity = Self.identity(of: session) else { return nil }
        let others = entries.values.map(\.session) + retiring.values.map(\.session)
        return others.first { other in
            guard other !== session, other.holdsScanner, let theirs = Self.identity(of: other) else { return false }
            return identity.conflicts(with: theirs)
        }?.station.name
    }

    private func makeSession(_ station: Station) -> StationSession {
        let session = StationSession(station: station, environment: environment)
        session.addressConflict = { [weak self] session in self?.conflictingStation(for: session) }
        session.onConnected = { [weak self] session in self?.recordConnected(session) }
        return session
    }

    /// The station whose session just connected becomes the launch station (`lastStationID`),
    /// unless the registry has already let go of that session. Saves run one after another, so the
    /// latest connect is the one that stays. Internal for tests; the session's `onConnected` calls it.
    func recordConnected(_ session: StationSession) {
        let id = session.station.id
        guard entries[id]?.session === session, !session.isRetired else { return }
        let settings = environment.settings
        let previous = lastStationSave
        lastStationSave = Task {
            await previous?.value
            await settings.setLastStationID(id)
        }
    }

    // MARK: Internals

    /// Puts a fresh session for `station` in `entry`'s place (same refcount), retires the old one,
    /// and launches the fresh one after that stop.
    private func replace(_ entry: Entry, station: Station) {
        let fresh = makeSession(station)
        entries[station.id] = Entry(session: fresh, count: entry.count)
        retire(entry.session, id: station.id)
        launch(fresh, id: station.id)
    }

    /// Starts `session` once any earlier stop for the station has finished, unless by then it is
    /// no longer the station's session (released, replaced, `stopAll`), or the registry is
    /// suspended (then `resumeAll()` starts it).
    private func launch(_ session: StationSession, id: UUID) {
        let identity = Self.identity(of: session)
        let priors = [pendingStops[id]].compactMap { $0 }
            + retiring.values.filter { prior in
                guard let identity, let theirs = Self.identity(of: prior.session) else { return false }
                return identity.conflicts(with: theirs)
            }.map(\.stop)
        Task {
            for prior in priors { await prior.value }
            guard self.entries[id]?.session === session else { return }
            if self.suspended {
                self.entries[id]?.startDeferred = true
                return
            }
            await session.start()
        }
    }

    /// Stops a session the registry no longer holds, recorded in `pendingStops` until done (and
    /// after any earlier stop for the same station). The session is marked retired first, so
    /// nothing (a reconnect whose halt this stop joins, a wake, a restart, a stray `start()`) can
    /// start it again.
    @discardableResult
    private func retire(_ session: StationSession, id: UUID) -> Task<Void, Never> {
        session.markRetired()
        let prior = pendingStops[id]
        let task = Task {
            await session.stop()
            await prior?.value
        }
        pendingStops[id] = task
        let key = ObjectIdentifier(session)
        retiring[key] = (session, task)
        Task {
            await task.value
            if self.pendingStops[id] == task { self.pendingStops[id] = nil }
            if self.retiring[key]?.stop == task { self.retiring[key] = nil }
        }
        return task
    }

    /// Whether `task` finishes within `deadline`. Doesn't cancel it either way.
    private static func finished(_ task: Task<Void, Never>, within deadline: Duration) async -> Bool {
        final class Once {
            var continuation: CheckedContinuation<Bool, Never>?
            func resume(_ value: Bool) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let once = Once()
        var timer: Task<Void, Never>?
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.continuation = continuation
            Task { @MainActor in
                await task.value
                once.resume(true)
            }
            timer = Task { @MainActor in
                do { try await Task.sleep(for: deadline) } catch { return }
                once.resume(false)
            }
        }
        timer?.cancel()
        return result
    }
}
