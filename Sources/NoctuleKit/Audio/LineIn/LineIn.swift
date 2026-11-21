// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Which channel of a line-in device carries the scanner's audio (line-in design §5). A mono device
/// has one channel and ignores the choice.
public enum LineInChannel: String, Codable, Sendable, CaseIterable {
    case left, right, both
}

/// The audio input a station listens to: the device (by its stable UID, with the name it had when
/// it was chosen, for showing it while it is unplugged) and the channel.
public struct LineInConfig: Sendable, Equatable {
    public var deviceUID: String
    public var deviceName: String
    public var channel: LineInChannel

    public init(deviceUID: String, deviceName: String, channel: LineInChannel) {
        self.deviceUID = deviceUID; self.deviceName = deviceName; self.channel = channel
    }
}

/// One meter reading of a line-in's audio: the loudest sample and the root mean square of a short
/// window, in dBFS (both `-.infinity` for digital silence). The meter draws the peak; silence
/// detection uses the RMS.
public struct LineInLevel: Sendable, Equatable {
    public var peakDBFS: Double
    public var rmsDBFS: Double
    public var clipped: Bool
    public var at: ContinuousClock.Instant

    public init(peakDBFS: Double, rmsDBFS: Double, clipped: Bool, at: ContinuousClock.Instant) {
        self.peakDBFS = peakDBFS; self.rmsDBFS = rmsDBFS; self.clipped = clipped; self.at = at
    }
}

public enum LineInState: Sendable, Equatable {
    case starting
    case streaming(deviceName: String)
    /// The configured device isn't there (unplugged, or never plugged in): not an error to throw.
    case missing(deviceName: String)
    /// The system won't let the app use audio input.
    case denied
    case failed(String)
    case stopped
}

/// A source of the scanner's audio from a line-in: 16-bit 8 kHz mono `AudioChunk`s of 320 samples,
/// meter levels and state changes. `start()` returns once the first state is known (a missing
/// device is `.missing`, not a throw); `stop()` finishes all three streams.
public protocol LineInSource: AnyObject, Sendable {
    var chunks: AsyncStream<AudioChunk> { get }
    var levels: AsyncStream<LineInLevel> { get }
    var states: AsyncStream<LineInState> { get }
    func start() async
    func stop() async
}

public typealias LineInSourceFactory = @Sendable (LineInConfig) -> any LineInSource

/// An audio input the system lists.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public var uid: String
    public var name: String
    public var channelCount: Int
    public var id: String { uid }

    public init(uid: String, name: String, channelCount: Int) {
        self.uid = uid; self.name = name; self.channelCount = channelCount
    }
}

public protocol AudioInputListing: Sendable {
    func inputs() -> [AudioInputDevice]
}

public struct FixedAudioInputListing: AudioInputListing {
    public var devices: [AudioInputDevice]
    public init(inputs: [AudioInputDevice]) { devices = inputs }
    public func inputs() -> [AudioInputDevice] { devices }
    public static let empty = FixedAudioInputListing(inputs: [])
}

/// The line-in source for a run where audio inputs are off (the kill-switch): it opens nothing,
/// says why on `states`, and has no chunks or levels.
public final class DisabledLineInSource: LineInSource {
    public let chunks: AsyncStream<AudioChunk>
    public let levels: AsyncStream<LineInLevel>
    public let states: AsyncStream<LineInState>
    private let reason: String
    private let chunkSink: AsyncStream<AudioChunk>.Continuation
    private let levelSink: AsyncStream<LineInLevel>.Continuation
    private let stateSink: AsyncStream<LineInState>.Continuation

    public init(reason: String) {
        self.reason = reason
        (chunks, chunkSink) = AsyncStream.makeStream(of: AudioChunk.self)
        (levels, levelSink) = AsyncStream.makeStream(of: LineInLevel.self)
        (states, stateSink) = AsyncStream.makeStream(of: LineInState.self)
    }

    public func start() async {
        stateSink.yield(.failed(reason))
    }

    public func stop() async {
        chunkSink.finish()
        levelSink.finish()
        stateSink.finish()
    }
}
