// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleAudioPlayback

@Suite(.timeLimit(.minutes(3))) struct JitterBufferTests {
    private func ramp(_ range: Range<Int>) -> [Int16] { range.map { Int16($0) } }

    @Test func silenceUntilPrimed() {
        var buffer = JitterBuffer()
        buffer.push(ramp(0..<1000))
        #expect(buffer.pull(160) == [Int16](repeating: 0, count: 160))
        #expect(!buffer.isPrimed)
        buffer.push(ramp(1000..<2000))
        #expect(buffer.pull(160) == ramp(0..<160))
        #expect(buffer.isPrimed)
        #expect(buffer.underruns == 0)
    }

    @Test func underrunReprimesAndCounts() {
        var buffer = JitterBuffer(capacitySamples: 8000, prefillSamples: 100)
        buffer.push(ramp(0..<150))
        #expect(buffer.pull(100) == ramp(0..<100))
        // Only 50 left: serve them, pad with silence, and count an underrun.
        let tail = buffer.pull(100)
        #expect(tail == ramp(100..<150) + [Int16](repeating: 0, count: 50))
        #expect(buffer.underruns == 1)
        #expect(!buffer.isPrimed)
        // Re-priming: below prefill it stays silent, at prefill it plays again.
        buffer.push(ramp(200..<250))
        #expect(buffer.pull(10) == [Int16](repeating: 0, count: 10))
        buffer.push(ramp(250..<300))
        #expect(buffer.pull(10) == ramp(200..<210))
        #expect(buffer.isPrimed)
        #expect(buffer.underruns == 1)
    }

    @Test func overflowDropsOldest() {
        var buffer = JitterBuffer(capacitySamples: 400, prefillSamples: 100)
        buffer.push(ramp(0..<300))
        buffer.push(ramp(300..<600))
        #expect(buffer.overflowDroppedSamples == 200)
        #expect(buffer.pull(200) == ramp(200..<400))
        #expect(buffer.pull(200) == ramp(400..<600))
    }

    @Test func oversizedPushKeepsNewest() {
        var buffer = JitterBuffer(capacitySamples: 100, prefillSamples: 10)
        buffer.push(ramp(0..<250))
        #expect(buffer.overflowDroppedSamples == 150)
        #expect(buffer.pull(100) == ramp(150..<250))
    }

    @Test func pullAlwaysReturnsCount() {
        var buffer = JitterBuffer(capacitySamples: 400, prefillSamples: 100)
        #expect(buffer.pull(0).isEmpty)
        #expect(buffer.pull(77).count == 77)
        buffer.push(ramp(0..<120))
        #expect(buffer.pull(50).count == 50)
        #expect(buffer.pull(500).count == 500)
        #expect(buffer.pull(33).count == 33)
        buffer.push(ramp(0..<40))
        #expect(buffer.bufferedSamples == 40)
    }

    @Test func pullIntoWritesCountWithoutAllocating() {
        var buffer = JitterBuffer(capacitySamples: 400, prefillSamples: 100)
        buffer.push(ramp(0..<150))
        var out = [Int16](repeating: -1, count: 120)
        out.withUnsafeMutableBufferPointer { buffer.pull(into: $0.baseAddress!, count: 100) }
        #expect(Array(out[0..<100]) == ramp(0..<100))
        #expect(Array(out[100...]) == [Int16](repeating: -1, count: 20))
        // Underrun path pads with zeros in place.
        out.withUnsafeMutableBufferPointer { buffer.pull(into: $0.baseAddress!, count: 100) }
        #expect(Array(out[0..<50]) == ramp(100..<150))
        #expect(Array(out[50..<100]) == [Int16](repeating: 0, count: 50))
        #expect(buffer.underruns == 1)
    }

    @Test func finishServesRemainderBelowPrefill() {
        var buffer = JitterBuffer()
        buffer.push(ramp(0..<500))
        buffer.finish()
        #expect(buffer.pull(500) == ramp(0..<500))
        #expect(buffer.bufferedSamples == 0)
    }

    @Test func resetEmptiesAndUnprimes() {
        var buffer = JitterBuffer(capacitySamples: 400, prefillSamples: 100)
        buffer.push(ramp(0..<200))
        _ = buffer.pull(10)
        buffer.reset()
        #expect(buffer.bufferedSamples == 0)
        #expect(!buffer.isPrimed)
    }
}
