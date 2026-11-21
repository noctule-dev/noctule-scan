// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Foundation
import NoctuleKit
import Synchronization

/// The line-in source on an audio engine (line-in design §5.2, §5.4): it asks for permission, finds
/// the station's input, captures from it through a `LineInEngine` and turns the blocks into chunks
/// and levels with a `LineInPipeline`.
///
/// - Permission comes first: refused is `.denied`, and nothing more happens until a new source.
/// - The input is the one with the saved UID, else the only one with the saved name (design §5.1:
///   the UID carries the USB location); neither is `.missing(name)`, and the source waits for the
///   device list to change.
/// - A configuration change of the engine (it stops itself), or a change in the device list, is
///   acted on once things have been quiet for `restartDebounce`: the input gone is `.missing`, the
///   input back (or still there after a configuration change) starts a new engine. Each start
///   builds a new pipeline from the format that start returns (a device can come back at another
///   rate), carrying on the sequence, with the first chunk after a restart flagged `discontinuity`.
/// - `stop()` stops the engine and finishes the three streams. It returns while a permission prompt
///   is still up: the wait for the answer is abandoned, and a late answer starts nothing. Once
///   `stop()` is called no engine is started, whatever was being decided or queued then.
///   (The permission's own task can't be cancelled: when the prompt is never answered it stays
///   suspended, holding only the permission closure.)
///
/// The render callback copies each block into a `CaptureRing` slot and wakes a serial queue, which
/// runs the pipeline; the source's own decisions run in one task.
public final class EngineLineInSource: LineInSource {
    /// How long the device list and the engine's configuration must stay quiet before a restart.
    public static let restartDebounce: Duration = .milliseconds(250)

    public let chunks: AsyncStream<AudioChunk>
    public let levels: AsyncStream<LineInLevel>
    public let states: AsyncStream<LineInState>
    private let chunkSink: AsyncStream<AudioChunk>.Continuation
    private let levelSink: AsyncStream<LineInLevel>.Continuation
    private let stateSink: AsyncStream<LineInState>.Continuation

    private let config: LineInConfig
    private let inputs: any AudioInputListing
    private let permission: @Sendable () async -> Bool
    private let makeEngine: @Sendable () -> any LineInEngine
    private let processing: DispatchQueue

    private let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation
    /// Forwards the device list's changes to `events` from init to `stop()`, so the device-list
    /// stream ends (and its listener goes) on `stop()` whether or not the source started.
    private let deviceWatch: Task<Void, Never>

    private struct Lifecycle {
        var task: Task<Void, Never>?
        var stopped = false
    }
    private let lifecycle = Mutex(Lifecycle())
    /// Resolved once the first state after `.starting` is known, or on `stop()`.
    private let firstState = OneShot<Void>()

    public convenience init(
        config: LineInConfig, inputs: any AudioInputListing, deviceChanges: AsyncStream<Void>,
        permission: @escaping @Sendable () async -> Bool, makeEngine: @escaping @Sendable () -> any LineInEngine
    ) {
        self.init(config: config, inputs: inputs, deviceChanges: deviceChanges, permission: permission,
                  makeEngine: makeEngine,
                  processing: DispatchQueue(label: "app.noctule.line-in", qos: .userInteractive))
    }

