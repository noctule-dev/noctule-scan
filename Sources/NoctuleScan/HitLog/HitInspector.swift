// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// What the inspector shows for the current selection: one group (with its transmissions, oldest
/// first, and the units seen across them), one transmission, or a count.
struct InspectedSelection: Equatable {
    var rows: Set<String>
    var group: HitGroup?
    var transmissions: [LoggedHit]
    var units: [String]

    static let empty = InspectedSelection(rows: [], group: nil, transmissions: [], units: [])

    /// The playable recordings, in order (transmissions without a file are skipped).
    var playable: [WAVPlayback.Item] {
        transmissions.compactMap { t in t.audioPath.map { WAVPlayback.Item(id: t.hit.id, url: URL(fileURLWithPath: $0)) } }
    }

    /// Loads it for `model.selection` (one row: details and transmissions; more: the count only).
    @MainActor
    static func load(_ model: HitLogModel) async -> InspectedSelection {
        let rows = model.selection
        guard rows.count == 1, let id = rows.first else {
            return InspectedSelection(rows: rows, group: nil, transmissions: [], units: [])
        }
        switch model.layout {
        case .groups:
            guard let group = model.groups.first(where: { $0.id == id }) else { return .empty }
            let txs = await model.transmissions(for: group)
            return InspectedSelection(rows: rows, group: group, transmissions: txs,
                                      units: Set(txs.flatMap(\.hit.unitIDs)).sorted())
        case .transmissions:
            guard let t = model.transmissions.first(where: { $0.hit.id.uuidString == id }) else { return .empty }
            return InspectedSelection(rows: rows, group: nil, transmissions: [t], units: t.hit.unitIDs)
        }
    }
}

/// The inspector beside the table (design §9.2): details, units seen, and the transmissions, each
/// with play/stop ("no audio: <error>" without a recording; "Clipped" beside a line-in recording
/// that clipped), "Play All in Order" and "Show in Finder".
struct HitInspector: View {
    let model: HitLogModel
    let playback: WAVPlayback
    let showInFinder: () -> Void

    @State private var inspected = InspectedSelection.empty

    private var reloadKey: String {
        // Reload when the selection or the rows behind it change (a new transmission, a delete).
        let rows = model.selection.sorted().joined(separator: ",")
        let groupStamp = model.groups.first { model.selection.contains($0.id) }.map { "\($0.hits)-\($0.lastSeen.timeIntervalSince1970)" } ?? ""
        return "\(model.layout.rawValue)|\(rows)|\(groupStamp)|\(model.transmissions.count)"
    }

