// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Foundation
import NoctuleKit
import Testing
import NoctuleAudioCapture

/// The line-in pipeline on synthetic buffers: nothing here opens an audio device.
@Suite(.timeLimit(.minutes(3))) struct LineInPipelineTests {
    /// Feeds `seconds` of audio to `pipeline` in buffers of `frames`, each timed at its first sample
    /// from `start`, with `sample(channel, index)` the value of that channel at that device sample.
    @discardableResult
    private func feed(
        _ pipeline: LineInPipeline, format: AVAudioFormat, seconds: Double, frames: AVAudioFrameCount = 480,
        start: ContinuousClock.Instant, firstIndex: Int = 0,
        sample: (Int, Int) -> Float
    ) -> (chunks: [AudioChunk], levels: [LineInLevel]) {
        var chunks: [AudioChunk] = []
        var levels: [LineInLevel] = []
        let total = Int(seconds * format.sampleRate)
        var index = 0
        while index < total {
            let count = min(Int(frames), total - index)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(format.channelCount) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<count { data[i] = sample(channel, firstIndex + index + i) }
            }
            let at = start + .seconds(Double(firstIndex + index) / format.sampleRate)
            let result = pipeline.process(buffer, firstSampleAt: at)
            chunks += result.chunks
            levels += result.levels
            index += count
        }
        return (chunks, levels)
    }

    private func format(_ rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    private func tone(_ hz: Double, amplitude: Float, rate: Double) -> (Int) -> Float {
        { i in amplitude * Float(sin(2 * Double.pi * hz * Double(i) / rate)) }
    }

    private func peak(_ chunks: [AudioChunk]) -> Int {
        chunks.flatMap(\.samples).map { abs(Int($0)) }.max() ?? 0
    }

    @Test func chunksAre320At8k() {
        let fmt = format(48_000, channels: 2)
        let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 77)
        let start = ContinuousClock.now
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        let out = feed(pipeline, format: fmt, seconds: 1, start: start) { _, i in t(i) }
        #expect(out.chunks.count == 25)
        #expect(out.chunks.allSatisfy { $0.samples.count == 320 })
        #expect(out.chunks.map(\.sequence) == (0..<25).map { UInt16($0) })
        #expect(out.chunks.allSatisfy { $0.ssrc == 77 })
        #expect(out.chunks.allSatisfy { $0.lostBefore == 0 && !$0.discontinuity })
        for (n, chunk) in out.chunks.enumerated() {
            let expected = start + .milliseconds(40 * n)
            let error = chunk.receivedAt - expected
            #expect(error > .milliseconds(-1) && error < .milliseconds(1), "chunk \(n) is \(error) off")
            #expect(chunk.rtpTimestamp == UInt32(n * 320))
        }
        #expect(out.levels.count == 30)
    }

    /// A minute of audio, seconds of CPU on the runner: fed on a dispatch thread, as the ten-minute
    /// check is, so it holds no cooperative thread the line-in source's tests need.
    @Test func fortyFourOneHasNoDrift() async {
        let fmt = format(44_100, channels: 2)
        let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        let start = ContinuousClock.now
        let t = tone(440, amplitude: 0.5, rate: 44_100)
        nonisolated(unsafe) let work = { feed(pipeline, format: fmt, seconds: 60, frames: 512, start: start) { _, i in t(i) } }
        let out = await withCheckedContinuation { (continuation: CheckedContinuation<(chunks: [AudioChunk], levels: [LineInLevel]), Never>) in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
        let total = out.chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 480_000) <= 320, "got \(total) samples")
        #expect(out.chunks.allSatisfy { $0.samples.count == 320 })
        // 44.1 kHz input still steps 40 ms exactly (blocks of 512 frames, the rig's size, don't
        // convert to a whole number of samples, so a converter rebuilt per buffer would drift).
        let last = out.chunks[out.chunks.count - 1]
        let error = last.receivedAt - (start + .milliseconds(40 * (out.chunks.count - 1)))
        #expect(error > .milliseconds(-1) && error < .milliseconds(1))
    }

    @Test func leftAndRightAreSeparate() {
        let fmt = format(48_000, channels: 2)
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        let left = LineInPipeline(inputFormat: fmt, channel: .left, ssrc: 1)
        let leftOut = feed(left, format: fmt, seconds: 1, start: .now) { c, i in c == 0 ? t(i) : 0 }
        let right = LineInPipeline(inputFormat: fmt, channel: .right, ssrc: 1)
        let rightOut = feed(right, format: fmt, seconds: 1, start: .now) { c, i in c == 0 ? t(i) : 0 }
        let expected = 0.5 * 32767
        #expect(Double(peak(Array(leftOut.chunks.dropFirst(2)))) > expected * 0.9)
        #expect(Double(peak(Array(leftOut.chunks.dropFirst(2)))) < expected * 1.1)
        #expect(peak(rightOut.chunks) <= 1)
        // The meter follows the chosen channel too.
        #expect(leftOut.levels.contains { $0.peakDBFS > -7 })
        #expect(rightOut.levels.allSatisfy { $0.peakDBFS == -.infinity })
    }

    @Test func bothIsTheMean() {
        let fmt = format(48_000, channels: 2)
        let t = tone(440, amplitude: 1, rate: 48_000)
        let mean = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        let meanOut = feed(mean, format: fmt, seconds: 1, start: .now) { c, i in c == 0 ? 0.6 * t(i) : 0.2 * t(i) }
        // The mean of 0.6 and 0.2 of one tone is 0.4 of it.
        let p = Double(peak(Array(meanOut.chunks.dropFirst(2))))
        #expect(p > 0.4 * 32767 * 0.9 && p < 0.4 * 32767 * 1.1, "peak \(p)")
        let cancel = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        let cancelOut = feed(cancel, format: fmt, seconds: 1, start: .now) { c, i in c == 0 ? 0.5 * t(i) : -0.5 * t(i) }
        #expect(peak(cancelOut.chunks) <= 2)
    }

    /// Under Both the meter reads the louder raw channel (ruling R20): a full-scale signal on one
    /// side and silence on the other averages to half scale, about -6 dBFS, inside the target band,
    /// so a meter on the mean would show an ideal level and no clip while the input clips. The
    /// recording still takes the mean.
    @Test func bothMetersTheLouderRawChannel() {
        let fmt = format(48_000, channels: 2)
        let square: (Int) -> Float = { i in (i / 60) % 2 == 0 ? 1 : -1 }  // 400 Hz, full scale
        for loud in [0, 1] {
            let both = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
            let out = feed(both, format: fmt, seconds: 1, start: .now) { c, i in c == loud ? square(i) : 0 }
            #expect(out.levels.contains { $0.clipped }, "clip on channel \(loud) not caught")
            let peak = out.levels.map(\.peakDBFS).max() ?? -.infinity
            #expect(peak > -0.1, "channel \(loud): meter peak \(peak) dBFS")

            // The chunks are the mean: the same as half the square on one channel alone.
            let half = LineInPipeline(inputFormat: fmt, channel: .left, ssrc: 1)
            let reference = feed(half, format: fmt, seconds: 1, start: .now) { c, i in c == 0 ? 0.5 * square(i) : 0 }
            #expect(out.chunks.map(\.samples) == reference.chunks.map(\.samples))
            #expect(!reference.levels.contains { $0.clipped })
        }

        // An interleaved buffer's right channel is metered from its own samples too.
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        let data = buffer.floatChannelData![0]
        for i in 0..<4_800 { data[2 * i] = 0; data[2 * i + 1] = square(i) }
        let levels = LineInPipeline(inputFormat: interleaved, channel: .both, ssrc: 1).process(buffer, firstSampleAt: .now).levels
        #expect(levels.contains { $0.clipped })
        #expect((levels.map(\.peakDBFS).max() ?? -.infinity) > -0.1)
    }

    @Test func monoDeviceIgnoresTheChannelChoice() {
        let fmt = format(48_000, channels: 1)
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        for channel in LineInChannel.allCases {
            let pipeline = LineInPipeline(inputFormat: fmt, channel: channel, ssrc: 1)
            let out = feed(pipeline, format: fmt, seconds: 1, start: .now) { _, i in t(i) }
            let p = Double(peak(Array(out.chunks.dropFirst(2))))
            #expect(p > 0.5 * 32767 * 0.9, "\(channel): peak \(p)")
            #expect(out.levels.contains { $0.peakDBFS > -7 })
        }
    }

    @Test func clipMeasuredBeforeConversion() {
        let fmt = format(48_000, channels: 2)
        let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        // 12 kHz square wave at full scale: above the 8 kHz stream's band, so almost nothing survives
        // conversion, yet the input was clipping.
        let out = feed(pipeline, format: fmt, seconds: 0.5, start: .now) { _, i in (i / 2) % 2 == 0 ? 1 : -1 }
        #expect(out.levels.contains { $0.clipped })
        #expect(peak(out.chunks) < 8000, "the converted square wave kept a peak of \(peak(out.chunks))")
    }

    @Test func discontinuityFlagsTheNextChunk() {
        let fmt = format(48_000, channels: 2)
        let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        let start = ContinuousClock.now
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        let before = feed(pipeline, format: fmt, seconds: 0.5, start: start) { _, i in t(i) }
        #expect(before.chunks.allSatisfy { !$0.discontinuity })
        pipeline.markDiscontinuity()
        // The device came back 3 s later.
        let resumedAt = start + .seconds(3.5)
        let after = feed(pipeline, format: fmt, seconds: 0.5, start: resumedAt) { _, i in t(i) }
        #expect(after.chunks.count >= 10)
        #expect(after.chunks[0].discontinuity)
        #expect(after.chunks.dropFirst().allSatisfy { !$0.discontinuity })
        // Re-anchored on the new time, and the sequence carried on.
        let error = after.chunks[0].receivedAt - resumedAt
        #expect(error > .milliseconds(-1) && error < .milliseconds(1))
        #expect(after.chunks[0].sequence == before.chunks[before.chunks.count - 1].sequence &+ 1)
    }

    @Test func droppedChunksSetLostBefore() {
        let fmt = format(48_000, channels: 2)
        let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        let start = ContinuousClock.now
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        let before = feed(pipeline, format: fmt, seconds: 0.4, start: start) { _, i in t(i) }
        // Five chunks (200 ms) of buffers never arrived.
        pipeline.noteDropped(chunks: 5)
        let resumedAt = start + .milliseconds(600)
        let after = feed(pipeline, format: fmt, seconds: 0.4, start: start, firstIndex: 28_800) { _, i in t(i) }
        #expect(after.chunks[0].lostBefore == 5)
        #expect(after.chunks.dropFirst().allSatisfy { $0.lostBefore == 0 })
        #expect(!after.chunks[0].discontinuity)
        #expect(after.chunks[0].sequence == before.chunks[before.chunks.count - 1].sequence &+ 6)
        let error = after.chunks[0].receivedAt - resumedAt
        #expect(error > .milliseconds(-1) && error < .milliseconds(1))
    }

    @Test func interleavedStereoIsReadLikePlanar() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        let data = buffer.floatChannelData![0]
        for i in 0..<4_800 { data[2 * i] = t(i); data[2 * i + 1] = 0 }
        let right = LineInPipeline(inputFormat: fmt, channel: .right, ssrc: 1)
        #expect(peak(right.process(buffer, firstSampleAt: .now).chunks) <= 1)
        let left = LineInPipeline(inputFormat: fmt, channel: .left, ssrc: 1)
        let out = left.process(buffer, firstSampleAt: .now)
        #expect(out.chunks.count == 2)
        #expect(peak(out.chunks) > 10_000)
    }

    /// Ten minutes of audio is seconds of CPU in a debug build (33 s under background priority and
    /// load): on a cooperative thread it held every other test in this process, and under a
    /// one-thread pool `EngineLineInSourceTests` timed out waiting (local sweep). It runs on a
    /// dispatch thread.
    @Test func chunkTimesFollowAFastDeviceClock() async {
        // A device clock 100 ppm fast: its n-th sample is captured at n / (rate × 1.0001) host seconds.
        let rate = 48_000.0
        let fmt = format(rate, channels: 2)
        let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        let start = ContinuousClock.now
        let block = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 512)!
        block.frameLength = 512
        for c in 0..<2 { for i in 0..<512 { block.floatChannelData![c][i] = 0.1 * Float(sin(Double(i) * 0.3)) } }
        nonisolated(unsafe) let work = (pipeline, block)
        let (last, lastCount) = await withCheckedContinuation { (continuation: CheckedContinuation<(AudioChunk?, Int), Never>) in
            DispatchQueue.global().async {
                let (pipeline, block) = work
                var last: AudioChunk?
                var lastCount = 0
                let blocks = 56_250   // ten minutes
                for n in 0..<blocks {
                    let at = start + .seconds(Double(n * 512) / (rate * 1.0001))
                    let out = pipeline.process(block, firstSampleAt: at)
                    if let chunk = out.chunks.last { last = chunk }
                    lastCount += out.chunks.count
                }
                continuation.resume(returning: (last, lastCount))
            }
        }
        let chunk = try! #require(last)
        // Chunk k starts at input sample k × 1920.
        let capture = start + .seconds(Double((lastCount - 1) * 1920) / (rate * 1.0001))
        let error = chunk.receivedAt - capture
        #expect(error > .milliseconds(-25) && error < .milliseconds(25), "the last chunk is \(error) off its capture")
        #expect(chunk.sequence == UInt16(truncatingIfNeeded: lastCount - 1))
        #expect(!chunk.discontinuity)
    }

    @Test func anUnreportedGapMovesTheChunksAfterIt() {
        let fmt = format(48_000, channels: 2)
        let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        let start = ContinuousClock.now
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        let before = feed(pipeline, format: fmt, seconds: 0.5, frames: 512, start: start) { _, i in t(i) }
        // 200 ms of buffers never arrived and nobody said so.
        let resumedAt = start + .milliseconds(700)
        let after = feed(pipeline, format: fmt, seconds: 0.5, frames: 512, start: resumedAt) { _, i in t(i) }
        // The chunk that was half built at the gap holds old samples; every later chunk starts that
        // many 8 kHz samples after the first post-gap sample. 4 000 output samples came before the gap.
        let held = 4_000 % 320
        for (j, chunk) in after.chunks.enumerated().dropFirst() {
            let expected = resumedAt + .seconds(Double(320 * j - held) / 8_000)
            let error = chunk.receivedAt - expected
            #expect(error > .milliseconds(-25) && error < .milliseconds(25), "chunk \(j) is \(error) off")
        }
        // The chunks are still one stream: no flag, no skipped sequence, nothing lost.
        let all = before.chunks + after.chunks
        #expect(all.map(\.sequence) == (0..<all.count).map { UInt16($0) })
        #expect(all.allSatisfy { !$0.discontinuity && $0.lostBefore == 0 })
        #expect(after.chunks.count >= 10)
    }

    @Test func aDiscontinuityCarriesNoLostBefore() {
        let fmt = format(48_000, channels: 2)
        let t = tone(440, amplitude: 0.5, rate: 48_000)
        for dropFirst in [true, false] {
            let pipeline = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
            let start = ContinuousClock.now
            feed(pipeline, format: fmt, seconds: 0.2, start: start) { _, i in t(i) }
            if dropFirst {
                pipeline.noteDropped(chunks: 3)
                pipeline.markDiscontinuity()
            } else {
                pipeline.markDiscontinuity()
                pipeline.noteDropped(chunks: 3)
            }
            let after = feed(pipeline, format: fmt, seconds: 0.2, start: start + .seconds(1)) { _, i in t(i) }
            #expect(after.chunks[0].discontinuity)
            #expect(after.chunks[0].lostBefore == 0)
        }
    }

    /// A restarted capture may come back at another rate, which this pipeline's guard would drop:
    /// `continued` makes a pipeline for the new rate that carries on the sequence and the RTP
    /// timestamp, with its first chunk flagged.
    @Test func continuedFollowsOnAtAnotherRate() {
        let fmt48 = format(48_000, channels: 1)
        let fmt441 = format(44_100, channels: 1)
        let first = LineInPipeline(inputFormat: fmt48, channel: .both, ssrc: 1)
        let start = ContinuousClock.now
        let before = feed(first, format: fmt48, seconds: 0.5, start: start) { _, i in
            tone(440, amplitude: 0.5, rate: 48_000)(i)
        }
        #expect(before.chunks.count == 12)

        let next = first.continued(inputFormat: fmt441, ssrc: 2)
        let resumedAt = start + .seconds(2)
        let after = feed(next, format: fmt441, seconds: 0.5, start: resumedAt) { _, i in
            tone(440, amplitude: 0.5, rate: 44_100)(i)
        }
        #expect(after.chunks.count >= 11)
        #expect(after.chunks.allSatisfy { $0.samples.count == 320 && $0.ssrc == 2 && $0.lostBefore == 0 })
        #expect(after.chunks[0].discontinuity)
        #expect(after.chunks.dropFirst().allSatisfy { !$0.discontinuity })
        let last = before.chunks[before.chunks.count - 1]
        #expect(after.chunks[0].sequence == last.sequence &+ 1)
        #expect(after.chunks[0].rtpTimestamp == last.rtpTimestamp &+ 320)
        let error = after.chunks[0].receivedAt - resumedAt
        #expect(error > .milliseconds(-1) && error < .milliseconds(1))
        // The old pipeline would have dropped every buffer at the new rate.
        let stale = feed(first, format: fmt441, seconds: 0.2, start: resumedAt) { _, _ in 0.5 }
        #expect(stale.chunks.isEmpty)
    }

    /// Before any chunk there is nothing to be discontinuous with: the first chunk of a stream is
    /// never flagged (`AudioChunk.discontinuity`), even when its capture restarted first.
    @Test func continuedBeforeAnyChunkIsNotADiscontinuity() {
        let fmt = format(48_000, channels: 1)
        let first = LineInPipeline(inputFormat: fmt, channel: .both, ssrc: 1)
        // Less than a chunk, then a restart.
        feed(first, format: fmt, seconds: 0.02, start: ContinuousClock.now) { _, _ in 0.25 }
        let next = first.continued(inputFormat: fmt, ssrc: 2)
        let after = feed(next, format: fmt, seconds: 0.2, start: ContinuousClock.now) { _, _ in 0.25 }
        #expect(after.chunks.count == 5)
        #expect(after.chunks.allSatisfy { !$0.discontinuity })
        #expect(after.chunks.map(\.sequence) == [0, 1, 2, 3, 4])
    }
}
