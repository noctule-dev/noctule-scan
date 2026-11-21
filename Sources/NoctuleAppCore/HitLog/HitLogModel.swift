// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import NoctuleKit
import NoctuleStore

public enum HitLogLayout: String, Sendable { case groups, transmissions }

/// Thrown by `HitLogModel.delete` after the rows are gone, when some audio files couldn't be
/// moved to the Trash (a missing file is not an error).
public struct HitLogTrashError: Error, CustomStringConvertible {
    public var failures: [(path: String, error: any Error)]
    public var description: String {
        "couldn't move \(failures.count) file(s) to the Trash: "
            + failures.map { "\($0.path) (\($0.error.localizedDescription))" }.joined(separator: "; ")
    }
}

/// The view model behind the hit log window: layout, filter, search, session day, selection,
/// and the storage actions. No UI framework; the window binds to it.
///
/// Changing `layout`, `filter` or `selectedSession` starts a reload by itself; `searchText` does
/// so after 300 ms of quiet. `reload()` can also be awaited directly. A reload superseded by a
/// newer one is dropped, so slow results never overwrite fresh ones.
@MainActor @Observable
public final class HitLogModel {
    public private(set) var station: Station
    public var layout: HitLogLayout = .groups { didSet { if layout != oldValue { scheduleReload() } } }
    public var filter = HitFilter() { didSet { if filter != oldValue { scheduleReload() } } }
    /// Mapped to `filter.text` after 300 ms.
    public var searchText = "" { didSet { if searchText != oldValue { debounceSearch() } } }
    /// Any moment of the local calendar day to show; nil shows every day.
    public var selectedSession: Date? { didSet { if selectedSession != oldValue { scheduleReload() } } }
    public private(set) var groups: [HitGroup] = []
    public private(set) var transmissions: [LoggedHit] = []
    /// Hit counts per local day, newest first, for the sidebar.
    public private(set) var sessions: [(day: Date, count: Int)] = []
    /// Row ids: `HitGroup.id` for group rows, a hit's UUID string for transmission rows.
    public var selection: Set<String> = []

    @ObservationIgnored private let log: HitLog
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let trash: @Sendable (URL) throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var latest: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var changedTask: Task<Void, Never>?

    public init(station: Station, log: HitLog, settings: any SettingsStore,
                trash: @escaping @Sendable (URL) throws -> Void) {
        self.station = station
        self.log = log
        self.settings = settings
        self.trash = trash
    }

    deinit { searchTask?.cancel(); changedTask?.cancel() }

    // MARK: Loading

    /// The filter as sent to the log: `selectedSession` becomes `since`/`until` for that day.
    /// (`since` also sets the "new" threshold for talkgroups, so a day view shows what first
    /// appeared that day.)
    private var effectiveFilter: HitFilter {
        var f = filter
        if let day = selectedSession {
            let cal = Calendar.current
            let start = cal.startOfDay(for: day)
            f.since = start
            f.until = cal.date(byAdding: .day, value: 1, to: start)
        }
        return f
    }

    private func scheduleReload() { Task { await reload() } }

    /// Reloads for the current layout, filter and session. If a newer reload starts meanwhile,
    /// this one's results are dropped and the call returns when the newest has finished.
    public func reload() async {
        generation += 1
        let mine = generation
        let task = Task { await self.performReload(mine) }
        latest = task
        await task.value
        if mine != generation, let newest = latest { await newest.value }
    }

    private func performReload(_ mine: Int) async {
        let f = effectiveFilter
        let layout = layout
        let countsSince = station.countsResetAt
        do {
            let newSessions = try await log.sessions()
            var newGroups = groups, newTx = transmissions
            switch layout {
            case .groups: newGroups = try await log.groups(f, countsSince: countsSince)
            case .transmissions: newTx = try await log.transmissions(f)
            }
            guard mine == generation else { return }
            sessions = newSessions
            groups = newGroups
            transmissions = newTx
            let valid: Set<String> = layout == .groups
                ? Set(newGroups.map(\.id)) : Set(newTx.map { $0.hit.id.uuidString })
            if !selection.isSubset(of: valid) { selection.formIntersection(valid) }
        } catch {
            // Keep showing the last good rows; a failed read changes nothing.
        }
    }

