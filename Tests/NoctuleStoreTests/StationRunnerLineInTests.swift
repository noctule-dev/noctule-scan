// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleKitTestSupport
import NoctuleMockScanner
@testable import NoctuleStore

// StationRunner on a USB station with a line-in (line-in design §5.4), against an in-process
// MockSerialScanner (a mock SDS150 on a pseudo-terminal behind a link in a temporary directory, an
// empty fake port listing) and a `FakeLineInSource` the test feeds: no real serial port or audio
// input is ever looked up or opened. Scenario time is a stepped clock; pushes, chunks and polls
// run in real time, so every wait is a bounded poll. Every test stops the runner and the mock and
// checks that the runner never touched the RTSP cooldown store, left no `PSI` subscription running
// and left every line-in source it made stopped. All names and values are fictional.

private let firstAt = 2.0
private let secondAt = 9.0
private let pollInterval: Duration = .milliseconds(50)
private let startCommands = ["MDL", "VER", "PSI,100"]
private let input = LineInConfig(deviceUID: "test-input-uid-1", deviceName: "Test Line In", channel: .both)
private let otherInput = LineInConfig(deviceUID: "test-input-uid-2", deviceName: "Other Test Input", channel: .left)
private let missingWarning = "the audio input \"Test Line In\" isn't connected; logging without audio"
private let preRoll: Duration = .milliseconds(500)
private let postRoll: Duration = .milliseconds(500)

private let silentWarning = "no audio on the line-in during the last 3 transmissions; check the cable and the scanner's volume"
/// The idle floor the rig measured (line-in design §3a), a hit with no audio on it (under the
/// floor + 15 dB), and one that carries audio.
private let idleRMS = -52.0
private let silentRMS = -45.0
private let loudRMS = -20.0
/// A hit long enough to be judged (≥ 2 s), and one too short.
private let longHold: Duration = .milliseconds(2500)
private let shortHold: Duration = .milliseconds(1200)

/// A meter reading at `rms`, measured `ago` before now.
private func reading(_ rms: Double, clipped: Bool = false, ago: Duration = .zero) -> LineInLevel {
    LineInLevel(peakDBFS: clipped ? 0 : rms + 14, rmsDBFS: rms, clipped: clipped, at: .now - ago)
}

private struct TimedOut: Error {}

/// Runs `body` in an unstructured task and gives up after `limit`, even if `body` never returns.
private func bounded<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = Mutex<CheckedContinuation<T, any Error>?>(nil)
    return try await withCheckedThrowingContinuation { continuation in
        box.withLock { $0 = continuation }
        let work = Task {
            let result: Result<T, any Error>
            do { result = .success(try await body()) } catch { result = .failure(error) }
            box.withLock { $0.take() }?.resume(with: result)
        }
        Task {
            try? await Task.sleep(for: limit)
            if let pending = box.withLock({ $0.take() }) {
                work.cancel()
                pending.resume(throwing: TimedOut())
            }
        }
    }
}

/// Polls `condition` every 10 ms until it holds, or throws `TimedOut` after `limit`.
private func eventually(_ limit: Duration = .seconds(10), _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await bounded(limit) {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Collects every runner event in the background.
private final class EventLog: Sendable {
    private let items = Mutex<[RunnerEvent]>([])
    private let finished = Mutex(false)

    init(_ stream: AsyncStream<RunnerEvent>) {
        Task { [self] in
            for await event in stream { items.withLock { $0.append(event) } }
            finished.withLock { $0 = true }
        }
    }

    var all: [RunnerEvent] { items.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }
    var started: [LoggedHit] { all.compactMap { if case .hitStarted(let h) = $0 { h } else { nil } } }
    var ended: [LoggedHit] { all.compactMap { if case .hitEnded(let h) = $0 { h } else { nil } } }
    var warnings: [String] { all.compactMap { if case .warning(let w) = $0 { w } else { nil } } }
    var lineIn: [LineInState] { all.compactMap { if case .lineIn(let s) = $0 { s } else { nil } } }
    var clipped: [LoggedHit] { all.compactMap { if case .clipped(let h) = $0 { h } else { nil } } }
    var connections: Int { all.filter { if case .connected = $0 { true } else { false } }.count }
    var disconnects: Int { all.filter { if case .disconnected = $0 { true } else { false } }.count }
}

/// A cooldown store that fails the test on any call: a line-in station never makes one.
private final class ForbiddenCooldownStore: RTSPCooldownStore {
    private let recorded = Mutex<[String]>([])

    var calls: [String] { recorded.withLock { $0 } }
    private func note(_ call: String) {
        recorded.withLock { $0.append(call) }
        Issue.record("the runner called the cooldown store (\(call)) for a USB station")
    }

    func claim(hosts: [String], pid: Int32, policy: RTSPCooldownPolicy) async -> RTSPCooldownClaim {
        note("claim")
        return .claimed
    }

    func closeHistory(host: String) async -> RTSPCloseHistory? {
        note("closeHistory")
        return nil
    }

    func recordClosed(host: String, at: Date, clean: Bool) async { note("recordClosed") }
    func recordOpened(host: String, at: Date, pid: Int32) async { note("recordOpened") }
    func clear(host: String) async { note("clear") }

    var lastWriteError: String? {
        get async {
            note("lastWriteError")
            return nil
        }
    }
}

/// Feeds the newest fake source a 320-sample chunk every 40 ms, as a capture would, each chunk's
/// samples all equal to its index (1, 2, …), so a recording shows which chunks it holds. Paused,
/// it yields nothing.
private final class ChunkFeeder: Sendable {
    private struct State {
        var paused = false
        var index = 0
        var yielded: [(index: Int, at: ContinuousClock.Instant)] = []
    }
    private let state = Mutex(State())
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ sources: FakeLineInSources) {
        let feeding = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self else { return }
                guard let source = sources.last else { continue }
                let now = ContinuousClock.now
                if let next = self.next(at: now) {
                    source.yield(chunk: FakeLineInSource.chunk(sequence: next, value: Int16(next), at: now))
                }
            }
        }
        task.withLock { $0 = feeding }
    }

    /// The next chunk's index, noted as yielded at `at`; nil while paused.
    private func next(at: ContinuousClock.Instant) -> Int? {
        state.withLock { s in
            guard !s.paused else { return nil }
            s.index += 1
            s.yielded.append((s.index, at))
            return s.index
        }
    }

    /// How many chunks have been yielded so far.
    var count: Int { state.withLock { $0.index } }

    /// Waits until `count` more chunks than `base` have been yielded. A test waits on this, not
    /// on a fixed time, for audio it means to find in a recording: the feeder's 40 ms sleeps can
    /// take much longer on a busy or throttled machine (timer coalescing), so a second of wall
    /// time may hold far fewer than 25 chunks.
    func waitForChunks(_ count: Int, after base: Int, limit: Duration = .seconds(10)) async throws {
        try await eventually(limit) { self.count >= base + count }
    }

    func pause() { state.withLock { $0.paused = true } }
    func resume() { state.withLock { $0.paused = false } }
    func cancel() { task.withLock { $0?.cancel() } }
    var yielded: [(index: Int, at: ContinuousClock.Instant)] { state.withLock { $0.yielded } }
}