    /// `processing` is the serial queue the pipeline runs on (a test holds it to make the ring overflow).
    init(
        config: LineInConfig, inputs: any AudioInputListing, deviceChanges: AsyncStream<Void>,
        permission: @escaping @Sendable () async -> Bool, makeEngine: @escaping @Sendable () -> any LineInEngine,
        processing: DispatchQueue
    ) {
        self.processing = processing
        self.config = config
        self.inputs = inputs
        self.permission = permission
        self.makeEngine = makeEngine
        (chunks, chunkSink) = AsyncStream.makeStream(of: AudioChunk.self)
        (levels, levelSink) = AsyncStream.makeStream(of: LineInLevel.self)
        (states, stateSink) = AsyncStream.makeStream(of: LineInState.self)
        let (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        self.eventSink = eventSink
        deviceWatch = Task {
            for await _ in deviceChanges { eventSink.yield(.devicesChanged) }
        }
    }

    public func start() async {
        lifecycle.withLock { state in
            guard state.task == nil, !state.stopped else { return }
            state.task = Task { await self.run() }
        }
        await firstState.wait()
    }

    public func stop() async {
        let (task, first) = lifecycle.withLock { state in
            defer { state.stopped = true }
            return (state.task, !state.stopped)
        }
        deviceWatch.cancel()
        task?.cancel()
        await task?.value
        firstState.resolve(())
        guard first else { return }
        stateSink.yield(.stopped)
        chunkSink.finish()
        levelSink.finish()
        stateSink.finish()
    }

    // MARK: - The source's task

    private enum Event: Sendable {
        case devicesChanged
        case configurationChanged(generation: Int)
        case settle(token: Int)
    }

    /// The engine running now.
    private struct Running {
        var engine: any LineInEngine
        var uid: String
        var capture: Capture
        var generation: Int
        var watcher: Task<Void, Never>
    }

    private func run() async {
        var lastState: LineInState?
        func emit(_ state: LineInState) {
            guard state != lastState else { return }
            lastState = state
            stateSink.yield(state)
        }

        emit(.starting)
        guard let granted = await askPermission(), !Task.isCancelled else { return }
        guard granted else {
            emit(.denied)
            firstState.resolve(())
            return
        }

        var running: Running?
        var previous: Capture?
        var generation = 0
        var token = 0
        var timer: Task<Void, Never>?
        var configurationChanged = false
        let eventSink = self.eventSink

        func stopRunning() {
            guard let current = running else { return }
            running = nil
            current.watcher.cancel()
            current.engine.stop()
            processing.sync { current.capture.finish() }
        }

        func reconcile(restart: Bool) {
            guard let device = findDevice() else {
                stopRunning()
                emit(.missing(deviceName: config.deviceName))
                return
            }
            if let current = running {
                if current.uid == device.uid, !restart { return }
                stopRunning()
            }
            // A stop that came in while the input was being looked for wins: no engine, no microphone.
            guard !Task.isCancelled else { return }
            generation += 1
            let engine = makeEngine()
            let capture = Capture(queue: processing, chunkSink: chunkSink, levelSink: levelSink)
            do {
                let format = try engine.start(deviceUID: device.uid) { buffer, time in
                    capture.receive(buffer, at: time)
                }
                let channel = config.channel
                processing.sync { capture.arm(format: format, continuing: previous, channel: channel) }
                previous = capture
                let current = generation
                let watcher = Task {
                    for await _ in engine.configurationChanges {
                        eventSink.yield(.configurationChanged(generation: current))
                    }
                }
                running = Running(engine: engine, uid: device.uid, capture: capture, generation: current,
                                  watcher: watcher)
                emit(.streaming(deviceName: device.name))
            } catch LineInEngineError.deviceNotFound {
                engine.stop()
                emit(.missing(deviceName: config.deviceName))
            } catch {
                engine.stop()
                emit(.failed("couldn't start the audio input \"\(device.name)\": \(error)"))
            }
        }

        reconcile(restart: false)
        firstState.resolve(())

        for await event in events {
            // Events queued before a stop are still delivered after it: act on none of them.
            if Task.isCancelled { break }
            switch event {
            case .configurationChanged(let changed):
                guard changed == running?.generation else { continue }
                configurationChanged = true
            case .devicesChanged:
                break
            case .settle(let settled):
                guard settled == token else { continue }
                let restart = configurationChanged
                configurationChanged = false
                reconcile(restart: restart)
                continue
            }
            // Wait for things to settle: each change pushes the restart back.
            token += 1
            timer?.cancel()
            timer = Task { [token] in
                guard (try? await Task.sleep(for: Self.restartDebounce)) != nil else { return }
                eventSink.yield(.settle(token: token))
            }
        }
        timer?.cancel()
        stopRunning()
    }

    /// The input to use: the one with the saved UID, else the only one with the saved name.
    private func findDevice() -> AudioInputDevice? {
        let all = inputs.inputs()
        if let byUID = all.first(where: { $0.uid == config.deviceUID }) { return byUID }
        let named = all.filter { $0.name == config.deviceName }
        return named.count == 1 ? named[0] : nil
    }

    /// The permission's answer, or nil when the task was cancelled first (a stop while the prompt is
    /// up). The prompt runs in a task of its own, so an answer that never comes can't hold up a stop.
    private func askPermission() async -> Bool? {
        let answer = OneShot<Bool?>()
        let permission = self.permission
        Task { answer.resolve(await permission()) }
        return await withTaskCancellationHandler {
            await answer.wait()
        } onCancel: {
            answer.resolve(nil)
        }
    }
}

/// One engine start's capture: the ring its render callback writes, and the pipeline the processing
/// queue runs the ring's blocks through.
private final class Capture: @unchecked Sendable {
    private final class Armed: @unchecked Sendable {
        let ring: CaptureRing
        let wake: DispatchSourceUserDataAdd
        init(ring: CaptureRing, wake: DispatchSourceUserDataAdd) { self.ring = ring; self.wake = wake }
    }

