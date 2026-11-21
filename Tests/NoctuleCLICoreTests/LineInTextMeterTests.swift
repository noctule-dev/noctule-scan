// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleCLICore

/// The one-line text meter `listen --station --meter` draws (Plan 19 Task 4): 20 cells over
/// -60...0 dBFS, cell k filled when the held peak reaches -60 + 3(k+1), a `|` after the 18th cell
/// (-6 dBFS, the top of the target band), the peak in dBFS, and CLIP latched for 3 s.
@Suite(.timeLimit(.minutes(1))) struct LineInTextMeterTests {
    private let t0 = ContinuousClock.now

    private func level(_ peak: Double, clipped: Bool = false, at: ContinuousClock.Instant) -> LineInLevel {
        LineInLevel(peakDBFS: peak, rmsDBFS: peak - 6, clipped: clipped, at: at)
    }

    /// 20 cells with the `|` after the 18th: `filled` of them `▇`, the rest `·`.
    private func cells(filled: Int) -> String {
        let all = (0..<20).map { $0 < filled ? "▇" : "·" }
        return all[0..<18].joined() + "|" + all[18...].joined()
    }

    @Test func meterLineAtMinus9() {
        var meter = LineInTextMeter()
        meter.update(level(-9, at: t0))
        #expect(meter.line(at: t0) == "line-in \(cells(filled: 17)) peak \u{2212}9 dBFS")
        #expect(meter.line(at: t0) == "line-in ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇·|·· peak −9 dBFS")
    }

    @Test func meterSilence() {
        var meter = LineInTextMeter()
        meter.update(level(-.infinity, at: t0))
        #expect(meter.line(at: t0) == "line-in \(cells(filled: 0)) peak \u{2212}\u{221E} dBFS")
        #expect(meter.line(at: t0) == "line-in ··················|·· peak −∞ dBFS")
    }

    @Test func meterBeforeAnyLevelReadsAsSilence() {
        let meter = LineInTextMeter()
        #expect(meter.line(at: t0) == "line-in \(cells(filled: 0)) peak \u{2212}\u{221E} dBFS")
    }

    @Test func meterCellsFollowTheScale() {
        let cases: [(Double, Int)] = [
            (-60.1, 0), (-60, 0), (-58, 0), (-57, 1), (-56.9, 1), (-12, 16), (-9, 17), (-7, 17),
            (-6.1, 17), (-6, 18), (-3, 19), (-0.5, 19), (0, 20),
        ]
        for (peak, filled) in cases {
            var meter = LineInTextMeter()
            meter.update(level(peak, at: t0))
            #expect(meter.line(at: t0).hasPrefix("line-in \(cells(filled: filled)) peak "), "peak \(peak)")
        }
    }

    @Test func meterRoundsThePeakToTheNearestDecibel() {
        let cases: [(Double, String)] = [
            (-9.4, "\u{2212}9"), (-9.6, "\u{2212}10"), (-0.2, "0"), (0, "0"), (-30, "\u{2212}30"),
        ]
        for (peak, text) in cases {
            var meter = LineInTextMeter()
            meter.update(level(peak, at: t0))
            #expect(meter.line(at: t0).hasSuffix(" peak \(text) dBFS"), "peak \(peak)")
        }
    }

    @Test func meterClipLatchesThreeSeconds() {
        var meter = LineInTextMeter()
        meter.update(level(0, clipped: true, at: t0))
        #expect(meter.line(at: t0).hasSuffix(" CLIP"))
        #expect(meter.line(at: t0 + .milliseconds(2900)).hasSuffix(" CLIP"))
        #expect(!meter.line(at: t0 + .seconds(3)).contains("CLIP"))
        #expect(!meter.line(at: t0 + .seconds(10)).contains("CLIP"))
        #expect(LineInTextMeter.clipLatch == .seconds(3))
    }

    @Test func meterClipRelatchesOnTheNextClippedLevel() {
        var meter = LineInTextMeter()
        meter.update(level(0, clipped: true, at: t0))
        meter.update(level(-20, at: t0 + .seconds(1)))
        meter.update(level(0, clipped: true, at: t0 + .seconds(2)))
        #expect(meter.line(at: t0 + .milliseconds(4900)).hasSuffix(" CLIP"))
        #expect(!meter.line(at: t0 + .seconds(5)).contains("CLIP"))
    }

    @Test func meterUnclippedLevelsNeverShowClip() {
        var meter = LineInTextMeter()
        meter.update(level(-1, at: t0))
        #expect(!meter.line(at: t0).contains("CLIP"))
    }

    @Test func meterPeakHoldsOneAndAHalfSeconds() {
        var meter = LineInTextMeter()
        meter.update(level(-9, at: t0))
        meter.update(level(-30, at: t0 + .milliseconds(1400)))
        #expect(meter.line(at: t0 + .milliseconds(1400)).hasSuffix(" peak \u{2212}9 dBFS"))
        meter.update(level(-30, at: t0 + .milliseconds(1500)))
        #expect(meter.line(at: t0 + .milliseconds(1500)).hasSuffix(" peak \u{2212}30 dBFS"))
        // A higher peak replaces the held one at once.
        meter.update(level(-3, at: t0 + .milliseconds(1600)))
        #expect(meter.line(at: t0 + .milliseconds(1600)).hasSuffix(" peak \u{2212}3 dBFS"))
    }

    @Test func meterRateFollowsTheTerminal() {
        #expect(LineInTextMeter.redrawInterval(isTerminal: true) == .milliseconds(100))
        #expect(LineInTextMeter.redrawInterval(isTerminal: false) == .seconds(1))
        #expect(LineInTextMeter.cells == 20)
    }
}