/// Counts what a `liveAudio()` tap receives.
private final class TapLog: Sendable {
    private let received = Mutex<[Int16]>([])

    init(_ stream: AsyncStream<AudioChunk>) {
        Task { [self] in
            for await chunk in stream { received.withLock { $0.append(chunk.samples.first ?? 0) } }
        }
    }

    var count: Int { received.withLock { $0.count } }
    /// The first sample of each chunk received (the feeder's index).
    var values: [Int16] { received.withLock { $0 } }
}

/// The samples of a 16-bit 8 kHz mono WAV with a 44-byte header.
private func wavSamples(_ path: String) throws -> [Int16] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count >= 44 else { return [] }
    return stride(from: 44, to: data.count - 1, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
}

private enum LineInFactory {
    /// No factory at all.
    case none
    /// `FakeLineInSources` with this start delay.
    case fake(startDelay: Duration?)
    /// `DisabledLineInSource`, as under the kill-switch.
    case disabled
}

private struct LineInSetup {
    var saveAudio: SaveAudio = .everyTransmission
    var lineIn: LineInConfig? = input
    var factory: LineInFactory = .fake(startDelay: nil)
    var startRunner = true
}

private struct LineInRig: Sendable {
    let mock: MockSerialScanner
    let clock: MockClock
    let runner: StationRunner
    let log: HitLog
    let events: EventLog
    let sources: FakeLineInSources
    let dir: URL

    /// Moves the scenario into the transmission that starts at `start` for `hold` of real time,
    /// then back to idle.
    func play(at start: Double, hold: Duration = .seconds(1)) async throws {
        clock.set(start + 0.01)
        try await Task.sleep(for: hold)
        clock.set(0)
    }

    func waitForEnded(_ count: Int, limit: Duration = .seconds(10)) async throws {
        let events = self.events
        try await eventually(limit) { events.ended.count >= count }
    }

    func waitForLineIn(_ state: LineInState, count: Int = 1) async throws {
        let events = self.events
        try await eventually { events.lineIn.filter { $0 == state }.count >= count }
    }

    /// Gives the newest source `count` meter readings at `rms`, each measured `ago` before now.
    func readings(_ count: Int = 30, rms: Double = idleRMS, clipped: Bool = false, ago: Duration = .zero) throws {
        let source = try #require(sources.last)
        for _ in 0..<count { source.yield(level: reading(rms, clipped: clipped, ago: ago)) }
    }

    /// Starts the next hit: the scenario moves to the other of the transmissions at `firstAt` and
    /// `secondAt` (the one the hit count says), which ends the open hit, if any, at that push
    /// (`channelChanged`, a normal end with no hangover to wait out). Once the hit has started:
    /// five readings at `rms` (none when nil), `clips` clipped ones halfway through `hold`, and
    /// the rest of `hold`. The hit stays open.
    func hit(hold: Duration = longHold, rms: Double?, clips: Int = 0) async throws {
        let events = self.events
        let started = events.started.count
        clock.set([firstAt, secondAt][started % 2] + 0.01)
        try await eventually { events.started.count > started }
        if let rms { try readings(5, rms: rms) }
        try await Task.sleep(for: hold / 2)
        if clips > 0 { try readings(clips, rms: rms ?? loudRMS, clipped: true) }
        try await Task.sleep(for: hold / 2)
    }

    /// Ends the open hit normally and returns it: by starting another (`channelChanged`; that one
    /// gets no readings, stays open and is ended by the stop), or, with `idle`, by going back to
    /// idle and waiting out the hangover (`signalLost`).
    @discardableResult
    func endHit(idle: Bool = false) async throws -> LoggedHit {
        let events = self.events
        let ended = events.ended.count
        clock.set(idle ? 0 : [firstAt, secondAt][events.started.count % 2] + 0.01)
        try await waitForEnded(ended + 1)
        return events.ended[ended]
    }

    /// How many times the silent line-in warning has been raised.
    var silentWarnings: Int { events.warnings.filter { $0 == silentWarning }.count }

