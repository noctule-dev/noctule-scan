// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// The station window's alternate view (design §7.2): the same information laid out for reading
/// at a glance. A `System › Department` breadcrumb, the channel name large, the digital details
/// as chips, the scanner's mode and list, the shared Mac controls (Hold, Avoid, Listen, Logging,
/// app volume), and the scanner's own volume and squelch as sliders, with a line-in station's
/// `Line-in level` meter under Volume (line-in design §6.2). While the scanner is in a
/// menu, `MacMenuView` takes the place of the breadcrumb, headline and chips; the Menu button
/// (before the chips) enters it. "Active now" and the recent
/// hits are in the window's sidebar (`StationContentView`). Nothing here reads `session.packets`.
struct MacStyleView: View {
    let session: StationSession

    private var connected: Bool {
        if case .connected = session.phase { return true }
        return false
    }

    var body: some View {
        let info = connected ? session.info : nil
        let chips = MacStyleText.chips(info)
        let profile = ModelProfile.profile(for: session.model)
        let showsLevelRow = LineInMeterPlacement.placement(in: .macStyle, lineIn: session.lineInConfig) == .levelRow
        let labelWidth = LevelSlider.labelWidth(lineIn: showsLevelRow)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.menu.isInMenu {
                    MacMenuView(session: session)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(MacStyleText.breadcrumb(info) ?? " ")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(MacStyleText.headline(info, phase: session.phase, stationName: session.station.name))
                            .font(.system(size: 40, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        if let scanning = MacStyleText.scanning(info) {
                            Label(scanning, systemImage: "dot.radiowaves.up.forward")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .center, spacing: 14) {
                        // Through `MacMenuActions`, so a held Return on the focused button sends once.
                        Button { MacMenuActions(menu: session.menu, state: MacMenuState()).enter() } label: {
                            Label("Menu", systemImage: "list.bullet")
                        }
                        .disabled(!connected || session.menu.isBusy)
                        .tracksKeyboardFocus()
                        .help("Open the scanner's menu (sends Menu)")
                        if !chips.isEmpty {
                            InfoChipsView(chips: chips)
                        }
                    }
                }

                Divider()

                MacControlsBar(session: session)

                GroupBox {
                    VStack(spacing: 10) {
                        LevelSlider(title: "Volume", systemImage: "speaker.wave.2", current: session.info?.volume,
                                    range: profile.volumeRange, enabled: connected, set: session.setScannerVolume,
                                    labelWidth: labelWidth)
                        if showsLevelRow {
                            LineInLevelRow(session: session)
                        }
                        LevelSlider(title: "Squelch", systemImage: "waveform.path", current: session.info?.squelch,
                                    range: profile.squelchRange, enabled: connected, set: session.setScannerSquelch,
                                    labelWidth: labelWidth)
                    }
                    .padding(6)
                } label: {
                    Text("Scanner")
                }
                .frame(maxWidth: 460)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A line-in station's meter and CLIP, in the Scanner group under Volume, lined up with the sliders.
/// It moves whether or not Listen is on.
struct LineInLevelRow: View {
    let session: StationSession

    var body: some View {
        HStack(spacing: 10) {
            Label("Line-in level", systemImage: "waveform")
                .frame(width: LevelSlider.labelWidth(lineIn: true), alignment: .leading)
            LineInMeterView(level: session.lineInLevel?.peakDBFS, peakHold: session.peakHoldDBFS,
                            clipLatched: session.clipLatched, clearClip: session.clearClip)
            // Where the sliders show their value.
            Color.clear.frame(width: 28, height: 1)
        }
    }
}

/// A scanner level (volume or squelch) as a stepped slider. A move sends through `set` (the
/// session debounces); the slider shows the level asked for until the scanner reports it back,
/// or for 3 s after the last move.
struct LevelSlider: View {
    let title: String
    let systemImage: String
    let current: Int?
    let range: ClosedRange<Int>?
    let enabled: Bool
    let set: (Int) -> Void
    /// The width of the label column. `labelWidth(lineIn:)` gives it for the Scanner group.
    var labelWidth: CGFloat = 92

    @State private var pending: Int?
    @State private var lastMove = Date.distantPast

    /// The Scanner group's label width: 92, or 120 when the `Line-in level` row shows, whose longer
    /// label the others line up with (line-in design §6.2: every other station's layout is unchanged).
    static func labelWidth(lineIn: Bool) -> CGFloat { lineIn ? 120 : 92 }

    var body: some View {
        let shown = pending ?? current
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .frame(width: labelWidth, alignment: .leading)
            if let range, range.upperBound > range.lowerBound {
                Slider(value: binding(range), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                    .disabled(!enabled || current == nil)
                    .accessibilityLabel("Scanner \(title.lowercased())")
                    .tracksKeyboardFocus()
            } else {
                Text("Not available on this model").foregroundStyle(.secondary)
                Spacer()
            }
            Text(shown.map(String.init) ?? "–")
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .onChange(of: current) { _, new in if new == pending { pending = nil } }
        .task(id: lastMove) {
            guard pending != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { pending = nil }
        }
    }

    private func binding(_ range: ClosedRange<Int>) -> Binding<Double> {
        Binding(
            get: { Double(pending ?? current ?? range.lowerBound) },
            set: { value in
                let level = min(max(Int(value.rounded()), range.lowerBound), range.upperBound)
                guard level != (pending ?? current) else { return }
                pending = level
                lastMove = Date()
                set(level)
            })
    }
}
#endif
