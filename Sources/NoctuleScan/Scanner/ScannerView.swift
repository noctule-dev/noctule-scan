// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// The station window's default view, laid out like the SDS200 so button habits carry over
/// (design §7.1): the Volume/Light and Squelch/Menu knobs, the display with its three soft keys,
/// the keypad, and the Scroll knob on the front panel, with the Mac controls under it. A line-in
/// station's meter stands on the panel just right of the VOL knob (`LineInMeterPlacement`, the
/// owner's call, 2026-11-17): CLIP on top, the bar, `IN` under it; any other station's panel is
/// unchanged. The banner, recent hits, status bar and keyboard are the window's (`StationContentView`).
///
/// Everything the scanner does goes through the session (`press`, `setScannerVolume/Squelch`,
/// `hold`, `reconnect`, `restartScanner`), which sends only in response to these user actions.
/// Nothing here reads `session.packets`.
struct ScannerView: View {
    let session: StationSession

    /// Levels asked for by a knob turn and not yet reported back by the scanner.
    @State private var pendingVolume: Int?
    @State private var pendingSquelch: Int?
    @State private var lastTurn = Date.distantPast
    @State private var scrollTurns = 0

    private var connected: Bool {
        if case .connected = session.phase { return true }
        return false
    }

    /// The model `MDL` last reported (kept through a USB station's wait, so the knobs keep the
    /// SDS150's 0–15), else the station's override, else SDS200.
    private var model: ScannerModel { session.model }

    private var profile: ModelProfile { ModelProfile.profile(for: model) }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 16) {
                frontPanel
                MacControlsBar(session: session)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: lastTurn) { await expirePendingLevels() }
        .onChange(of: session.info?.volume) { _, new in if new == pendingVolume { pendingVolume = nil } }
        .onChange(of: session.info?.squelch) { _, new in if new == pendingSquelch { pendingSquelch = nil } }
    }

    // MARK: Front panel

    private var showsLineInMeter: Bool {
        LineInMeterPlacement.placement(in: .scanner, lineIn: session.lineInConfig) == .besideVolumeKnob
    }

    private var frontPanel: some View {
        HStack(alignment: .top, spacing: 22) {
            // With a meter beside VOL, SQL keeps its place under VOL; without one, the column is as before.
            VStack(alignment: showsLineInMeter ? .leading : .center, spacing: 22) {
                if showsLineInMeter {
                    HStack(alignment: .top, spacing: 8) {
                        volumeKnob
                        LineInMeterView(level: session.lineInLevel?.peakDBFS, peakHold: session.peakHoldDBFS,
                                        clipLatched: session.clipLatched, clearClip: session.clearClip,
                                        axis: .vertical)
                    }
                    // The meter as tall as the knob and its labels.
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    volumeKnob
                }
                levelKnob(title: "SQL", push: "Menu", key: .squelchPush, current: session.info?.squelch,
                          pending: $pendingSquelch, range: profile.squelchRange, set: session.setScannerSquelch)
            }
            .padding(.top, 6)

            DisplayView(display: session.display,
                        palette: DisplayPalette.factory(model: model, mode: session.station.appearance.colorMode),
                        placeholder: ScannerIndicators.phase(session.phase, stationName: session.station.name).text,
                        keysEnabled: connected, press: session.press)

            KeypadView(enabled: connected, press: session.press)

            KnobView(title: "SCROLL", pushCaption: "Func", readout: nil, angle: Double(scrollTurns) * 18,
                     enabled: connected,
                     onSteps: turnScroll, onPush: { session.press(.scrollPush) }, diameter: 66)
                .padding(.top, 6)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.13)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private var volumeKnob: some View {
        levelKnob(title: "VOL", push: "Light", key: .volumePush, current: session.info?.volume,
                  pending: $pendingVolume, range: profile.volumeRange, set: session.setScannerVolume)
    }

    private func levelKnob(title: String, push: String, key: FrontPanelKey, current: Int?, pending: Binding<Int?>,
                           range: ClosedRange<Int>?, set: @escaping (Int) -> Void) -> some View {
        let shown = pending.wrappedValue ?? current
        let enabled = connected && range != nil
        return KnobView(title: title, pushCaption: push, readout: shown.map(String.init),
                        angle: Self.angle(shown, in: range), enabled: enabled,
                        onSteps: { steps in
                            guard enabled, let range,
                                  let target = LevelStepper.target(current: current, pending: pending.wrappedValue,
                                                                   steps: steps, range: range) else { return }
                            pending.wrappedValue = target
                            lastTurn = Date()
                            set(target)
                        },
                        onPush: { session.press(key) })
    }

    /// -135° at the bottom of the range to +135° at the top.
    static func angle(_ value: Int?, in range: ClosedRange<Int>?) -> Double {
        guard let value, let range, range.upperBound > range.lowerBound else { return -135 }
        let fraction = Double(value - range.lowerBound) / Double(range.upperBound - range.lowerBound)
        return -135 + 270 * fraction
    }

    private func turnScroll(_ steps: Int) {
        guard connected else { return }
        scrollTurns += steps
        // One press per step, through the session's queue (it drops presses beyond 8 pending).
        for _ in 0..<abs(steps) { session.press(steps > 0 ? .scrollRight : .scrollLeft) }
    }

    /// A level the scanner never reported back (it refused, or a push was missed) stops
    /// overriding the readout 3 s after the last turn.
    private func expirePendingLevels() async {
        guard pendingVolume != nil || pendingSquelch != nil else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        pendingVolume = nil
        pendingSquelch = nil
    }
}
#endif