    var wavFiles: [String] {
        (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.path } ?? []).filter { $0.hasSuffix(".wav") }
    }
}

private struct LineInOutcome {
    let commands: [String]
    let subscribers: Int
    let events: [RunnerEvent]
    let cooldownCalls: [String]
    let sources: [FakeLineInSource]
}

/// Starts a mock SDS150 behind a link path and a runner for a USB station on that path with the
/// setup's line-in, runs `body`, then always stops the runner (bounded) and the mock, and checks
/// what holds for every run: no cooldown call, no network audio event, no subscription left
/// running, every fake source stopped, `.stopped` last.
@discardableResult
private func withLineInRunner(
    _ setup: LineInSetup = LineInSetup(), limit: Duration = .seconds(40),
    _ body: @escaping @Sendable (LineInRig) async throws -> Void
) async throws -> LineInOutcome {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-line-in-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let clock = MockClock.stepped(at: 0)
    let mock = MockSerialScanner(scenario: .default, clock: clock, personality: .sds150,
                                 linkPath: dir.appendingPathComponent("port").path)
    let port = try await mock.start()

    var station = Station()
    station.name = "Test Handheld"
    station.connection.transport = .usbSerial
    station.recording.saveAudio = setup.saveAudio
    var device = StationDeviceSettings(stationID: station.id)
    device.usbPort = port
    device.audioInputDevice = setup.lineIn?.deviceUID
    device.audioInputName = setup.lineIn?.deviceName
    device.audioInputChannel = setup.lineIn?.channel

    let sources: FakeLineInSources
    let factory: LineInSourceFactory?
    switch setup.factory {
    case .none:
        sources = FakeLineInSources()
        factory = nil
    case .fake(let startDelay):
        sources = FakeLineInSources(startDelay: startDelay)
        factory = sources.factory
    case .disabled:
        sources = FakeLineInSources()
        factory = { _ in DisabledLineInSource(reason: LineInDetection.disabledReason) }
    }

    let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))
    let cooldown = ForbiddenCooldownStore()
    let runner = StationRunner(station: station, device: device, log: log,
                               recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
                               cooldownStore: cooldown,
                               transportFactory: StationTransportFactory(ports: FakePorts([])),
                               portPollInterval: pollInterval,
                               audioConfig: AudioSessionConfig(cooldownStore: cooldown),
                               pushInterval: .milliseconds(100), lineInSources: factory)
    let events = EventLog(runner.events)
    let rig = LineInRig(mock: mock, clock: clock, runner: runner, log: log, events: events, sources: sources, dir: dir)

    var failure: (any Error)?
    do {
        if setup.startRunner { try await bounded(.seconds(15)) { try await runner.start() } }
        try await bounded(limit) { try await body(rig) }
    } catch {
        failure = error
    }
    do {
        try await bounded(.seconds(15)) { await runner.stop() }
        try await eventually(.seconds(2)) { events.isFinished }
    } catch {
        if failure == nil { failure = error }
    }
    await mock.stop()
    let outcome = LineInOutcome(commands: await mock.receivedCommands, subscribers: await mock.activeSubscribers,
                                events: events.all, cooldownCalls: cooldown.calls, sources: sources.sources)
    await log.close()
    if let failure { throw failure }

    #expect(outcome.cooldownCalls == [])
    #expect(!outcome.events.contains { if case .audio = $0 { true } else { false } })
    #expect(outcome.subscribers == 0, "\(outcome.commands.suffix(5))")
    #expect(outcome.sources.allSatisfy { $0.stopped })
    #expect(outcome.events.last == .stopped)
    #expect(outcome.events.filter { $0 == .stopped }.count == 1)
    return outcome
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct StationRunnerLineInTests {
    /// One hit on a streaming line-in: a WAV of the chunks received during it, with the pre-roll
    /// and the post-roll, and its path on the hit.
    @Test func lineInRecordsAHit() async throws {
        let outcome = try await withLineInRunner { rig in
            #expect(await rig.runner.hasAudio)
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            #expect(source.config == input)
            #expect(source.startCalls == 1)
            let feeder = ChunkFeeder(rig.sources)
            defer { feeder.cancel() }
            // More than the pre-roll before the hit.
            try await Task.sleep(for: .milliseconds(800))
            // The hit lasts 25 chunks, not a fixed second: the feeder's 40 ms sleeps can take far
            // longer (LESSONS.md 2026-11-20), and a recording under 500 ms is dropped.
            rig.clock.set(firstAt + 0.01)
            try await eventually { rig.events.started.count == 1 }
            try await feeder.waitForChunks(25, after: feeder.count)
            rig.clock.set(0)
            try await rig.waitForEnded(1)
            feeder.cancel()

            let ended = try #require(rig.events.ended.first)
            let path = try #require(ended.audioPath)
            #expect(ended.audioError == nil)
            #expect(rig.events.started.first?.audioPath == path)
            let row = try #require(try await rig.log.transmissions(HitFilter()).first)
            #expect(row.audioPath == path)

            let samples = try wavSamples(path)
            #expect(samples.count % 320 == 0)
            let blocks = stride(from: 0, to: samples.count, by: 320).map { Int(samples[$0]) }
            for (offset, start) in stride(from: 0, to: samples.count, by: 320).enumerated() {
                #expect(samples[start..<(start + 320)].allSatisfy { Int($0) == blocks[offset] })
            }
            // Whole chunks, in order, none missing or repeated.
            let first = try #require(blocks.first)
            #expect(blocks == Array(first..<(first + blocks.count)), "\(blocks)")

            let start = ended.hit.startInstant
            let end = try #require(ended.hit.endInstant)
            let yielded = feeder.yielded
            let at = Dictionary(uniqueKeysWithValues: yielded.map { ($0.index, $0.at) })
            // Every chunk of the hit itself is in the file.
            let during = yielded.filter { $0.at >= start && $0.at <= end }.map(\.index)
            #expect(!during.isEmpty)
            #expect(Set(during).isSubset(of: Set(blocks)))
            // The post-roll: every chunk up to the hit's end plus 0.5 s, and none after.
            let lastWanted = try #require(yielded.last { $0.at <= end + postRoll }?.index)
            #expect(blocks.last == lastWanted)
            // The pre-roll: from 0.5 s before the start (a chunk or two later when the push that
            // started the hit was handled a moment after it arrived). When the feeder fell behind,
            // so that no chunk came in the first 200 ms of the pre-roll, from the first that did.
            let firstChunkAt = try #require(at[first])
            let firstInPreRoll = try #require(yielded.first { $0.at >= start - preRoll })
            #expect(firstChunkAt >= start - preRoll)
            #expect(firstChunkAt < start - preRoll + .milliseconds(200) || first == firstInPreRoll.index,
                    "\(start - firstChunkAt)")
        }
        #expect(outcome.commands == startCommands + ["PSI,0"])
        #expect(outcome.events.contains(.lineIn(.starting)))
        #expect(outcome.events.contains(.lineIn(.stopped)))
        #expect(outcome.sources.count == 1)
        // Line-in recordings are placed by the model's offset: none yet for any model.
        for model in ScannerModel.allCases { #expect(ModelProfile.profile(for: model).lineInAudioOffset == .zero) }
    }

    /// Save-audio "never" governs recordings only: the tap still gets the line-in's chunks.
    @Test func saveAudioNeverStillStreamsTheTap() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup) { rig in
            #expect(await rig.runner.hasAudio)
            let tap = TapLog(await rig.runner.liveAudio())
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let feeder = ChunkFeeder(rig.sources)
            defer { feeder.cancel() }
            try await rig.play(at: firstAt)
            try await rig.waitForEnded(1)
            try await eventually { tap.count >= 10 }
            feeder.cancel()

            let values = tap.values
            #expect(values == Array(1...Int16(values.count)))
            #expect(rig.events.ended.first?.audioPath == nil)
            #expect(rig.wavFiles == [])
        }
    }

    /// No line-in configured, or no factory to make one: the station runs as before the line-in.
    @Test func noLineInConfigIsTodaysBehaviour() async throws {
        var noConfig = LineInSetup()
        noConfig.lineIn = nil
        var noFactory = LineInSetup()
        noFactory.factory = .none
        for setup in [noConfig, noFactory] {
            let outcome = try await withLineInRunner(setup) { rig in
                #expect(await rig.runner.hasAudio == false)
                try await rig.play(at: firstAt)
                try await rig.waitForEnded(1)
                #expect(rig.events.ended.first?.audioPath == nil)
                #expect(rig.wavFiles == [])
                // No line-in: whether it clipped is unknown.
                #expect(rig.events.ended.first?.audioClipped == nil)
                #expect(try await rig.log.transmissions(HitFilter()).first?.audioClipped == nil)
            }
            #expect(outcome.sources.isEmpty)
            #expect(!outcome.events.contains { if case .lineIn = $0 { true } else { false } })
            #expect(outcome.events.allSatisfy { if case .warning = $0 { false } else { true } })
            #expect(outcome.commands == startCommands + ["PSI,0"])
        }
    }

    /// The audio input unplugged mid-hit, then back (review focus 1).
    @Test func lineInMissingThenBack() async throws {
        try await withLineInRunner { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            let feeder = ChunkFeeder(rig.sources)
            defer { feeder.cancel() }
            try await Task.sleep(for: .milliseconds(300))

            // Hit 1 records, then the input goes away in the middle of it.
            rig.clock.set(firstAt + 0.01)
            try await eventually { rig.events.started.count == 1 }
            try await feeder.waitForChunks(25, after: feeder.count)
            feeder.pause()
            source.setState(.missing(deviceName: "Test Line In"))
            try await rig.waitForLineIn(.missing(deviceName: "Test Line In"))
            try await Task.sleep(for: .milliseconds(300))
            rig.clock.set(0)
            try await rig.waitForEnded(1)
            let first = try #require(rig.events.ended.first)
            let path = try #require(first.audioPath, "the hit keeps what it had")
            #expect(try wavSamples(path).count >= 320 * 20)
            #expect(rig.events.warnings == [missingWarning])

            // Still missing (the source says so again): no second warning; hit 2 has no audio.
            source.setState(.missing(deviceName: "Test Line In"))
            try await rig.waitForLineIn(.missing(deviceName: "Test Line In"), count: 2)
            try await rig.play(at: secondAt)
            try await rig.waitForEnded(2)
            #expect(rig.events.ended[1].audioPath == nil)
            #expect(rig.events.started[1].audioPath == nil)
            #expect(rig.events.warnings == [missingWarning])

            // Back: hit 3 records again, and the input is never restarted by the runner.
            source.setState(.streaming(deviceName: "Test Line In"))
            feeder.resume()
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"), count: 2)
            try await Task.sleep(for: .milliseconds(600))
            rig.clock.set(firstAt + 0.01)
            try await eventually { rig.events.started.count == 3 }
            try await feeder.waitForChunks(25, after: feeder.count)
            rig.clock.set(0)
            try await rig.waitForEnded(3)
            let third = rig.events.ended[2]
            let thirdPath = try #require(third.audioPath)
            #expect(thirdPath != path)
            #expect(try wavSamples(thirdPath).count >= 320 * 20)
            #expect(source.startCalls == 1)
            #expect(!source.stopped)

            // A new spell warns again.
            source.setState(.missing(deviceName: "Test Line In"))
            try await eventually { rig.events.warnings.count == 2 }
            #expect(rig.events.warnings == [missingWarning, missingWarning])

            let rows = try await rig.log.transmissions(HitFilter()).sorted { $0.hit.startedAt < $1.hit.startedAt }
            #expect(rows.count == 3)
            #expect(rows.map { $0.audioPath != nil } == [true, false, true])
        }
    }

    /// The scanner unplugged while the line-in runs (review focus 2): the line-in keeps going and
    /// is never stopped or restarted; after the resume hits record again.
    @Test func lineInSurvivesAScannerDisconnect() async throws {
        try await withLineInRunner { rig in
            let tap = TapLog(await rig.runner.liveAudio())
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            let feeder = ChunkFeeder(rig.sources)
            defer { feeder.cancel() }
            try await eventually { tap.count >= 5 }

            await rig.mock.unplug()
            try await eventually { rig.events.disconnects == 1 }
            let atDisconnect = tap.count
            try await eventually { tap.count >= atDisconnect + 10 }
            #expect(source.startCalls == 1)
            #expect(!source.stopped)

            _ = try await rig.mock.replug()
            try await eventually { rig.events.connections == 2 }
            let atResume = tap.count
            try await eventually { tap.count >= atResume + 5 }
            #expect(source.startCalls == 1)
            #expect(!source.stopped)
            #expect(rig.sources.sources.count == 1)

            // A hit of 25 chunks, not a fixed second (see `lineInRecordsAHit`).
            rig.clock.set(firstAt + 0.01)
            try await eventually { rig.events.started.count == 1 }
            try await feeder.waitForChunks(25, after: feeder.count)
            rig.clock.set(0)
            try await rig.waitForEnded(1)
            #expect(rig.events.ended.first?.audioPath != nil)
            // The tap saw every chunk, in order, through the wait.
            let values = tap.values
            #expect(values == Array(1...Int16(values.count)))
            // Only `.starting` and `.streaming`: the scanner's absence isn't the line-in's business.
            #expect(rig.events.lineIn == [.starting, .streaming(deviceName: "Test Line In")])
        }
    }

    /// A stop while the source is still starting (review focus 3): the stop returns at once, the
    /// source is stopped, and `PSI,0` is sent.
    @Test func stopWhileTheSourceIsStarting() async throws {
        var setup = LineInSetup()
        setup.factory = .fake(startDelay: .seconds(10))
        setup.startRunner = false
        let outcome = try await withLineInRunner(setup) { rig in
            let runner = rig.runner
            let starting = Task { try await runner.start() }
            try await rig.waitForLineIn(.starting)
            let source = try #require(rig.sources.last)
            #expect(source.started)
            #expect(!source.stopped)

            let began = ContinuousClock.now
            try await bounded(.seconds(2)) { await runner.stop() }
            #expect(ContinuousClock.now - began < .seconds(2))
            #expect(source.stopped)
            _ = await starting.result
            #expect(await rig.mock.receivedCommands.last == "PSI,0")
        }
        #expect(outcome.commands == startCommands + ["PSI,0"])
        #expect(!outcome.events.contains(.lineIn(.streaming(deviceName: "Test Line In"))))
    }

    /// A whole line-in run (a recording, the input missing and back, a replacement, the stop)
    /// makes no call on the RTSP cooldown store.
    @Test func neverTouchesTheCooldownStore() async throws {
        let outcome = try await withLineInRunner { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let feeder = ChunkFeeder(rig.sources)
            defer { feeder.cancel() }
            try await Task.sleep(for: .milliseconds(300))
            try await rig.play(at: firstAt)
            try await rig.waitForEnded(1)
            #expect(rig.events.ended.first?.audioPath != nil)
            rig.sources.last?.setState(.missing(deviceName: "Test Line In"))
            rig.sources.last?.setState(.streaming(deviceName: "Test Line In"))
            await rig.runner.replaceLineIn(otherInput)
            try await rig.waitForLineIn(.streaming(deviceName: "Other Test Input"))
        }
        #expect(outcome.cooldownCalls == [])
        #expect(outcome.sources.count == 2)
    }

    /// `replaceLineIn` stops the running source and starts one for the new input, or none,
    /// without touching the scanner.
    @Test func replaceLineInSwapsTheSource() async throws {
        let outcome = try await withLineInRunner { rig in
            let tap = TapLog(await rig.runner.liveAudio())
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let first = try #require(rig.sources.last)
            first.yield(chunk: FakeLineInSource.chunk(sequence: 1, value: 1))
            try await eventually { tap.values == [1] }

            await rig.runner.replaceLineIn(otherInput)
            #expect(first.stopped)
            #expect(rig.sources.sources.count == 2)
            let second = try #require(rig.sources.last)
            #expect(second.config == otherInput)
            #expect(!second.stopped)
            // Started, but not waited for.
            try await rig.waitForLineIn(.streaming(deviceName: "Other Test Input"))
            #expect(second.startCalls == 1)
            #expect(await rig.runner.hasAudio)
            // The old source is gone; the new one feeds the tap.
            first.yield(chunk: FakeLineInSource.chunk(sequence: 2, value: 2))
            second.yield(chunk: FakeLineInSource.chunk(sequence: 3, value: 3))
            try await eventually { tap.values.count >= 2 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(tap.values == [1, 3])
            #expect(rig.events.lineIn == [.starting, .streaming(deviceName: "Test Line In"), .stopped,
                                          .starting, .streaming(deviceName: "Other Test Input")])

            await rig.runner.replaceLineIn(nil)
            #expect(second.stopped)
            #expect(rig.sources.sources.count == 2)
            #expect(await rig.runner.hasAudio == false)
            try await eventually { rig.events.lineIn.count == 6 }
            #expect(rig.events.lineIn.last == .stopped)
            // The scanner was never touched.
            #expect(await rig.mock.receivedCommands == startCommands)
        }
        #expect(outcome.commands == startCommands + ["PSI,0"])
    }

    /// Under the kill-switch the source says why it is off: one warning, and hits are still logged.
    @Test func disabledSourceWarnsOnce() async throws {
        var setup = LineInSetup()
        setup.factory = .disabled
        let outcome = try await withLineInRunner(setup) { rig in
            try await rig.waitForLineIn(.failed("audio input disabled by NOCTULE_NO_USB_DETECTION"))
            try await rig.play(at: firstAt)
            try await rig.waitForEnded(1)
            #expect(rig.events.ended.first?.audioPath == nil)
            #expect(rig.wavFiles == [])
            #expect(try await rig.log.transmissions(HitFilter()).count == 1)
        }
        #expect(outcome.events.compactMap { if case .warning(let w) = $0 { w } else { nil } }
                == ["audio input disabled by NOCTULE_NO_USB_DETECTION"])
    }

    /// Permission refused: the permission copy, once, and hits logged without audio.
    @Test func deniedWarnsOnce() async throws {
        let outcome = try await withLineInRunner { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            source.setState(.denied)
            source.setState(.denied)
            try await rig.waitForLineIn(.denied, count: 2)
            try await rig.play(at: firstAt)
            try await rig.waitForEnded(1)
            #expect(rig.events.ended.first?.audioPath == nil)
        }
        #expect(outcome.events.compactMap { if case .warning(let w) = $0 { w } else { nil } }
                == ["Noctule Scan isn't allowed to use audio input. Allow it in System Settings › Privacy & Security › Microphone."])
    }

    /// `liveLevels()` gets the line-in's meter readings; a second call finishes the first, and the
    /// stop finishes the second.
    @Test func liveLevelsFollowTheSource() async throws {
        let level = LineInLevel(peakDBFS: -12, rmsDBFS: -20, clipped: false, at: .now)
        let later = LineInLevel(peakDBFS: -6, rmsDBFS: -15, clipped: false, at: .now)
        let tap = Slot<LevelLog>()
        try await withLineInRunner { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            let first = LevelLog(await rig.runner.liveLevels())
            source.yield(level: level)
            try await eventually { first.levels == [level] }

            let second = LevelLog(await rig.runner.liveLevels())
            try await eventually { first.isFinished }
            source.yield(level: later)
            try await eventually { second.levels == [later] }
            #expect(first.levels == [level])
            tap.set(second)
        }
        let second = try #require(tap.value)
        try await eventually { second.isFinished }
    }

    // MARK: Clipped and silent hits (line-in design §5.3)

    /// A hit that starts while the input is missing records once the input is back.
    @Test func hitWaitingForTheLineInRecordsWhenItComesBack() async throws {
        try await withLineInRunner { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            let feeder = ChunkFeeder(rig.sources)
            defer { feeder.cancel() }
            feeder.pause()
            source.setState(.missing(deviceName: "Test Line In"))
            try await rig.waitForLineIn(.missing(deviceName: "Test Line In"))

            rig.clock.set(firstAt + 0.01)
            try await eventually { rig.events.started.count == 1 }
            #expect(rig.events.started.first?.audioPath == nil)
            try await Task.sleep(for: .milliseconds(300))
            source.setState(.streaming(deviceName: "Test Line In"))
            feeder.resume()
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"), count: 2)
            try await feeder.waitForChunks(25, after: feeder.count)
            rig.clock.set(0)
            try await rig.waitForEnded(1)
            let path = try #require(rig.events.ended.first?.audioPath, "recorded from the input's return")
            #expect(try wavSamples(path).count >= 320 * 20)
            #expect(try await rig.log.transmissions(HitFilter()).first?.audioPath == path)
        }
    }
}

