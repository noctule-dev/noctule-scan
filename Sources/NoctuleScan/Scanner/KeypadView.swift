// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleKit
import SwiftUI

/// One keypad key: its key, its label, and the second function printed above it (Func then key).
struct PanelKey: Identifiable {
    let key: FrontPanelKey
    let label: String
    let caption: String?
    var id: String { key.rawValue }
}

/// The front panel's keypad, laid out like the SDS200's: Menu, Func, Avoid; Zip, Services,
/// Range; the digits with their second functions; ./No, 0, E/Yes; Replay. Presses are only
/// forwarded (`press`), so multi-key sequences (Func then 4, Avoid twice) behave as on the scanner.
/// The remaining front-panel keys are the soft keys (`DisplayView`) and the knob pushes and
/// scroll steps (`KnobView`).
struct KeypadView: View {
    let enabled: Bool
    /// The keys the model has; a key it lacks is left off the panel and its row closes up.
    var keys: Set<FrontPanelKey> = Set(FrontPanelKey.allCases)
    /// A Services or Range walk is running: the whole keypad waits (`StationSession.menuShortcutInFlight`).
    var walking: Bool = false
    let press: (FrontPanelKey) -> Void

    /// The SDS200's whole keypad (the rows of a model with every key).
    static let allRows: [[PanelKey]] = [
        [PanelKey(key: .menu, label: "Menu", caption: nil),
         PanelKey(key: .function, label: "Func", caption: nil),
         PanelKey(key: .avoid, label: "Avoid", caption: nil)],
        [PanelKey(key: .zip, label: "Zip", caption: nil),
         PanelKey(key: .serviceType, label: "Services", caption: nil),
         PanelKey(key: .range, label: "Range", caption: nil)],
        [PanelKey(key: .digit1, label: "1", caption: "SRCH1"),
         PanelKey(key: .digit2, label: "2", caption: "SRCH2"),
         PanelKey(key: .digit3, label: "3", caption: "SRCH3")],
        [PanelKey(key: .digit4, label: "4", caption: "ATT"),
         PanelKey(key: .digit5, label: "5", caption: "DIM"),
         PanelKey(key: .digit6, label: "6", caption: "WX")],
        [PanelKey(key: .digit7, label: "7", caption: "IFX"),
         PanelKey(key: .digit8, label: "8", caption: nil),
         PanelKey(key: .digit9, label: "9", caption: nil)],
        [PanelKey(key: .dotNo, label: ". / No", caption: nil),
         PanelKey(key: .digit0, label: "0", caption: nil),
         PanelKey(key: .enterYes, label: "E / Yes", caption: nil)],
    ]
    /// `allRows` without the keys the model lacks (design §5.11); Services and Range are menu shortcuts, not keys, so every model keeps them; a row left empty is dropped.
    static func rows(keys: Set<FrontPanelKey>) -> [[PanelKey]] {
        allRows.map { $0.filter { keys.contains($0.key) || MenuShortcut(key: $0.key) != nil } }.filter { !$0.isEmpty }
    }
    static let replay = PanelKey(key: .replay, label: "Replay", caption: "Record")

    static let keyWidth: CGFloat = 62
    static let spacing: CGFloat = 7

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(Self.rows(keys: keys).enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.spacing) {
                    ForEach(row) { key in button(key).frame(width: Self.keyWidth) }
                }
            }
            button(Self.replay).frame(width: Self.keyWidth * 3 + Self.spacing * 2)
        }
        .disabled(!enabled || walking)
    }

    static func help(for key: FrontPanelKey) -> String? {
        switch key {
        case .serviceType: "Open Select Service Types"
        case .range: "Open Set Range"
        default: nil
        }
    }

    private func button(_ key: PanelKey) -> some View {
        Button { press(key.key) } label: {
            VStack(spacing: 1) {
                Text(key.caption ?? " ")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(key.caption == nil ? Color.clear : Color.orange)
                Text(key.label)
                    .font(.system(size: key.label.count == 1 ? 15 : 11.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PanelKeyStyle(height: 38))
        .help(Self.help(for: key.key) ?? "")
        .accessibilityLabel(key.caption.map { "\(key.label), second function \($0)" } ?? key.label)
    }
}

/// A rubbery front-panel key: graphite, lighter on top, darker while pressed.
struct PanelKeyStyle: ButtonStyle {
    var height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(Color(white: isEnabled ? 0.93 : 0.55))
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: pressed ? [Color(white: 0.2), Color(white: 0.25)]
                                                         : [Color(white: 0.34), Color(white: 0.24)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(pressed ? 0.04 : 0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(pressed ? 0.1 : 0.45), radius: pressed ? 0.5 : 1.5, y: pressed ? 0 : 1.5)
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Rectangle())
    }
}
#endif
