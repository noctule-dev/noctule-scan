// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

public struct DisplaySegment: Equatable, Sendable {
    public var text: String
    public var highlighted: Bool
    /// The mask character `_` (a menu's title line).
    public var underlined: Bool
    public init(text: String, highlighted: Bool, underlined: Bool = false) {
        self.text = text; self.highlighted = highlighted; self.underlined = underlined
    }
}

public struct DisplayRow: Equatable, Sendable {
    public var segments: [DisplaySegment]
    public var large: Bool
    public init(segments: [DisplaySegment], large: Bool) { self.segments = segments; self.large = large }
}

public struct SoftKey: Equatable, Sendable {
    public var key: FrontPanelKey
    public var label: String
    /// The label has no printable ASCII (the icons of a name-entry screen); `label` is then "".
    public var isGlyph: Bool
    public init(key: FrontPanelKey, label: String, isGlyph: Bool = false) {
        self.key = key; self.label = label; self.isGlyph = isGlyph
    }
}

public struct DisplayModel: Equatable, Sendable {
    public var rows: [DisplayRow]
    public var softKeys: [SoftKey]
    public var isMenu: Bool

    public init(status: DisplayStatus, info: ScannerInfo?) {
        let menu = info?.isMenu ?? false
        isMenu = menu
        let keys: [FrontPanelKey] = [.soft1, .soft2, .soft3]
        if menu && info?.menuScreenKind != .input {
            // A menu list has no soft-key row: every line is a row.
            rows = status.lines.map(Self.row)
            softKeys = []
        } else {
            // The last STS line is the soft-key row; it is not a display row.
            rows = status.lines.dropLast().map(Self.row)
            if menu, let last = status.lines.last {
                softKeys = zip(keys, Self.softKeyRanges).map { Self.softKey($0, line: last.text, columns: $1) }
            } else {
                softKeys = zip(keys, status.softKeyLabels).map { SoftKey(key: $0, label: $1) }
            }
        }
    }

    /// The scan screen's soft-key mask widths: columns 0..<9, 10..<20, 21..<30.
    private static let softKeyRanges: [Range<Int>] = [0..<9, 10..<20, 21..<30]

    private static func softKey(_ key: FrontPanelKey, line: String, columns: Range<Int>) -> SoftKey {
        let group = line.enumerated().filter { columns.contains($0.offset) }.map(\.element)
        let printable = group.contains { Self.isPrintable($0) && $0 != " " }
        if printable {
            return SoftKey(key: key, label: String(group.filter { Self.isPrintable($0) }).trimmingCharacters(in: .whitespaces))
        }
        let blank = group.allSatisfy { $0 == " " }
        return SoftKey(key: key, label: "", isGlyph: !blank)
    }

    private static func isPrintable(_ ch: Character) -> Bool {
        ch.unicodeScalars.count == 1 && (0x20...0x7E).contains(ch.unicodeScalars.first!.value)
    }

    /// The soft key whose label matches, ignoring case and surrounding spaces.
    public func softKey(labelled label: String) -> FrontPanelKey? {
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        return softKeys.first { $0.label.lowercased() == wanted }?.key
    }

    private static func row(_ line: DisplayStatus.Line) -> DisplayRow {
        let mask = Array(line.highlightMask)
        var segments: [DisplaySegment] = []
        for (i, ch) in line.text.enumerated() {
            let c = isPrintable(ch) ? ch : "·"
            let hl = i < mask.count && mask[i] == "*"
            let ul = i < mask.count && mask[i] == "_"
            if let last = segments.last, last.highlighted == hl, last.underlined == ul {
                segments[segments.count - 1].text.append(c)
            } else {
                segments.append(DisplaySegment(text: String(c), highlighted: hl, underlined: ul))
            }
        }
        return DisplayRow(segments: segments, large: line.sizeFlag == "1")
    }
}
