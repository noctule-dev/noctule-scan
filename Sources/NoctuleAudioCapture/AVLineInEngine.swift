// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Foundation

/// What `EngineLineInSource` captures with: an audio engine on one input device. `AVLineInEngine`
/// is the real one; tests use a fake.
public protocol LineInEngine: AnyObject, Sendable {
    /// Starts capture from the input whose Core Audio UID is `deviceUID` and returns the format of
    /// the buffers `onBuffer` will get (the device's rate and channels). `onBuffer` runs on the render
    /// thread, with a buffer of at most `LineInBlock.maxFrames` frames that is reused once it returns,
    /// and the capture time of the buffer's first sample: it must copy, and never block or allocate.
    /// (`EngineLineInSource` drops a bigger buffer and counts it as lost.) Throws
    /// `LineInEngineError.deviceNotFound` when no device has that UID (it left since it was listed).
    func start(
        deviceUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, ContinuousClock.Instant) -> Void
    ) throws -> AVAudioFormat
    /// Stops capture; no `onBuffer` call follows. Ends `configurationChanges`.
    func stop()
    /// Yields when the engine's configuration changed (the device's format changed, or it left), which
    /// stops it.
    var configurationChanges: AsyncStream<Void> { get }
}

/// The size of the blocks a `LineInEngine` hands on, and of `CaptureRing`'s slots.
public enum LineInBlock {
    /// Twice the 512-frame blocks the owner's interface delivers (design §3a); an engine splits a
    /// bigger block.
    public static let maxFrames: AVAudioFrameCount = 1024
}

public enum LineInEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case deviceNotFound(String)
    /// The device has no usable input format.
    case noInput
    case startFailed(String)

    public var description: String {
        switch self {
        case .deviceNotFound(let uid): "no audio input has the UID \(uid)"
        case .noInput: "the device has no audio input"
        case .startFailed(let reason): reason
        }
    }
}

/// Puts `AudioTimeStamp.mHostTime` (mach absolute time, which stops while the Mac sleeps) on the
/// continuous clock: mach continuous time is absolute time plus the time slept, an offset read when
/// capture starts (a wake restarts capture, so it is read again), and one reading of both clocks
/// at that moment ties continuous ticks to a `ContinuousClock.Instant`. Plain arithmetic, so the
/// render thread can use it.
struct HostTimeConverter: Sendable {
    private let numer: UInt64
    private let denom: UInt64
    private let continuousMinusAbsolute: UInt64
    private let anchorInstant: ContinuousClock.Instant
    private let anchorContinuous: UInt64

    init(numer: UInt32, denom: UInt32, continuousMinusAbsolute: UInt64,
         anchorInstant: ContinuousClock.Instant, anchorContinuous: UInt64) {
        self.numer = UInt64(numer); self.denom = UInt64(max(1, denom))
        self.continuousMinusAbsolute = continuousMinusAbsolute
        self.anchorInstant = anchorInstant; self.anchorContinuous = anchorContinuous
    }

    static func now() -> HostTimeConverter {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let absolute = mach_absolute_time()
        let continuous = mach_continuous_time()
        return HostTimeConverter(
            numer: timebase.numer, denom: timebase.denom, continuousMinusAbsolute: continuous &- absolute,
            anchorInstant: .now, anchorContinuous: continuous)
    }

    func instant(hostTime: UInt64) -> ContinuousClock.Instant {
        let ticks = Int64(bitPattern: (hostTime &+ continuousMinusAbsolute) &- anchorContinuous)
        let magnitude = ticks.magnitude
        let nanoseconds = (magnitude / denom) * numer + (magnitude % denom) * numer / denom
        let offset = Duration.nanoseconds(Int64(nanoseconds))
        return ticks < 0 ? anchorInstant - offset : anchorInstant + offset
    }
}

#if os(macOS)
import CoreAudio

/// The AVAudioEngine line-in (line-in design §5.2): the input node pointed at the device through its
/// audio unit, connected to an `AVAudioSinkNode`, which gets the device's own blocks (512 frames
/// every 10.67 ms on the owner's rig; a tap gave 100 ms buffers, design §3a). The sink's callback
/// copies each block into a buffer allocated at start and hands it on, timed from its host time.
///
/// One `start` and one `stop` per engine (`EngineLineInSource` makes a new one for each start),
/// called from one task.
public final class AVLineInEngine: LineInEngine, @unchecked Sendable {
    /// The largest piece handed on at once; a bigger block from the device goes in several.
    static let maxBlockFrames = LineInBlock.maxFrames

    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var observer: NSObjectProtocol?
    public let configurationChanges: AsyncStream<Void>
    private let changes: AsyncStream<Void>.Continuation

    public init() {
        (configurationChanges, changes) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start(
        deviceUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, ContinuousClock.Instant) -> Void
    ) throws -> AVAudioFormat {
        guard let deviceID = CoreAudioInputs.deviceID(forUID: deviceUID) else {
            throw LineInEngineError.deviceNotFound(deviceUID)
        }
        let input = engine.inputNode
        do {
            try input.auAudioUnit.setDeviceID(deviceID)
        } catch {
            throw LineInEngineError.startFailed("\(error)")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxBlockFrames) else {
            throw LineInEngineError.noInput
        }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let capacity = Int(Self.maxBlockFrames)
        let rate = format.sampleRate
        let clock = HostTimeConverter.now()
        let sink = AVAudioSinkNode { timestamp, frameCount, audioBufferList in
            // The render thread: copies into `scratch` (allocated above), no locks.
            let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            let to = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
            let first = timestamp.pointee.mFlags.contains(.hostTimeValid)
                ? clock.instant(hostTime: timestamp.pointee.mHostTime) : ContinuousClock.now
            let total = Int(frameCount)
            var done = 0
            while done < total {
                let frames = min(capacity, total - done)
                for i in 0..<min(from.count, to.count) {
                    guard let source = from[i].mData, let target = to[i].mData else { continue }
                    let offset = done * bytesPerFrame
                    let bytes = min(frames * bytesPerFrame, Int(from[i].mDataByteSize) - offset)
                    if bytes > 0 { memcpy(target, source + offset, bytes) }
                }
                scratch.frameLength = AVAudioFrameCount(frames)
                onBuffer(scratch, done == 0 ? first : first + .seconds(Double(done) / rate))
                done += frames
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        let changes = self.changes
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in changes.yield() }
        self.sink = sink
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw LineInEngineError.startFailed("\(error)")
        }
        return format
    }

    public func stop() {
        engine.stop()
        if let sink {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
        }
        sink = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        changes.finish()
    }
}
#endif
