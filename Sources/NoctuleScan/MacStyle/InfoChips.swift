// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// One detail chip: a short label and its value ("TGID", "1201").
struct InfoChip: Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

/// The Mac-style view's text, from the scanner's status (`ScannerInfo`).
enum MacStyleText {
    /// Mode, TGID, UID, NAC / tone, frequency (`%.4f MHz`) and RSSI (`<n> dBm`), in that order;
    /// each is left out when the scanner doesn't report it (or reports it empty).
    static func chips(_ info: ScannerInfo?) -> [InfoChip] {
        guard let info else { return [] }
        var chips: [InfoChip] = []
        func add(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return }
            chips.append(InfoChip(label: label, value: value))
        }
        add("Mode", info.modulation)
        add("TGID", info.talkgroupID)
        add("UID", info.unitID)
        let code = codeChip(info.toneOrCode)
        add(code.label, code.value)
        add("Freq", info.frequencyMHz.map { String(format: "%.4f MHz", $0) })
        add("RSSI", info.rssi.map { "\($0) dBm" })
        return chips
    }

    /// The tone or code's chip. The scanner often prefixes the kind ("NAC 2A1h", "CTCSS 100.0Hz"):
    /// that word becomes the label. Otherwise the label is "NAC / Tone".
    static func codeChip(_ raw: String?) -> (label: String, value: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return ("NAC / Tone", nil) }
        let parts = raw.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].allSatisfy({ $0.isLetter && $0.isUppercase }) {
            return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
        }
        return ("NAC / Tone", raw)
    }

    /// "System › Department", leaving out what isn't reported; nil when neither is.
    static func breadcrumb(_ info: ScannerInfo?) -> String? {
        let parts = [info?.system?.name, info?.department?.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }

    /// The big name: the receiving channel's name, else "TG <id>" or the frequency; "Scanning…"
    /// while connected with nothing on the air (`ScannerInfo.isReceiving`: an SDS150 names each
    /// channel it steps through, with `Sig` 0); otherwise the connection phase.
    static func headline(_ info: ScannerInfo?, phase: SessionPhase, stationName: String) -> String {
        guard case .connected = phase else { return ScannerIndicators.phase(phase, stationName: stationName).text }
        guard let info, info.isReceiving else { return "Scanning…" }
        if let name = info.channel?.name.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let tg = info.talkgroupID { return "TG \(tg)" }
        if let mhz = info.frequencyMHz { return String(format: "%.4f MHz", mhz) }
        return "Scanning…"
    }

    /// The scanner's mode and list: "Trunk Scan · Favorites". Nil when neither is reported.
    static func scanning(_ info: ScannerInfo?) -> String? {
        let parts = [info?.mode, info?.monitorList?.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The chips, wrapped onto as many lines as they need.
struct InfoChipsView: View {
    let chips: [InfoChip]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(chips) { chip in
                HStack(spacing: 6) {
                    Text(chip.label).foregroundStyle(.secondary)
                    Text(chip.value).fontWeight(.semibold).monospacedDigit()
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.quaternary))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Lays subviews out left to right, wrapping to a new line when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
#endif
