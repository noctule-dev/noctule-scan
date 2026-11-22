// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

@Suite(.timeLimit(.minutes(3))) struct LineInMeterTests {
    private func sine(amplitude: Float, frequency: Double = 1000, sampleRate: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { Float(Double(amplitude) * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    private func ingest(_ meter: inout LineInMeter, _ samples: [Float], at: ContinuousClock.Instant) -> [LineInLevel] {
        samples.withUnsafeBufferPointer { meter.ingest($0, firstSampleAt: at) }
    }

    @Test func sineAtHalfScaleIsMinusSix() {
        var meter = LineInMeter(sampleRate: 48_000)
        let levels = ingest(&meter, sine(amplitude: 0.5, sampleRate: 48_000, seconds: 1), at: .now)
        #expect(levels.count == 30)
        for level in levels {
            #expect(abs(level.peakDBFS - -6.02) < 0.1)
            #expect(abs(level.rmsDBFS - -9.03) < 0.1)
            #expect(!level.clipped)
        }
    }

    @Test func oneFullScaleSampleIsNotAClip() {
        var meter = LineInMeter(sampleRate: 48_000)
        var samples = [Float](repeating: 0.1, count: 48_000)
        samples[500] = 1.0
        samples[2000] = -1.0
        let levels = ingest(&meter, samples, at: .now)
        #expect(levels.count == 30)
        #expect(levels.allSatisfy { !$0.clipped })
        #expect(abs(levels[0].peakDBFS) < 0.001)
        // The -1.0 sits in window 1: a signed peak would miss it, an unreset peak would hide window 2 on.
        #expect(abs(levels[1].peakDBFS) < 0.001)
        #expect(abs(levels[2].peakDBFS - -20) < 0.01)
        #expect(abs(levels[29].peakDBFS - -20) < 0.01)
    }

    @Test(arguments: [8_000.0, 22_050.0])
    func fractionalWindowsDontDrift(sampleRate: Double) {
        // 8 kHz / 30 = 266.67 samples, 22.05 kHz / 30 = 735 (even): the first needs the carry.
        var meter = LineInMeter(sampleRate: sampleRate)
        let start = ContinuousClock.now
        let seconds = 100
        var levels: [LineInLevel] = []
        let piece = [Float](repeating: 0.2, count: Int(sampleRate / 10))
        for n in 0..<(seconds * 10) {
            levels += ingest(&meter, piece, at: start + .seconds(Double(n) * 0.1))
        }
        #expect(abs(levels.count - 30 * seconds) <= 1)
        let last = levels[levels.count - 1]
        let drift = abs((last.at - start - .seconds(Double(levels.count - 1) / 30)) / .milliseconds(1))
        #expect(drift < 1)
    }

    @Test func twoConsecutiveAreAClip() {
        var meter = LineInMeter(sampleRate: 48_000)
        var samples = [Float](repeating: 0.1, count: 48_000)
        samples[3300] = 0.99
        samples[3301] = 0.99
        let levels = ingest(&meter, samples, at: .now)
        #expect(levels.count == 30)
        // 1600 samples a window: 3300 and 3301 are in window 2.
        for (index, level) in levels.enumerated() { #expect(level.clipped == (index == 2)) }
    }

    @Test func aRunNeedsSamplesAtThresholdOrAbove() {
        var meter = LineInMeter(sampleRate: 48_000)
        var samples = [Float](repeating: 0.1, count: 1600)
        samples[10] = LineInMeter.clipThreshold
        samples[11] = -LineInMeter.clipThreshold
        samples[20] = 0.98
        samples[21] = 0.98
        #expect(ingest(&meter, samples, at: .now).map(\.clipped) == [true])
        var quiet = LineInMeter(sampleRate: 48_000)
        samples[10] = 0.98
        samples[11] = 0.98
        #expect(ingest(&quiet, samples, at: .now).map(\.clipped) == [false])
    }

    @Test func clipRunAcrossTwoIngests() {
        var meter = LineInMeter(sampleRate: 48_000)
        let start = ContinuousClock.now
        var first = [Float](repeating: 0.1, count: 1000)
        first[999] = 0.995
        var second = [Float](repeating: 0.1, count: 1000)
        second[0] = 0.995
        #expect(ingest(&meter, first, at: start).isEmpty)
        let levels = ingest(&meter, second, at: start + .seconds(1000.0 / 48_000))
        #expect(levels.map(\.clipped) == [true])
    }

    @Test func aRunStraddlingTwoWindowsFlagsTheSecond() {
        var meter = LineInMeter(sampleRate: 48_000)
        var samples = [Float](repeating: 0.1, count: 3200)
        samples[1599] = 0.995
        samples[1600] = 0.995
        let levels = ingest(&meter, samples, at: .now)
        #expect(levels.map(\.clipped) == [false, true])
    }

    @Test func silenceIsMinusInfinity() {
        var meter = LineInMeter(sampleRate: 8_000)
        let levels = ingest(&meter, [Float](repeating: 0, count: 8_000), at: .now)
        #expect(levels.count == 30)
        #expect(levels.allSatisfy { $0.peakDBFS == -.infinity && $0.rmsDBFS == -.infinity && !$0.clipped })
    }

    @Test func levelTimesFollowTheSamples() {
        var meter = LineInMeter(sampleRate: 48_000)
        let start = ContinuousClock.now
        let samples = sine(amplitude: 0.5, sampleRate: 48_000, seconds: 1)
        // Fed in uneven pieces, as a device delivers them.
        var levels: [LineInLevel] = []
        var offset = 0
        for size in [700, 4_000, 123, 20_000, 23_177] {
            let piece = Array(samples[offset..<offset + size])
            levels += ingest(&meter, piece, at: start + .seconds(Double(offset) / 48_000))
            offset += size
        }
        #expect(offset == 48_000)
        #expect(levels.count == 30)
        for (n, level) in levels.enumerated() {
            let expected = Duration.seconds(Double(n) / 30)
            let error = abs((level.at - start - expected) / .milliseconds(1))
            #expect(error < 1)
        }
    }

    @Test func fortyFourOneWindows() {
        var meter = LineInMeter(sampleRate: 44_100)
        let start = ContinuousClock.now
        let samples = [Float](repeating: 0.25, count: 441_000)
        var levels: [LineInLevel] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 441, samples.count)
            levels += ingest(&meter, Array(samples[offset..<end]), at: start + .seconds(Double(offset) / 44_100))
            offset = end
        }
        #expect(abs(levels.count - 300) <= 1)
        let last = levels[levels.count - 1]
        let drift = abs((last.at - start - .seconds(Double(levels.count - 1) / 30)) / .milliseconds(1))
        #expect(drift < 1)
    }

    @Test func aWindowWaitsForItsLastSample() {
        var meter = LineInMeter(sampleRate: 48_000)
        #expect(ingest(&meter, [Float](repeating: 0.1, count: 1599), at: .now).isEmpty)
        #expect(ingest(&meter, [Float](repeating: 0.1, count: 1), at: .now).count == 1)
    }
}
