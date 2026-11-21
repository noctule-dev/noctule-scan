// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Foundation
import Synchronization

/// Hands the render callback's blocks to the queue that runs the pipeline, without allocating or
/// taking a lock on the render thread (LESSONS.md 2026-11-08): a ring of buffers allocated up front,
/// with one writer (the render callback) and one reader (the processing queue), and the two
/// positions in atomics.
///
/// A block that finds the ring full, or that is bigger than a slot, is dropped and its frames are
/// counted; the next block written carries the count, which the reader turns into `lostBefore`.
/// Blocks are copied in the ring's format: a block in another format is copied as far as its
/// buffers and bytes match.
final class CaptureRing: @unchecked Sendable {
    let format: AVAudioFormat
    private let slots: [AVAudioPCMBuffer]
    private let frameCapacity: Int
    private let bytesPerFrame: Int
    private let times: UnsafeMutablePointer<ContinuousClock.Instant>
    private let droppedBefore: UnsafeMutablePointer<Int>
    /// Blocks written and blocks read since the ring was made; block n lives in slot n % slots.count.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// Frames dropped since the last block written. Only the writer touches it (unchecked: no
    /// exclusivity bookkeeping on the render thread).
    @exclusivity(unchecked) private var droppedFrames = 0

    /// 64 slots of `LineInBlock.maxFrames` (1024) frames, 256 KiB a channel: the rig's 512-frame
    /// blocks fill it in about 680 ms, so the reader can fall that far behind before audio is lost.
    /// Every slot is written once here, off the render thread, so the render callback's first pass
    /// through the ring doesn't take a page fault on each slot.
    init(format: AVAudioFormat, slots count: Int = 64, frameCapacity: AVAudioFrameCount = LineInBlock.maxFrames) {
        self.format = format
        self.frameCapacity = Int(frameCapacity)
        bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        slots = (0..<count).map { _ in
            let slot = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
            slot.frameLength = frameCapacity
            for buffer in UnsafeMutableAudioBufferListPointer(slot.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            slot.frameLength = 0
            return slot
        }
        times = .allocate(capacity: count)
        times.initialize(repeating: .now, count: count)
        droppedBefore = .allocate(capacity: count)
        droppedBefore.initialize(repeating: 0, count: count)
    }

    deinit {
        times.deallocate()
        droppedBefore.deallocate()
    }

    /// The writer's side (the render callback): copies `buffer` into the next free slot. False when
    /// it was dropped.
    func write(_ buffer: AVAudioPCMBuffer, at time: ContinuousClock.Instant) -> Bool {
        let frames = Int(buffer.frameLength)
        let position = written.load(ordering: .relaxed)
        guard frames <= frameCapacity, position - read.load(ordering: .acquiring) < slots.count else {
            droppedFrames += frames
            return false
        }
        let index = position % slots.count
        let slot = slots[index]
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(slot.mutableAudioBufferList)
        for i in 0..<min(from.count, to.count) {
            guard let source = from[i].mData, let target = to[i].mData else { continue }
            let bytes = min(Int(from[i].mDataByteSize), frames * bytesPerFrame, frameCapacity * bytesPerFrame)
            memcpy(target, source, bytes)
        }
        slot.frameLength = AVAudioFrameCount(frames)
        times[index] = time
        droppedBefore[index] = droppedFrames
        droppedFrames = 0
        written.store(position + 1, ordering: .releasing)
        return true
    }

    /// The reader's side: hands each block written since the last drain to `body`, with its first
    /// sample's capture time and the frames dropped just before it, oldest first. The buffer is the
    /// ring's own and is reused once `body` returns.
    func drain(_ body: (AVAudioPCMBuffer, ContinuousClock.Instant, Int) -> Void) {
        var position = read.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        while position < end {
            let index = position % slots.count
            body(slots[index], times[index], droppedBefore[index])
            position += 1
            read.store(position, ordering: .releasing)
        }
    }
}
