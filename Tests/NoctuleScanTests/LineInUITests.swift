// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import NoctuleAppCore
import NoctuleKit
import NoctuleStore
import Testing
@testable import NoctuleScan

/// The app's line-in UI as pure logic (line-in design §5.3, §6): the meter's scale, the status-bar
/// indicator, which Mac controls show, the notices under them, the editor's meter, and the hit-log
/// inspector's `Clipped`. Nothing here opens an audio input.
@Suite struct LineInUITests {
    private static func reading(_ peak: Double, clipped: Bool = false, at: ContinuousClock.Instant) -> LineInLevel {
        LineInLevel(peakDBFS: peak, rmsDBFS: peak - 6, clipped: clipped, at: at)
    }

    // MARK: The meter's scale

    /// −60 to 0 dBFS across the bar; below −60 (digital silence included) is empty, above 0 full.
    @Test func meterScaleFractions() {
        #expect(MeterScale.fraction(dBFS: -60) == 0)
        #expect(MeterScale.fraction(dBFS: -30) == 0.5)
        #expect(MeterScale.fraction(dBFS: -15) == 0.75)
        #expect(MeterScale.fraction(dBFS: 0) == 1)
        #expect(MeterScale.fraction(dBFS: -61) == 0)
        #expect(MeterScale.fraction(dBFS: -.infinity) == 0)
        #expect(MeterScale.fraction(dBFS: .nan) == 0)
        #expect(MeterScale.fraction(dBFS: 2) == 1)
    }

    /// Green to −12, yellow to −3, red above; the target band is −18 to −6.
    @Test func meterZones() {
        #expect(MeterScale.zone(dBFS: -60) == .green)
        #expect(MeterScale.zone(dBFS: -12.1) == .green)
        #expect(MeterScale.zone(dBFS: -12) == .green)
        #expect(MeterScale.zone(dBFS: -11.9) == .yellow)
        #expect(MeterScale.zone(dBFS: -3) == .yellow)
        #expect(MeterScale.zone(dBFS: -2.9) == .red)
        #expect(MeterScale.zone(dBFS: 0) == .red)
        #expect(MeterScale.band.low == -18.0 && MeterScale.band.high == -6.0)
    }

    // MARK: The status bar

    /// `No audio over USB` gives way to the line-in's state (design §6.2).
    @Test func lineInIndicatorTexts() {
        let name = "Fictional Interface"
        let listening = ScannerIndicators.lineIn(.streaming(deviceName: name), listening: true, deviceName: name)
        #expect(listening.text == "Listening · Fictional Interface")
        #expect(listening.tone == .good)
        let quiet = ScannerIndicators.lineIn(.streaming(deviceName: name), listening: false, deviceName: name)
        #expect(quiet.text == "Not listening")
        let missing = ScannerIndicators.lineIn(.missing(deviceName: name), listening: true, deviceName: name)
        #expect(missing.text == "Line-in not connected")
        #expect(missing.tone == .warning)
        // The tooltip is the runner's own warning, so the window and stderr say the same thing.
        #expect(missing.help == StationRunner.lineInMissingMessage(deviceName: name))
        let denied = ScannerIndicators.lineIn(.denied, listening: true, deviceName: name)
        #expect(denied.text == "Line-in blocked")
        #expect(denied.tone == .bad)
        #expect(denied.help == StationRunner.lineInDeniedMessage)
    }

    /// Ruling R13: a line-in that can't start (the kill-switch's disabled source among them) is
    /// `Line-in blocked` too, its reason as the help, never "Listening".
    @Test func failedLineInIsBlockedWithItsReason() {
        let killSwitch = ScannerIndicators.lineIn(.failed(LineInDetection.disabledReason), listening: true,
                                                  deviceName: "Fictional Interface")
        #expect(killSwitch.text == "Line-in blocked")
        #expect(killSwitch.help == "audio input disabled by NOCTULE_NO_USB_DETECTION")
        #expect(killSwitch.tone == .bad)
        let other = ScannerIndicators.lineIn(.failed("the device went away"), listening: false, deviceName: "X")
        #expect(other.text == "Line-in blocked" && other.help == "the device went away")
        // Neither starting nor stopped claims to be listening.
        for state: LineInState? in [nil, .starting, .stopped] {
            let item = ScannerIndicators.lineIn(state, listening: true, deviceName: "Fictional Interface")
            #expect(!item.text.hasPrefix("Listening"), "\(String(describing: state))")
        }
        // The other indicators keep no help of their own (the text is the tooltip).
        #expect(ScannerIndicators.noAudioOverUSB.help == nil)
    }

    // MARK: The Mac controls