    private func debounceSearch() {
        searchTask?.cancel()
        let text = searchText
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.filter.text = trimmed.isEmpty ? nil : text
        }
    }

    /// Debounced (500 ms) reload; the window calls it when the session's hits change.
    public func hitsChanged() {
        changedTask?.cancel()
        changedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    // MARK: Inspector

    /// The group's transmissions under the current filter, oldest first.
    public func transmissions(for group: HitGroup) async -> [LoggedHit] {
        var f = effectiveFilter
        f.onlyNew = false  // "new" is a group-level test here
        let all = (try? await log.transmissions(f, limit: 1_000_000)) ?? []
        return all.filter { $0.hit.endedAt != nil && HitGroup.id(for: $0.hit.key) == group.id }
            .sorted { $0.hit.startedAt < $1.hit.startedAt }
    }

    /// The sorted union of unit ids across the group's transmissions.
    public func unitsSeen(in group: HitGroup) async -> [String] {
        Set(await transmissions(for: group).flatMap(\.hit.unitIDs)).sorted()
    }

    /// The transmissions behind row ids (`selection` by default): a group row stands for all of
    /// its transmissions under the current filter, a transmission row for itself. Oldest first
    /// (the order "play all" uses); unknown ids are skipped; each hit appears once.
    public func loggedHits(forRows rows: Set<String>? = nil) async -> [LoggedHit] {
        let rows = rows ?? selection
        var result: [LoggedHit] = []
        var seen = Set<UUID>()
        func add(_ hit: LoggedHit) { if seen.insert(hit.hit.id).inserted { result.append(hit) } }
        switch layout {
        case .groups:
            for group in groups where rows.contains(group.id) {
                for hit in await transmissions(for: group) { add(hit) }
            }
        case .transmissions:
            for hit in transmissions where rows.contains(hit.hit.id.uuidString) { add(hit) }
        }
        return result.sorted { $0.hit.startedAt < $1.hit.startedAt }
    }

    // MARK: Actions

    /// Deletes the hits, then moves their audio files to the Trash. Missing files are skipped;
    /// other Trash errors are thrown (as `HitLogTrashError`) after every deletion is done.
    public func delete(_ ids: [UUID]) async throws {
        let paths = try await log.deleteHits(ids: ids)
        var failures: [(path: String, error: any Error)] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            do { try trash(URL(fileURLWithPath: path)) } catch { failures.append((path, error)) }
        }
        await reload()
        if !failures.isEmpty { throw HitLogTrashError(failures: failures) }
    }

    /// Every hit matching the current filter and session, oldest first.
    public func exportCSV() async throws -> String {
        try await log.exportCSV(effectiveFilter)
    }

    /// Re-reads the station from the store, so a rename, saved filter or counts reset made in
    /// another window shows here. Reloads the rows if `countsResetAt` changed. A station that is
    /// gone, or a store that can't be read, leaves the current copy alone.
    public func refreshStation() async {
        guard let stored = try? await settings.stations().first(where: { $0.id == station.id }),
              stored != station else { return }
        let countsChanged = stored.countsResetAt != station.countsResetAt
        station = stored
        if countsChanged { await reload() }
    }

    /// Sets the station's `countsResetAt` to now (only that field, atomically in the store).
    /// Throws `StationNoLongerExists` if the station was deleted.
    public func resetCounts() async throws {
        let now = Date()
        station = try await updateStation { $0.countsResetAt = now }
        await reload()
    }

    /// Saves the current filter (without the session day) under `named`, as a new entry.
    public func saveFilter(named name: String) async throws {
        var saved = filter
        saved.id = UUID()
        saved.name = name
        let entry = saved
        station = try await updateStation { $0.savedFilters.append(entry) }
    }

    public func deleteFilter(_ id: UUID) async throws {
        station = try await updateStation { $0.savedFilters.removeAll { $0.id == id } }
    }

    /// Changes only the fields `mutate` touches, in one store-side read-modify-write, so edits
    /// another window saved meanwhile (a rename, a view choice, a filter) are kept.
    private func updateStation(_ mutate: @escaping @Sendable (inout Station) -> Void) async throws -> Station {
        guard let updated = try await settings.update(id: station.id, mutate) else {
            throw StationNoLongerExists(id: station.id)
        }
        return updated
    }
}
