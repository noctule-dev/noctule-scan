// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import SwiftUI

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// The scanner's screen, drawn from `STS`: each row in a monospaced font (large rows at 1.6×),
/// highlighted segments in reverse video from the palette, and the three soft keys under it.
/// A menu screen is drawn the same way; underlined segments are a menu title.
struct DisplayView: View {
    let display: DisplayModel?
    /// The model's screen: its columns size the screen, and a model with no soft-key line gets no
    /// soft-key buttons (hidden, not disabled).
    var layout: DisplayLayout = .sds
    let palette: DisplayPalette
    /// Shown in place of the rows when there is no display yet (connecting, no answer, …).
    let placeholder: String
    let keysEnabled: Bool
    let press: (FrontPanelKey) -> Void

    static var baseSize: CGFloat { DisplayRowsView.baseSize }

    var body: some View {
        VStack(spacing: 10) {
            screen
            if layout.hasSoftKeyLine { softKeys }
        }
    }

    private var screen: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(palette.background))
            if let display {
                DisplayRowsView(display: display, palette: palette)
            } else {
                Text(placeholder)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(palette.text).opacity(0.7))
                    .padding()
            }
        }
        .frame(width: Self.screenWidth(columns: layout.columns), height: Self.screenHeight)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanner display")
    }

    /// Wide enough for `columns` columns of the base font.
    static func screenWidth(columns: Int) -> CGFloat { CGFloat(columns) * baseSize * 0.6 + 20 }
    static let screenHeight: CGFloat = 318

    /// The soft key's face: a bullet for an icon, the capitalised label, or a space when blank.
    static func softKeyTitle(_ key: SoftKey?) -> String {
        guard let key else { return " " }
        if key.isGlyph { return "•" }
        return key.label.isEmpty ? " " : key.label.capitalized
    }

    private var softKeys: some View {
        HStack(spacing: 12) {
            ForEach(Array([FrontPanelKey.soft1, .soft2, .soft3].enumerated()), id: \.offset) { index, key in
                let softKey = display?.softKeys.first(where: { $0.key == key })
                let label = softKey?.label ?? ""
                Button { press(key) } label: {
                    Text(Self.softKeyTitle(softKey))
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelKeyStyle(height: 24))
                .disabled(!keysEnabled)
                .accessibilityLabel(label.isEmpty ? "Soft key \(index + 1)" : label.capitalized)
                .help(label.isEmpty ? "Soft key \(index + 1)" : "Soft key \(index + 1): \(label)")
            }
        }
        .frame(width: Self.screenWidth(columns: layout.columns) + 14)
    }
}
/// The rows of a scanner screen as `DisplayView` draws them (monospaced, large rows at 1.6×,
/// highlights in reverse video, menu titles underlined), on whatever background the caller gives
/// them; the Mac-style menu reuses it for screens the scanner doesn't describe.
struct DisplayRowsView: View {
    let display: DisplayModel
    let palette: DisplayPalette

    static let baseSize: CGFloat = 13
    static let largeScale: CGFloat = 1.6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(display.rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rowView(_ row: DisplayRow) -> some View {
        let size = row.large ? Self.baseSize * Self.largeScale : Self.baseSize
        return HStack(spacing: 0) {
            ForEach(Array(Self.trimmed(row.segments).enumerated()), id: \.offset) { _, segment in
                Text(segment.text)
                    .foregroundStyle(Color(segment.highlighted ? palette.highlightText : palette.text))
                    .background(segment.highlighted ? Color(palette.highlightBackground) : .clear)
                    .underline(segment.underlined)
            }
        }
        .font(.system(size: size, weight: row.large ? .semibold : .regular, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(height: size * 1.22, alignment: .leading)
    }

    /// Drops trailing spaces that aren't highlighted, so a large row's padding doesn't shrink it.
    static func trimmed(_ segments: [DisplaySegment]) -> [DisplaySegment] {
        var result = segments
        while let last = result.last, !last.highlighted {
            let text = String(last.text.reversed().drop(while: { $0 == " " }).reversed())
            if text.isEmpty { result.removeLast() } else { result[result.count - 1].text = text; break }
        }
        return result
    }
}
#endif