    var body: some View {
        Group {
            if model.selection.isEmpty {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                       description: Text("Select a row to see its transmissions and play them."))
            } else if model.selection.count > 1 {
                VStack(spacing: 12) {
                    ContentUnavailableView("\(model.selection.count) Rows Selected", systemImage: "square.stack")
                    Button("Show in Finder", systemImage: "folder", action: showInFinder)
                }
                .padding(.bottom, 24)
            } else {
                details
            }
        }
        .frame(minWidth: 240, idealWidth: 250)
        .task(id: reloadKey) { inspected = await InspectedSelection.load(model) }
    }

    // MARK: Single row

    private var title: String {
        if let group = inspected.group { return group.label }
        if let t = inspected.transmissions.first { return RecentHitText.title(t.hit) }
        return ""
    }

    private var isNew: Bool { inspected.group?.isNew ?? inspected.transmissions.first?.isNew ?? false }

    private var subtitle: String {
        if let group = inspected.group {
            var parts: [String] = []
            if let tg = group.key.talkgroupID { parts.append("TG \(tg)") }
            else if let f = group.key.frequencyMHz { parts.append(RecentHitText.frequency(f)) }
            for p in [group.key.system, group.department] { if let p, !p.isEmpty { parts.append(p) } }
            return parts.joined(separator: " · ")
        }
        guard let h = inspected.transmissions.first?.hit else { return "" }
        var parts = [RecentHitText.detail(h)]
        if let d = h.department, !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        if isNew { NewBadge() }
                    }
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                facts
                if !inspected.units.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Units Seen").font(.headline)
                        Text(inspected.units.joined(separator: ", "))
                            .font(.callout.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
                Divider()
                transmissionsSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            if let g = inspected.group {
                fact("Hits", "\(g.hits)")
                fact("Talk time", HitLogText.talkTime(g.talkTime))
                fact("First", HitLogText.time(g.firstSeen))
                fact("Last", HitLogText.time(g.lastSeen))
                fact("Mode", HitLogText.text(g.modes.joined(separator: ", ")))
                fact("Tone/NAC/CC", HitLogText.text(g.toneOrCode ?? ""))
                fact("RSSI", g.rssiMax.map(String.init) ?? HitLogText.none)
                fact("Programmed", g.programmed ? "Yes" : "No")
            } else if let t = inspected.transmissions.first {
                let h = t.hit
                fact("Started", HitLogText.time(h.startedAt))
                fact("Duration", HitLogText.duration(h.endedAt.map { $0.timeIntervalSince(h.startedAt) } ?? -1))
                fact("Frequency", h.key.frequencyMHz.map(RecentHitText.frequency) ?? HitLogText.none)
                fact("Mode", HitLogText.text(h.modulation ?? ""))
                fact("Tone/NAC/CC", HitLogText.text(h.toneOrCode ?? ""))
                fact("RSSI", h.rssiMax.map(String.init) ?? HitLogText.none)
                fact("Site", HitLogText.text(h.site ?? ""))
                fact("Programmed", h.programmed ? "Yes" : "No")
            }
        }
        .font(.callout)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }

    // MARK: Transmissions

    private var transmissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transmissions").font(.headline)
                Spacer()
                Text("\(inspected.transmissions.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { transmissionButtons }
                VStack(alignment: .leading, spacing: 6) { transmissionButtons }
            }
            .controlSize(.small)
            if let problem = playback.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(inspected.transmissions.enumerated()), id: \.element.hit.id) { index, t in
                    if index > 0 { Divider() }
                    transmissionRow(t)
                }
            }
        }
    }

    @ViewBuilder
    private var transmissionButtons: some View {
        if playback.isPlayingAll {
            Button("Stop", systemImage: "stop.fill") { playback.stop() }
                .fixedSize()
        } else {
            Button("Play All in Order", systemImage: "play.fill") { playback.playAll(inspected.playable) }
                .disabled(inspected.playable.isEmpty)
                .fixedSize()
        }
        Button("Show in Finder", systemImage: "folder", action: showInFinder)
            .disabled(inspected.playable.isEmpty)
            .fixedSize()
    }

    private func transmissionRow(_ t: LoggedHit) -> some View {
        let h = t.hit
        let playing = playback.playingID == h.id
        return HStack(alignment: .center, spacing: 8) {
            if let path = t.audioPath {
                Button {
                    playback.toggle(WAVPlayback.Item(id: h.id, url: URL(fileURLWithPath: path)))
                } label: {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help(playing ? "Stop" : "Play this transmission")
                .accessibilityLabel(playing ? "Stop" : "Play")
            } else {
                Image(systemName: "speaker.slash")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(HitLogText.time(h.startedAt)).monospacedDigit()
                    Text(HitLogText.duration(h.endedAt.map { $0.timeIntervalSince(h.startedAt) } ?? -1))
                        .monospacedDigit().foregroundStyle(.secondary)
                    if t.isNew && inspected.group != nil { NewBadge() }
                    if let clipped = HitLogText.clipped(t) {
                        Label(clipped, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help("The line-in clipped during this transmission: turn the scanner's volume down a step")
                    }
                }
                .font(.callout)
                if let noAudio = HitLogText.noAudio(t) {
                    Text(noAudio).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if !h.unitIDs.isEmpty {
                    Text("UID \(h.unitIDs.joined(separator: ", "))").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .background(playing ? Color.accentColor.opacity(0.08) : .clear)
        .accessibilityElement(children: .contain)
    }
}
#endif
