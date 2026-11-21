// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// One table row, in either layout. Every sortable field is non-optional (a missing value is a
/// sentinel that sorts first ascending) so `KeyPathComparator`s can sort on it.
struct HitRow: Identifiable, Equatable {
    /// `HitGroup.id` for a group row, the hit's UUID string for a transmission row.
    var id: String
    var tgid: String
    /// -1 when there is none.
    var frequency: Double
    var tone: String
    var mode: String
    /// `Int.min` when there is none.
    var rssi: Int
    var uid: String
    var hits: Int
    var talkTime: Double
    var first: Date
    var last: Date
    /// -1 while the transmission is still on air.
    var duration: Double
    var path: String
    /// The non-empty parts of `path` (system, dept, channel), for truncating at the " › " boundaries.
    var pathParts: [String]
    var isNew: Bool

    init(group g: HitGroup) {
        id = g.id
        tgid = g.key.talkgroupID ?? ""
        frequency = g.key.frequencyMHz ?? -1
        tone = g.toneOrCode ?? ""
        mode = g.modes.joined(separator: ", ")
        rssi = g.rssiMax ?? .min
        uid = g.lastUnitID ?? ""
        hits = g.hits
        talkTime = g.talkTime
        first = g.firstSeen
        last = g.lastSeen
        duration = g.talkTime
        pathParts = HitLogText.pathParts(g.key.system, g.department, g.label)
        path = HitLogText.path(pathParts)
        isNew = g.isNew
    }

    init(transmission t: LoggedHit) {
        let h = t.hit
        id = h.id.uuidString
        tgid = h.key.talkgroupID ?? ""
        frequency = h.key.frequencyMHz ?? -1
        tone = h.toneOrCode ?? ""
        mode = h.modulation ?? ""
        rssi = h.rssiMax ?? .min
        uid = h.unitIDs.joined(separator: ", ")
        hits = 1
        talkTime = h.endedAt.map { $0.timeIntervalSince(h.startedAt) } ?? 0
        first = h.startedAt
        last = h.endedAt ?? h.startedAt
        duration = h.endedAt.map { $0.timeIntervalSince(h.startedAt) } ?? -1
        pathParts = HitLogText.pathParts(h.system, h.department, h.channel ?? RecentHitText.title(h))
        path = HitLogText.path(pathParts)
        isNew = t.isNew
    }

    @MainActor static func rows(_ model: HitLogModel) -> [HitRow] {
        switch model.layout {
        case .groups: model.groups.map(HitRow.init(group:))
        case .transmissions: model.transmissions.map(HitRow.init(transmission:))
        }
    }
}

/// How the hit log window words and formats things.
enum HitLogText {
    static let none = "—"

    /// "System › Dept › Channel", skipping empty parts.
    static func path(_ parts: String?...) -> String { path(pathParts(parts)) }

    static func path(_ kept: [String]) -> String { kept.isEmpty ? none : kept.joined(separator: " › ") }

    /// The non-empty, trimmed parts.
    static func pathParts(_ parts: String?...) -> [String] { pathParts(parts) }

    static func pathParts(_ parts: [String?]) -> [String] {
        parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The path's shorter forms, longest first, each dropping whole leading parts:
    /// "S › D › C", "D › C", "C". The channel is always the part that survives.
    static func pathFallbacks(_ parts: [String]) -> [String] {
        guard !parts.isEmpty else { return [none] }
        return parts.indices.map { path(Array(parts[$0...])) }
    }

    static func frequency(_ mhz: Double) -> String { mhz < 0 ? none : String(format: "%.4f", mhz) }

    static func rssi(_ value: Int) -> String { value == .min ? none : "\(value)" }

    static func text(_ s: String) -> String { s.isEmpty ? none : s }

    /// Talk time as ProScan shows it: "m:ss", or "h:mm:ss" from an hour.
    static func talkTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A transmission's length: "2.3 s" under a minute, else "m:ss"; "on air" while open.
    static func duration(_ seconds: Double) -> String {
        if seconds < 0 { return "on air" }
        return seconds < 60 ? String(format: "%.1f s", seconds) : talkTime(seconds)
    }

    /// "HH:mm:ss" on `now`'s day, else the date too ("Nov 7, 22:32:35").
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let clock = RecentHitText.time(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return "\(date.formatted(style)), \(clock)"
    }

    /// A sessions-sidebar day: "Today", "Yesterday", else "Sat, Nov 7" (with the year if not this year).
    static func session(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) { style = style.year() }
        return day.formatted(style)
    }

    /// The delete confirmation (brief: "Delete N rows and move their recordings to the Trash?").
    static func deleteConfirmation(rows n: Int) -> String {
        "Delete \(n) \(n == 1 ? "row" : "rows") and move their recordings to the Trash?"
    }

