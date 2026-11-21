// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import AVFAudio
import Foundation
import NoctuleKit
import Synchronization

public enum AudioPlayerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The engine couldn't start, typically because there is no audio output device.
    case engineStartFailed(String)

    public var description: String {
        switch self {
        case .engineStartFailed(let reason): "Couldn't start audio output: \(reason)"
        }
    }
}

/// Plays scanner audio (`AudioChunk`s: 16-bit, 8 kHz, mono) through the default output.
///
/// An `AVAudioSourceNode` (Float32, 8000 Hz, mono) feeds `mainMixerNode`; the engine resamples to
/// the device rate. The render block pulls from a `JitterBuffer` under a `Mutex`, into a scratch
/// buffer allocated up front, so it never allocates. `volume` is the app's own level (0...1),
/// separate from the scanner's VOL.
///
/// The player follows the system output: when its engine posts `AVAudioEngineConfigurationChange`
/// during `play` (the default output changed, or its format did), it builds and starts a new engine
/// on the current default output, keeping the jitter buffer, and counts it in `engineRestarts`.
/// The restart runs in `play`'s own task, never in the notification's handler, so it can't race
/// `play`'s consumption or its teardown.
public final class AudioPlayer: Sendable {
    static let sampleRate = 8000.0
    /// Largest render slice the scratch buffer holds. Bigger requests are rendered in pieces.
    private static let scratchSamples = 16384
    /// The prefill for a line-in, about 60 ms: a cable has no network jitter to smooth (design §5.6).
    public static let lineInPrefillSamples = 480

    /// `scratch` is only touched while holding the lock, so this is safe to share.
    private struct Shared: @unchecked Sendable {
        var jitter: JitterBuffer
        var volume: Float = 1
        var scratch: UnsafeMutablePointer<Int16>
    }

