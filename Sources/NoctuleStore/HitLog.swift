// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// One logged transmission as the hit log returns it.
public struct LoggedHit: Sendable, Equatable {
    public var hit: Hit
    public var audioPath: String?
    public var audioError: String?
    /// Whether the recording's line-in audio clipped: nil when unknown (a hit logged before
    /// schema version 2, or one with no line-in audio).
    public var audioClipped: Bool?
    /// See `HitQueries.isNewSQL`: conventional and weather, `!programmed`; trunk, this hit is the
    /// one that first sighted its talkgroup.
    public var isNew: Bool
    public init(hit: Hit, audioPath: String?, audioError: String?, isNew: Bool, audioClipped: Bool? = nil) {
        self.hit = hit; self.audioPath = audioPath; self.audioError = audioError; self.isNew = isNew
        self.audioClipped = audioClipped
    }
}

/// All the closed hits for one source, aggregated: a trunk talkgroup (system + TG), or a
/// conventional or weather channel (system + frequency to 4 decimal places).
/// `HitQueries.groups` documents every field.
public struct HitGroup: Sendable, Equatable {
    public var key: HitKey
    public var label: String
    public var hits: Int
    public var talkTime: Double
    public var firstSeen: Date
    public var lastSeen: Date
    public var rssiMax: Int?
    public var programmed: Bool
    public var isNew: Bool
    public var modes: [String]
    public var toneOrCode: String?
    /// The latest non-empty department name.
    public var department: String?
    /// The latest unit id reported, if any hit reported one.
    public var lastUnitID: String?

    /// A stable row id: the key `HitQueries.groups` aggregates by.
    public var id: String { Self.id(for: key) }
    /// The id of the group a hit with `key` belongs to.
    public static func id(for key: HitKey) -> String { HitQueries.groupKey(key) }

    public init(key: HitKey, label: String, hits: Int, talkTime: Double, firstSeen: Date, lastSeen: Date,
                rssiMax: Int?, programmed: Bool, isNew: Bool, modes: [String], toneOrCode: String?,
                department: String? = nil, lastUnitID: String? = nil) {
        self.key = key; self.label = label; self.hits = hits; self.talkTime = talkTime
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.rssiMax = rssiMax
        self.programmed = programmed; self.isNew = isNew; self.modes = modes; self.toneOrCode = toneOrCode
        self.department = department; self.lastUnitID = lastUnitID
    }
}