    /// The export's default file name: "<station name> hits.csv" (no path separators).
    static func csvFileName(stationName: String) -> String {
        let safe = stationName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "Station" : safe) hits.csv"
    }

    /// What a transmission without a recording shows: "no audio: <error>".
    static func noAudio(_ logged: LoggedHit) -> String? {
        guard logged.audioPath == nil else { return nil }
        let reason = logged.audioError?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "no audio: \(reason?.isEmpty == false ? reason! : "not recorded")"
    }

    /// "Clipped" beside a recording whose line-in clipped during the hit (line-in design §5.5); nil
    /// otherwise, and for a hit without a recording.
    static func clipped(_ logged: LoggedHit) -> String? {
        logged.audioPath != nil && logged.audioClipped == true ? "Clipped" : nil
    }
}

/// The table's columns, per design §9.2. Columns can be sorted (in-view, over the loaded rows),
/// reordered, resized and hidden; each layout keeps its own `TableColumnCustomization`.
struct HitTable: View {
    let rows: [HitRow]
    let layout: HitLogLayout
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<HitRow>]
    @Binding var groupColumns: TableColumnCustomization<HitRow>
    @Binding var transmissionColumns: TableColumnCustomization<HitRow>

    var body: some View {
        switch layout {
        case .groups:
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $groupColumns) {
                sourceColumns
                Group {
                    TableColumn("Hits", value: \HitRow.hits) { Text("\($0.hits)").monospacedDigit() }
                        .width(min: 30, ideal: 38).alignment(.trailing).customizationID("hits")
                    TableColumn("Talk time", value: \HitRow.talkTime) { Text(HitLogText.talkTime($0.talkTime)).monospacedDigit() }
                        .width(min: 44, ideal: 56).alignment(.trailing).customizationID("talkTime")
                    TableColumn("First", value: \HitRow.first) { Text(HitLogText.time($0.first)).monospacedDigit() }
                        .width(min: 56, ideal: 60).customizationID("first")
                    TableColumn("Last", value: \HitRow.last) { Text(HitLogText.time($0.last)).monospacedDigit() }
                        .width(min: 56, ideal: 60).customizationID("last")
                    pathColumn
                }
            }
        case .transmissions:
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $transmissionColumns) {
                TableColumn("Time", value: \HitRow.first) { Text(HitLogText.time($0.first)).monospacedDigit() }
                    .width(min: 56, ideal: 64).customizationID("time")
                sourceColumns
                Group {
                    TableColumn("Duration", value: \HitRow.duration) { Text(HitLogText.duration($0.duration)).monospacedDigit() }
                        .width(min: 50, ideal: 64).alignment(.trailing).customizationID("duration")
                    pathColumn
                }
            }
        }
    }

    @TableColumnBuilder<HitRow, KeyPathComparator<HitRow>>
    private var sourceColumns: some TableColumnContent<HitRow, KeyPathComparator<HitRow>> {
        TableColumn("TGID", value: \HitRow.tgid, comparator: .localizedStandard) { Text(HitLogText.text($0.tgid)).monospacedDigit() }
            .width(min: 36, ideal: 46).customizationID("tgid")
        TableColumn("Frequency", value: \HitRow.frequency) { Text(HitLogText.frequency($0.frequency)).monospacedDigit() }
            .width(min: 56, ideal: 66).alignment(.trailing).customizationID("frequency")
        TableColumn("Tone/NAC/CC", value: \HitRow.tone) { Text(HitLogText.text($0.tone)) }
            .width(min: 72, ideal: 86).customizationID("tone")
        TableColumn("Mode", value: \HitRow.mode) { Text(HitLogText.text($0.mode)) }
            .width(min: 32, ideal: 42).customizationID("mode")
        TableColumn("RSSI", value: \HitRow.rssi) { Text(HitLogText.rssi($0.rssi)).monospacedDigit() }
            .width(min: 28, ideal: 34).alignment(.trailing).customizationID("rssi")
        TableColumn("UID", value: \HitRow.uid, comparator: .localizedStandard) { Text(HitLogText.text($0.uid)).monospacedDigit() }
            .width(min: 36, ideal: 54).customizationID("uid")
    }

    private var pathColumn: some TableColumnContent<HitRow, KeyPathComparator<HitRow>> {
        TableColumn("System › Dept › Channel", value: \HitRow.path, comparator: .localizedStandard) { row in
            HStack(spacing: 6) {
                if row.isNew { NewBadge() }
                PathText(parts: row.pathParts)
            }
            .accessibilityElement(children: .combine)
        }
        .width(min: 150, ideal: 250)
        .customizationID("path")
    }
}
/// "System › Dept › Channel" that, when the column is narrow, drops whole leading parts
/// ("Dept › Channel", then "Channel") instead of cutting mid-word; only the channel alone is
/// tail-truncated.
struct PathText: View {
    let parts: [String]

    var body: some View {
        let forms = HitLogText.pathFallbacks(parts)
        ViewThatFits(in: .horizontal) {
            ForEach(Array(forms.dropLast().enumerated()), id: \.offset) { _, form in
                Text(form).lineLimit(1).fixedSize()
            }
            Text(forms.last ?? HitLogText.none).lineLimit(1).truncationMode(.tail)
        }
        .help(HitLogText.path(parts))
    }
}
#endif
