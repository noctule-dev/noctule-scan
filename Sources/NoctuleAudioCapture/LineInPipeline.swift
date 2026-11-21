// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Foundation
import NoctuleKit

/// Turns a line-in's device-rate buffers into what the recorder takes: 16-bit 8 kHz mono
/// `AudioChunk`s of 320 samples (40 ms, the size of an SDS200 RTP packet), plus meter levels
/// (line-in design §5.2, §5.3).
///
/// Per buffer: pick the chosen channel (Both is the mean of the first two; a one-channel device
/// uses its channel whatever is chosen), measure levels at the device's rate, convert to 8 kHz
/// mono, round to 16 bits and cut into chunks. Under Both the levels come from the two raw
/// channels, not the mean: each window takes the louder channel's peak and RMS, and is clipped
/// when either channel clipped, since a clip on one side alone averages to half scale (ruling R20). One `AVAudioConverter` lives as long as the
/// pipeline, so the resampler's state carries across buffers: no drift and no click at a buffer edge.
///
/// A chunk's `receivedAt` is the capture time of its first sample, counted from a capture time the
/// pipeline took (its first buffer, or the first after `markDiscontinuity()` or
/// `noteDropped(chunks:)`), so exactly timed input of any rate still steps 40 ms exactly. Each
/// buffer's own `firstSampleAt` is checked against that count, and the count starts again from it
/// when they differ by more than `retimeThreshold`: a device clock that runs a little fast or slow
/// against the host's, or a gap nobody reported, can't carry the times away from the capture.
/// A new pipeline is needed for another sample rate (`continued(inputFormat:ssrc:)` after a
/// restart). Not thread-safe: one queue calls it.
public final class LineInPipeline {
    public static let chunkSamples = 320
    public static let outputRate = 8000.0
    /// How far a buffer's time may differ from the sample count's before the count restarts from it:
    /// above the jitter of buffers handed over in 20 ms blocks, and far inside the recorder's 0.5 s pre-roll.
    static let retimeThreshold: Duration = .milliseconds(20)

    private let channel: LineInChannel
    private let ssrc: UInt32
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let monoInput: AVAudioFormat
    private let monoOutput: AVAudioFormat
    private var meter: LineInMeter
    /// The right channel's meter under Both on a device with two or more channels (`meter` then
    /// reads the left); nil otherwise.
    private var rightMeter: LineInMeter?

    private var scratch: AVAudioPCMBuffer?
    /// A buffer's raw left and right samples, for the meters under Both.
    private var rawLeft: [Float] = []
    private var rawRight: [Float] = []
    private var converted: AVAudioPCMBuffer?

    /// Converted samples not yet in a chunk.
    private var pending: [Int16] = []
    /// The capture time the next chunk counts from, and how many converted samples have gone into
    /// chunks since. `nil` until a buffer sets it.
    private var anchor: ContinuousClock.Instant?
    private var samplesSinceAnchor = 0
    private var needsAnchor = true

    private var sequence: UInt16 = 0
    private var rtpTimestamp: UInt32 = 0
    private var droppedChunks = 0
    private var flagDiscontinuity = false
    /// Whether this pipeline, or one it continues, has made a chunk.
    private var madeChunks = false

