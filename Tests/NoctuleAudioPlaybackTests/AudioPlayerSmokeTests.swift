// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import NoctuleKit
import Testing
@testable import NoctuleAudioPlayback
#if os(macOS)
import AVFAudio
import CoreAudio
#endif

/// Opt-in: `NOCTULE_AUDIO_OUTPUT_TEST=1 swift test --filter AudioPlayerSmokeTests`.
/// Plays one second of a 440 Hz tone through the default output device.
@Suite struct AudioPlayerSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOCTULE_AUDIO_OUTPUT_TEST"] == "1"))
    func playsToneAndReturnsWhenStreamFinishes() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let chunkSize = 320
        for index in 0..<25 {
            let samples = (0..<chunkSize).map { i -> Int16 in
                let t = Double(index * chunkSize + i) / 8000
                return Int16(8000 * sin(2 * .pi * 440 * t))
            }
            continuation.yield(AudioChunk(samples: samples, rtpTimestamp: UInt32(index * chunkSize),
                                          sequence: UInt16(index), receivedAt: .now))
        }
        continuation.finish()
        let player = AudioPlayer()
        player.volume = 0.3
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await player.play(stream) }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                player.stop()
                Issue.record("play did not return within 10 s")
            }
            try await group.next()
            group.cancelAll()
        }
        // The whole second of tone must play out before `play` returns.
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(900))
        #expect(elapsed < .seconds(5))
    }
}

/// The prefill, through the same render code the output node runs; no output device needed.
@Suite struct AudioPlayerPrefillTests {
    private func tone(_ count: Int) -> [Int16] { [Int16](repeating: 4000, count: count) }

    @Test func prefillIsConfigurable() {
        let player = AudioPlayer(prefillSamples: AudioPlayer.lineInPrefillSamples)
        #expect(AudioPlayer.lineInPrefillSamples == 480)
        player.push(tone(479))
        #expect(player.render(count: 100) == [Float](repeating: 0, count: 100))
        #expect(!player.isPrimed)
        player.push(tone(1))
        let out = player.render(count: 100)
        #expect(player.isPrimed)
        #expect(out.allSatisfy { $0 > 0 })
        #expect(player.bufferedSamples == 380)
    }

    @Test func theDefaultPrefillIsUnchanged() {
        let player = AudioPlayer()
        player.push(tone(1599))
        #expect(player.render(count: 100) == [Float](repeating: 0, count: 100))
        #expect(!player.isPrimed)
        player.push(tone(1))
        #expect(player.render(count: 100).allSatisfy { $0 > 0 })
        #expect(player.isPrimed)
    }
}

#if os(macOS)
/// True when the Mac has a default output device. Reads the output's ID only; no input is listed
/// or opened.
private var hasDefaultOutput: Bool {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                            &size, &device)
    return status == noErr && device != kAudioObjectUnknown
}

/// Following output changes, on the real default output (silence only, volume 0). Skipped on a
/// machine with no output device.
@Suite(.serialized, .enabled(if: hasDefaultOutput, "needs an audio output device"), .timeLimit(.minutes(1)))
struct AudioPlayerOutputChangeTests {
    private struct EngineStartRefused: Error {}

    private static func chunks(_ count: Int) -> [AudioChunk] {
        (0..<count).map { index in
            AudioChunk(samples: [Int16](repeating: 0, count: 320), rtpTimestamp: UInt32(index * 320),
                       sequence: UInt16(index), receivedAt: .now)
        }
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes.
    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Awaits `play`'s task. Past `limit` it records an issue and cancels the task, which stops the
    /// player, so a regression fails instead of hanging the suite.
    private func outcome(of playing: Task<Void, any Error>,
                         within limit: Duration = .seconds(10)) async -> Result<Void, any Error> {
        let watchdog = Task {
            try await Task.sleep(for: limit)
            Issue.record("play did not return within \(limit)")
            playing.cancel()
        }
        defer { watchdog.cancel() }
        return await playing.result
    }

    private func postConfigurationChange(_ object: AVAudioEngine) {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: object)
    }

    @Test func configurationChangeRestartsTheEngine() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let player = AudioPlayer()
        player.volume = 0
        let playing = Task { try await player.play(stream) }
        defer { player.stop(); continuation.finish() }
        #expect(await eventually { player.currentEngine != nil })
        let first = try #require(player.currentEngine)

        // A second of audio buffered, then the engine stops itself and says so, as on a change of
        // output device.
        for chunk in Self.chunks(25) { continuation.yield(chunk) }
        #expect(await eventually { player.receivedChunks == 25 })
        first.stop()
        let buffered = player.bufferedSamples
        postConfigurationChange(first)

        #expect(await eventually { player.engineRestarts == 1 })
        let second = try #require(player.currentEngine)
        #expect(second !== first)
        #expect(second.isRunning)
        // The jitter buffer is kept: only what the new engine has rendered is gone.
        #expect(player.bufferedSamples > buffered - 2400)

        // A late notice from the old engine changes nothing.
        postConfigurationChange(first)
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.engineRestarts == 1)
        #expect(player.currentEngine === second)

        // The new engine's own change is still followed.
        second.stop()
        postConfigurationChange(second)
        #expect(await eventually { player.engineRestarts == 2 })
        let third = try #require(player.currentEngine)
        #expect(third !== second)
        #expect(third.isRunning)

        // `play` is still consuming, and returns normally when the stream ends.
        for chunk in Self.chunks(5) { continuation.yield(chunk) }
        #expect(await eventually { player.receivedChunks == 30 })
        continuation.finish()
        try await outcome(of: playing).get()
        #expect(player.currentEngine == nil)

        // After `play` has ended, a notice does nothing.
        postConfigurationChange(third)
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.engineRestarts == 2)
        #expect(player.currentEngine == nil)
    }

    @Test func anotherEnginesChangeIsIgnored() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let player = AudioPlayer()
        player.volume = 0
        let playing = Task { try await player.play(stream) }
        #expect(await eventually { player.currentEngine != nil })
        let engine = try #require(player.currentEngine)
        postConfigurationChange(AVAudioEngine())
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.engineRestarts == 0)
        #expect(player.currentEngine === engine)
        continuation.finish()
        try await outcome(of: playing).get()
    }

    @Test func aFailedRestartEndsPlay() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        defer { continuation.finish() }
        let starts = Mutex(0)
        let player = AudioPlayer(prefillSamples: AudioPlayer.lineInPrefillSamples) { engine in
            let count = starts.withLock { $0 += 1; return $0 }
            if count > 1 { throw EngineStartRefused() }
            try engine.start()
        }
        player.volume = 0
        let playing = Task { try await player.play(stream) }
        #expect(await eventually { player.currentEngine != nil })
        let engine = try #require(player.currentEngine)
        postConfigurationChange(engine)
        await #expect(throws: AudioPlayerError.engineStartFailed("\(EngineStartRefused())")) {
            try await outcome(of: playing).get()
        }
        #expect(player.engineRestarts == 0)
        #expect(player.currentEngine == nil)
        #expect(!engine.isRunning)
    }
}
#endif
