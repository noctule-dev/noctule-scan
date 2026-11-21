// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleKit
import NoctuleStore
import SwiftUI

/// How a hit reads in the recent list.
enum RecentHitText {
    /// The channel's name, else "TG <id>", else the frequency, else "Unknown".
    static func title(_ hit: Hit) -> String {
        if let channel = hit.channel?.trimmingCharacters(in: .whitespaces), !channel.isEmpty { return channel }
        if let tg = hit.key.talkgroupID, !tg.isEmpty { return "TG \(tg)" }
        if let mhz = hit.key.frequencyMHz { return frequency(mhz) }
        return "Unknown"
    }

    /// The talkgroup or frequency, then the system: "TG 1201 · Testville".
    static func detail(_ hit: Hit) -> String {
        var parts: [String] = []
        if let tg = hit.key.talkgroupID, !tg.isEmpty { parts.append("TG \(tg)") }
        else if let mhz = hit.key.frequencyMHz { parts.append(frequency(mhz)) }
        if let system = hit.system?.trimmingCharacters(in: .whitespaces), !system.isEmpty { parts.append(system) }
        return parts.joined(separator: " · ")
    }

    static func frequency(_ mhz: Double) -> String { String(format: "%.4f MHz", mhz) }

    /// "Active now": the newest hit still open (`endedAt == nil`), if any. `hits` is newest first.
    static func activeHit(_ hits: [LoggedHit]) -> LoggedHit? { hits.first { $0.hit.endedAt == nil } }

    /// "HH:mm:ss" in `calendar`'s time zone.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

/// The small "New" capsule on a new hit (an unprogrammed frequency or a first-seen talkgroup),
/// shared by the recent hits and the hit log.
struct NewBadge: View {
    var body: some View {
        Text("New")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            .foregroundStyle(Color.accentColor)
            .fixedSize()
    }
}

/// The session's recent hits, newest first: channel, TG or frequency, start time, a `New` badge,
/// and a live dot while the transmission is on air. With `showsActiveNow` (the Mac-style view),
/// the open hit is pulled out above the list as "Active now". "Open Hit Log" opens the full log.
struct RecentHitsList: View {
    let hits: [LoggedHit]
    var showsActiveNow = false
    let openHitLog: () -> Void

    /// The sidebar's width: room for a two-line title beside the `New` badge and the time.
    static let width: CGFloat = 300

    private var active: LoggedHit? { showsActiveNow ? RecentHitText.activeHit(hits) : nil }
    private var listed: [LoggedHit] {
        guard let active else { return hits }
        return hits.filter { $0.hit.id != active.hit.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Hits").font(.headline)
                Spacer()
                Text("\(hits.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if let active { activeNow(active) }

            if listed.isEmpty && active == nil {
                ContentUnavailableView("No Hits Yet", systemImage: "waveform",
                                       description: Text("Transmissions appear here as the scanner stops on them."))
                    .frame(maxHeight: .infinity)
            } else {
                // A plain stack, not a `List`: a List's outline view becomes first responder on
                // a click and would keep the scanner's keyboard shortcuts from working.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(listed.enumerated()), id: \.element.hit.id) { index, hit in
                            if index > 0 { Divider().padding(.leading, 30) }
                            row(hit).padding(.horizontal, 14).padding(.vertical, 5)
                        }
                    }
                }
            }

            Divider()
            Button(action: openHitLog) {
                Label("Open Hit Log", systemImage: "list.bullet.rectangle.portrait")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .tracksKeyboardFocus()
            .padding(10)
        }
    }

    private func activeNow(_ logged: LoggedHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Active now", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            HStack(alignment: .firstTextBaseline) {
                Text(RecentHitText.title(logged.hit)).font(.title3.weight(.semibold)).lineLimit(2)
                if logged.isNew { NewBadge() }
                Spacer(minLength: 4)
                Text(RecentHitText.time(logged.hit.startedAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(RecentHitText.detail(logged.hit)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private func row(_ logged: LoggedHit) -> some View {
        let hit = logged.hit
        let live = hit.endedAt == nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(live ? Color.green : Color.clear)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(RecentHitText.title(hit)).font(.body.weight(.medium)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if logged.isNew { NewBadge() }
                }
                Text(RecentHitText.detail(hit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text(RecentHitText.time(hit.startedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(live ? "on air" : "")
    }
}
#endif
