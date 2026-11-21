// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// SQL fragments, row decoding and CSV formatting for `HitLog`.
enum HitQueries {
    // MARK: Keys

    /// The `first_seen.key` string: `trunk:<system>|<tg>` for trunk keys (a nil system is empty),
    /// `freq:<%.4f>` for conventional and weather keys (`freq:none` with no frequency).
    static func keyString(_ key: HitKey) -> String {
        if let tg = key.talkgroupID { return "trunk:\(key.system ?? "")|\(tg)" }
        return "freq:" + (key.frequencyMHz.map { String(format: "%.4f", $0) } ?? "none")
    }

    /// The trunk key string built in SQL from a `hits` row. It relies on the hit's `system`
    /// column equalling its key's system, which holds for `HitDetector` (both come from
    /// `ScannerInfo.system?.name`). Only trunk keys are built in SQL: conventional "new" does not
    /// need `first_seen`, and grouping by frequency happens in Swift, so SQLite's own `%.4f`
    /// formatting never has to agree with Foundation's.
    static let trunkKeySQL = "'trunk:' || COALESCE(hits.system, '') || '|' || hits.talkgroup_id"

    /// The trunk key's `first_seen_at` for a `hits` row (NULL for conventional rows).
    static let firstSeenSQL = """
        CASE WHEN hits.talkgroup_id IS NULL THEN NULL ELSE \
        (SELECT fs.first_seen_at FROM first_seen fs WHERE fs.key = \(trunkKeySQL)) END
        """

    /// Per-hit "new" (0/1):
    /// - conventional and weather (no talkgroup): `!programmed`;
    /// - trunk: the hit's `started_at` equals its key's `first_seen_at`, i.e. it is the hit that
    ///   first sighted the talkgroup. The comparison is exact on purpose: the runner passes the
    ///   same `Date` (`hit.startedAt`) to `isFirstSighting(_:at:)` and `begin(_:)`, so both
    ///   columns hold the identical REAL. A trunk key with no `first_seen` row is not new.
    static let isNewSQL = """
        CASE WHEN hits.talkgroup_id IS NULL THEN (hits.programmed = 0) \
        ELSE COALESCE((\(firstSeenSQL)) = hits.started_at, 0) END
        """

    /// The key `groups` aggregates by. Trunk: the `keyString`. Conventional and weather: system
    /// plus frequency, so the same frequency in two systems, or a nil-system search hit, forms its
    /// own group (otherwise a programmed channel elsewhere would hide an unprogrammed sighting).
    /// `first_seen` keeps the brief's frequency-only key; conventional "new" doesn't use it.
    static func groupKey(_ key: HitKey) -> String {
        if key.talkgroupID != nil { return keyString(key) }
        let system = key.system.map { "s:" + $0 } ?? "nil"
        return "conv:\(system)|" + (key.frequencyMHz.map { String(format: "%.4f", $0) } ?? "none")
    }

    // MARK: Rows

    static let columns = """
        hits.id, hits.system, hits.department, hits.channel, hits.site, hits.talkgroup_id, \
        hits.frequency_mhz, hits.unit_ids, hits.modulation, hits.tone_or_code, hits.rssi_max, \
        hits.programmed, hits.continued, hits.started_at, hits.ended_at, hits.end_reason, \
        hits.audio_path, hits.audio_error, hits.audio_clipped
        """
    static let columnCount: Int32 = 19