/// A station's hit log: one SQLite file (WAL, schema version 2). Use one `HitLog` per file; every
/// statement runs on the actor. The connection opens in `init` and closes in `close()` or when the
/// actor is released.
///
/// The runner's sequence for a transmission is `begin` (which records the first sighting and
/// returns `isNew`), then `end`. After a crash, `closeDangling` at the next start
/// closes hits that never got their `end`.
public actor HitLog {
    private let db: SQLiteDB

    public init(url: URL) throws {
        db = try HitLogSchema.open(path: url.path)
    }

    /// Closes the connection. Any later call throws `HitLogError.closed`. Idempotent.
    public func close() { db.close() }

    /// The normal way to log a hit's start. In one transaction, it records the key's first
    /// sighting with `first_seen_at = hit.startedAt` and inserts the hit's row (normally open,
    /// with `endedAt` nil). Returns the hit's `isNew` under the per-hit rule (`HitQueries.isNewSQL`):
    /// conventional and weather, `!programmed`; trunk, true when this call was the key's first
    /// sighting. Because `begin` takes the sighting time from the hit itself, a caller cannot pass
    /// a different time (such as `Date()`) and silently make every trunk hit not new.
    ///
    /// `audioPath` records the recording's path while the hit is still open, so that if the
    /// process dies mid-hit, `closeDangling` keeps the path of the WAV the recorder has already
    /// flushed. Pass it when the path is known at begin time; it defaults to nil.
    @discardableResult
    public func begin(_ hit: Hit, audioPath: String? = nil) throws -> Bool {
        try db.transaction {
            let first = try recordSighting(hit.key, at: hit.startedAt)
            try db.run("INSERT INTO hits (\(HitQueries.columns.replacingOccurrences(of: "hits.", with: ""))) VALUES (\(placeholders))",
                       HitQueries.values(hit, audioPath: audioPath, audioError: nil, audioClipped: nil))
            return hit.key.talkgroupID == nil ? !hit.programmed : first
        }
    }

    /// Writes the hit's final state: every column is replaced from `hit`, and `audioPath` and
    /// `audioError` replace whatever `begin` stored (nil clears them, for example when a too-short
    /// recording was discarded), and so does `audioClipped` (nil: unknown). Inserts the row if
    /// `begin` was never called.
    public func end(_ hit: Hit, audioPath: String?, audioError: String?, audioClipped: Bool? = nil) throws {
        let names = HitQueries.columns.replacingOccurrences(of: "hits.", with: "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let updates = names.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try db.run("INSERT INTO hits (\(names.joined(separator: ", "))) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(updates)",
                   HitQueries.values(hit, audioPath: audioPath, audioError: audioError, audioClipped: audioClipped))
    }

    /// Sets (or clears, with nil) the audio path of hit `id`, typically an open hit right after
    /// its recording file was created, so a crash keeps the WAV findable. Does nothing if no row
    /// has that id.
    public func setAudioPath(id: UUID, path: String?) throws {
        try db.run("UPDATE hits SET audio_path = ? WHERE id = ?",
                   [.optText(path), .text(id.uuidString)])
    }

    /// True if `key` had never been seen before this call. Records it with `first_seen_at = at`
    /// (`INSERT OR IGNORE`, so the first sighting's time is kept).
    ///
    /// `begin` already does this for every hit; this is for other callers. A trunk hit's per-hit
    /// `isNew` is only true when `at` equals that hit's `startedAt` exactly.
    public func isFirstSighting(_ key: HitKey, at: Date) throws -> Bool {
        try recordSighting(key, at: at)
    }

    private func recordSighting(_ key: HitKey, at: Date) throws -> Bool {
        try db.run("INSERT OR IGNORE INTO first_seen (key, first_seen_at) VALUES (?, ?)",
                   [.text(HitQueries.keyString(key)), .double(at.timeIntervalSince1970)]) == 1
    }

    /// Hits matching `f`, newest first, at most `limit`. Open hits are included. `onlyNew` keeps
    /// hits whose per-hit `isNew` is true.
    public func transmissions(_ f: HitFilter, limit: Int = 1000) throws -> [LoggedHit] {
        try loggedHits(f, newestFirst: true, limit: limit)
    }

    /// Closed hits matching `f` (except `onlyNew`), aggregated per key and ordered by `lastSeen`
    /// descending; `onlyNew` then keeps the groups whose group-level `isNew` is true. Open
    /// (dangling) hits are left out until they end or `closeDangling` closes them.
    /// `now` only sets "today" for the trunk new rule when neither `f.since` nor `countsSince` is set.
    public func groups(_ f: HitFilter, countsSince: Date?, now: Date = Date()) throws -> [HitGroup] {
        var (conditions, args) = HitQueries.conditions(f)
        conditions.insert("hits.ended_at IS NOT NULL", at: 0)
        let s = try db.prepare("SELECT \(HitQueries.columns), \(HitQueries.firstSeenSQL) FROM hits"
                               + HitQueries.whereClause(conditions) + " ORDER BY hits.started_at ASC", args)
        var rows: [(hit: Hit, firstSeenAt: Date?)] = []
        while try s.step() {
            rows.append((HitQueries.hit(s).hit, s.double(HitQueries.columnCount).map { Date(timeIntervalSince1970: $0) }))
        }
        return HitQueries.groups(rows: rows, filter: f, countsSince: countsSince, now: now)
    }

    /// Deletes the hits and returns their non-nil audio paths so the caller can delete the files.
    /// `first_seen` is untouched: deleting a talkgroup's hits does not make it new again.
    public func deleteHits(ids: [UUID]) throws -> [String] {
        try db.transaction {
            var paths: [String] = []
            for id in ids {
                let s = try db.prepare("SELECT audio_path FROM hits WHERE id = ?", [.text(id.uuidString)])
                if try s.step(), let p = s.text(0) { paths.append(p) }
                try db.run("DELETE FROM hits WHERE id = ?", [.text(id.uuidString)])
            }
            return paths
        }
    }

    /// Deletes hits that started before `olderThan` and returns their non-nil audio paths.
    /// `first_seen` is untouched.
    public func purge(olderThan: Date) throws -> [String] {
        try db.transaction {
            let cutoff = SQLValue.double(olderThan.timeIntervalSince1970)
            let s = try db.prepare("SELECT audio_path FROM hits WHERE started_at < ? AND audio_path IS NOT NULL", [cutoff])
            var paths: [String] = []
            while try s.step() { if let p = s.text(0) { paths.append(p) } }
            try db.run("DELETE FROM hits WHERE started_at < ?", [cutoff])
            return paths
        }
    }

    /// Every hit matching `f` (no limit), oldest first, as RFC 4180 CSV. See `HitQueries.csv`.
    public func exportCSV(_ f: HitFilter) throws -> String {
        HitQueries.csv(try loggedHits(f, newestFirst: false, limit: nil))
    }

    /// Hit counts per local calendar day of `started_at` (`Calendar.current`), newest day first.
    public func sessions() throws -> [(day: Date, count: Int)] {
        let s = try db.prepare("SELECT started_at FROM hits ORDER BY started_at DESC")
        var result: [(day: Date, count: Int)] = []
        let calendar = Calendar.current
        while try s.step() {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: s.double(0) ?? 0))
            if result.last?.day == day { result[result.count - 1].count += 1 } else { result.append((day, 1)) }
        }
        return result
    }

    /// Closes hits left open by a crash or kill: `ended_at = started_at` (a zero-length record,
    /// since when the transmission really stopped is unknown) and `end_reason = 'interrupted'`.
    /// `audio_path` is kept, so a WAV the recorder had already flushed stays findable. Returns the
    /// number closed. `now` is not used for the end time; it is part of the call for symmetry with
    /// the runner's start-up and in case a later rule needs it.
    public func closeDangling(now: Date) throws -> Int {
        try db.run("UPDATE hits SET ended_at = started_at, end_reason = ? WHERE ended_at IS NULL",
                   [.text(Hit.EndReason.interrupted.rawValue)])
    }

    // MARK: Private

    private var placeholders: String {
        Array(repeating: "?", count: Int(HitQueries.columnCount)).joined(separator: ", ")
    }

    private func loggedHits(_ f: HitFilter, newestFirst: Bool, limit: Int?) throws -> [LoggedHit] {
        var (conditions, args) = HitQueries.conditions(f)
        if f.onlyNew { conditions.append("(\(HitQueries.isNewSQL)) = 1") }
        var sql = "SELECT \(HitQueries.columns), \(HitQueries.isNewSQL) FROM hits" + HitQueries.whereClause(conditions)
            + " ORDER BY hits.started_at \(newestFirst ? "DESC" : "ASC"), hits.id"
        if let limit { sql += " LIMIT ?"; args.append(.int(Int64(limit))) }
        let s = try db.prepare(sql, args)
        var result: [LoggedHit] = []
        while try s.step() {
            let row = HitQueries.hit(s)
            result.append(LoggedHit(hit: row.hit, audioPath: row.audioPath, audioError: row.audioError,
                                    isNew: (s.int(HitQueries.columnCount) ?? 0) != 0,
                                    audioClipped: row.audioClipped))
        }
        return result
    }
}