    /// A class so the render block can capture the (noncopyable) `Mutex`.
    private final class Box: Sendable {
        let mutex: Mutex<Shared>
        /// Owns the scratch buffer, so a render callback holding the Box never sees a freed pointer.
        init(prefillSamples: Int) {
            let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: AudioPlayer.scratchSamples)
            scratch.initialize(repeating: 0, count: AudioPlayer.scratchSamples)
            mutex = Mutex(Shared(jitter: JitterBuffer(prefillSamples: prefillSamples), scratch: scratch))
        }
        deinit { mutex.withLock { $0.scratch.deallocate() } }
        func withLock<R>(_ body: (inout sending Shared) -> sending R) -> sending R { mutex.withLock(body) }
    }

    /// The engine `play` is running and its configuration-change observer. The token is only
    /// passed to `NotificationCenter.removeObserver`, which is thread-safe.
    private struct Output: @unchecked Sendable {
        let engine: AVAudioEngine
        let observer: any NSObjectProtocol
    }

    private let shared: Box
    private let output: Mutex<Output?> = Mutex(nil)
    private let stopSignal = Mutex<Bool>(false)
    private let restarts = Mutex(0)
    private let chunksReceived = Mutex(0)
    private let startEngine: @Sendable (AVAudioEngine) throws -> Void

    /// `prefillSamples` is how much the jitter buffer holds before playback starts: the default,
    /// 200 ms, smooths the SDS200's network jitter; a line-in uses `lineInPrefillSamples`.
    public convenience init(prefillSamples: Int = 1600) {
        self.init(prefillSamples: prefillSamples) { try $0.start() }
    }

    /// `startEngine` starts each engine `play` builds (tests make it fail).
    init(prefillSamples: Int, startEngine: @escaping @Sendable (AVAudioEngine) throws -> Void) {
        shared = Box(prefillSamples: prefillSamples)
        self.startEngine = startEngine
    }

    public var volume: Float {
        get { shared.withLock { $0.volume } }
        set { shared.withLock { $0.volume = min(1, max(0, newValue.isNaN ? 0 : newValue)) } }
    }

    /// Jitter buffer counters, for diagnostics.
    public var underruns: Int { shared.withLock { $0.jitter.underruns } }
    public var overflowDroppedSamples: Int { shared.withLock { $0.jitter.overflowDroppedSamples } }
    /// Engines rebuilt after a configuration change (a new output device), over the player's life.
    public var engineRestarts: Int { restarts.withLock { $0 } }

    var bufferedSamples: Int { shared.withLock { $0.jitter.bufferedSamples } }
    var isPrimed: Bool { shared.withLock { $0.jitter.isPrimed } }
    /// Chunks `play` has taken from its stream, over the player's life.
    var receivedChunks: Int { chunksReceived.withLock { $0 } }
    var currentEngine: AVAudioEngine? { output.withLock { $0?.engine } }

    func push(_ samples: [Int16]) {
        shared.withLock { $0.jitter.push(samples) }
    }

    /// Renders `count` frames the way the output node does, for tests.
    func render(count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            shared.withLock { Self.render(&$0, into: base, count: count) }
        }
        return out
    }

    /// Starts the engine and plays until the stream finishes, `stop()` is called, or the task is
    /// cancelled. Throws `AudioPlayerError.engineStartFailed` if the engine can't start, or can't
    /// be started again after a configuration change.
    /// (Signature is `async throws`, a change from the plan's non-throwing `async`.)
    public func play(_ chunks: AsyncStream<AudioChunk>) async throws {
        stopSignal.withLock { $0 = false }
        // Unbounded, so a late notice from a replaced engine can't push out the current one's; the
        // follower's identity check collapses a burst.
        let (changes, changed) = AsyncStream.makeStream(of: ObjectIdentifier.self)
        let engine = try makeAndStartEngine()
        let observer = observe(engine, changed)
        output.withLock { $0 = Output(engine: engine, observer: observer) }
        defer { stop() }

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.consume(chunks)
                    changed.finish()
                }
                group.addTask { try await self.followConfigurationChanges(changes, changed) }
                // Not `waitForAll()`, which waits for every child before it rethrows: a failed restart
                // must end `play` while consumption still waits on its stream.
                while try await group.next() != nil {}
            }
        } onCancel: {
            stop()
        }
    }

    /// Stops the engine and makes `play` return. Safe to call repeatedly, from any thread.
    public func stop() {
        stopSignal.withLock { $0 = true }
        let current = output.withLock { current -> Output? in
            defer { current = nil }
            return current
        }
        if let current {
            NotificationCenter.default.removeObserver(current.observer)
            current.engine.stop()
        }
        shared.withLock { $0.jitter.reset() }
    }

    private func consume(_ chunks: AsyncStream<AudioChunk>) async {
        for await chunk in chunks {
            if stopSignal.withLock({ $0 }) { break }
            push(chunk.samples)
            chunksReceived.withLock { $0 += 1 }
        }
        // The stream ended: serve what is buffered even if below prefill, and let it play out
        // (bounded), unless stopped.
        shared.withLock { $0.jitter.finish() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !stopSignal.withLock({ $0 }), !Task.isCancelled, ContinuousClock.now < deadline,
              shared.withLock({ $0.jitter.bufferedSamples > 0 }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The last render slice is still queued in the output path.
        if !stopSignal.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(150)) }
    }

    /// Rebuilds the engine for each configuration change of the current one, until `play`'s
    /// consumption ends (which finishes `changes`). A notice from an engine already replaced is
    /// ignored. A failed start stops the player and throws, ending `play`.
    private func followConfigurationChanges(_ changes: AsyncStream<ObjectIdentifier>,
                                            _ changed: AsyncStream<ObjectIdentifier>.Continuation) async throws {
        for await changedEngine in changes {
            guard output.withLock({ $0.map { ObjectIdentifier($0.engine) } == changedEngine }) else { continue }
            let replacement: AVAudioEngine
            do {
                replacement = try makeAndStartEngine()
            } catch {
                stop()
                throw error
            }
            guard let replaced = install(replacement, observing: changed, replacing: changedEngine) else {
                // Stopped (or replaced) meanwhile: this engine is not wanted.
                replacement.stop()
                return
            }
            NotificationCenter.default.removeObserver(replaced.observer)
            replaced.engine.stop()
            restarts.withLock { $0 += 1 }
        }
    }

    /// Puts `replacement` in place of the engine `replaced`, observing it instead, unless the player
    /// was stopped or the engine replaced meanwhile (nil). Returns what it replaced.
    private func install(_ replacement: AVAudioEngine, observing changed: AsyncStream<ObjectIdentifier>.Continuation,
                         replacing replaced: ObjectIdentifier) -> Output? {
        output.withLock { current -> Output? in
            guard let old = current, ObjectIdentifier(old.engine) == replaced,
                  !stopSignal.withLock({ $0 }) else { return nil }
            current = Output(engine: replacement, observer: observe(replacement, changed))
            return old
        }
    }

    private func observe(_ engine: AVAudioEngine,
                         _ changed: AsyncStream<ObjectIdentifier>.Continuation) -> any NSObjectProtocol {
        let id = ObjectIdentifier(engine)
        return NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                      object: engine, queue: nil) { _ in
            changed.yield(id)
        }
    }

    private func makeAndStartEngine() throws -> AVAudioEngine {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            throw AudioPlayerError.engineStartFailed("\(error)")
        }
        #endif
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw AudioPlayerError.engineStartFailed("unsupported audio format")
        }
        let shared = self.shared
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first, let out = first.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            shared.withLock { Self.render(&$0, into: out, count: Int(frameCount)) }
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try startEngine(engine)
        } catch {
            throw AudioPlayerError.engineStartFailed("\(error)")
        }
        return engine
    }

    /// The render path: pulls `count` samples from the jitter buffer, through the scratch buffer,
    /// scaled by the volume. Never allocates.
    private static func render(_ state: inout Shared, into out: UnsafeMutablePointer<Float>, count total: Int) {
        var done = 0
        while done < total {
            let n = min(total - done, scratchSamples)
            state.jitter.pull(into: state.scratch, count: n)
            let gain = state.volume / 32768
            for i in 0..<n { out[done + i] = Float(state.scratch[i]) * gain }
            done += n
        }
    }
}
