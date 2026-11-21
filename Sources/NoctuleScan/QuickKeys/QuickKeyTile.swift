// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// What one switch (a tile, the header's "Scan this list", a system's or a department's) shows for its
/// `QuickKeySwitchState` (design §5.4, §5.5 "States"): on or off only from a read made since this open;
/// busy, in a menu, under a shared system key and while the other lists are checked it keeps showing the state
/// read but takes no click;
/// unknown, checking, unavailable, unreported and no-quick-key show no on/off (a neutral look).
struct QuickKeySwitchLook: Equatable {
    /// Nil for the neutral look.
    let isOn: Bool?
    /// Only `.on` and `.off` take a click.
    let isEnabled: Bool
    /// A change to this row's scope is under way: the working look.
    let isBusy: Bool

    /// `raw` is the row's state from the model's last read (`QuickKeyListItem.state`, `SystemRow.state`,
    /// `ChildRow.state`).
    init(state: QuickKeySwitchState, raw: QuickKeyState?) {
        let read: Bool? = switch raw {
        case .some(.on): true
        case .some(.off): false
        default: nil
        }
        switch state {
        case .on: isOn = true
        case .off: isOn = false
        case .busy, .inMenu, .sharedSystemKey, .sharedListKey, .checkingOtherLists: isOn = read
        case .unknown, .checking, .unavailable, .unreported, .noQuickKey: isOn = nil
        }
        isEnabled = state == .on || state == .off
        isBusy = state == .busy
    }
}

/// A keypad tile's look (design §5.5 "Colors"): blue fill and border on, gray off, neutral when no state
/// was read; a green ring on the list being scanned; an outline with a pointer on the list whose tree
/// is open.
struct QuickKeyTileLook: Equatable {
    enum Fill: Equatable { case on, off, neutral }

    let fill: Fill
    let hasScanningRing: Bool
    let hasShownOutline: Bool

    init(state: QuickKeySwitchState, raw: QuickKeyState?, isScanning: Bool, isShown: Bool) {
        fill = switch QuickKeySwitchLook(state: state, raw: raw).isOn {
        case .some(true): .on
        case .some(false): .off
        case nil: .neutral
        }
        hasScanningRing = isScanning
        hasShownOutline = isShown
    }
}

/// The pop-over's colours, adapted to light and dark (the mockups are the dark theme).
enum QuickKeyColors {
    static let onFill = Color(nsColor: .systemBlue).opacity(0.30)
    static let onBorder = Color(nsColor: .systemBlue)
    static let offFill = Color.primary.opacity(0.07)
    static let offBorder = Color.primary.opacity(0.16)
    static let neutralFill = Color.primary.opacity(0.035)
    static let neutralBorder = Color.primary.opacity(0.12)
    static let scanning = Color(nsColor: .systemGreen)
    static let shown = Color.primary
    static let highlight = Color(nsColor: .keyboardFocusIndicatorColor)
    static let switchOff = Color.primary.opacity(0.28)
    static let lines = Color.primary.opacity(0.22)

    static func fill(_ fill: QuickKeyTileLook.Fill) -> Color {
        switch fill {
        case .on: onFill
        case .off: offFill
        case .neutral: neutralFill
        }
    }

    static func border(_ fill: QuickKeyTileLook.Fill) -> Color {
        switch fill {
        case .on: onBorder
        case .off: offBorder
        case .neutral: neutralBorder
        }
    }
}

/// A key's tag (`F1`, `S0`, `D2`): blue while its row is on.
struct QuickKeyBadge: View {
    let text: String
    var isOn: Bool? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(isOn == true ? Color.white : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 22)
            .background(isOn == true ? QuickKeyColors.onBorder : Color.primary.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A small text tag ("site", "Avoided", "shared", "no quick key", "Not monitored").
struct QuickKeyTag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.45), lineWidth: 0.5))
    }
}

/// A row's on/off switch, drawn as the mockups' small switch so it can also show neutral (no state read)
/// and working (busy). A toggle for accessibility; one click is one `toggle`.
struct QuickKeySwitch: View {
    let look: QuickKeySwitchLook
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule().fill(trackColor)
                if look.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(Color.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                        .offset(x: knobOffset)
                }
            }
            .frame(width: 30, height: 17)
            .opacity(look.isOn == nil ? 0.55 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tracksKeyboardFocus()
        .disabled(!look.isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(QuickKeysText.accessibilityValue(isOn: look.isOn) ?? "")
        .accessibilityAddTraits(.isToggle)
    }

    private var trackColor: Color {
        switch look.isOn {
        case .some(true): QuickKeyColors.onBorder
        case .some(false): QuickKeyColors.switchOff
        case nil: QuickKeyColors.neutralBorder
        }
    }

    private var knobOffset: CGFloat {
        switch look.isOn {
        case .some(true): 6.5
        case .some(false): -6.5
        case nil: 0
        }
    }
}

