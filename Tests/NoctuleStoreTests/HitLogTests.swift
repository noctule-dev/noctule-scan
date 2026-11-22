// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import SQLite3
import Synchronization
import Testing
import NoctuleKit
@testable import NoctuleStore

/// Every test uses its own temp-file database and removes its folder afterwards. All values are
/// fictional. Dates are whole or quarter seconds so they survive the REAL Unix-seconds round trip
/// exactly.
@Suite(.timeLimit(.minutes(3))) struct HitLogTests {
    private func tempDB() -> (dir: URL, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-hitlog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("hits.sqlite"))
    }

    /// Local noon on a fixed day, so a few hours either side stay on the same local day.
    private let noon: Date = {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        return day.addingTimeInterval(12 * 3600)
    }()

    private func trunk(
        tg: String = "4711", system: String = "Fictional County P25", channel: String? = "Fire Dispatch",
        start: Date, duration: Double? = 2, mode: String? = "NFM", tone: String? = nil, rssi: Int? = 3,
        programmed: Bool = true
    ) -> Hit {
        Hit(id: UUID(), key: HitKey(system: system, talkgroupID: tg, frequencyMHz: nil),
            startedAt: start, endedAt: duration.map { start.addingTimeInterval($0) },
            startInstant: .now, endInstant: duration == nil ? nil : .now,
            system: system, department: "Fire", channel: channel, site: "North Site",
            unitIDs: ["100200", "100201"], modulation: mode, toneOrCode: tone, rssiMax: rssi,
            programmed: programmed, endReason: duration == nil ? nil : .signalLost)
    }

    private func conv(
        freq: Double = 155.1234, system: String = "Fictional Valley", channel: String? = "Marina Ops",
        start: Date, duration: Double? = 2, mode: String? = "AM", tone: String? = nil,
        programmed: Bool = false
    ) -> Hit {
        Hit(id: UUID(), key: HitKey(system: system, talkgroupID: nil, frequencyMHz: freq),
            startedAt: start, endedAt: duration.map { start.addingTimeInterval($0) },
            startInstant: .now, endInstant: duration == nil ? nil : .now,
            system: system, department: "Harbor", channel: channel, site: nil,
            unitIDs: [], modulation: mode, toneOrCode: tone, rssiMax: 2,
            programmed: programmed, endReason: duration == nil ? nil : .signalLost)
    }

    /// A hit as the log returns it: the runtime-only instants are placeholders.
    private func normalized(_ h: Hit) -> Hit {
        var h = h
        h.startInstant = Hit.decodedInstantPlaceholder
        h.endInstant = h.endedAt == nil ? nil : Hit.decodedInstantPlaceholder
        return h
    }

    /// Logs a finished hit the way the runner does: `begin` (which records the sighting), then `end`.
    private func log(_ hit: Hit, in log: HitLog, audioPath: String? = nil) async throws {
        try await log.begin(hit)
        if hit.endedAt != nil { try await log.end(hit, audioPath: audioPath, audioError: nil) }
    }

    @Test func beginEndRoundTrip() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        var hit = trunk(start: noon, duration: nil)
        try await log.begin(hit)
        var rows = try await log.transmissions(HitFilter())
        #expect(rows.count == 1)
        #expect(rows.first?.hit == normalized(hit))
        #expect(rows.first?.hit.endedAt == nil && rows.first?.audioPath == nil)

        hit.endedAt = noon.addingTimeInterval(4.25)
        hit.endInstant = .now
        hit.endReason = .channelChanged
        hit.rssiMax = 5
        hit.unitIDs.append("100202")
        try await log.end(hit, audioPath: "/rec/a.wav", audioError: "disk full")
        rows = try await log.transmissions(HitFilter())
        #expect(rows.count == 1)
        #expect(rows.first?.hit == normalized(hit))
        #expect(rows.first?.audioPath == "/rec/a.wav")
        #expect(rows.first?.audioError == "disk full")

        // Conventional hit with a frequency, read back by a second instance on the same file.
        let c = conv(start: noon.addingTimeInterval(10), duration: 1.5, tone: "CTCSS 100.0")
        try await log.begin(c)
        try await log.end(c, audioPath: nil, audioError: nil)
        await log.close()
        let reopened = try HitLog(url: url)
        let again = try await reopened.transmissions(HitFilter())
        #expect(again.map(\.hit) == [normalized(c), normalized(hit)])  // newest first
    }

    @Test func firstSightingOnlyOnce() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let tg = HitKey(system: "Fictional County P25", talkgroupID: "4711", frequencyMHz: nil)
        let other = HitKey(system: "Fictional County P25", talkgroupID: "4712", frequencyMHz: nil)
        let freq = HitKey(system: "Fictional Valley", talkgroupID: nil, frequencyMHz: 155.1234)
        #expect(try await log.isFirstSighting(tg, at: noon))
        #expect(try await !log.isFirstSighting(tg, at: noon.addingTimeInterval(5)))
        #expect(try await log.isFirstSighting(other, at: noon))
        #expect(try await log.isFirstSighting(freq, at: noon))
        #expect(try await !log.isFirstSighting(freq, at: noon.addingTimeInterval(5)))
        await log.close()
        #expect(try await !HitLog(url: url).isFirstSighting(tg, at: noon.addingTimeInterval(9)))
    }

    @Test func newRules() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let unprogrammed = conv(start: noon, programmed: false)
        let programmed = conv(freq: 460.5, channel: "Yard", start: noon.addingTimeInterval(1), programmed: true)
        let first = trunk(start: noon.addingTimeInterval(10))
        let second = trunk(start: noon.addingTimeInterval(20))
        for h in [unprogrammed, programmed, first, second] { try await self.log(h, in: log) }

        let rows = try await log.transmissions(HitFilter())
        let isNew = Dictionary(uniqueKeysWithValues: rows.map { ($0.hit.id, $0.isNew) })
        #expect(isNew[unprogrammed.id] == true)
        #expect(isNew[programmed.id] == false)
        #expect(isNew[first.id] == true)
        #expect(isNew[second.id] == false)

        // Group: no since and no countsSince, so the trunk group is new if first seen today.
        let now = noon.addingTimeInterval(3600)
        let groups = try await log.groups(HitFilter(), countsSince: nil, now: now)
        let byLabel = Dictionary(uniqueKeysWithValues: groups.map { ($0.label, $0) })
        #expect(byLabel["Fire Dispatch"]?.isNew == true)
        #expect(byLabel["Marina Ops"]?.isNew == true)
        #expect(byLabel["Yard"]?.isNew == false)
        // Seen yesterday: not new today.
        let tomorrow = now.addingTimeInterval(24 * 3600)
        let later = try await log.groups(HitFilter(), countsSince: nil, now: tomorrow)
        #expect(later.first { $0.label == "Fire Dispatch" }?.isNew == false)
        // countsSince stands in for the start of the day.
        let reset = try await log.groups(HitFilter(), countsSince: noon.addingTimeInterval(15), now: now)
        #expect(reset.first { $0.label == "Fire Dispatch" }?.isNew == false)
        // A filter `since` after the first sighting: the group is not new.
        var f = HitFilter(); f.since = noon.addingTimeInterval(15)
        let sinceGroups = try await log.groups(f, countsSince: nil, now: now)
        #expect(sinceGroups.first { $0.label == "Fire Dispatch" }?.isNew == false)
        var g = HitFilter(); g.since = noon.addingTimeInterval(5)
        #expect(try await log.groups(g, countsSince: nil, now: now).first { $0.label == "Fire Dispatch" }?.isNew == true)
    }

    @Test func groupsAggregate() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let h1 = trunk(tg: "9", channel: "Old Name", start: noon, duration: 1.5, mode: "NFM", rssi: 2)
        let h2 = trunk(tg: "9", channel: "", start: noon.addingTimeInterval(60), duration: 2.0, mode: "FM",
                       tone: "NAC 293", rssi: 5)
        let h3 = trunk(tg: "9", channel: "New Name", start: noon.addingTimeInterval(120), duration: 3.25,
                       mode: "NFM", tone: nil, rssi: 4)
        let dangling = trunk(tg: "9", start: noon.addingTimeInterval(200), duration: nil)
        let unnamed = trunk(tg: "77", channel: nil, start: noon.addingTimeInterval(10), duration: 1)
        let freqOnly = conv(freq: 453.25, channel: nil, start: noon.addingTimeInterval(5), duration: 1, programmed: true)
        for h in [h1, h2, h3, dangling, unnamed, freqOnly] { try await self.log(h, in: log) }

        let groups = try await log.groups(HitFilter(), countsSince: nil, now: noon)
        #expect(groups.count == 3)
        let g = try #require(groups.first { $0.key.talkgroupID == "9" })
        #expect(g.hits == 3)
        #expect(g.talkTime == 6.75)
        #expect(g.firstSeen == noon)
        #expect(g.lastSeen == noon.addingTimeInterval(123.25))
        #expect(g.label == "New Name")
        #expect(g.rssiMax == 5)
        #expect(g.modes == ["NFM", "FM"])
        #expect(g.toneOrCode == "NAC 293")
        #expect(g.programmed)
        #expect(groups.map(\.key.talkgroupID) == ["9", "77", nil])  // lastSeen descending
        #expect(groups[1].label == "TG 77")
        #expect(groups[2].label == "453.2500 MHz")
    }

    /// The group layout's UID and System › Dept › Channel columns.
    @Test func groupsCarryDepartmentAndLastUnit() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        var h1 = trunk(tg: "9", start: noon, duration: 1)
        h1.unitIDs = ["100300", "100301"]
        var h2 = trunk(tg: "9", start: noon.addingTimeInterval(60), duration: 1)
        h2.unitIDs = []
        h2.department = ""
        let c = conv(start: noon.addingTimeInterval(5), duration: 1)
        for h in [h1, h2, c] { try await self.log(h, in: log) }
        let groups = try await log.groups(HitFilter(), countsSince: nil, now: noon)
        let g = try #require(groups.first { $0.key.talkgroupID == "9" })
        #expect(g.department == "Fire")
        #expect(g.lastUnitID == "100301")
        let m = try #require(groups.first { $0.key.talkgroupID == nil })
        #expect(m.department == "Harbor")
        #expect(m.lastUnitID == nil)
    }

    @Test func countsResetRespected() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        for (i, d) in [1.0, 2.0, 4.5].enumerated() {
            try await self.log(trunk(tg: "9", start: noon.addingTimeInterval(Double(i) * 100), duration: d), in: log)
        }
        try await self.log(trunk(tg: "10", channel: "Quiet", start: noon.addingTimeInterval(-50), duration: 3), in: log)
        let groups = try await log.groups(HitFilter(), countsSince: noon.addingTimeInterval(150), now: noon)
        let g = try #require(groups.first { $0.key.talkgroupID == "9" })
        #expect(g.hits == 1)
        #expect(g.talkTime == 4.5)
        #expect(g.firstSeen == noon)  // first/last still describe the whole history
        let quiet = try #require(groups.first { $0.key.talkgroupID == "10" })
        #expect(quiet.hits == 0 && quiet.talkTime == 0)
        let all = try await log.groups(HitFilter(), countsSince: nil, now: noon)
        #expect(all.first { $0.key.talkgroupID == "9" }?.hits == 3)
    }

    @Test func filters() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let a1 = trunk(start: noon, mode: "NFM")                                  // new (first sighting)
        let a2 = trunk(start: noon.addingTimeInterval(30), mode: "NFM")           // not new
        let b = conv(start: noon.addingTimeInterval(60), mode: "AM", tone: "CTCSS 100.0", programmed: false)
        let c = conv(freq: 460.5, system: "Fictional Port", channel: "Crane Yard",
                     start: noon.addingTimeInterval(90), mode: "NFM", tone: "DCS 023", programmed: true)
        for h in [a1, a2, b, c] { try await self.log(h, in: log) }

        func ids(_ f: HitFilter) async throws -> Set<UUID> { Set(try await log.transmissions(f).map(\.hit.id)) }
        var f = HitFilter(); f.onlyNew = true
        #expect(try await ids(f) == [a1.id, b.id])
        f = HitFilter(); f.modes = ["AM"]
        #expect(try await ids(f) == [b.id])
        f.modes = ["AM", "NFM"]
        #expect(try await ids(f) == [a1.id, a2.id, b.id, c.id])
        f = HitFilter(); f.toneOrCode = "DCS 023"
        #expect(try await ids(f) == [c.id])
        f = HitFilter(); f.text = "fire DISPATCH"
        #expect(try await ids(f) == [a1.id, a2.id])
        f.text = "county"
        #expect(try await ids(f) == [a1.id, a2.id])
        f.text = "4711"
        #expect(try await ids(f) == [a1.id, a2.id])
        f.text = "155.12"
        #expect(try await ids(f) == [b.id])
        f.text = "crane"
        #expect(try await ids(f) == [c.id])
        f.text = "100%_"  // LIKE wildcards are matched literally
        #expect(try await ids(f).isEmpty)
        f = HitFilter(); f.system = "Fictional Port"
        #expect(try await ids(f) == [c.id])
        f = HitFilter(); f.since = noon.addingTimeInterval(30)
        #expect(try await ids(f) == [a2.id, b.id, c.id])
        #expect(try await log.transmissions(HitFilter(), limit: 2).map(\.hit.id) == [c.id, b.id])

        // Group-level onlyNew: the trunk group (first seen today) and the unprogrammed channel.
        f = HitFilter(); f.onlyNew = true
        let groups = try await log.groups(f, countsSince: nil, now: noon)
        #expect(Set(groups.map(\.label)) == ["Fire Dispatch", "Marina Ops"])
        #expect(groups.first { $0.label == "Fire Dispatch" }?.hits == 2)
    }

    @Test func deleteReturnsPaths() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let h1 = trunk(start: noon), h2 = trunk(start: noon.addingTimeInterval(10)), h3 = trunk(start: noon.addingTimeInterval(20))
        try await self.log(h1, in: log, audioPath: "/rec/1.wav")
        try await self.log(h2, in: log, audioPath: "/rec/2.wav")
        try await self.log(h3, in: log, audioPath: nil)
        let paths = try await log.deleteHits(ids: [h1.id, h3.id, UUID()])
        #expect(paths == ["/rec/1.wav"])
        #expect(try await log.transmissions(HitFilter()).map(\.hit.id) == [h2.id])
        // Deleting hits does not make the talkgroup new again.
        #expect(try await !log.isFirstSighting(h1.key, at: noon.addingTimeInterval(99)))
    }

    @Test func purgeByAge() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let day = 24.0 * 3600
        let old1 = trunk(start: noon.addingTimeInterval(-10 * day))
        let old2 = conv(start: noon.addingTimeInterval(-5 * day))
        let recent = trunk(start: noon.addingTimeInterval(-1 * day))
        try await self.log(old1, in: log, audioPath: "/rec/old1.wav")
        try await self.log(old2, in: log, audioPath: "/rec/old2.wav")
        try await self.log(recent, in: log, audioPath: "/rec/recent.wav")
        let paths = try await log.purge(olderThan: noon.addingTimeInterval(-3 * day))
        #expect(Set(paths) == ["/rec/old1.wav", "/rec/old2.wav"])
        #expect(try await log.transmissions(HitFilter()).map(\.hit.id) == [recent.id])
        #expect(try await log.purge(olderThan: noon.addingTimeInterval(-3 * day)).isEmpty)
    }

    @Test func csvQuoting() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let h = trunk(channel: "Pier \"7\", North", start: noon, duration: 2.5)
        let multi = conv(channel: "Line1\nLine2", start: noon.addingTimeInterval(10), duration: 1)
        try await self.log(h, in: log, audioPath: "/rec/pier.wav")
        try await self.log(multi, in: log)
        let csv = try await log.exportCSV(HitFilter())
        let header = "started,ended,duration_s,system,department,channel,site,tgid,uids,frequency_mhz,mode,tone_or_code,rssi_max,programmed,new,audio_path,audio_clipped"
        #expect(csv.hasPrefix(header + "\r\n"))

        let iso = ISO8601DateFormatter(); iso.timeZone = .current; iso.formatOptions = [.withInternetDateTime]
        let start = iso.string(from: noon), end = iso.string(from: noon.addingTimeInterval(2.5))
        let row = "\(start),\(end),2.5,Fictional County P25,Fire,\"Pier \"\"7\"\", North\",North Site,4711,100200 100201,,NFM,,3,1,1,/rec/pier.wav,"
        #expect(csv.contains("\r\n" + row + "\r\n"))
        #expect(csv.contains(",\"Line1\nLine2\","))
        #expect(csv.contains(",155.1234,AM,"))
        // Header, two records, trailing CRLF: chronological order, oldest first.
        #expect(csv.components(separatedBy: "\r\n").count == 4)
        let pier = try #require(csv.range(of: "Pier")), line1 = try #require(csv.range(of: "Line1"))
        #expect(pier.lowerBound < line1.lowerBound)
    }

    @Test func danglingClosedAsInterrupted() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try HitLog(url: url)
        let open = trunk(start: noon, duration: nil)
        #expect(try await first.begin(open, audioPath: "/rec/partial.wav"))
        // Simulated crash: the actor goes away without `end`.
        await first.close()

        let log = try HitLog(url: url)
        #expect(try await log.groups(HitFilter(), countsSince: nil, now: noon).isEmpty)  // dangling excluded
        #expect(try await log.closeDangling(now: noon.addingTimeInterval(3600)) == 1)
        let row = try #require(try await log.transmissions(HitFilter()).first)
        #expect(row.hit.endReason == .interrupted)
        #expect(row.hit.endedAt == open.startedAt)
        #expect(row.audioPath == "/rec/partial.wav")
        #expect(row.isNew)
        #expect(try await log.closeDangling(now: noon.addingTimeInterval(3600)) == 0)
        let groups = try await log.groups(HitFilter(), countsSince: nil, now: noon)
        #expect(groups.count == 1 && groups[0].hits == 1 && groups[0].talkTime == 0)
    }

    @Test func schemaVersionSet() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        try await log.begin(trunk(start: noon))
        await log.close()
        _ = try HitLog(url: url)  // reopening an existing v2 database works

        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        func scalar(_ sql: String) -> String? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        }
        #expect(scalar("PRAGMA user_version") == "2")
        #expect(scalar("PRAGMA journal_mode") == "wal")
        #expect(scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND tbl_name = 'hits' AND sql IS NOT NULL") == "3")
        #expect(scalar("SELECT count(*) FROM first_seen") == "1")  // begin recorded the sighting
    }

    // MARK: Schema version 2 (audio_clipped)

    /// Writes a version 1 file: the v1 schema and one closed hit, no `audio_clipped` column. It is in
    /// WAL mode, as every file the version 1 build opened is.
    private func makeVersionOneFile(at url: URL, hitID: UUID, version: Int = 1) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let sql = "PRAGMA journal_mode=WAL;" + HitLogSchema.v1 + """
            ;INSERT INTO hits (id, system, channel, talkgroup_id, unit_ids, programmed, continued, started_at, ended_at,
                               end_reason, audio_path)
            VALUES ('\(hitID.uuidString)', 'Fictional County P25', 'Fire Dispatch', '4711', '[]', 1, 0,
                    \(noon.timeIntervalSince1970), \(noon.timeIntervalSince1970 + 2), 'signalLost', '/rec/old.wav');
            PRAGMA user_version = \(version);
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func userVersion(of url: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    @Test func migratesVersionOneInPlace() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try makeVersionOneFile(at: url, hitID: id)
        #expect(userVersion(of: url) == "1")

        let log = try HitLog(url: url)
        let rows = try await log.transmissions(HitFilter())
        #expect(rows.count == 1)
        #expect(rows.first?.hit.id == id)
        #expect(rows.first?.audioPath == "/rec/old.wav")
        #expect(rows.first?.audioClipped == nil)
        await log.close()
        #expect(userVersion(of: url) == "2")

        // Opening it again is a no-op, and the migrated file takes the new column.
        let again = try HitLog(url: url)
        let hit = trunk(tg: "4712", start: noon.addingTimeInterval(60))
        try await again.begin(hit)
        try await again.end(hit, audioPath: nil, audioError: nil, audioClipped: true)
        let clipped = try await again.transmissions(HitFilter()).first { $0.hit.id == hit.id }
        #expect(clipped?.audioClipped == true)
    }

    @Test func newDatabaseEndsAtVersionTwo() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        await log.close()
        #expect(userVersion(of: url) == "2")
    }

    @Test func endStoresClipped() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let clipped = trunk(tg: "4711", start: noon)
        let clean = trunk(tg: "4712", start: noon.addingTimeInterval(10))
        let unknown = trunk(tg: "4713", start: noon.addingTimeInterval(20))
        let open = trunk(tg: "4714", start: noon.addingTimeInterval(30), duration: nil)
        for h in [clipped, clean, unknown, open] { try await log.begin(h) }
        try await log.end(clipped, audioPath: "/rec/a.wav", audioError: nil, audioClipped: true)
        try await log.end(clean, audioPath: "/rec/b.wav", audioError: nil, audioClipped: false)
        try await log.end(unknown, audioPath: "/rec/c.wav", audioError: nil)
        let rows = try await log.transmissions(HitFilter())
        func clippedFlag(_ h: Hit) -> Bool?? { rows.first { $0.hit.id == h.id }.map(\.audioClipped) }
        #expect(clippedFlag(clipped) == .some(true))
        #expect(clippedFlag(clean) == .some(false))
        #expect(clippedFlag(unknown) == .some(nil))
        #expect(clippedFlag(open) == .some(nil))
    }

    @Test func csvHasAudioClippedLast() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let a = trunk(tg: "4711", start: noon), b = trunk(tg: "4712", start: noon.addingTimeInterval(10))
        let c = trunk(tg: "4713", start: noon.addingTimeInterval(20))
        for h in [a, b, c] { try await log.begin(h) }
        try await log.end(a, audioPath: "/rec/a.wav", audioError: nil, audioClipped: true)
        try await log.end(b, audioPath: "/rec/b.wav", audioError: nil, audioClipped: false)
        try await log.end(c, audioPath: "/rec/c.wav", audioError: nil)
        let csv = try await log.exportCSV(HitFilter())
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0].hasSuffix(",audio_path,audio_clipped"))
        #expect(lines[1].hasSuffix(",/rec/a.wav,1"))
        #expect(lines[2].hasSuffix(",/rec/b.wav,0"))
        #expect(lines[3].hasSuffix(",/rec/c.wav,"))
    }

    @Test func newerSchemaStillRefused() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeVersionOneFile(at: url, hitID: UUID(), version: 3)
        #expect(throws: HitLogError.unsupportedSchemaVersion(3)) { try HitLog(url: url) }
        #expect(userVersion(of: url) == "3")
    }

    /// Opens `url` from `count` `HitLog`s on as many threads at once, and returns each open's
    /// error, or nil for an open that succeeded.
    /// The test waits for them without blocking its own (cooperative) thread: the opens retry a
    /// busy file for up to 5 s each (LESSONS.md 2026-11-22).
    private func openAtOnce(_ url: URL, count: Int) async -> [String?] {
        let results = Mutex([String?](repeating: nil, count: count))
        let go = DispatchSemaphore(value: 0), done = DispatchGroup()  // off the cooperative pool: the threads below wait on them
        for i in 0..<count {
            done.enter()
            Thread {
                go.wait()  // off the cooperative pool: its own Thread
                do { _ = try HitLog(url: url) } catch { results.withLock { $0[i] = "\(error)" } }
                done.leave()
            }.start()
        }
        for _ in 0..<count { go.signal() }  // release them together
        await withCheckedContinuation { continuation in done.notify(queue: .global()) { continuation.resume() } }
        return results.withLock { $0 }
    }

    /// The session and the hit-log window (or `noctule hits` and the app) can open a version 1
    /// log at the same moment: every open must succeed, and the file is migrated once.
    @Test func concurrentOpensMigrateVersionOneOnce() async throws {
        for _ in 0..<30 {
            let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
            try makeVersionOneFile(at: url, hitID: UUID())
            let errors = await openAtOnce(url, count: 4).compactMap { $0 }
            #expect(errors.isEmpty, "\(errors)")
            #expect(userVersion(of: url) == "2")
            if !errors.isEmpty { return }
        }
    }

    /// The same for a brand-new file: one open creates the schema, the others find it there.
    @Test func concurrentOpensCreateANewLogOnce() async throws {
        for _ in 0..<30 {
            let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
            let errors = await openAtOnce(url, count: 4).compactMap { $0 }
            #expect(errors.isEmpty, "\(errors)")
            #expect(userVersion(of: url) == "2")
            if !errors.isEmpty { return }
        }
    }

    @Test func sessionsByLocalDay() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let day = 24.0 * 3600
        for offset in [-day, -day + 60, 0, 60, 120] {
            try await self.log(trunk(start: noon.addingTimeInterval(offset)), in: log)
        }
        let sessions = try await log.sessions()
        let today = Calendar.current.startOfDay(for: noon)
        let yesterday = Calendar.current.startOfDay(for: noon.addingTimeInterval(-day))
        #expect(sessions.map(\.day) == [today, yesterday])
        #expect(sessions.map(\.count) == [3, 2])
    }
    // MARK: Follow-up (QA P5 and the begin/first-sighting trap)

    @Test func conventionalGroupsBySystemAndFrequency() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let countyA = conv(freq: 154.43, system: "County A", channel: "A Fire", start: noon, programmed: true)
        let countyB = conv(freq: 154.43, system: "County B", channel: "B Fire",
                           start: noon.addingTimeInterval(10), programmed: true)
        var search = conv(freq: 154.43, system: "", channel: nil, start: noon.addingTimeInterval(20), programmed: false)
        search.system = nil; search.key.system = nil
        for h in [countyA, countyB, search] { try await self.log(h, in: log) }
        let groups = try await log.groups(HitFilter(), countsSince: nil, now: noon)
        #expect(groups.count == 3)
        let nilGroup = try #require(groups.first { $0.key.system == nil })
        #expect(nilGroup.isNew && !nilGroup.programmed && nilGroup.hits == 1)
        #expect(nilGroup.label == "154.4300 MHz")
        #expect(groups.filter { $0.key.system != nil }.allSatisfy { !$0.isNew && $0.programmed })
        var f = HitFilter(); f.onlyNew = true
        #expect(try await log.groups(f, countsSince: nil, now: noon).map(\.key.system) == [nil])
    }

    @Test func groupProgrammedIsLatestHit() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        // Unprogrammed, then programmed: the latest wins, so programmed and not new.
        try await self.log(conv(freq: 151.25, start: noon, programmed: false), in: log)
        try await self.log(conv(freq: 151.25, start: noon.addingTimeInterval(60), programmed: true), in: log)
        // Programmed, then unprogrammed (for example, removed from the favorites): new.
        try await self.log(conv(freq: 152.5, start: noon, programmed: true), in: log)
        try await self.log(conv(freq: 152.5, start: noon.addingTimeInterval(60), programmed: false), in: log)
        let groups = try await log.groups(HitFilter(), countsSince: nil, now: noon)
        let a = try #require(groups.first { $0.key.frequencyMHz == 151.25 })
        #expect(a.programmed && !a.isNew && a.hits == 2)
        let b = try #require(groups.first { $0.key.frequencyMHz == 152.5 })
        #expect(!b.programmed && b.isNew && b.hits == 2)
    }

    @Test func beginRecordsFirstSighting() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        // A start time with sub-microsecond precision (as Date() gives) must still match exactly.
        let precise = Date(timeIntervalSinceReferenceDate: noon.timeIntervalSinceReferenceDate + 0.123456789)
        let first = trunk(start: precise), second = trunk(start: precise.addingTimeInterval(30.000000417))
        #expect(try await log.begin(first))
        #expect(try await !log.begin(second))
        #expect(try await log.begin(conv(start: noon, programmed: false)))
        #expect(try await !log.begin(conv(freq: 460.5, start: noon, programmed: true)))
        let isNew = Dictionary(uniqueKeysWithValues: try await log.transmissions(HitFilter()).map { ($0.hit.id, $0.isNew) })
        #expect(isNew[first.id] == true && isNew[second.id] == false)
        // The sighting is recorded: a later explicit check sees it.
        #expect(try await !log.isFirstSighting(first.key, at: Date()))
    }

    @Test func setAudioPathOnAnOpenHitSurvivesCloseDangling() async throws {
        let (dir, url) = tempDB(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: url)
        let open = trunk(start: noon, duration: nil)
        let other = trunk(tg: "4712", start: noon.addingTimeInterval(1), duration: nil)
        try await log.begin(open, audioPath: nil)
        try await log.begin(other, audioPath: nil)
        try await log.setAudioPath(id: open.id, path: "/rec/open.wav")
        var rows = try await log.transmissions(HitFilter())
        #expect(rows.first { $0.hit.id == open.id }?.audioPath == "/rec/open.wav")
        #expect(rows.first { $0.hit.id == other.id }?.audioPath == nil)
        #expect(rows.first { $0.hit.id == open.id }?.hit.endedAt == nil)

        // A crash: the next start closes it and keeps the path.
        #expect(try await log.closeDangling(now: noon.addingTimeInterval(60)) == 2)
        rows = try await log.transmissions(HitFilter())
        #expect(rows.first { $0.hit.id == open.id }?.audioPath == "/rec/open.wav")

        // nil clears it; an unknown id is a no-op.
        try await log.setAudioPath(id: open.id, path: nil)
        try await log.setAudioPath(id: UUID(), path: "/rec/none.wav")
        rows = try await log.transmissions(HitFilter())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.audioPath == nil })
    }
}
