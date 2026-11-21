// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import Synchronization

/// A line-in source for tests: it opens nothing, and the test gives it its chunks, levels and
/// states. `start()` reports `.starting`, then (after `startDelay`, when set) `startState`, which
/// is `.streaming` with the config's device name unless the test chose another. `stop()` reports
/// `.stopped` and finishes the three streams; a second `stop()`, and a `start()` after a stop, do
/// nothing.
///
/// `startDelay` is a start that takes that long and that neither a stop nor a cancellation cuts
/// short, like a permission prompt nobody answers: a caller that awaits `start()` on its stop path
/// waits the whole delay. A stop during the delay still stops the source at once, and the start,
/// when it returns, reports nothing more.
public final class FakeLineInSource: LineInSource {
    public let config: LineInConfig
    public let chunks: AsyncStream<AudioChunk>
    public let levels: AsyncStream<LineInLevel>
    public let states: AsyncStream<LineInState>
    private let chunkSink: AsyncStream<AudioChunk>.Continuation
    private let levelSink: AsyncStream<LineInLevel>.Continuation
    private let stateSink: AsyncStream<LineInState>.Continuation

    private struct Status {
        var startCalls = 0
        var stopCalls = 0
        var stopped = false
        var startDelay: Duration?
        var startState: LineInState
    }
    private let status: Mutex<Status>

    public init(config: LineInConfig) {
        self.config = config
        (chunks, chunkSink) = AsyncStream.makeStream(of: AudioChunk.self)
        (levels, levelSink) = AsyncStream.makeStream(of: LineInLevel.self)
        (states, stateSink) = AsyncStream.makeStream(of: LineInState.self)
        status = Mutex(Status(startState: .streaming(deviceName: config.deviceName)))
    }

    /// Whether `start()` has been called.
    public var started: Bool { startCalls > 0 }
    /// How many times `start()` has been called.
    public var startCalls: Int { status.withLock { $0.startCalls } }
    /// Whether `stop()` has been called.
    public var stopped: Bool { status.withLock { $0.stopped } }
    /// How many times `stop()` has been called.
    public var stopCalls: Int { status.withLock { $0.stopCalls } }
    /// How long `start()` takes before it reports `startState`; nil: no time at all.
    public var startDelay: Duration? {
        get { status.withLock { $0.startDelay } }
        set { status.withLock { $0.startDelay = newValue } }
    }
    /// The state `start()` reports once it is done.
    public var startState: LineInState {
        get { status.withLock { $0.startState } }
        set { status.withLock { $0.startState = newValue } }
    }

    public func start() async {
        let delay: Duration?? = status.withLock { s in
            s.startCalls += 1
            guard s.startCalls == 1, !s.stopped else { return nil }
            stateSink.yield(.starting)
            return .some(s.startDelay)
        }
        guard let delay else { return }
        if let delay {
            // A task of its own, awaited: the caller's cancellation doesn't end the wait.
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
        status.withLock { s in
            guard !s.stopped else { return }
            stateSink.yield(s.startState)
        }
    }

    public func stop() async {
        let first = status.withLock { s in
            s.stopCalls += 1
            guard !s.stopped else { return false }
            s.stopped = true
            stateSink.yield(.stopped)
            return true
        }
        guard first else { return }
        chunkSink.finish()
        levelSink.finish()
        stateSink.finish()
    }

    /// Delivers a chunk, as the capture would (dropped once stopped).
    public func yield(chunk: AudioChunk) { chunkSink.yield(chunk) }

    /// Delivers a meter reading (dropped once stopped).
    public func yield(level: LineInLevel) { levelSink.yield(level) }

    /// Reports a state, as the source would on its own (a device unplugged is `.missing`, back is
    /// `.streaming`). Nothing once stopped.
    public func setState(_ state: LineInState) {
        status.withLock { s in
            guard !s.stopped else { return }
            stateSink.yield(state)
        }
    }

    /// A chunk of 320 samples, every one of them `value`, received at `at`.
    public static func chunk(sequence: Int, value: Int16, at: ContinuousClock.Instant = .now) -> AudioChunk {
        AudioChunk(samples: Array(repeating: value, count: 320), rtpTimestamp: UInt32(truncatingIfNeeded: sequence * 320),
                   sequence: UInt16(truncatingIfNeeded: sequence), receivedAt: at)
    }
}

/// A `LineInSourceFactory` that makes `FakeLineInSource`s and keeps them, newest last, for a test
/// to drive. Every source it makes gets `startDelay`.
public final class FakeLineInSources: Sendable {
    private let made = Mutex<[FakeLineInSource]>([])
    private let startDelay: Duration?

    public init(startDelay: Duration? = nil) { self.startDelay = startDelay }

    /// Every source made so far, in order.
    public var sources: [FakeLineInSource] { made.withLock { $0 } }
    /// The newest source.
    public var last: FakeLineInSource? { sources.last }

    public var factory: LineInSourceFactory {
        { [self] config in
            let source = FakeLineInSource(config: config)
            source.startDelay = startDelay
            made.withLock { $0.append(source) }
            return source
        }
    }
}
