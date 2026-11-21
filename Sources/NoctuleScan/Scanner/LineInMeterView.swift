// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import SwiftUI

/// The line-in meter's scale (line-in design §5.3): −60 to 0 dBFS across the bar, green to −12,
/// yellow to −3 and red above, with the target band for a transmission's peaks at −18 to −6.
enum MeterScale {
    enum Zone: Equatable { case green, yellow, red }

    static let floor = -60.0
    /// The top of the green zone and of the yellow one.
    static let greenTop = -12.0
    static let yellowTop = -3.0
    /// Where a transmission's peaks should sit.
    static let band = (low: -18.0, high: -6.0)

    /// How far along the bar `dBFS` lies, 0…1: nothing at −60 and below (digital silence, and a
    /// reading that isn't a number, included), full at 0 and above.
    static func fraction(dBFS: Double) -> Double {
        guard !dBFS.isNaN else { return 0 }
        return min(max((dBFS - floor) / -floor, 0), 1)
    }

    static func zone(dBFS: Double) -> Zone {
        if dBFS <= greenTop { return .green }
        if dBFS <= yellowTop { return .yellow }
        return .red
    }

    static func color(_ zone: Zone) -> Color {
        switch zone {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }
}

/// Where `MeterScale`'s marks fall along a bar `length` points long, measured from its empty end
/// (the left of a horizontal bar, the bottom of the Scanner view's vertical one).
struct MeterLayout: Equatable {
    /// One zone's stretch of the bar.
    struct Segment: Equatable {
        var zone: MeterScale.Zone
        var start: Double
        var end: Double
    }

    let length: Double

    func offset(_ dBFS: Double) -> Double { length * MeterScale.fraction(dBFS: dBFS) }

    /// How much of the bar a reading fills; none without one.
    func fill(_ level: Double?) -> Double { level.map(offset) ?? 0 }

    /// Green, yellow and red, empty end first.
    var segments: [Segment] {
        let greenTop = offset(MeterScale.greenTop), yellowTop = offset(MeterScale.yellowTop)
        return [Segment(zone: .green, start: 0, end: greenTop),
                Segment(zone: .yellow, start: greenTop, end: yellowTop),
                Segment(zone: .red, start: yellowTop, end: length)]
    }

    /// The zone a fill ending at `offset` reaches (a zone's top edge is still that zone, as in
    /// `MeterScale.zone`).
    func zone(at offset: Double) -> MeterScale.Zone {
        segments.last(where: { $0.start < offset })?.zone ?? .green
    }

    /// The target band's two edges, the low one first.
    var bandTicks: [Double] { [offset(MeterScale.band.low), offset(MeterScale.band.high)] }

    /// Where the peak-hold tick, `width` long, starts: ending at the held level, kept inside the
    /// bar. Nil when nothing is held above the floor.
    func peakTick(_ peakHold: Double?, width: Double) -> Double? {
        guard let peakHold, MeterScale.fraction(dBFS: peakHold) > 0 else { return nil }
        return max(offset(peakHold) - width, 0)
    }
}

/// Where a station view puts the line-in meter (line-in design §6.2), nil when the station has none:
/// only a station whose audio comes from an input (`StationSession.lineInConfig`) shows one, so a
/// network station and a USB station without an input keep their layout.
enum LineInMeterPlacement: Equatable {
    /// The Scanner view: a vertical meter on the front panel, just right of the VOL knob (the
    /// owner's call, 2026-11-17).
    case besideVolumeKnob
    /// The Mac-style view: the Line-in level row in the Scanner group, under Volume.
    case levelRow

    static func placement(in view: PreferredView, lineIn: LineInConfig?) -> LineInMeterPlacement? {
        guard lineIn != nil else { return nil }
        return switch view {
        case .scanner: .besideVolumeKnob
        case .macStyle: .levelRow
        }
    }
}

/// A meter the view keeps for itself (the station editor's, from `SessionRegistry.previewLevels`),
/// as the session keeps its own: the latest peak, the peak held (`PeakHold`, 1.5 s), and CLIP lit
/// by any clipped reading until `clearClip()`.
struct LineInMeterState: Equatable {
    private(set) var level: Double?
    private(set) var peakHold: Double?
    private(set) var clipLatched = false
    private var hold = PeakHold()

