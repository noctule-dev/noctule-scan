// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Foundation
import NoctuleKit
import Synchronization
import Testing
@testable import NoctuleAudioCapture

/// `EngineLineInSource` against a fake engine, a listing and a permission the test controls.
/// Nothing here opens an audio device, lists Core Audio's devices or asks for permission: no test
/// calls `EngineLineInSource.system(_:)`, `CoreAudioInputs` or `AVLineInEngine`.
@Suite(.timeLimit(.minutes(1))) struct EngineLineInSourceTests {
    static let savedUID = "fake-uid:USB Line In:1"
    static let savedName = "USB Line In"
    static let config = LineInConfig(deviceUID: savedUID, deviceName: savedName, channel: .both)
    static let device = AudioInputDevice(uid: savedUID, name: savedName, channelCount: 1)

    // MARK: - Fakes

    /// An input listing the test changes. `hold()` makes the next `inputs()` call wait until
    /// `release()`, as a slow Core Audio listing would, so a test can stop the source mid-decision.
    final class Inputs: AudioInputListing {
        private struct State {
            var devices: [AudioInputDevice]
            /// Set by `hold()`; the next `inputs()` takes it and waits on it.
            var gate: DispatchSemaphore?
            var waitingOn: DispatchSemaphore?
        }
        private let state: Mutex<State>
        init(_ devices: [AudioInputDevice]) { state = Mutex(State(devices: devices)) }

        func inputs() -> [AudioInputDevice] {
            let gate = state.withLock { s -> DispatchSemaphore? in
                defer { s.gate = nil }
                s.waitingOn = s.gate
                return s.gate
            }
            gate?.wait()
            return state.withLock { $0.devices }
        }

        func set(_ new: [AudioInputDevice]) { state.withLock { $0.devices = new } }
        func hold() { state.withLock { $0.gate = DispatchSemaphore(value: 0) } }
        /// Whether an `inputs()` call is waiting on `hold()`.
        var isHeld: Bool { state.withLock { $0.waitingOn != nil } }
        func release() {
            state.withLock { s in defer { s.waitingOn = nil }; return s.waitingOn }?.signal()
        }
    }

    struct FakeEngineError: Error, CustomStringConvertible {
        var description: String { "the device refused" }
    }

    /// Every engine the source made, and what the next start gives.
    final class Engines: Sendable {
        private struct State {
            var made: [FakeEngine] = []
            var nextRate = 48_000.0
            var failNext = false
        }
        private let state = Mutex(State())

        func make() -> any LineInEngine {
            let engine = FakeEngine(owner: self)
            state.withLock { $0.made.append(engine) }
            return engine
        }

        var made: [FakeEngine] { state.withLock { $0.made } }
        /// The UIDs the engines were started on, in order.
        var starts: [String] { made.compactMap(\.startedUID) }
        var latest: FakeEngine? { made.last { $0.startedUID != nil } }

        func setNextRate(_ rate: Double) { state.withLock { $0.nextRate = rate } }
        func failNextStart() { state.withLock { $0.failNext = true } }

        fileprivate func takeStartPlan() -> (rate: Double, fail: Bool) {
            state.withLock { s in
                defer { s.failNext = false }
                return (s.nextRate, s.failNext)
            }
        }
    }

    /// Records its start and stop, and hands the test's buffers to the source as the sink node would.
    final class FakeEngine: LineInEngine, @unchecked Sendable {
        private struct State {
            var uid: String?
            var onBuffer: (@Sendable (AVAudioPCMBuffer, ContinuousClock.Instant) -> Void)?
            var stopped = false
            var rate = 0.0
        }
        private let state = Mutex(State())
        private unowned let owner: Engines
        let configurationChanges: AsyncStream<Void>
        private let changes: AsyncStream<Void>.Continuation

        init(owner: Engines) {
            self.owner = owner
            (configurationChanges, changes) = AsyncStream.makeStream(of: Void.self)
        }

        func start(
            deviceUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, ContinuousClock.Instant) -> Void
        ) throws -> AVAudioFormat {
            let plan = owner.takeStartPlan()
            if plan.fail { throw FakeEngineError() }
            state.withLock { $0.uid = deviceUID; $0.onBuffer = onBuffer; $0.rate = plan.rate }
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: plan.rate, channels: 1, interleaved: false)!
        }

        func stop() {
            state.withLock { $0.stopped = true; $0.onBuffer = nil }
            changes.finish()
        }

        var startedUID: String? { state.withLock { $0.uid } }
        var stopped: Bool { state.withLock { $0.stopped } }
        var rate: Double { state.withLock { $0.rate } }

        func changeConfiguration() { changes.yield() }

        /// Hands one block to the source, as the render callback would.
        func push(_ buffer: AVAudioPCMBuffer, at time: ContinuousClock.Instant) {
            state.withLock { $0.onBuffer }?(buffer, time)
        }
    }

    /// A permission prompt that answers only when the test says so.
    final class PermissionGate: Sendable {
        private let waiting = Mutex<[CheckedContinuation<Bool, Never>]>([])
        private let count = Mutex(0)

        func ask() async -> Bool {
            await withCheckedContinuation { continuation in
                waiting.withLock { $0.append(continuation) }
                count.withLock { $0 += 1 }
            }
        }

        var asked: Int { count.withLock { $0 } }

        func answer(_ granted: Bool) {
            for continuation in waiting.withLock({ w in defer { w = [] }; return w }) {
                continuation.resume(returning: granted)
            }
        }
    }

    /// Everything a stream has yielded, and whether it has finished.
    final class Collector<Element: Sendable>: Sendable {
        private let state = Mutex<(items: [Element], finished: Bool)>(([], false))

        init(_ stream: AsyncStream<Element>) {
            Task {
                for await item in stream { self.state.withLock { $0.items.append(item) } }
                self.state.withLock { $0.finished = true }
            }
        }

        var items: [Element] { state.withLock { $0.items } }
        var finished: Bool { state.withLock { $0.finished } }
    }

    struct Rig {
        let source: EngineLineInSource
        let inputs: Inputs
        let engines: Engines
        let deviceChanges: AsyncStream<Void>.Continuation
        let chunks: Collector<AudioChunk>
        let levels: Collector<LineInLevel>
        let states: Collector<LineInState>
    }

    private func makeRig(
        config: LineInConfig = Self.config, inputs: [AudioInputDevice] = [Self.device],
        permission: @escaping @Sendable () async -> Bool = { true },
        processing: DispatchQueue = DispatchQueue(label: "test.line-in")
    ) -> Rig {
        let listing = Inputs(inputs)
        let engines = Engines()
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        let source = EngineLineInSource(
            config: config, inputs: listing, deviceChanges: changes, permission: permission,
            makeEngine: { engines.make() }, processing: processing)
        return Rig(source: source, inputs: listing, engines: engines, deviceChanges: continuation,
                   chunks: Collector(source.chunks), levels: Collector(source.levels), states: Collector(source.states))
    }

    // MARK: - Helpers

    /// Polls `condition` until it holds, failing the test after `timeout`.
    private func waitUntil(
        _ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Stops `source` (see `stopWithin`).
    private func stop(
        _ source: EngineLineInSource, within limit: Duration = .seconds(1),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await stopWithin(source, limit, sourceLocation: sourceLocation)
    }

    /// Pushes `seconds` of a 440 Hz tone at the engine's rate in the rig's 512-frame blocks, timed
    /// from `start`, and waits for its whole chunks to come out (allowing the resampler 8 samples of
    /// delay, so pick lengths whose 8 kHz sample count isn't a multiple of 320 for an exact count).
    /// It pauses every 32 blocks until the source has caught up, so the capture ring never fills.
    private func feed(
        _ rig: Rig, seconds: Double, from start: ContinuousClock.Instant, amplitude: Float = 0.5
    ) async throws {
        let engine = try #require(rig.engines.latest)
        let rate = engine.rate
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let total = Int(seconds * rate)
        let chunksBefore = rig.chunks.items.count
        var index = 0
        var blocks = 0
        while index < total {
            let frames = min(512, total - index)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = buffer.floatChannelData![0]
            for i in 0..<frames {
                data[i] = amplitude * Float(sin(2 * Double.pi * 440 * Double(index + i) / rate))
            }
            engine.push(buffer, at: start + .seconds(Double(index) / rate))
            index += frames
            blocks += 1
            if blocks % 32 == 0 || index == total {
                let expected = chunksBefore + Int((Double(index) / rate * 8000 - 8) / 320) - (index == total ? 0 : 1)
                try await waitUntil("\(expected) chunks") { rig.chunks.items.count >= expected }
            }
        }
    }

    // MARK: - Tests

    @Test func deniedNeverStartsTheEngine() async throws {
        let rig = makeRig(permission: { false })
        await rig.source.start()
        try await waitUntil("denied") { rig.states.items.contains(.denied) }
        rig.deviceChanges.yield()
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.engines.made.isEmpty)
        #expect(rig.states.items == [.starting, .denied])
        try await stop(rig.source)
        #expect(rig.engines.made.isEmpty)
    }

    @Test func fallsBackToTheSavedName() async throws {
        // No input has the saved UID (the interface moved to another socket); one has the name.
        let moved = AudioInputDevice(uid: "fake-uid:USB Line In:2", name: Self.savedName, channelCount: 1)
        let other = AudioInputDevice(uid: "fake-uid:Built-in", name: "Built-in Microphone", channelCount: 1)
        let rig = makeRig(inputs: [other, moved])
        await rig.source.start()
        #expect(rig.engines.starts == [moved.uid])
        try await waitUntil("streaming") { rig.states.items.last == .streaming(deviceName: Self.savedName) }
        try await stop(rig.source)

        // Two have the name: neither is guessed.
        let twin = AudioInputDevice(uid: "fake-uid:USB Line In:3", name: Self.savedName, channelCount: 1)
        let ambiguous = makeRig(inputs: [moved, twin])
        await ambiguous.source.start()
        #expect(ambiguous.engines.starts.isEmpty)
        try await waitUntil("missing") { ambiguous.states.items.last == .missing(deviceName: Self.savedName) }
        try await stop(ambiguous.source)

        // The saved UID wins over another input with the saved name.
        let renamed = AudioInputDevice(uid: Self.savedUID, name: "Renamed Interface", channelCount: 1)
        let byUID = makeRig(inputs: [moved, renamed])
        await byUID.source.start()
        #expect(byUID.engines.starts == [Self.savedUID])
        try await waitUntil("streaming") { byUID.states.items.last == .streaming(deviceName: "Renamed Interface") }
        try await stop(byUID.source)
    }

    @Test func missingWaitsForTheDevice() async throws {
        let rig = makeRig(inputs: [])
        await rig.source.start()
        try await waitUntil("missing") { rig.states.items == [.starting, .missing(deviceName: Self.savedName)] }
        #expect(rig.engines.starts.isEmpty)

        // Another device arriving changes nothing.
        rig.inputs.set([AudioInputDevice(uid: "fake-uid:Other", name: "Other", channelCount: 2)])
        rig.deviceChanges.yield()
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.engines.starts.isEmpty)

        rig.inputs.set([Self.device])
        rig.deviceChanges.yield()
        try await waitUntil("the engine to start") { rig.engines.starts == [Self.savedUID] }
        try await waitUntil("streaming") { rig.states.items.last == .streaming(deviceName: Self.savedName) }
        try await feed(rig, seconds: 0.2, from: .now)
        #expect(!rig.chunks.items[0].discontinuity)
        try await stop(rig.source)
    }

    @Test func deviceLeavingIsMissing() async throws {
        let rig = makeRig()
        await rig.source.start()
        let start = ContinuousClock.now
        try await feed(rig, seconds: 0.25, from: start)
        let first = try #require(rig.engines.latest)

        rig.inputs.set([])
        rig.deviceChanges.yield()
        try await waitUntil("missing") { rig.states.items.last == .missing(deviceName: Self.savedName) }
        #expect(first.stopped)

        // It comes back: started again, and the audio after the gap is flagged.
        let before = rig.chunks.items.count
        rig.inputs.set([Self.device])
        rig.deviceChanges.yield()
        try await waitUntil("a second start") { rig.engines.starts.count == 2 }
        try await waitUntil("streaming") { rig.states.items.last == .streaming(deviceName: Self.savedName) }
        try await feed(rig, seconds: 0.2, from: start + .seconds(5))
        let after = Array(rig.chunks.items[before...])
        #expect(after.count >= 4)
        #expect(after[0].discontinuity)
        #expect(after.dropFirst().allSatisfy { !$0.discontinuity })
        #expect(after[0].sequence == rig.chunks.items[before - 1].sequence &+ 1)
        try await stop(rig.source)
    }

    @Test func configurationChangeRestartsOnce() async throws {
        let rig = makeRig()
        await rig.source.start()
        let start = ContinuousClock.now
        try await feed(rig, seconds: 0.25, from: start)
        let first = try #require(rig.engines.latest)
        let before = rig.chunks.items.count
        #expect(before == 6)

        // Three changes within 100 ms, each to the engine running then: one restart.
        for n in 0..<3 {
            if n > 0 { try await Task.sleep(for: .milliseconds(40)) }
            try #require(rig.engines.latest).changeConfiguration()
        }
        try await waitUntil("a restart") { rig.engines.starts.count == 2 }
        #expect(first.stopped)
        try await Task.sleep(for: .milliseconds(600))
        #expect(rig.engines.starts.count == 2)
        #expect(rig.states.items.last == .streaming(deviceName: Self.savedName))

        try await feed(rig, seconds: 0.2, from: start + .seconds(1))
        let after = Array(rig.chunks.items[before...])
        #expect(after[0].discontinuity)
        #expect(after.dropFirst().allSatisfy { !$0.discontinuity })
        try await stop(rig.source)
    }

    /// The device comes back from a restart at another rate: a pipeline built for the old rate would
    /// drop every buffer, so the source builds one from the format each start returns (Task 3's
    /// review), and the sequence carries on.
    @Test func restartAtAnotherRateKeepsStreaming() async throws {
        let rig = makeRig()
        await rig.source.start()
        let start = ContinuousClock.now
        try await feed(rig, seconds: 0.5, from: start)
        let before = rig.chunks.items.count
        #expect(before == 12)

        rig.engines.setNextRate(44_100)
        try #require(rig.engines.latest).changeConfiguration()
        try await waitUntil("a restart") { rig.engines.starts.count == 2 }
        #expect(rig.engines.latest?.rate == 44_100)
        try await feed(rig, seconds: 0.5, from: start + .seconds(2))

        let all = rig.chunks.items
        let after = Array(all[before...])
        #expect(after.count >= 11)
        #expect(after.allSatisfy { $0.samples.count == 320 })
        #expect(after[0].discontinuity)
        #expect(all.filter(\.discontinuity).count == 1)
        #expect(all.map(\.sequence) == (0..<all.count).map { UInt16($0) })
        let error = after[0].receivedAt - (start + .seconds(2))
        #expect(error > .milliseconds(-1) && error < .milliseconds(1))
        try await stop(rig.source)
    }

    @Test func stopDuringAPendingPermissionReturns() async throws {
        let gate = PermissionGate()
        let rig = makeRig(permission: { await gate.ask() })
        let started = Mutex(false)
        let starting = Task { [source = rig.source] in
            await source.start()
            started.withLock { $0 = true }
        }
        try await waitUntil("the permission prompt") { gate.asked == 1 }

        try await stop(rig.source)
        try await waitUntil("start to return", timeout: .seconds(1)) { started.withLock { $0 } }
        await starting.value
        try await waitUntil("the streams to finish") {
            rig.states.finished && rig.chunks.finished && rig.levels.finished
        }
        #expect(rig.states.items.last == .stopped)

        // The prompt is answered after the stop: still nothing is started.
        gate.answer(true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.engines.made.isEmpty)
    }

    @Test func stopStopsTheEngineAndEndsTheStreams() async throws {
        let rig = makeRig()
        await rig.source.start()
        let engine = try #require(rig.engines.latest)
        try await stop(rig.source)
        #expect(engine.stopped)
        try await waitUntil("the streams to finish") {
            rig.states.finished && rig.chunks.finished && rig.levels.finished
        }
        #expect(rig.states.items == [.starting, .streaming(deviceName: Self.savedName), .stopped])
        // A device change after the stop starts nothing.
        rig.deviceChanges.yield()
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.engines.starts.count == 1)
    }

    @Test func buffersBecomeChunks() async throws {
        let rig = makeRig()
        await rig.source.start()
        let start = ContinuousClock.now
        try await feed(rig, seconds: 1, from: start)
        let chunks = rig.chunks.items
        #expect(chunks.count >= 24 && chunks.count <= 25)
        #expect(chunks.allSatisfy { $0.samples.count == 320 && $0.lostBefore == 0 && !$0.discontinuity })
        #expect(chunks.map(\.sequence) == (0..<chunks.count).map { UInt16($0) })
        #expect(Set(chunks.map(\.ssrc)).count == 1)
        for (n, chunk) in chunks.enumerated() {
            let error = chunk.receivedAt - (start + .milliseconds(40 * n))
            #expect(error > .milliseconds(-1) && error < .milliseconds(1), "chunk \(n) is \(error) off")
        }
        // 0.5 amplitude is about 16 384 at 16 bits.
        let peak = chunks.flatMap(\.samples).map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 15_000 && peak < 17_500)
        try await waitUntil("levels") { rig.levels.items.count >= 25 }
        #expect(rig.levels.items.allSatisfy { abs($0.peakDBFS - -6.02) < 0.5 && !$0.clipped })
        try await stop(rig.source)
    }

    @Test func aFailedStartIsReported() async throws {
        let rig = makeRig()
        rig.engines.failNextStart()
        await rig.source.start()
        try await waitUntil("a state after starting") { rig.states.items.count >= 2 }
        let last = try #require(rig.states.items.last)
        guard case .failed(let reason) = last else {
            Issue.record("expected .failed, got \(last)")
            return
        }
        #expect(reason.contains(Self.savedName))
        #expect(reason.contains("the device refused"))

        // A device change (the interface plugged in again) tries once more.
        rig.deviceChanges.yield()
        try await waitUntil("streaming") { rig.states.items.last == .streaming(deviceName: Self.savedName) }
        #expect(rig.engines.starts == [Self.savedUID])
        try await stop(rig.source)
    }

    /// A stop that arrives while the source is deciding to start (here, a slow device listing after
    /// the device came back) wins: no engine is started, so the microphone is never opened after the
    /// user stopped.
    @Test func stopWhileDecidingNeverStartsTheEngine() async throws {
        let rig = makeRig(inputs: [])
        await rig.source.start()
        try await waitUntil("missing") { rig.states.items.last == .missing(deviceName: Self.savedName) }

        rig.inputs.set([Self.device])
        rig.inputs.hold()
        rig.deviceChanges.yield()
        try await waitUntil("the source to look for its input") { rig.inputs.isHeld }
        let stopped = Mutex(false)
        Task { [source = rig.source] in
            await source.stop()
            stopped.withLock { $0 = true }
        }
        // Let the stop's cancellation land, then let the listing answer with the device present.
        try await Task.sleep(for: .milliseconds(100))
        rig.inputs.release()
        try await waitUntil("stop() to return", timeout: .seconds(1)) { stopped.withLock { $0 } }
        #expect(rig.engines.made.isEmpty)
        #expect(rig.engines.starts.isEmpty)
        // Nothing queued before the stop acts after it.
        rig.deviceChanges.yield()
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.engines.starts.isEmpty)
        #expect(rig.states.items.last == .stopped)
    }

    /// The processing queue falls behind (held here) and the ring overflows: the chunk after the
    /// gap carries the whole chunks lost in `lostBefore`, its sequence skips them, and the fraction
    /// of a chunk carries over to the next overflow.
    @Test func anOverflowingRingSetsLostBefore() async throws {
        let processing = DispatchQueue(label: "test.line-in.held")
        let rig = makeRig(processing: processing)
        await rig.source.start()
        let engine = try #require(rig.engines.latest)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let start = ContinuousClock.now
        var index = 0
        func push(blocks: Int) {
            for _ in 0..<blocks {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
                buffer.frameLength = 512
                let data = buffer.floatChannelData![0]
                for i in 0..<512 { data[i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(index + i) / 48_000)) }
                engine.push(buffer, at: start + .seconds(Double(index) / 48_000))
                index += 512
            }
        }
        /// Pushes 70 blocks while the processing queue is held: the ring (64 slots) keeps 64 and
        /// drops 6 (3072 frames, 512 samples at 8 kHz), which the next block written carries.
        func overflow() {
            let held = DispatchSemaphore(value: 0)
            let holding = DispatchSemaphore(value: 0)
            processing.async { holding.signal(); held.wait() }
            holding.wait()
            push(blocks: 70)
            held.signal()
        }

        // 64 blocks are 5461 samples at 8 kHz: 17 chunks.
        overflow()
        try await waitUntil("the first 17 chunks") { rig.chunks.items.count >= 17 }
        // One chunk lost (512 samples), 192 samples carried; 17 more chunks.
        overflow()
        try await waitUntil("34 chunks") { rig.chunks.items.count >= 34 }
        // 192 + 512 = 704 samples: two chunks lost, 64 carried; 10 blocks are 2 more chunks.
        push(blocks: 10)
        try await waitUntil("36 chunks") { rig.chunks.items.count >= 36 }

        let chunks = rig.chunks.items
        let lost = chunks.filter { $0.lostBefore > 0 }
        #expect(lost.map(\.lostBefore) == [1, 2])
        #expect(chunks.allSatisfy { !$0.discontinuity })
        for (n, chunk) in chunks.enumerated() where n > 0 {
            #expect(chunk.sequence == chunks[n - 1].sequence &+ 1 &+ UInt16(chunk.lostBefore))
        }
        // The chunk after a gap is timed from the block after it.
        let firstGap = try #require(lost.first)
        let error = firstGap.receivedAt - (start + .seconds(Double(70 * 512) / 48_000))
        #expect(error > .milliseconds(-1) && error < .milliseconds(1))
        try await stop(rig.source)
    }

    // MARK: - The pieces under the source

    /// The render callback's ring: a full ring drops the block and counts its frames, and the next
    /// block that fits carries the count.
    @Test func aFullRingCountsWhatItDropped() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let ring = CaptureRing(format: format, slots: 4, frameCapacity: 1024)
        let start = ContinuousClock.now
        func block(_ value: Float, frames: Int = 512) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<2 {
                for i in 0..<frames { buffer.floatChannelData![channel][i] = value + Float(channel) }
            }
            return buffer
        }
        var accepted: [Bool] = []
        for n in 0..<6 { accepted.append(ring.write(block(Float(n)), at: start + .milliseconds(10 * n))) }
        #expect(accepted == [true, true, true, true, false, false])

        var seen: [(value: Float, right: Float, frames: Int, at: ContinuousClock.Instant, dropped: Int)] = []
        ring.drain { buffer, at, dropped in
            seen.append((buffer.floatChannelData![0][0], buffer.floatChannelData![1][511],
                         Int(buffer.frameLength), at, dropped))
        }
        #expect(seen.map(\.value) == [0, 1, 2, 3])
        #expect(seen.map(\.right) == [1, 2, 3, 4])
        #expect(seen.allSatisfy { $0.frames == 512 && $0.dropped == 0 })
        #expect(seen.map(\.at) == (0..<4).map { start + .milliseconds(10 * $0) })

        // A block bigger than a slot is dropped too.
        #expect(!ring.write(block(9, frames: 2048), at: start))
        #expect(ring.write(block(7), at: start + .milliseconds(70)))
        seen = []
        ring.drain { buffer, at, dropped in
            seen.append((buffer.floatChannelData![0][0], 0, Int(buffer.frameLength), at, dropped))
        }
        #expect(seen.count == 1)
        #expect(seen.first?.value == 7)
        #expect(seen.first?.dropped == 512 + 512 + 2048)
    }

    /// `AudioTimeStamp.mHostTime` (mach absolute time) on the continuous clock.
    @Test func hostTimeConvertsToTheContinuousClock() {
        let anchor = ContinuousClock.now
        // Apple silicon's timebase: 125/3 ns a tick. The Mac slept 1000 ticks since boot.
        let converter = HostTimeConverter(
            numer: 125, denom: 3, continuousMinusAbsolute: 1000, anchorInstant: anchor, anchorContinuous: 100_000)
        // 24 000 ticks after the anchor is 1 ms.
        #expect(converter.instant(hostTime: 99_000 + 24_000) == anchor + .milliseconds(1))
        #expect(converter.instant(hostTime: 99_000 - 24_000) == anchor - .milliseconds(1))
        #expect(converter.instant(hostTime: 99_000) == anchor)

        // The real clocks agree to well within a block.
        let live = HostTimeConverter.now()
        let error = live.instant(hostTime: mach_absolute_time()) - ContinuousClock.now
        #expect(error > .milliseconds(-5) && error < .milliseconds(5))
    }
}