    /// A line-in station shows Listen and the app volume; while its line-in is blocked, Listen and
    /// the app volume stay shown but are off. The bar has no meter (the owner's call, 2026-11-17: the
    /// Scanner view's stands beside VOL, `meterPlacement`), so a line-in station's bar is a network
    /// station's.
    @Test func enablementShowsAudioForLineIn() {
        let lineIn = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: false, hasAudio: true,
                                               canListen: true)
        #expect(lineIn.showsAudioControls && lineIn.listen && lineIn.appVolume)
        let blocked = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: false, hasAudio: true,
                                                canListen: false)
        #expect(blocked.showsAudioControls)
        #expect(!blocked.listen && !blocked.appVolume)
        let network = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: false, hasAudio: true)
        #expect(network == lineIn)
        let usb = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: false, hasAudio: false,
                                            canListen: false)
        #expect(!usb.showsAudioControls && !usb.listen)
        let offline = MacControlsBar.Enablement(connected: false, canHoldAny: false, inMenu: false, hasAudio: true,
                                                canListen: true)
        #expect(!offline.listen && offline.appVolume)
    }

    // MARK: Where the meter goes

    /// The owner's call (2026-11-17, option C of the mockups): the Scanner view's meter stands on the
    /// front panel beside the VOL knob, no longer in the controls bar; the Mac-style view keeps its
    /// Line-in level row. Only a station whose audio comes from an input has a meter: a network
    /// station and a USB station without one show the panel as before.
    @Test func meterPlacement() {
        let input = LineInConfig(deviceUID: "fictional-input-1", deviceName: "Fictional Interface", channel: .left)
        #expect(LineInMeterPlacement.placement(in: .scanner, lineIn: input) == .besideVolumeKnob)
        #expect(LineInMeterPlacement.placement(in: .macStyle, lineIn: input) == .levelRow)
        #expect(LineInMeterPlacement.placement(in: .scanner, lineIn: nil) == nil)
        #expect(LineInMeterPlacement.placement(in: .macStyle, lineIn: nil) == nil)
    }

    /// The bar's marks come from `MeterScale` whichever way it runs (the panel's fills bottom-up):
    /// half way at −30 dBFS, the zones' edges at −12 and −3, the band's ticks at −18 and −6, and the
    /// peak-hold tick ending at the held level, kept inside the bar.
    @Test func meterLayoutAlongTheBar() {
        func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
        let bar = MeterLayout(length: 60)
        #expect(close(bar.fill(-30), 30))
        #expect(bar.fill(nil) == 0 && bar.fill(-70) == 0 && bar.fill(-.infinity) == 0)
        #expect(close(bar.fill(3), 60))
        #expect(bar.segments.map(\.zone) == [.green, .yellow, .red])
        let edges = bar.segments.flatMap { [$0.start, $0.end] }
        for (edge, expected) in zip(edges, [0, 48, 48, 57, 57, 60.0]) { #expect(close(edge, expected)) }
        #expect(bar.zone(at: bar.fill(-12.1)) == .green)
        #expect(bar.zone(at: bar.fill(-12)) == .green)
        #expect(bar.zone(at: bar.fill(-11.9)) == .yellow)
        #expect(bar.zone(at: bar.fill(-3)) == .yellow)
        #expect(bar.zone(at: bar.fill(-2.9)) == .red)
        #expect(bar.bandTicks.count == 2)
        #expect(close(bar.bandTicks.first, 42) && close(bar.bandTicks.last, 54))
        #expect(close(bar.peakTick(-6, width: 2), 52))
        #expect(bar.peakTick(-59.5, width: 2) == 0)
        #expect(bar.peakTick(nil, width: 2) == nil && bar.peakTick(-60, width: 2) == nil)
        // The panel's bar: about 6 points wide, at least the mockup's 58 tall.
        #expect(LineInMeterView.PanelMetrics.barWidth == 6)
        #expect(LineInMeterView.PanelMetrics.minBarHeight == 58)
    }

    /// The clip warning offers Volume −1 (one step, off at the bottom of the range, with no reading,
    /// or while disconnected) and a dismiss; a blocked input offers Open Privacy Settings.
    @Test func lineInNotices() {
        let text = "The audio input clipped during \"Fire Dispatch\". Turn the scanner's volume down a step."
        let clip = LineInNotice.make(clipWarning: text, lineIn: .streaming(deviceName: "X"), volume: 9,
                                     volumeRange: 0...15, connected: true)
        #expect(clip == [LineInNotice(text: text, action: .volumeDown(enabled: true), dismissible: true)])
        #expect(LineInNotice.make(clipWarning: text, lineIn: nil, volume: 0, volumeRange: 0...15, connected: true)
                == [LineInNotice(text: text, action: .volumeDown(enabled: false), dismissible: true)])
        #expect(LineInNotice.make(clipWarning: text, lineIn: nil, volume: nil, volumeRange: 0...15, connected: true)
                .first?.action == .volumeDown(enabled: false))
        #expect(LineInNotice.make(clipWarning: text, lineIn: nil, volume: 5, volumeRange: nil, connected: true)
                .first?.action == .volumeDown(enabled: false))
        #expect(LineInNotice.make(clipWarning: text, lineIn: nil, volume: 5, volumeRange: 0...15, connected: false)
                .first?.action == .volumeDown(enabled: false))

        let denied = LineInNotice.make(clipWarning: nil, lineIn: .denied, volume: 5, volumeRange: 0...15,
                                       connected: true)
        #expect(denied == [LineInNotice(text: StationRunner.lineInDeniedMessage, action: .openPrivacySettings,
                                        dismissible: false)])
        #expect(LineInNotice.make(clipWarning: nil, lineIn: .failed(LineInDetection.disabledReason), volume: 5,
                                  volumeRange: 0...15, connected: true).isEmpty)
        #expect(LineInNotice.make(clipWarning: nil, lineIn: .streaming(deviceName: "X"), volume: 5,
                                  volumeRange: 0...15, connected: true).isEmpty)
        #expect(LineInNotice.privacySettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Design §6.3: Volume −1 never repeats. A held Space (or Return) on the focused button reaches
    /// SwiftUI once per repeat; only the first press may step the volume, as the menu's actions do.
    @MainActor @Test func volumeDownIgnoresKeyRepeats() {
        var steps = 0
        var repeating = false
        let actions = LineInNoticeActions(stepVolumeDown: { steps += 1 }, isKeyRepeat: { repeating })
        #expect(actions.volumeDown())
        #expect(steps == 1)
        repeating = true
        #expect(!actions.volumeDown())
        #expect(!actions.volumeDown())
        #expect(steps == 1)
        repeating = false
        #expect(actions.volumeDown())
        #expect(steps == 2)
    }

    /// The Scanner group keeps its labels' width (92) unless the Line-in level row shows, whose
    /// longer label needs 120 (design §6.2: other stations' layout is unchanged).
    @Test func scannerGroupLabelWidth() {
        #expect(LevelSlider.labelWidth(lineIn: false) == 92)
        #expect(LevelSlider.labelWidth(lineIn: true) == 120)
    }

    // MARK: The editor's meter

    /// The editor's own meter: the latest peak, held 1.5 s, and CLIP latched until cleared.
    @Test func editorMeterHoldsThePeakAndLatchesClip() {
        let start = ContinuousClock.now
        var meter = LineInMeterState()
        #expect(meter.level == nil && meter.peakHold == nil && !meter.clipLatched)
        meter.take(Self.reading(-10, at: start))
        meter.take(Self.reading(-30, at: start + .milliseconds(500)))
        #expect(meter.level == -30)
        #expect(meter.peakHold == -10)
        meter.take(Self.reading(-30, at: start + .milliseconds(1600)))
        #expect(meter.peakHold == -30)
        meter.take(Self.reading(-0.05, clipped: true, at: start + .seconds(2)))
        meter.take(Self.reading(-40, at: start + .seconds(3)))
        #expect(meter.clipLatched)
        meter.clearClip()
        #expect(!meter.clipLatched)
        #expect(meter.level == -40)
    }

    // MARK: The hit log

    /// `Clipped` shows beside a recording whose hit clipped, and only there.
    @Test func inspectorSaysClipped() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let hit = Hit(id: UUID(), key: HitKey(system: nil, talkgroupID: nil, frequencyMHz: 151.25),
                      startedAt: start, endedAt: start.addingTimeInterval(3), startInstant: .now, endInstant: .now,
                      system: "Fictional County", department: "Roads", channel: "Road Crews", site: nil,
                      unitIDs: [], modulation: "NFM", toneOrCode: nil, rssiMax: 2, programmed: true,
                      endReason: .signalLost)
        func logged(_ path: String?, _ clipped: Bool?) -> LoggedHit {
            LoggedHit(hit: hit, audioPath: path, audioError: nil, isNew: false, audioClipped: clipped)
        }
        #expect(HitLogText.clipped(logged("/tmp/a.wav", true)) == "Clipped")
        #expect(HitLogText.clipped(logged("/tmp/a.wav", false)) == nil)
        #expect(HitLogText.clipped(logged("/tmp/a.wav", nil)) == nil)
        #expect(HitLogText.clipped(logged(nil, true)) == nil)
    }
}
#endif