    mutating func take(_ reading: LineInLevel) {
        level = reading.peakDBFS
        peakHold = hold.update(peak: reading.peakDBFS, at: reading.at)
        if reading.clipped { clipLatched = true }
    }

    mutating func clearClip() { clipLatched = false }
}

/// A line-in meter: the bar (green, yellow and red zones; the target band marked; a peak-hold
/// tick) and CLIP, which a click clears. Across, it is a row's (the Mac-style view's, the editor's);
/// `.vertical` is the Scanner view's, on the front panel beside VOL: a CLIP lamp on top, the bar
/// filling bottom-up, and `IN` under it, as tall as its container lets it be (`PanelMetrics`).
struct LineInMeterView: View {
    let level: Double?
    let peakHold: Double?
    let clipLatched: Bool
    let clearClip: () -> Void
    var axis: Axis = .horizontal

    /// The vertical meter's sizes (the owner's mockup, option C).
    enum PanelMetrics {
        static let barWidth: CGFloat = 6
        static let minBarHeight: CGFloat = 58
        static let lampDiameter: CGFloat = 8
    }

    var body: some View {
        Group {
            switch axis {
            case .horizontal:
                HStack(spacing: 6) {
                    MeterBar(level: level, peakHold: peakHold, axis: .horizontal)
                        .frame(height: 10)
                        .frame(maxWidth: .infinity)
                    ClipLight(latched: clipLatched, clear: clearClip)
                }
            case .vertical:
                VStack(spacing: 4) {
                    ClipLight(latched: clipLatched, clear: clearClip, lamp: true)
                    MeterBar(level: level, peakHold: peakHold, axis: .vertical)
                        .frame(width: PanelMetrics.barWidth)
                        .frame(minHeight: PanelMetrics.minBarHeight, maxHeight: .infinity)
                    Text("IN")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(white: 0.7))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Line-in level")
        .accessibilityValue(MeterText.accessibilityValue(level: level, clipped: clipLatched))
    }
}

enum MeterText {
    static func accessibilityValue(level: Double?, clipped: Bool) -> String {
        let reading = level.flatMap { $0.isFinite ? "\(Int($0.rounded())) dBFS" : nil } ?? "no signal"
        return clipped ? "\(reading), clipped" : reading
    }
}

/// The bar of `LineInMeterView`, filling from the left, or from the bottom when `.vertical`.
private struct MeterBar: View {
    let level: Double?
    let peakHold: Double?
    let axis: Axis

    private var alignment: Alignment { axis == .horizontal ? .leading : .bottom }

    var body: some View {
        GeometryReader { geometry in
            let bar = MeterLayout(length: axis == .horizontal ? geometry.size.width : geometry.size.height)
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                // The target band, under the fill.
                span(Color.primary.opacity(0.12), from: bar.bandTicks[0], length: bar.bandTicks[1] - bar.bandTicks[0])
                ZStack(alignment: alignment) {
                    ForEach(bar.segments, id: \.zone) { segment in
                        span(MeterScale.color(segment.zone), from: segment.start, length: segment.end - segment.start)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .mask(alignment: alignment) {
                    span(Color.black, from: 0, length: bar.fill(level))
                }
                ForEach(bar.bandTicks.indices, id: \.self) { index in
                    span(Color.primary.opacity(0.45), from: bar.bandTicks[index], length: 1)
                }
                if let peakHold, let tick = bar.peakTick(peakHold, width: 2) {
                    span(MeterScale.color(MeterScale.zone(dBFS: peakHold)), from: tick, length: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .help("Line-in level: during a transmission the peaks should sit in the marked band")
    }

    /// A stretch of the bar `length` long, `from` its empty end, across the bar's whole thickness.
    private func span(_ style: some ShapeStyle, from start: Double, length: Double) -> some View {
        Rectangle()
            .fill(style)
            .frame(width: axis == .horizontal ? max(length, 0) : nil, height: axis == .vertical ? max(length, 0) : nil)
            .offset(x: axis == .horizontal ? start : 0, y: axis == .vertical ? -start : 0)
    }
}

/// CLIP: red while latched, a click clears it. A badge reading CLIP in a row; with `lamp`, the
/// Scanner view's small round light (dark grey off, red latched).
private struct ClipLight: View {
    let latched: Bool
    let clear: () -> Void
    var lamp = false

    var body: some View {
        Button(action: clear) {
            if lamp {
                Circle()
                    .fill(latched ? Color.red : Color(white: 0.28))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                    .frame(width: LineInMeterView.PanelMetrics.lampDiameter,
                           height: LineInMeterView.PanelMetrics.lampDiameter)
                    // A target a little larger than the light.
                    .padding(3)
                    .contentShape(Rectangle())
            } else {
                Text("CLIP")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(latched ? Color.white : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 3).fill(latched ? Color.red : Color.secondary.opacity(0.18)))
            }
        }
        .buttonStyle(.plain)
        .disabled(!latched)
        .help(latched ? "The line-in clipped. Click to clear." : "Lights when the line-in clips")
        .accessibilityLabel(latched ? "Clipped, clear" : "Not clipped")
    }
}

/// One line-in notice under the Mac controls (line-in design §6.3): the clip warning, with
/// Volume −1 and a dismiss, or a blocked input's permission message, with Open Privacy Settings.
/// A missing or silent input is one of the session's ordinary warnings (the status bar).
struct LineInNotice: Equatable {
    enum Action: Equatable {
        /// Volume −1: one `VOL` step down (`stepScannerVolumeDown()`), off when it can't step.
        case volumeDown(enabled: Bool)
        case openPrivacySettings
    }

    var text: String
    var action: Action
    var dismissible: Bool

    /// System Settings › Privacy & Security › Microphone.
    static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// The clip warning (`clipWarning`, the session's text), then the permission notice while the
    /// input is `.denied`. Volume −1 is on only while connected, with a reported `volume` above the
    /// bottom of the model's `volumeRange`.
    static func make(clipWarning: String?, lineIn: LineInState?, volume: Int?, volumeRange: ClosedRange<Int>?,
                     connected: Bool) -> [LineInNotice] {
        var notices: [LineInNotice] = []
        if let clipWarning {
            let canStep = connected && volume.map { v in volumeRange.map { v > $0.lowerBound } ?? false } ?? false
            notices.append(LineInNotice(text: clipWarning, action: .volumeDown(enabled: canStep), dismissible: true))
        }
        if lineIn == .denied {
            notices.append(LineInNotice(text: StationRunner.lineInDeniedMessage, action: .openPrivacySettings,
                                        dismissible: false))
        }
        return notices
    }
}

/// What a notice's buttons do. Volume −1 never repeats (line-in design §6.3): a held Space or
/// Return on the focused button reaches SwiftUI once per key repeat, so an activation that comes
/// from a repeat (`isKeyRepeat`, as `MacMenuActions` does) sends nothing; only the first press steps.
@MainActor struct LineInNoticeActions {
    /// One `VOL` step down (`StationSession.stepScannerVolumeDown()`).
    let stepVolumeDown: @MainActor () -> Void
    /// True while the event being handled is a key-down repeat.
    var isKeyRepeat: @MainActor () -> Bool = MacMenuActions.currentEventIsKeyRepeat

    /// Steps the volume down unless this is a key repeat; true when it stepped.
    @discardableResult
    func volumeDown() -> Bool {
        guard !isKeyRepeat() else { return false }
        stepVolumeDown()
        return true
    }
}

/// The notices of `LineInNotice.make` for a session, one row each.
struct LineInNoticesView: View {
    let session: StationSession

    private var connected: Bool {
        if case .connected = session.phase { return true }
        return false
    }

    var body: some View {
        let notices = LineInNotice.make(
            clipWarning: session.clipWarningText, lineIn: session.lineIn, volume: session.info?.volume,
            volumeRange: ModelProfile.profile(for: session.model).volumeRange, connected: connected)
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notices, id: \.text) { notice in
                    row(notice)
                }
            }
        }
    }

    private func row(_ notice: LineInNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(notice.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            switch notice.action {
            case .volumeDown(let enabled):
                Button("Volume −1") { LineInNoticeActions(stepVolumeDown: session.stepScannerVolumeDown).volumeDown() }
                    .disabled(!enabled)
                    .tracksKeyboardFocus()
                    .help("Turn the scanner's volume down one step")
            case .openPrivacySettings:
                Button("Open Privacy Settings") { NSWorkspace.shared.open(LineInNotice.privacySettingsURL) }
                    .tracksKeyboardFocus()
                    .help("System Settings › Privacy & Security › Microphone")
            }
            if notice.dismissible {
                Button { session.dismissClipWarning() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }
}
#endif