/// One keypad tile (design §5.5 "The keypad", "Clicks"): the key large, the list's name under it (two
/// lines), and in its top-right corner a small "n ›" button with its number of systems. A click on the
/// tile toggles the list; the corner button shows its tree and changes nothing.
struct QuickKeyTile: View {
    let item: QuickKeyListItem
    let state: QuickKeySwitchState
    let isScanning: Bool
    let isShown: Bool
    let isHighlighted: Bool
    let sharing: Int
    let toggle: () -> Void
    let showTree: () -> Void

    static let minHeight: CGFloat = 66
    private static let shape = RoundedRectangle(cornerRadius: 10)

    var body: some View {
        let look = QuickKeyTileLook(state: state, raw: item.state, isScanning: isScanning, isShown: isShown)
        let switchLook = QuickKeySwitchLook(state: state, raw: item.state)
        ZStack(alignment: .topTrailing) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.key.map(String.init) ?? "–")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(look.fill == .neutral ? Color.secondary : Color.primary)
                    Text(item.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.monitored {
                        Text(QuickKeysText.notMonitoredTag)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.top, 7)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .topLeading)
                .background(QuickKeyColors.fill(look.fill), in: Self.shape)
                .overlay(Self.shape.strokeBorder(QuickKeyColors.border(look.fill), lineWidth: 1))
                .overlay {
                    if look.hasScanningRing { Self.shape.strokeBorder(QuickKeyColors.scanning, lineWidth: 2) }
                }
                .contentShape(Self.shape)
            }
            .buttonStyle(.plain)
            .tracksKeyboardFocus()
            .disabled(!switchLook.isEnabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(QuickKeysText.tileAccessibilityLabel(name: item.name, key: item.key))
            .accessibilityValue(QuickKeysText.accessibilityValue(isOn: switchLook.isOn) ?? "")
            .accessibilityAddTraits(.isToggle)

            Button(action: showTree) {
                Text(QuickKeysText.cornerButtonTitle(systemCount: item.systemCount))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isShown ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(isShown ? QuickKeyColors.shown : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tracksKeyboardFocus()
            .padding(5)
            .accessibilityLabel(QuickKeysText.cornerButtonLabel(name: item.name))
            .help(QuickKeysText.cornerButtonLabel(name: item.name))
        }
        .overlay(alignment: .bottomTrailing) {
            if switchLook.isBusy { ProgressView().controlSize(.small).padding(6) }
        }
        .overlay {
            if look.hasShownOutline {
                Self.shape.inset(by: -2).stroke(QuickKeyColors.shown, lineWidth: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if look.hasShownOutline {
                QuickKeyPointer().fill(QuickKeyColors.shown).frame(width: 14, height: 7).offset(y: 9)
            }
        }
        .overlay {
            if isHighlighted { Self.shape.inset(by: -4).stroke(QuickKeyColors.highlight, lineWidth: 3) }
        }
        .help(help)
    }

    private var help: String {
        var parts: [String] = []
        if let text = QuickKeysText.help(for: state) { parts.append(text) }
        if sharing > 1, let key = item.key {
            parts.append(QuickKeysText.sharingHelp(count: sharing, tag: QuickKeysText.keyTag(.list(item.index), key: key)))
        }
        if !item.monitored { parts.append(QuickKeysText.notMonitoredLine) }
        return parts.joined(separator: " ")
    }
}

/// A key with no list: a faint placeholder, so each number stays in the same spot.
struct QuickKeyPlaceholderTile: View {
    let key: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(key)).font(.system(size: 18, weight: .bold, design: .monospaced))
            Text("—").font(.system(size: 11.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .frame(maxWidth: .infinity, minHeight: QuickKeyTile.minHeight, alignment: .topLeading)
        .background(QuickKeyColors.offFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(QuickKeyColors.offBorder, lineWidth: 1))
        .opacity(0.25)
        .accessibilityHidden(true)
    }
}

/// The pointer under the shown list's tile, down toward its tree.
struct QuickKeyPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
#endif