    /// Values for an INSERT of every column, in `columns` order.
    static func values(_ hit: Hit, audioPath: String?, audioError: String?, audioClipped: Bool?) -> [SQLValue] {
        let uids = (try? JSONEncoder().encode(hit.unitIDs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return [
            .text(hit.id.uuidString), .optText(hit.system), .optText(hit.department), .optText(hit.channel),
            .optText(hit.site), .optText(hit.key.talkgroupID), .optDouble(hit.key.frequencyMHz), .text(uids),
            .optText(hit.modulation), .optText(hit.toneOrCode), .optInt(hit.rssiMax),
            .bool(hit.programmed), .bool(hit.continued),
            .double(hit.startedAt.timeIntervalSince1970), .optDouble(hit.endedAt?.timeIntervalSince1970),
            .optText(hit.endReason?.rawValue), .optText(audioPath), .optText(audioError),
            .optBool(audioClipped),
        ]
    }

    /// Decodes a row selected with `columns`. Instants are `Hit.decodedInstantPlaceholder`
    /// (meaningless, as for a JSON-decoded hit). The key is rebuilt from the row: its system is
    /// the hit's system.
    static func hit(_ s: SQLiteStatement) -> (hit: Hit, audioPath: String?, audioError: String?, audioClipped: Bool?) {
        let uids = s.text(7).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let endedAt = s.double(14).map { Date(timeIntervalSince1970: $0) }
        let system = s.text(1)
        let hit = Hit(
            id: s.text(0).flatMap(UUID.init(uuidString:)) ?? UUID(),
            key: HitKey(system: system, talkgroupID: s.text(5), frequencyMHz: s.double(6)),
            startedAt: Date(timeIntervalSince1970: s.double(13) ?? 0),
            endedAt: endedAt,
            startInstant: Hit.decodedInstantPlaceholder,
            endInstant: endedAt == nil ? nil : Hit.decodedInstantPlaceholder,
            system: system, department: s.text(2), channel: s.text(3), site: s.text(4),
            unitIDs: uids, modulation: s.text(8), toneOrCode: s.text(9), rssiMax: s.int(10).map(Int.init),
            programmed: (s.int(11) ?? 1) != 0, continued: (s.int(12) ?? 0) != 0,
            endReason: s.text(15).flatMap(Hit.EndReason.init(rawValue:)))
        return (hit, s.text(16), s.text(17), s.int(18).map { $0 != 0 })
    }

    // MARK: Filters

    /// WHERE conditions for every `HitFilter` field except `onlyNew` (which is hit-level for
    /// transmissions and group-level for groups, so callers apply it themselves).
    ///
    /// - `system` and `toneOrCode`: exact match.
    /// - `modes`: `modulation IN (...)`; empty means any.
    /// - `since`: `started_at >= since`; `until`: `started_at < until`.
    /// - `text` (trimmed; blank means none): a case-insensitive substring of system, department,
    ///   channel, talkgroup id, or the frequency formatted `%.4f`. Matching uses `instr`, so `%` and
    ///   `_` are literal. SQLite's `lower` folds ASCII only.
    static func conditions(_ f: HitFilter) -> (sql: [String], args: [SQLValue]) {
        var sql: [String] = [], args: [SQLValue] = []
        if let system = f.system { sql.append("hits.system = ?"); args.append(.text(system)) }
        if let tone = f.toneOrCode { sql.append("hits.tone_or_code = ?"); args.append(.text(tone)) }
        if !f.modes.isEmpty {
            sql.append("hits.modulation IN (\(Array(repeating: "?", count: f.modes.count).joined(separator: ", ")))")
            args += f.modes.map(SQLValue.text)
        }
        if let since = f.since { sql.append("hits.started_at >= ?"); args.append(.double(since.timeIntervalSince1970)) }
        if let until = f.until { sql.append("hits.started_at < ?"); args.append(.double(until.timeIntervalSince1970)) }
        if let text = f.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let fields = [
                "hits.system", "hits.department", "hits.channel", "hits.talkgroup_id",
                "CASE WHEN hits.frequency_mhz IS NULL THEN NULL ELSE printf('%.4f', hits.frequency_mhz) END",
            ]
            sql.append("(" + fields.map { "instr(lower(COALESCE(\($0), '')), lower(?)) > 0" }.joined(separator: " OR ") + ")")
            args += Array(repeating: .text(text), count: fields.count)
        }
        return (sql, args)
    }

    static func whereClause(_ conditions: [String]) -> String {
        conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    }

    // MARK: Groups

    /// Builds `HitGroup`s from closed hits in ascending `started_at` order.
    ///
    /// - Key: `groupKey` (system + talkgroup, or system + frequency to 4 decimal places);
    ///   `HitGroup.key` is the latest hit's key.
    /// - `hits` and `talkTime` count only hits with `started_at >= countsSince` (ProScan's "reset
    ///   counts"); a group whose hits are all older stays listed with zero counts.
    /// - `firstSeen` is the earliest `started_at` and `lastSeen` the latest `ended_at` among the
    ///   group's hits in the result, regardless of `countsSince`. `rssiMax` likewise.
    /// - `label`: the latest non-empty channel name, else `TG <id>`, else `<%.4f> MHz`.
    /// - `modes`: distinct non-empty modulations in order of first appearance; `toneOrCode`: the
    ///   latest non-empty value; `programmed`: the latest hit's `programmed` (a frequency
    ///   programmed since its unprogrammed sighting is no longer new, and the reverse is new again).
    /// - `department`: the latest non-empty department; `lastUnitID`: the last unit id of the
    ///   latest hit that reported one.
    /// - `isNew` (controller ruling T7): conventional and weather, `!programmed` (latest hit); trunk,
    ///   `first_seen_at >= (filter.since ?? countsSince ?? start of the local day of now)`. A trunk
    ///   key with no `first_seen` row is not new.
    static func groups(
        rows: [(hit: Hit, firstSeenAt: Date?)], filter: HitFilter, countsSince: Date?, now: Date
    ) -> [HitGroup] {
        var order: [String] = []
        var acc: [String: (group: HitGroup, firstSeenAt: Date?)] = [:]
        for (hit, firstSeenAt) in rows {
            let id = groupKey(hit.key)
            let ended = hit.endedAt ?? hit.startedAt
            let counted = countsSince.map { hit.startedAt >= $0 } ?? true
            var entry = acc[id] ?? {
                order.append(id)
                return (HitGroup(key: hit.key, label: "", hits: 0, talkTime: 0, firstSeen: hit.startedAt,
                                 lastSeen: ended, rssiMax: nil, programmed: false, isNew: false,
                                 modes: [], toneOrCode: nil), firstSeenAt)
            }()
            var g = entry.group
            g.key = hit.key
            if counted { g.hits += 1; g.talkTime += ended.timeIntervalSince(hit.startedAt) }
            g.firstSeen = min(g.firstSeen, hit.startedAt)
            g.lastSeen = max(g.lastSeen, ended)
            if let r = hit.rssiMax { g.rssiMax = max(g.rssiMax ?? r, r) }
            g.programmed = hit.programmed
            if let ch = hit.channel, !ch.isEmpty { g.label = ch }
            if let m = hit.modulation, !m.isEmpty, !g.modes.contains(m) { g.modes.append(m) }
            if let t = hit.toneOrCode, !t.isEmpty { g.toneOrCode = t }
            if let d = hit.department, !d.isEmpty { g.department = d }
            if let u = hit.unitIDs.last(where: { !$0.isEmpty }) { g.lastUnitID = u }
            entry.group = g
            entry.firstSeenAt = firstSeenAt ?? entry.firstSeenAt
            acc[id] = entry
        }
        let threshold = filter.since ?? countsSince ?? Calendar.current.startOfDay(for: now)
        var result: [HitGroup] = order.compactMap { id in
            guard let entry = acc[id] else { return nil }
            var g = entry.group
            if g.label.isEmpty {
                if let tg = g.key.talkgroupID { g.label = "TG \(tg)" }
                else if let f = g.key.frequencyMHz { g.label = String(format: "%.4f MHz", f) }
            }
            if g.key.talkgroupID != nil {
                g.isNew = entry.firstSeenAt.map { $0 >= threshold } ?? false
            } else {
                g.isNew = !g.programmed
            }
            return g
        }
        if filter.onlyNew { result.removeAll { !$0.isNew } }
        result.sort { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.label < $1.label }
        return result
    }

    // MARK: CSV

    static let csvHeader = [
        "started", "ended", "duration_s", "system", "department", "channel", "site", "tgid", "uids",
        "frequency_mhz", "mode", "tone_or_code", "rssi_max", "programmed", "new", "audio_path", "audio_clipped",
    ]

    /// RFC 4180: records end with CRLF; a field containing a comma, a double quote, CR or LF is
    /// wrapped in double quotes, with embedded quotes doubled.
    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// One CSV document, oldest hit first. Dates are ISO 8601 in the local time zone with its
    /// offset; `duration_s` has one decimal and is empty for an open hit; `uids` are
    /// space-separated; `frequency_mhz` is `%.4f`; `programmed` and `new` are 1/0; `audio_clipped` is 1, 0 or empty (unknown).
    static func csv(_ rows: [LoggedHit]) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        var out = csvHeader.joined(separator: ",") + "\r\n"
        for row in rows {
            let h = row.hit
            let fields: [String] = [
                iso.string(from: h.startedAt),
                h.endedAt.map { iso.string(from: $0) } ?? "",
                h.endedAt.map { String(format: "%.1f", $0.timeIntervalSince(h.startedAt)) } ?? "",
                h.system ?? "", h.department ?? "", h.channel ?? "", h.site ?? "",
                h.key.talkgroupID ?? "", h.unitIDs.joined(separator: " "),
                h.key.frequencyMHz.map { String(format: "%.4f", $0) } ?? "",
                h.modulation ?? "", h.toneOrCode ?? "", h.rssiMax.map(String.init) ?? "",
                h.programmed ? "1" : "0", row.isNew ? "1" : "0", row.audioPath ?? "",
                row.audioClipped.map { $0 ? "1" : "0" } ?? "",
            ]
            out += fields.map(csvField).joined(separator: ",") + "\r\n"
        }
        return out
    }
}
