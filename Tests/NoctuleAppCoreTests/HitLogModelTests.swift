// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleStore
@testable import NoctuleAppCore

/// Fictional hits only. Seeds a temp HitLog with two trunk talkgroups over two days and one
/// conventional channel.
@MainActor
@Suite(.timeLimit(.minutes(3))) struct HitLogModelTests {
    final class Trashed: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.withLock { _urls } }
        func add(_ u: URL) { lock.withLock { _urls.append(u) } }
    }

    struct Rig {
        let dir: URL
        let log: HitLog
        let settings: LocalSettingsStore
        let station: Station
        let model: HitLogModel
        let trashed: Trashed
        let day1: Date   // start of local day, older
        let day2: Date   // start of the next local day
        var hits: [String: Hit]
    }

    static func hit(tg: String?, freq: Double? = nil, system: String, channel: String, start: Date,
                    units: [String] = [], programmed: Bool = true) -> Hit {
        Hit(id: UUID(), key: HitKey(system: system, talkgroupID: tg, frequencyMHz: freq),
            startedAt: start, endedAt: start.addingTimeInterval(2),
            startInstant: .now, endInstant: .now,
            system: system, department: "Dept", channel: channel, site: nil,
            unitIDs: units, modulation: "NFM", toneOrCode: nil, rssiMax: 3,
            programmed: programmed, endReason: .signalLost)
    }

    static func makeRig(files: [String: String] = [:]) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-hitlogmodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))
        let settings = LocalSettingsStore(directory: dir)
        var station = Station()
        station.name = "Test Station"
        try await settings.save(station)
        let cal = Calendar.current
        let day1 = cal.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let day2 = cal.date(byAdding: .day, value: 1, to: day1)!
        let sys = "Fictional County P25"
        var hits: [String: Hit] = [:]
        func put(_ name: String, _ h: Hit) async throws {
            hits[name] = h
            _ = try await log.begin(h)
            try await log.end(h, audioPath: files[name], audioError: nil)
        }
        try await put("fire1", hit(tg: "4711", system: sys, channel: "Fire Dispatch",
                                   start: day1.addingTimeInterval(10 * 3600), units: ["100201", "100200"]))
        try await put("fire2", hit(tg: "4711", system: sys, channel: "Fire Dispatch",
                                   start: day1.addingTimeInterval(11 * 3600), units: ["100202", "100200"]))
        try await put("pw", hit(tg: "4712", system: sys, channel: "Public Works",
                                start: day2.addingTimeInterval(9 * 3600), units: ["100300"]))
        try await put("marina", hit(tg: nil, freq: 155.1234, system: "Fictional Valley", channel: "Marina Ops",
                                    start: day2.addingTimeInterval(10 * 3600), programmed: true))
        let trashed = Trashed()
        let model = HitLogModel(station: station, log: log, settings: settings,
                                trash: { trashed.add($0) })
        return Rig(dir: dir, log: log, settings: settings, station: station, model: model,
                   trashed: trashed, day1: day1, day2: day2, hits: hits)
    }

    @Test func groupsByDefault() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.model.reload()
        #expect(r.model.layout == .groups)
        #expect(r.model.groups.count == 3)
        #expect(r.model.groups.first(where: { $0.label.contains("Fire") })?.hits == 2)
        #expect(Set(r.model.groups.map(\.id)).count == 3)
        #expect(r.model.sessions.count == 2)
    }

    @Test func toggleShowsTransmissions() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        r.model.layout = .transmissions
        await r.model.reload()
        #expect(r.model.transmissions.count == 4)
        #expect(r.model.transmissions.first?.hit.id == r.hits["marina"]?.id)  // newest first
    }

    @Test func searchFilters() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.model.reload()
        r.model.searchText = "public works"
        try await waitUntil("search applied") { r.model.groups.count == 1 }
        #expect(r.model.filter.text == "public works")
        #expect(r.model.groups.first?.label.contains("Public Works") == true)
    }

    @Test func sessionSelectsDay() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        r.model.layout = .transmissions
        r.model.selectedSession = r.day1.addingTimeInterval(3600)  // any time that day
        await r.model.reload()
        #expect(Set(r.model.transmissions.map(\.hit.id)) == [r.hits["fire1"]!.id, r.hits["fire2"]!.id])
        r.model.selectedSession = r.day2
        await r.model.reload()
        #expect(r.model.transmissions.count == 2)
        r.model.selectedSession = nil
        await r.model.reload()
        #expect(r.model.transmissions.count == 4)
    }

    @Test func deleteTrashesFiles() async throws {
        let a = "/tmp/noctule-test-\(UUID().uuidString)-a.wav"
        let b = "/tmp/noctule-test-\(UUID().uuidString)-missing.wav"
        let r = try await Self.makeRig(files: ["fire1": a, "fire2": b])
        defer { try? FileManager.default.removeItem(at: r.dir); try? FileManager.default.removeItem(atPath: a) }
        FileManager.default.createFile(atPath: a, contents: Data([0]))
        r.model.layout = .transmissions
        await r.model.reload()
        r.model.selection = [r.hits["fire1"]!.id.uuidString]
        try await r.model.delete([r.hits["fire1"]!.id, r.hits["fire2"]!.id])
        #expect(r.trashed.urls == [URL(fileURLWithPath: a)])
        #expect(r.model.transmissions.count == 2)
        #expect(r.model.selection.isEmpty)
    }

    @Test func deleteCollectsTrashErrorsAfterAllDeletions() async throws {
        struct Boom: Error {}
        let a = "/tmp/noctule-test-\(UUID().uuidString)-a.wav"
        let b = "/tmp/noctule-test-\(UUID().uuidString)-b.wav"
        let r = try await Self.makeRig(files: ["fire1": a, "fire2": b])
        FileManager.default.createFile(atPath: a, contents: Data([0]))
        FileManager.default.createFile(atPath: b, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: r.dir); try? FileManager.default.removeItem(atPath: a); try? FileManager.default.removeItem(atPath: b) }
        let seen = Trashed()
        let model = HitLogModel(station: r.station, log: r.log, settings: r.settings,
                                trash: { seen.add($0); throw Boom() })
        await #expect(throws: (any Error).self) {
            try await model.delete([r.hits["fire1"]!.id, r.hits["fire2"]!.id])
        }
        #expect(seen.urls.count == 2)  // the second was still tried
        await model.reload()
        #expect(model.groups.filter { $0.label.contains("Fire") }.isEmpty)
    }

    @Test func resetCountsPersists() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        #expect(r.model.station.countsResetAt == nil)
        try await r.model.resetCounts()
        let at = try #require(r.model.station.countsResetAt)
        let stored = try await r.settings.stations().first { $0.id == r.station.id }
        #expect(abs((stored?.countsResetAt ?? .distantPast).timeIntervalSince(at)) < 1)
    }

    /// R18: the model's station copy is stale once another window saves a filter or renames the
    /// station; resetting counts must keep both.
    @Test func resetCountsKeepsAFilterSavedElsewhere() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        var other = HitFilter(); other.name = "From another window"; other.onlyNew = true
        let entry = other
        try await r.settings.update(id: r.station.id) { $0.savedFilters.append(entry); $0.name = "Renamed" }
        try await r.model.resetCounts()
        let stored = try #require(try await r.settings.stations().first { $0.id == r.station.id })
        #expect(stored.savedFilters == [entry])
        #expect(stored.name == "Renamed")
        #expect(stored.countsResetAt != nil)
        #expect(r.model.station.savedFilters == [entry] && r.model.station.name == "Renamed")
        // And a filter saved here keeps the other one too.
        try await r.model.saveFilter(named: "Mine")
        #expect(try await r.settings.stations().first?.savedFilters.map(\.name) == ["From another window", "Mine"])
    }

    @Test func stationActionsOnADeletedStationThrowAndDoNotRecreateIt() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        try await r.settings.deleteStation(id: r.station.id)
        await #expect(throws: StationNoLongerExists.self) { try await r.model.resetCounts() }
        await #expect(throws: StationNoLongerExists.self) { try await r.model.saveFilter(named: "X") }
        #expect(try await r.settings.stations().isEmpty)
    }

    /// Delete and Show in Finder act on every transmission behind the selected rows.
    @Test func loggedHitsForRowsExpandsGroups() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.model.reload()
        let fire = try #require(r.model.groups.first { $0.label == "Fire Dispatch" })
        let marina = try #require(r.model.groups.first { $0.label == "Marina Ops" })
        r.model.selection = [fire.id, marina.id]
        let ids = await r.model.loggedHits().map(\.hit.id)
        #expect(ids == [r.hits["fire1"]!.id, r.hits["fire2"]!.id, r.hits["marina"]!.id])
        #expect(await r.model.loggedHits(forRows: ["no such row"]).isEmpty)

        r.model.layout = .transmissions
        await r.model.reload()
        let pw = r.hits["pw"]!.id
        #expect(await r.model.loggedHits(forRows: [pw.uuidString]).map(\.hit.id) == [pw])
    }

    /// Minor 4 (QA): the window re-reads the station, so a rename elsewhere shows in its title.
    @Test func refreshStationPicksUpChangesMadeElsewhere() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.model.reload()
        let fire = try #require(r.model.groups.first { $0.label == "Fire Dispatch" })
        #expect(fire.hits == 2)
        // Renamed, and counts reset after every seeded hit, in another window.
        let resetAt = r.day2.addingTimeInterval(23 * 3600)
        try await r.settings.update(id: r.station.id) { $0.name = "Renamed"; $0.countsResetAt = resetAt }
        await r.model.refreshStation()
        #expect(r.model.station.name == "Renamed")
        #expect(r.model.groups.first { $0.label == "Fire Dispatch" }?.hits == 0)  // reloaded with the reset
        // Gone: the copy stays.
        try await r.settings.deleteStation(id: r.station.id)
        await r.model.refreshStation()
        #expect(r.model.station.name == "Renamed")
    }

    @Test func savedFilterRoundTrips() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        r.model.filter.onlyNew = true
        r.model.filter.system = "Fictional County P25"
        try await r.model.saveFilter(named: "New on county")
        let saved = try #require(r.model.station.savedFilters.first)
        #expect(saved.name == "New on county")
        #expect(saved.onlyNew && saved.system == "Fictional County P25")
        let stored = try await r.settings.stations().first { $0.id == r.station.id }
        #expect(stored?.savedFilters == [saved])
        try await r.model.deleteFilter(saved.id)
        #expect(r.model.station.savedFilters.isEmpty)
        let after = try await r.settings.stations().first { $0.id == r.station.id }
        #expect(after?.savedFilters.isEmpty == true)
    }

    @Test func unitsSeenUnion() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.model.reload()
        let fire = try #require(r.model.groups.first { $0.label.contains("Fire") })
        #expect(await r.model.unitsSeen(in: fire) == ["100200", "100201", "100202"])
    }

    @Test func inspectorOldestFirst() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.model.reload()
        let fire = try #require(r.model.groups.first { $0.label.contains("Fire") })
        let ts = await r.model.transmissions(for: fire)
        #expect(ts.map(\.hit.id) == [r.hits["fire1"]!.id, r.hits["fire2"]!.id])
    }

    @Test func exportCSVHonoursFilter() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        r.model.selectedSession = r.day2
        let csv = try await r.model.exportCSV()
        #expect(csv.contains("Public Works") && csv.contains("Marina Ops") && !csv.contains("Fire Dispatch"))
    }

    @Test func hitsChangedReloadsDebounced() async throws {
        let r = try await Self.makeRig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        await r.model.reload()
        #expect(r.model.groups.count == 3)
        let h = Self.hit(tg: "4713", system: "Fictional County P25", channel: "Parks", start: r.day2.addingTimeInterval(12 * 3600))
        _ = try await r.log.begin(h)
        try await r.log.end(h, audioPath: nil, audioError: nil)
        r.model.hitsChanged(); r.model.hitsChanged()
        try await waitUntil("reload") { r.model.groups.count == 4 }
    }
}
