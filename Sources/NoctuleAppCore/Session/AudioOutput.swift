// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import NoctuleKit

/// Where a session's live audio is played. The Mac app wires the AVAudioEngine `AudioPlayer`
/// (NoctuleAudioPlayback) through `SessionEnvironment.makeAudioOutput`; this module stays free of
/// AVFAudio so it builds for iOS.
public protocol AudioOutput: AnyObject, Sendable {
    /// Plays `chunks` until the stream finishes or `stop()` is called.
    func play(_ chunks: AsyncStream<AudioChunk>) async throws
    func stop()
    /// The output's own level, 0...1 (not the scanner's volume).
    var volume: Float { get set }
}

/// An output that discards everything: the default until the app supplies a real one.
public final class SilentAudioOutput: AudioOutput, Sendable {
    public init() {}
    public func play(_ chunks: AsyncStream<AudioChunk>) async throws {
        for await _ in chunks {}
    }
    public func stop() {}
    public var volume: Float {
        get { 0 }
        set {}
    }
}