    public init(inputFormat: AVAudioFormat, channel: LineInChannel, ssrc: UInt32) {
        self.inputFormat = inputFormat
        self.channel = channel
        self.ssrc = ssrc
        monoInput = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                  channels: 1, interleaved: false)!
        monoOutput = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate,
                                   channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: monoInput, to: monoOutput)
        // No priming frames, so the output starts with the input and the chunk times are honest from
        // the start; the best quality that adds only about a millisecond (the default folds 5 kHz
        // into the band at -15 dB, this at -52 dB, and the Mastering algorithm adds 72 ms).
        converter?.primeMethod = .none
        converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        meter = LineInMeter(sampleRate: inputFormat.sampleRate)
        if channel == .both && inputFormat.channelCount >= 2 {
            rightMeter = LineInMeter(sampleRate: inputFormat.sampleRate)
        }
    }

    /// Takes the next buffer, whose first sample was captured at `firstSampleAt`, and returns the
    /// chunks and meter levels it completes. A buffer that isn't 32-bit float, isn't at the
    /// pipeline's sample rate, or that the converter can't take, yields nothing.
    public func process(
        _ buffer: AVAudioPCMBuffer, firstSampleAt: ContinuousClock.Instant
    ) -> (chunks: [AudioChunk], levels: [LineInLevel]) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.format.sampleRate == inputFormat.sampleRate, let converter, let data = buffer.floatChannelData,
              let mono = monoBuffer(capacity: frames) else { return ([], []) }

        pickChannel(from: buffer, data: data, into: mono, frames: frames)
        mono.frameLength = AVAudioFrameCount(frames)

        let levels = rightMeter == nil
            ? meter.ingest(UnsafeBufferPointer(start: mono.floatChannelData![0], count: frames), firstSampleAt: firstSampleAt)
            : meterEachChannel(of: buffer, data: data, frames: frames, firstSampleAt: firstSampleAt)

        if needsAnchor {
            anchor = firstSampleAt
            samplesSinceAnchor = 0
            pending.removeAll(keepingCapacity: true)
            needsAnchor = false
        } else if let anchor {
            // Where the count puts this buffer's first sample, the half-built chunk counted in.
            let predicted = anchor + .seconds(Double(samplesSinceAnchor + pending.count) / Self.outputRate)
            let error = firstSampleAt - predicted
            if error > Self.retimeThreshold || error < .zero - Self.retimeThreshold {
                // Restart the count from the capture time, keeping the half-built chunk, whose
                // first sample comes `pending.count` samples before this buffer's.
                self.anchor = firstSampleAt - .seconds(Double(pending.count) / Self.outputRate)
                samplesSinceAnchor = 0
            }
        }

        let outCapacity = AVAudioFrameCount(Double(frames) * Self.outputRate / inputFormat.sampleRate) + 16
        guard let out = convertedBuffer(capacity: outCapacity) else { return ([], levels) }
        out.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return mono
        }
        guard status != .error, error == nil, let samples = out.floatChannelData?[0] else { return ([], levels) }
        for i in 0..<Int(out.frameLength) {
            pending.append(Int16(max(-32768, min(32767, (samples[i] * 32767).rounded()))))
        }
        return (cutChunks(), levels)
    }

    /// The next chunk follows a break in the capture (the device came back, the engine restarted):
    /// it is flagged `discontinuity`, the time and the resampler start afresh, and the half-built
    /// chunk and meter window are dropped.
    public func markDiscontinuity() {
        flagDiscontinuity = true
        // How much audio is missing before a discontinuity is unknown, so `lostBefore` is 0 on it.
        droppedChunks = 0
        converter?.reset()
        restart()
    }

    /// A pipeline for this line-in after its capture restarted, at the rate the restart gave (which
    /// may differ: this pipeline drops buffers at any other rate). Its chunks carry on this one's
    /// sequence and RTP timestamp under `ssrc`, and its first is flagged `discontinuity`, unless no
    /// chunk came before (a stream's first chunk never is).
    public func continued(inputFormat: AVAudioFormat, ssrc: UInt32) -> LineInPipeline {
        let next = LineInPipeline(inputFormat: inputFormat, channel: channel, ssrc: ssrc)
        next.sequence = sequence
        next.rtpTimestamp = rtpTimestamp
        next.madeChunks = madeChunks
        next.flagDiscontinuity = madeChunks
        return next
    }

    /// `chunks` whole chunks of audio, counted as 8 kHz output chunks of 320 samples (40 ms; the
    /// caller rounds the device blocks it lost), never reached `process` (the capture callback found
    /// its queue full): the next chunk carries them as `lostBefore`, its sequence and RTP timestamp
    /// skip them, and its time is taken from the buffer that follows the gap. The half-built chunk
    /// (under 40 ms) and the meter's partly filled window are dropped.
    public func noteDropped(chunks: Int) {
        guard chunks > 0 else { return }
        droppedChunks += chunks
        sequence &+= UInt16(truncatingIfNeeded: chunks)
        rtpTimestamp &+= UInt32(truncatingIfNeeded: chunks * Self.chunkSamples)
        restart()
    }

    private func restart() {
        needsAnchor = true
        pending.removeAll(keepingCapacity: true)
        meter = LineInMeter(sampleRate: inputFormat.sampleRate)
        if rightMeter != nil { rightMeter = LineInMeter(sampleRate: inputFormat.sampleRate) }
    }

    /// Meters `buffer`'s raw left and right channels apart and merges their windows, which line up
    /// (both meters take the same number of samples): the louder channel's peak and RMS, clipped
    /// when either channel clipped.
    private func meterEachChannel(
        of buffer: AVAudioPCMBuffer, data: UnsafePointer<UnsafeMutablePointer<Float>>,
        frames: Int, firstSampleAt: ContinuousClock.Instant
    ) -> [LineInLevel] {
        let stride = buffer.stride
        let left = data[0], right = buffer.format.isInterleaved ? data[0] + 1 : data[1]
        rawLeft.removeAll(keepingCapacity: true)
        rawRight.removeAll(keepingCapacity: true)
        for i in 0..<frames {
            rawLeft.append(left[i * stride])
            rawRight.append(right[i * stride])
        }
        let leftLevels = rawLeft.withUnsafeBufferPointer { meter.ingest($0, firstSampleAt: firstSampleAt) }
        let rightLevels = rawRight.withUnsafeBufferPointer { rightMeter!.ingest($0, firstSampleAt: firstSampleAt) }
        return zip(leftLevels, rightLevels).map { l, r in
            let louder = r.peakDBFS > l.peakDBFS ? r : l
            return LineInLevel(peakDBFS: louder.peakDBFS, rmsDBFS: louder.rmsDBFS,
                               clipped: l.clipped || r.clipped, at: l.at)
        }
    }

    private func cutChunks() -> [AudioChunk] {
        guard let anchor else { return [] }
        var chunks: [AudioChunk] = []
        var start = 0
        while pending.count - start >= Self.chunkSamples {
            chunks.append(AudioChunk(
                samples: Array(pending[start..<start + Self.chunkSamples]),
                rtpTimestamp: rtpTimestamp, sequence: sequence,
                receivedAt: anchor + .seconds(Double(samplesSinceAnchor) / Self.outputRate),
                ssrc: ssrc, lostBefore: flagDiscontinuity ? 0 : droppedChunks, discontinuity: flagDiscontinuity))
            droppedChunks = 0
            flagDiscontinuity = false
            madeChunks = true
            sequence &+= 1
            rtpTimestamp &+= UInt32(Self.chunkSamples)
            samplesSinceAnchor += Self.chunkSamples
            start += Self.chunkSamples
        }
        pending.removeFirst(start)
        return chunks
    }

    /// Writes the chosen channel of `buffer` into `mono`: a one-channel buffer as it is, otherwise
    /// the left (first), the right (second) or their mean.
    private func pickChannel(
        from buffer: AVAudioPCMBuffer, data: UnsafePointer<UnsafeMutablePointer<Float>>,
        into mono: AVAudioPCMBuffer, frames: Int
    ) {
        let out = mono.floatChannelData![0]
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        let channels = Int(buffer.format.channelCount)
        func source(_ channel: Int) -> UnsafeMutablePointer<Float> {
            interleaved ? data[0] + channel : data[channel]
        }
        let choice: LineInChannel = channels < 2 ? .left : channel
        switch choice {
        case .left:
            let left = source(0)
            for i in 0..<frames { out[i] = left[i * stride] }
        case .right:
            let right = source(1)
            for i in 0..<frames { out[i] = right[i * stride] }
        case .both:
            let left = source(0), right = source(1)
            for i in 0..<frames { out[i] = (left[i * stride] + right[i * stride]) / 2 }
        }
    }

    private func monoBuffer(capacity: Int) -> AVAudioPCMBuffer? {
        if let scratch, Int(scratch.frameCapacity) >= capacity { return scratch }
        scratch = AVAudioPCMBuffer(pcmFormat: monoInput, frameCapacity: AVAudioFrameCount(capacity))
        return scratch
    }

    private func convertedBuffer(capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let converted, converted.frameCapacity >= capacity { return converted }
        converted = AVAudioPCMBuffer(pcmFormat: monoOutput, frameCapacity: capacity)
        return converted
    }
}
