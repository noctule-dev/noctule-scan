// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Levels and clip detection for a line-in's audio, measured on the chosen channel at the
/// device's own rate, before any conversion, so resampling can't hide a clip (line-in design §5.3).
///
/// One `LineInLevel` per window of `sampleRate / windowsPerSecond` samples (about 33 ms at the
/// default 30 Hz). The window length carries its fractional part, so 44.1 kHz windows don't drift.
/// A clip is two or more consecutive samples at or above `clipThreshold` (0.1 dB under full
/// scale); one stray full-scale sample isn't one. A run that straddles windows or `ingest` calls
/// counts, and the window holding its second sample is the one marked `clipped`.
public struct LineInMeter: Sendable {
    /// Full scale minus 0.1 dB (`10^(-0.1/20)`).
    public static let clipThreshold: Float = 0.98855

    private let sampleRate: Double
    private let windowLength: Double

    /// Samples taken in all, and how many windows have ended: window `n` ends at sample
    /// `(n + 1) × windowLength`, rounded down. The `1e-6` is a guard: a product that should be a
    /// whole number but that floating point leaves a hair under it would otherwise end its window a
    /// sample early.
    private var samplesSeen = 0
    private var windowsDone = 0
    private var windowEnd: Int

    private var windowStart: ContinuousClock.Instant?
    private var peak: Float = 0
    private var sumOfSquares = 0.0
    private var windowSamples = 0
    private var windowClipped = false
    private var clipRun = 0

    public init(sampleRate: Double, windowsPerSecond: Double = 30) {
        self.sampleRate = sampleRate
        windowLength = sampleRate / windowsPerSecond
        windowEnd = max(1, Int((windowLength + 1e-6).rounded(.down)))
    }

    /// Takes the next `samples`, the first of which was captured at `firstSampleAt`, and returns the
    /// levels of the windows they complete, each timed at its window's first sample.
    public mutating func ingest(
        _ samples: UnsafeBufferPointer<Float>, firstSampleAt: ContinuousClock.Instant
    ) -> [LineInLevel] {
        var levels: [LineInLevel] = []
        for (index, sample) in samples.enumerated() {
            if windowStart == nil {
                windowStart = firstSampleAt + .seconds(Double(index) / sampleRate)
            }
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumOfSquares += Double(sample) * Double(sample)
            windowSamples += 1
            if magnitude >= Self.clipThreshold {
                clipRun += 1
                if clipRun >= 2 { windowClipped = true }
            } else {
                clipRun = 0
            }
            samplesSeen += 1
            if samplesSeen >= windowEnd, let start = windowStart {
                levels.append(LineInLevel(
                    peakDBFS: Self.dBFS(Double(peak)),
                    rmsDBFS: Self.dBFS((sumOfSquares / Double(windowSamples)).squareRoot()),
                    clipped: windowClipped, at: start))
                windowStart = nil
                peak = 0
                sumOfSquares = 0
                windowSamples = 0
                windowClipped = false
                windowsDone += 1
                windowEnd = max(samplesSeen + 1, Int((Double(windowsDone + 1) * windowLength + 1e-6).rounded(.down)))
            }
        }
        return levels
    }

    private static func dBFS(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }
}