    /// Set once, by `arm`; the render callback reads it lock-free and drops blocks until it is set
    /// (an engine may deliver before its `start` returns).
    private let armed = AtomicLazyReference<Armed>()
    private let queue: DispatchQueue
    private let chunkSink: AsyncStream<AudioChunk>.Continuation
    private let levelSink: AsyncStream<LineInLevel>.Continuation
    /// Touched only on `queue`.
    private var pipeline: LineInPipeline?
    private var droppedOutputSamples = 0.0

    init(queue: DispatchQueue, chunkSink: AsyncStream<AudioChunk>.Continuation,
         levelSink: AsyncStream<LineInLevel>.Continuation) {
        self.queue = queue
        self.chunkSink = chunkSink
        self.levelSink = levelSink
    }

    /// The render callback: copies the block into the ring and wakes the queue (a dispatch source's
    /// merge, which neither allocates nor locks).
    func receive(_ buffer: AVAudioPCMBuffer, at time: ContinuousClock.Instant) {
        guard let armed = armed.load() else { return }
        if armed.ring.write(buffer, at: time) { armed.wake.add(data: 1) }
    }

    /// On `queue`, once the engine has said its format: the pipeline (carrying on from `previous`'s,
    /// whose last blocks have been run through it) and the ring.
    func arm(format: AVAudioFormat, continuing previous: Capture?, channel: LineInChannel) {
        dispatchPrecondition(condition: .onQueue(queue))
        let ssrc = UInt32.random(in: .min ... .max)
        pipeline = previous?.pipeline?.continued(inputFormat: format, ssrc: ssrc)
            ?? LineInPipeline(inputFormat: format, channel: channel, ssrc: ssrc)
        let wake = DispatchSource.makeUserDataAddSource(queue: queue)
        wake.setEventHandler { [weak self] in self?.drain() }
        _ = armed.storeIfNil(Armed(ring: CaptureRing(format: format), wake: wake))
        wake.activate()
    }

    /// On `queue`, after the engine stopped: runs what the ring still holds and stops listening.
    func finish() {
        dispatchPrecondition(condition: .onQueue(queue))
        drain()
        armed.load()?.wake.cancel()
    }

    private func drain() {
        guard let armed = armed.load(), let pipeline else { return }
        let rate = armed.ring.format.sampleRate
        armed.ring.drain { buffer, time, droppedFrames in
            if droppedFrames > 0 {
                // Whole 40 ms chunks lost; the fraction carries to the next loss.
                droppedOutputSamples += Double(droppedFrames) * LineInPipeline.outputRate / rate
                let lost = Int(droppedOutputSamples / Double(LineInPipeline.chunkSamples))
                if lost > 0 {
                    pipeline.noteDropped(chunks: lost)
                    droppedOutputSamples -= Double(lost * LineInPipeline.chunkSamples)
                }
            }
            let out = pipeline.process(buffer, firstSampleAt: time)
            for chunk in out.chunks { chunkSink.yield(chunk) }
            for level in out.levels { levelSink.yield(level) }
        }
    }
}

/// A value set once; every waiter, earlier or later, gets it.
private final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var resolved = false
        var waiters: [CheckedContinuation<Value, Never>] = []
    }
    private let state = Mutex(State())

    func resolve(_ value: Value) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard !state.resolved else { return [] }
            state.resolved = true
            state.value = value
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let value = state.withLock { state -> Value? in
                if state.resolved { return state.value }
                state.waiters.append(continuation)
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}

#if os(macOS)
extension EngineLineInSource {
    /// The real line-in: Core Audio's inputs and device-list changes, the system's microphone
    /// permission, and `AVLineInEngine`. Never called from a test (it would prompt for the
    /// microphone and record the room).
    public static func system(_ config: LineInConfig) -> EngineLineInSource {
        EngineLineInSource(
            config: config, inputs: CoreAudioInputs(), deviceChanges: CoreAudioInputs.deviceListChanges(),
            permission: { await AVAudioApplication.requestRecordPermission() },
            makeEngine: { AVLineInEngine() })
    }
}
#endif