/// Clipped and silent hits (line-in design §5.3), on the line-in rig. Not serialized: each test
/// waits out several hits of real time (a judged hit is at least 2 s long), so they run side by
/// side; each has its own mock, runner and sources. Consecutive hits change channel, so no hit
/// waits out a hangover unless the test needs a quiet line between hits.
@Suite(.timeLimit(.minutes(2))) struct StationRunnerClippedAndSilentHitsTests {
    /// One clipped reading in the middle of a recorded hit: one `.clipped`, while the hit is
    /// still open, and the hit ends clipped in the events and in the log.
    @Test func clipDuringAHitMarksIt() async throws {
        try await withLineInRunner { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let feeder = ChunkFeeder(rig.sources)
            defer { feeder.cancel() }
            try rig.readings()
            try await Task.sleep(for: .milliseconds(300))
            let base = feeder.count
            try await rig.hit(hold: .seconds(1), rms: loudRMS, clips: 1)
            // Enough chunks to keep: the feeder's 40 ms sleeps can take far longer than that
            // (LESSONS.md 2026-11-20), and a recording under 500 ms is dropped.
            try await feeder.waitForChunks(25, after: base)
            // At the clip: the hit is still open.
            try await eventually(.seconds(2)) { rig.events.clipped.count == 1 }
            #expect(rig.events.ended.isEmpty)
            let ended = try await rig.endHit()
            feeder.cancel()

            #expect(ended.audioPath != nil)
            #expect(ended.audioClipped == true)
            let clipped = rig.events.clipped
            #expect(clipped.count == 1)
            #expect(clipped.first?.hit.id == ended.hit.id)
            #expect(clipped.first?.audioClipped == true)
            // At the clip, not at the end.
            let all = rig.events.all
            let clipIndex = try #require(all.firstIndex { if case .clipped = $0 { true } else { false } })
            let endIndex = try #require(all.firstIndex { if case .hitEnded(let h) = $0 { h.hit.id == ended.hit.id } else { false } })
            #expect(clipIndex < endIndex)
            let row = try #require(try await rig.log.transmissions(HitFilter()).first { $0.hit.id == ended.hit.id })
            #expect(row.audioClipped == true)
            #expect(row.audioPath == ended.audioPath)
        }
    }

    /// A clip with no hit open (before one, and after it) marks nothing; the hit between is a
    /// line-in hit that didn't clip.
    @Test func clipBetweenHitsMarksNothing() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let levels = LevelLog(await rig.runner.liveLevels())
            let source = try #require(rig.sources.last)
            let before = reading(0, clipped: true)
            source.yield(level: before)
            // The runner has handled it.
            try await eventually { levels.levels.contains(before) }

            try await rig.hit(hold: .seconds(1), rms: loudRMS)
            let ended = try await rig.endHit(idle: true)
            let after = reading(0, clipped: true)
            source.yield(level: after)
            try await eventually { levels.levels.contains(after) }
            try await Task.sleep(for: .milliseconds(200))

            #expect(rig.events.clipped == [])
            #expect(ended.audioClipped == false)
            #expect(try await rig.log.transmissions(HitFilter()).first?.audioClipped == false)
        }
    }

    /// Two clips in one hit raise one `.clipped`.
    @Test func twoClipsOneEvent() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            try await rig.hit(hold: .seconds(1), rms: loudRMS, clips: 2)
            let ended = try await rig.endHit()
            #expect(rig.events.clipped.count == 1)
            #expect(ended.audioClipped == true)
            #expect(try await rig.log.transmissions(HitFilter()).first { $0.hit.id == ended.hit.id }?.audioClipped == true)
        }
    }

    /// Three silent hits in a row (the floor at −52 dBFS, the hits at −45) warn once; a fourth
    /// doesn't warn again.
    @Test func threeSilentHitsWarnOnce() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            try rig.readings()
            for _ in 0..<3 { try await rig.hit(rms: silentRMS) }
            #expect(rig.silentWarnings == 0)
            // The fourth hit ends the third.
            try await rig.hit(rms: silentRMS)
            try await eventually { rig.silentWarnings == 1 }
            try await rig.endHit()
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.events.warnings == [silentWarning])
            // Silence isn't clipping.
            #expect(rig.events.ended.allSatisfy { $0.audioClipped == false })
        }
    }

    /// A hit with audio resets the count and re-arms the warning: silent ×3 warns, loud, then it
    /// takes three more silent hits to warn again.
    @Test func loudHitReArms() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            try rig.readings()
            for _ in 0..<3 { try await rig.hit(rms: silentRMS) }
            try await rig.hit(rms: loudRMS)
            try await eventually { rig.silentWarnings == 1 }
            for _ in 0..<3 { try await rig.hit(rms: silentRMS) }
            // Two of those three have ended.
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.silentWarnings == 1)
            try await rig.endHit()
            try await eventually { rig.silentWarnings == 2 }
            #expect(rig.events.warnings == [silentWarning, silentWarning])
        }
    }

    /// Two silent hits aren't enough.
    @Test func twoSilentHitsDoNotWarn() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            try rig.readings()
            for _ in 0..<2 { try await rig.hit(rms: silentRMS) }
            try await rig.endHit()
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.events.warnings == [])
        }
    }

    /// Hits under 2 s neither count (a short silent one) nor reset (a short loud one).
    @Test func shortHitsDoNotCount() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            try rig.readings()
            try await rig.hit(rms: silentRMS)
            try await rig.hit(hold: shortHold, rms: silentRMS)
            try await rig.hit(rms: silentRMS)
            try await rig.hit(hold: shortHold, rms: loudRMS)
            // Ends the short loud one.
            try await rig.hit(rms: silentRMS)
            let ended = rig.events.ended
            #expect(ended.count == 4)
            for short in [ended[1], ended[3]] {
                let end = try #require(short.hit.endInstant)
                #expect(end - short.hit.startInstant < .seconds(2))
            }
            #expect(rig.silentWarnings == 0)
            try await rig.endHit()
            try await eventually { rig.silentWarnings == 1 }
            #expect(rig.events.warnings == [silentWarning])
        }
    }

    /// A hit while the input is missing is no evidence either way: it neither counts (silent
    /// readings during it) nor resets.
    @Test func missingDeviceIsNotSilence() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            try rig.readings()
            for _ in 0..<2 { try await rig.hit(rms: silentRMS) }
            // Ended before the input goes, so it counts.
            try await rig.endHit(idle: true)

            source.setState(.missing(deviceName: "Test Line In"))
            try await rig.waitForLineIn(.missing(deviceName: "Test Line In"))
            try await rig.hit(rms: silentRMS)
            source.setState(.streaming(deviceName: "Test Line In"))
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"), count: 2)
            // Ends the hit during the missing spell.
            try await rig.hit(rms: silentRMS)
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.events.warnings == [missingWarning])

            try await rig.endHit()
            try await eventually { rig.silentWarnings == 1 }
            #expect(rig.events.warnings == [missingWarning, silentWarning])
        }
    }

    /// With no idle reading yet there is no floor, so no hit is judged silent.
    @Test func noFloorYetJudgesNothing() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            for _ in 0..<3 { try await rig.hit(rms: silentRMS) }
            try await rig.endHit()
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.events.warnings == [])
        }
    }

    /// A third silent hit cut short by `stop()` isn't judged: two silent hits and a stop never
    /// warn. A clip still marks it, however it ends.
    @Test func aHitEndedByTheStopIsNotJudged() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        let outcome = try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            try rig.readings()
            for _ in 0..<2 { try await rig.hit(rms: silentRMS) }
            try await rig.hit(rms: silentRMS, clips: 1)
            #expect(rig.events.ended.count == 2)
            try await eventually { rig.events.clipped.count == 1 }
            await rig.runner.stop()
            let third = try #require(rig.events.ended.last)
            #expect(third.hit.endReason == .stopped)
            #expect(third.audioClipped == true)
            let row = try await rig.log.transmissions(HitFilter()).first { $0.hit.id == third.hit.id }
            #expect(row?.audioClipped == true)
        }
        let ended = outcome.events.compactMap { if case .hitEnded(let h) = $0 { h } else { nil } }
        #expect(ended.count == 3)
        #expect(ended.last?.hit.endReason == .stopped)
        #expect(outcome.events.allSatisfy { if case .warning = $0 { false } else { true } })
    }

    /// Nor is one during which the input went missing and came back: two silent hits, then a
    /// third that goes `.missing` and back while it runs, warn nothing; it doesn't reset either.
    @Test func goingMissingMidHitIsNotJudged() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let source = try #require(rig.sources.last)
            try rig.readings()
            for _ in 0..<3 { try await rig.hit(rms: silentRMS) }
            // The third hit, streaming as it started, loses its input for a moment.
            source.setState(.missing(deviceName: "Test Line In"))
            try await rig.waitForLineIn(.missing(deviceName: "Test Line In"))
            source.setState(.streaming(deviceName: "Test Line In"))
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"), count: 2)
            try await rig.endHit()
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.events.warnings == [missingWarning])
            // Not a reset: one more silent hit is the third.
            try await rig.hit(rms: silentRMS)
            try await rig.endHit()
            try await eventually { rig.silentWarnings == 1 }
            #expect(rig.events.warnings == [missingWarning, silentWarning])
        }
    }

    /// A clip timed before an open hit's start, handled while that hit is open, doesn't mark it.
    @Test func aClipBeforeTheHitsStartDoesNotMarkIt() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            let levels = LevelLog(await rig.runner.liveLevels())
            let source = try #require(rig.sources.last)
            try await rig.hit(hold: .seconds(1), rms: loudRMS)
            let start = try #require(rig.events.started.last?.hit.startInstant)
            let early = LineInLevel(peakDBFS: 0, rmsDBFS: -3, clipped: true, at: start - .milliseconds(500))
            source.yield(level: early)
            try await eventually { levels.levels.contains(early) }
            #expect(rig.events.ended.isEmpty)
            let ended = try await rig.endHit()
            #expect(rig.events.clipped == [])
            #expect(ended.audioClipped == false)
        }
    }

    /// The floor is the median of the last minute's idle readings: not their mean (pulled down
    /// by a few very low ones), not their maximum, and not readings older than 60 s. Against a
    /// floor of −52, hits at −45 are silent and a hit at −30 is loud; a mean floor (about −75)
    /// would make no hit silent, and a maximum (−25) or one that kept the old readings (−10) would
    /// make the −30 hit silent too.
    @Test func floorIsTheMedianOfTheLastMinute() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            // Outside the window: the first reading inside it drops them.
            try rig.readings(40, rms: -10, ago: .seconds(90))
            try rig.readings(6, rms: -150)
            try rig.readings(11, rms: idleRMS)
            try rig.readings(4, rms: -25)
            let mid = -30.0
            for rms in [silentRMS, silentRMS, mid, silentRMS] { try await rig.hit(rms: rms) }
            // The fourth hit, ending the −30 one, has started: the run is back to zero.
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.events.warnings == [])
            for _ in 0..<2 { try await rig.hit(rms: silentRMS) }
            try await rig.endHit()
            try await eventually { rig.silentWarnings == 1 }
            #expect(rig.events.warnings == [silentWarning])
        }
    }

    /// Nor is one cut short by the scanner going away (its push stream ends: `stalled`).
    @Test func aHitEndedByADisconnectIsNotJudged() async throws {
        var setup = LineInSetup()
        setup.saveAudio = .never
        try await withLineInRunner(setup, limit: .seconds(60)) { rig in
            try await rig.waitForLineIn(.streaming(deviceName: "Test Line In"))
            try rig.readings()
            for _ in 0..<3 { try await rig.hit(rms: silentRMS) }
            await rig.mock.unplug()
            try await rig.waitForEnded(3)
            #expect(rig.events.ended.last?.hit.endReason == .stalled)
            try await eventually { rig.events.disconnects == 1 }
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.events.warnings == [])
        }
    }
}

/// One value, set from inside a test body and read after it.
private final class Slot<T: Sendable>: Sendable {
    private let stored = Mutex<T?>(nil)
    func set(_ value: T) { stored.withLock { $0 = value } }
    var value: T? { stored.withLock { $0 } }
}

/// Collects what a `liveLevels()` stream delivers.
private final class LevelLog: Sendable {
    private let received = Mutex<[LineInLevel]>([])
    private let finished = Mutex(false)

    init(_ stream: AsyncStream<LineInLevel>) {
        Task { [self] in
            for await level in stream { received.withLock { $0.append(level) } }
            finished.withLock { $0 = true }
        }
    }

    var levels: [LineInLevel] { received.withLock { $0 } }
    var isFinished: Bool { finished.withLock { $0 } }
}
