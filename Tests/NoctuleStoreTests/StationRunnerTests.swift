// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleMockScanner
import NoctuleKitTestSupport
@testable import NoctuleStore

// StationRunner against an in-process MockSDS200 on loopback (control UDP, RTSP, RTP). The mock
// runs on a stepped clock: a test "plays" a transmission by moving the clock into it, holding it
// for real time, and moving it back to idle. Every wait is bounded, every test stops the runner
// and the mock, and every test checks that the mock saw no leaked RTSP session and that the last
// control command was `PSI,0`. All names and values are fictional.

private let mockCooldown: Duration = .milliseconds(300)

private let idle = MockIdle(system: "Testville County P25", site: "Testville Simulcast", frequencyMHz: 851.0125)
/// A 1.0 s talkgroup transmission on a programmed talkgroup.
private let talkgroup = MockTransmission(
    at: 2, duration: 1.0, system: "Testville County P25", department: "Testville Fire",
    channel: "Testville Fire Dispatch", tgid: "4711", unitID: "5101", frequencyMHz: 851.2375,
    toneOrCode: "NAC 2A1h", rssi: -62, programmed: true, toneHz: 440)
/// An unprogrammed conventional channel (no talkgroup).
private let conventional = MockTransmission(
    at: 5, duration: 1.0, system: "Testville Marine", department: "Testville Harbor",
    channel: "Testville Marina", tgid: nil, frequencyMHz: 155.1234, rssi: -60, programmed: false, toneHz: 660)
private let scenario = MockScenario(idle: idle, transmissions: [talkgroup, conventional])

private struct TimedOut: Error {}

/// Runs `body` in an unstructured task and gives up after `limit`, even if `body` never returns
/// (a task group would wait for it), so a hung runner fails the test instead of hanging it.
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

/// Polls `condition` every 20 ms until it holds, or throws `TimedOut` after `limit`.
private func eventually(_ limit: Duration = .seconds(10), _ condition: @escaping @Sendable () async -> Bool) async throws {
    try await bounded(limit) {
        while !(await condition()) { try await Task.sleep(for: .milliseconds(20)) }
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
    var audioStates: [AudioSessionState] { all.compactMap { if case .audio(let s) = $0 { s } else { nil } } }
}

/// A control transport that forwards to `UDPTransport` and can inject a response, so a test can
/// end the push stream (`PSI,NG`) while the link stays up.
private final class InjectingTransport: ScannerTransport, Sendable {
    private struct Link {
        var stream: AsyncStream<ScannerResponse>
        var continuation: AsyncStream<ScannerResponse>.Continuation?
        var pump: Task<Void, Never>?
    }

    let inner: UDPTransport
    private let link: Mutex<Link>

    init(host: String, port: UInt16) {
        inner = UDPTransport(host: host, port: port)
        let (stream, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        continuation.finish()
        link = Mutex(Link(stream: stream, continuation: nil, pump: nil))
    }

    func open() async throws {
        try await inner.open()
        let (stream, continuation) = AsyncStream.makeStream(of: ScannerResponse.self)
        let source = inner.responses
        let pump = Task {
            for await response in source { continuation.yield(response) }
            continuation.finish()
        }
        link.withLock { $0 = Link(stream: stream, continuation: continuation, pump: pump) }
    }

    func send(_ command: ScannerCommand) async throws { try await inner.send(command) }

    var responses: AsyncStream<ScannerResponse> { link.withLock { $0.stream } }

    func close() async {
        await inner.close()
        let old = link.withLock { $0 }
        old.pump?.cancel()
        old.continuation?.finish()
    }

    func inject(_ line: String) {
        guard let response = ResponseLineParser.parse(line) else { return }
        _ = link.withLock { $0.continuation?.yield(response) }
    }
}

private struct Rig: Sendable {
    let mock: MockSDS200
    let runner: StationRunner
    let log: HitLog
    let events: EventLog
    let folder: URL
    let dir: URL

    var clock: MockClock { mock.clock }

    /// Moves the scenario into `transmission` for `hold` of real time, then back to idle.
    func play(_ transmission: MockTransmission, hold: Duration = .seconds(1)) async throws {
        clock.set(transmission.at + 0.01)
        try await Task.sleep(for: hold)
        clock.set(0)
    }

    /// Waits until `count` hits have ended (their `hitEnded` event, which follows `log.end`).
    func waitForEnded(_ count: Int, limit: Duration = .seconds(10)) async throws {
        let events = self.events
        try await eventually(limit) { events.ended.count >= count }
    }

    func waitForStreaming(limit: Duration = .seconds(10)) async throws {
        let events = self.events
        try await eventually(limit) { events.audioStates.contains(.streaming) }
    }

    func rows() async throws -> [LoggedHit] {
        try await log.transmissions(HitFilter()).sorted { $0.hit.startedAt < $1.hit.startedAt }
    }
}

private struct Outcome {
    let leaked: [String]
    let commands: [String]
    let events: [RunnerEvent]
    let eventsFinished: Bool
}

private struct Setup {
    var saveAudio: SaveAudio = .everyTransmission
    var faults: MockFaults = .none
    var recordingsFolder: ((URL) throws -> String)? = nil
    var retentionDays: Int? = nil
    var runnerCooldown: Duration = mockCooldown
    var injecting = false
    var startRunner = true
    /// Scenario time when the mock starts (a time inside a transmission puts it on air at start).
    var clockStart: Double = 0
    /// The mock's RTSP reply delays (zero by default).
    var replyDelays: [String: Duration] = [:]
    var keepaliveInterval: Duration = .seconds(15)
    /// The runner's push keep-alive interval (`keepAliveInterval`), for a model that has one.
    var pushKeepAliveInterval: Duration? = nil
    /// The runner's push interval (`PSI,<ms>`); nil: the model's.
    var pushInterval: Duration? = .milliseconds(100)
    /// What the mock's `MDL` reports in place of the scenario's `SDS200`.
    var reportedModel: String? = nil
    var prepare: (@Sendable (HitLog, URL, any RTSPCooldownStore) async throws -> Void)? = nil
}

/// Starts a mock and a runner, runs `body`, then always stops the runner (bounded) and the mock.
@discardableResult
private func withRunner(
    _ setup: Setup = Setup(), limit: Duration = .seconds(40),
    _ body: @escaping @Sendable (Rig, InjectingTransport?) async throws -> Void
) async throws -> Outcome {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let options = MockSDS200.Options(clock: .stepped(at: setup.clockStart), reconnectCooldown: mockCooldown,
                                     replyDelays: setup.replyDelays)
    var mockScenario = scenario
    if let reportedModel = setup.reportedModel { mockScenario.model = reportedModel }
    let mock = MockSDS200(scenario: mockScenario, faults: setup.faults, options: options)
    let ports = try await mock.start()

    var station = Station()
    station.name = "Test Station"
    station.connection.host = "127.0.0.1"
    station.connection.udpPort = ports.udpPort
    station.connection.rtspPort = ports.rtspPort
    station.recording.saveAudio = setup.saveAudio
    station.recording.retentionDays = setup.retentionDays
    var device = StationDeviceSettings(stationID: station.id)
    device.recordingsFolder = try setup.recordingsFolder?(dir)

    let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))
    let store = InMemoryRTSPCooldownStore()
    try await setup.prepare?(log, dir, store)
    let config = AudioSessionConfig(keepaliveInterval: setup.keepaliveInterval,
                                    reconnectCooldown: setup.runnerCooldown, requestTimeout: .seconds(1),
                                    cooldownStore: InMemoryRTSPCooldownStore(), rtpCloseDelay: .milliseconds(50))
    let injecting = setup.injecting ? InjectingTransport(host: "127.0.0.1", port: ports.udpPort) : nil
    let makeTransport: @Sendable (String, UInt16) -> any ScannerTransport
    if let injecting {
        makeTransport = { _, _ in injecting }
    } else {
        makeTransport = { UDPTransport(host: $0, port: $1) }
    }
    // The runner gets `store`; the config carries a different one, which the runner must replace.
    let runner = StationRunner(station: station, device: device, log: log,
                               recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
                               cooldownStore: store,
                               transportFactory: StationTransportFactory(ports: FakePorts([]), makeNetworkTransport: makeTransport),
                               audioConfig: config,
                               pushInterval: setup.pushInterval, keepAliveInterval: setup.pushKeepAliveInterval)
    let events = EventLog(runner.events)
    let folder = device.recordingsFolder.map { URL(fileURLWithPath: $0) }
        ?? dir.appendingPathComponent("Recordings/Test Station", isDirectory: true)
    let rig = Rig(mock: mock, runner: runner, log: log, events: events, folder: folder, dir: dir)

    var failure: (any Error)?
    do {
        if setup.startRunner { try await bounded(.seconds(15)) { try await runner.start() } }
        try await bounded(limit) { try await body(rig, injecting) }
    } catch {
        failure = error
    }
    do {
        try await bounded(.seconds(15)) { await runner.stop() }
        try await eventually(.seconds(2)) { events.isFinished }
    } catch {
        if failure == nil { failure = error }
    }
    // The runner's `PSI,0` is a datagram the mock takes in on its own queue: wait (bounded) for it
    // before stopping the mock and reading its log, rather than reading at once (which flaked on
    // the CI runner). A missing `PSI,0` still fails `expectCleanStop`.
    _ = try? await eventually(.seconds(3)) {
        let commands = await mock.control.receivedCommands
        return !commands.contains { $0.hasPrefix("PSI,") && $0 != "PSI,0" } || commands.last == "PSI,0"
    }
    await mock.stop()
    let outcome = Outcome(leaked: await mock.leakedSessions, commands: await mock.control.receivedCommands,
                          events: events.all, eventsFinished: events.isFinished)
    await log.close()
    if let failure { throw failure }
    return outcome
}

/// Every test's safety checks: no leaked session, `PSI,0` last, `.stopped` last.
private func expectCleanStop(_ outcome: Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(outcome.leaked == [], sourceLocation: sourceLocation)
    #expect(outcome.commands.last == "PSI,0", "commands: \(outcome.commands.suffix(5))", sourceLocation: sourceLocation)
    #expect(outcome.events.last == .stopped, sourceLocation: sourceLocation)
    #expect(outcome.eventsFinished, sourceLocation: sourceLocation)
}

/// Seconds of audio in a 16-bit 8 kHz mono WAV with a 44-byte header.
private func wavSeconds(_ path: String) throws -> Double {
    let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
    return Double(max(0, size - 44)) / 16_000
}

@Suite(.timeLimit(.minutes(3))) struct StationRunnerTests {
    @Test func logsHitsWithAudio() async throws {
        let outcome = try await withRunner { rig, _ in
            try await rig.waitForStreaming()
            // One scenario loop: the talkgroup, then the unprogrammed conventional channel.
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
            try await rig.play(conventional)
            try await rig.waitForEnded(2)

            let first = try await rig.rows()
            #expect(first.count >= 2)
            for row in first {
                let path = try #require(row.audioPath, "no audio for \(row.hit.channel ?? "?")")
                #expect(FileManager.default.fileExists(atPath: path))
                #expect(path.hasPrefix(rig.folder.path))
                let seconds = try wavSeconds(path)
                #expect(seconds >= 1.0, "\(path) is \(seconds) s")
                #expect(row.audioError == nil)
                #expect(row.hit.endedAt != nil)
            }
            let tg = try #require(first.first { $0.hit.key.talkgroupID == "4711" })
            #expect(tg.isNew)
            #expect(tg.hit.endReason == .signalLost)
            let conv = try #require(first.first { $0.hit.key.talkgroupID == nil })
            #expect(conv.hit.key.frequencyMHz == 155.1234)
            #expect(conv.isNew)
            #expect(!conv.hit.programmed)

            // The second loop: the talkgroup is no longer new.
            try await rig.play(talkgroup)
            try await rig.waitForEnded(3)
            let again = try await rig.rows().filter { $0.hit.key.talkgroupID == "4711" }
            #expect(again.count == 2)
            #expect(again.last?.isNew == false)
            #expect(again.last?.audioPath != nil)

            // Events mirror the log.
            #expect(rig.events.all.first == .connected(model: "SDS200", firmware: "1.26.01"))
            #expect(rig.events.started.first?.isNew == true)
            #expect(rig.events.started.first?.audioPath != nil)
            #expect(rig.events.ended.count == 3)
            #expect(rig.events.ended.allSatisfy { $0.audioPath != nil })
            let recordings = rig.events.all.compactMap { if case .recording(let r) = $0 { r } else { nil } }
            #expect(recordings.count == 3 && recordings.allSatisfy { $0.path != nil && $0.error == nil })
        }
        expectCleanStop(outcome)
        #expect(outcome.events.contains(.audio(.stopped)))
        let audioStopped = try #require(outcome.events.firstIndex(of: .audio(.stopped)))
        #expect(audioStopped < outcome.events.count - 1)
    }

    @Test func onlyNewSkipsRepeatAudio() async throws {
        var setup = Setup()
        setup.saveAudio = .onlyNew
        let outcome = try await withRunner(setup) { rig, _ in
            try await rig.waitForStreaming()
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
            try await rig.play(talkgroup)
            try await rig.waitForEnded(2)
            try await rig.play(conventional)
            try await rig.waitForEnded(3)

            let rows = try await rig.rows()
            #expect(rows.count == 3)
            let tg = rows.filter { $0.hit.key.talkgroupID == "4711" }
            #expect(tg.count == 2)
            #expect(tg.first?.isNew == true && tg.first?.audioPath != nil)
            #expect(tg.last?.isNew == false && tg.last?.audioPath == nil && tg.last?.audioError == nil)
            let conv = try #require(rows.first { $0.hit.key.talkgroupID == nil })
            #expect(conv.isNew && conv.audioPath != nil)
            let files = try FileManager.default.contentsOfDirectory(atPath: rig.folder.path).filter { $0.hasSuffix(".wav") }
            #expect(files.count == 2)
        }
        expectCleanStop(outcome)
    }

    /// With no push interval given, a network station on an SDS200 subscribes at the SDS200's
    /// 100 ms (`ModelProfile.pushInterval`), as the SDS150 does.
    @Test func networkStationSubscribesAtTheSDS200sPushInterval() async throws {
        var setup = Setup()
        setup.saveAudio = .never
        setup.pushInterval = nil
        let outcome = try await withRunner(setup) { rig, _ in
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
        }
        expectCleanStop(outcome)
        #expect(outcome.commands == ["MDL", "VER", "PSI,100", "PSI,0"], "\(outcome.commands)")
    }

    /// A network scanner whose `MDL` names no known model keeps the 500 ms fallback, not the SDS200's rate.
    @Test func networkStationOfAnUnknownModelSubscribesAt500ms() async throws {
        var setup = Setup()
        setup.saveAudio = .never
        setup.pushInterval = nil
        setup.reportedModel = "XR9000"   // fictional; must not parse as a ScannerModel
        let outcome = try await withRunner(setup) { rig, _ in
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
        }
        expectCleanStop(outcome)
        #expect(outcome.commands == ["MDL", "VER", "PSI,500", "PSI,0"], "\(outcome.commands)")
    }

    /// A network station is never sent `KAL`, even when its scanner says it is an SDS150 (whose
    /// profile has a keep-alive) and the keep-alive interval is overridden: the keep-alive goes over
    /// serial only, and nothing on the network path changes.
    @Test func networkStationSendsNoKeepAlive() async throws {
        var setup = Setup()
        setup.saveAudio = .never
        setup.pushKeepAliveInterval = .milliseconds(50)
        setup.reportedModel = "SDS150"
        let outcome = try await withRunner(setup) { rig, _ in
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
            try await Task.sleep(for: .milliseconds(300))
        }
        expectCleanStop(outcome)
        #expect(!outcome.commands.contains { $0.hasPrefix("KAL") }, "\(outcome.commands)")
        #expect(outcome.commands == ["MDL", "VER", "PSI,100", "PSI,0"], "\(outcome.commands)")
    }

    /// A network station whose pushes stop, stalled well past any keep-alive interval (even with
    /// one overridden, and a scanner that says SDS150), only warns, once: it never ends its
    /// subscription to start another, as a USB station does.
    @Test func networkStationNeverResubscribes() async throws {
        var setup = Setup()
        setup.saveAudio = .never
        setup.pushKeepAliveInterval = .milliseconds(100)
        setup.reportedModel = "SDS150"
        setup.faults = MockFaults(stallPSIAfter: 0.5)
        let outcome = try await withRunner(setup) { rig, _ in
            let events = rig.events
            try await eventually(.seconds(8)) { events.warnings.contains(StationRunner.stalledMessage) }
            try await Task.sleep(for: .seconds(3))
            #expect(events.warnings.filter { $0 == StationRunner.stalledMessage }.count == 1, "\(events.warnings)")
            #expect(!events.warnings.contains(StationRunner.resubscribingMessage), "\(events.warnings)")
            #expect(!(await rig.mock.control.receivedCommands.contains("PSI,0")))
        }
        expectCleanStop(outcome)
        #expect(outcome.commands == ["MDL", "VER", "PSI,100", "PSI,0"], "\(outcome.commands)")
    }

    @Test func stopSendsPSI0AndTeardown() async throws {
        let outcome = try await withRunner { rig, _ in
            try await rig.waitForStreaming()
            // Stop in the middle of a transmission.
            rig.clock.set(talkgroup.at + 0.01)
            let events = rig.events
            try await eventually { !events.started.isEmpty }
            try await Task.sleep(for: .milliseconds(700))
            // Concurrent and repeated stops share one teardown.
            async let a: Void = rig.runner.stop()
            async let b: Void = rig.runner.stop()
            _ = await (a, b)
            await rig.runner.stop()

            let rows = try await rig.rows()
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.hit.endReason == .stopped)
            #expect(row.hit.endedAt != nil)
            let path = try #require(row.audioPath)
            #expect(FileManager.default.fileExists(atPath: path))
            // `stop()` returning doesn't mean the collector has taken in the last events: wait for
            // the stream to finish (CI run 44968370051 read `.audio(.stopped)`, the one before it).
            try await eventually(.seconds(5)) { events.isFinished }
            #expect(events.all.last == .stopped)
            #expect(events.all.filter { $0 == .stopped }.count == 1)
            #expect(events.ended.first?.hit.endReason == .stopped)
            // Starting again after a stop is refused.
            await #expect(throws: StationRunnerError.self) { try await rig.runner.start() }
        }
        expectCleanStop(outcome)
        #expect(outcome.commands.contains("PSI,100"))
    }

    @Test func stallEndsHitAndWarns() async throws {
        var setup = Setup()
        // Pushes stop 2.5 s into the subscription (PSI is still acknowledged).
        setup.faults = MockFaults(stallPSIAfter: 2.5)
        let outcome = try await withRunner(setup) { rig, _ in
            rig.clock.set(talkgroup.at + 0.01)  // the transmission is on air when the pushes stop
            try await rig.waitForEnded(1, limit: .seconds(12))
            let ended = try #require(rig.events.ended.first)
            #expect(ended.hit.endReason == .stalled)
            let events = rig.events
            try await eventually { events.warnings.contains("scanner stopped sending updates") }
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.endReason == .stalled)
            #expect(row.hit.endedAt != nil)
        }
        expectCleanStop(outcome)
    }

    @Test func pushStreamEndEndsHitAndWarns() async throws {
        var setup = Setup()
        setup.injecting = true
        let outcome = try await withRunner(setup) { rig, transport in
            try await rig.waitForStreaming()
            rig.clock.set(talkgroup.at + 0.01)
            let events = rig.events
            try await eventually { !events.started.isEmpty }
            // The scanner rejects the subscription: the client finishes the push stream.
            try #require(transport).inject("PSI,NG")
            try await rig.waitForEnded(1)
            #expect(events.ended.first?.hit.endReason == .stalled)
            try await eventually { events.warnings.contains("scanner stopped sending updates") }
            // Audio keeps running until stop().
            try await Task.sleep(for: .milliseconds(500))
            #expect(!events.audioStates.contains(.stopped))
            #expect(events.audioStates.last == .streaming)
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.endReason == .stalled)
        }
        expectCleanStop(outcome)
    }

    @Test func audioThatStopsArrivingStillEndsTheHit() async throws {
        var setup = Setup()
        // RTP stops 2 s after PLAY, in the middle of the transmission (as squelch gating might).
        setup.faults = MockFaults(dropAudioAfter: 2.0)
        let outcome = try await withRunner(setup) { rig, _ in
            try await rig.waitForStreaming()
            rig.clock.set(talkgroup.at + 0.01)
            try await Task.sleep(for: .milliseconds(2500))
            rig.clock.set(0)
            let idleAt = ContinuousClock.now
            // Hangover 1 s, post-roll 0.5 s, grace 0.5 s, tick 1 s: about 3 s after the hit's end.
            try await rig.waitForEnded(1, limit: .milliseconds(4500))
            let endedAfter = ContinuousClock.now - idleAt
            #expect(endedAfter <= .milliseconds(4000), "hitEnded \(endedAfter) after the transmission")
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.endedAt != nil)
            #expect(row.hit.endReason == .signalLost)
            let path = try #require(row.audioPath)
            #expect(FileManager.default.fileExists(atPath: path))
        }
        expectCleanStop(outcome)
    }

    @Test func audioUnavailableStillLogs() async throws {
        var setup = Setup()
        setup.faults = MockFaults(wedgeAudio: true)  // SETUP answers 503
        let outcome = try await withRunner(setup) { rig, _ in
            let events = rig.events
            try await eventually { !events.warnings.isEmpty }
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
            let rows = try await rig.rows()
            #expect(rows.count == 1)
            #expect(rows.first?.audioPath == nil)
            #expect(rows.first?.isNew == true)
            #expect(events.warnings.contains { $0.contains("audio") })
            #expect(events.audioStates.contains { if case .failed = $0 { true } else { false } })
        }
        expectCleanStop(outcome)
    }

    @Test func audioCooldownIsAWarning() async throws {
        var setup = Setup()
        setup.runnerCooldown = .seconds(60)
        // The runner's store says the scanner's audio closed a moment ago.
        setup.prepare = { _, _, store in await store.recordClosed(host: "127.0.0.1", at: Date()) }
        let outcome = try await withRunner(setup) { rig, _ in
            let events = rig.events
            try await eventually { !events.warnings.isEmpty }
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
            #expect(try await rig.rows().first?.audioPath == nil)
            #expect(events.warnings.contains { $0.contains("audio") })
            #expect(await rig.mock.rtsp.leakedSessions == [])
        }
        expectCleanStop(outcome)
    }

    @Test func unwritableFolderStillLogs() async throws {
        var setup = Setup()
        // The recordings "folder" is a regular file, so no recording can be created.
        setup.recordingsFolder = { dir in
            let file = dir.appendingPathComponent("not-a-folder")
            try Data("x".utf8).write(to: file)
            return file.path
        }
        let outcome = try await withRunner(setup) { rig, _ in
            try await rig.waitForStreaming()
            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
            try await rig.play(conventional)
            try await rig.waitForEnded(2)
            let rows = try await rig.rows()
            #expect(rows.count == 2)
            for row in rows {
                #expect(row.audioPath == nil)
                #expect(row.audioError != nil)
                #expect(row.hit.endedAt != nil)
            }
            #expect(rig.events.warnings.contains { $0.contains("recording") })
        }
        expectCleanStop(outcome)
    }

    @Test func startClosesDanglingAndPurgesOldHits() async throws {
        let oldID = UUID(), danglingID = UUID()
        let oldFile = Mutex<String?>(nil)
        var setup = Setup()
        setup.retentionDays = 7
        setup.prepare = { log, dir, _ in
            let file = dir.appendingPathComponent("old.wav")
            try Data(count: 64).write(to: file)
            oldFile.withLock { $0 = file.path }
            let key = HitKey(system: "Testville County P25", talkgroupID: "4711", frequencyMHz: nil)
            let old = Hit(id: oldID, key: key, startedAt: Date().addingTimeInterval(-10 * 86_400),
                          endedAt: Date().addingTimeInterval(-10 * 86_400 + 2), startInstant: .now, endInstant: .now,
                          channel: "Testville Fire Dispatch", endReason: .signalLost)
            try await log.begin(old)
            try await log.end(old, audioPath: file.path, audioError: nil)
            let dangling = Hit(id: danglingID, key: key, startedAt: Date().addingTimeInterval(-60),
                               startInstant: .now, endInstant: .now, channel: "Testville Fire Dispatch")
            try await log.begin(dangling, audioPath: nil)
        }
        let outcome = try await withRunner(setup) { rig, _ in
            let rows = try await rig.rows()
            #expect(!rows.contains { $0.hit.id == oldID })
            let dangling = try #require(rows.first { $0.hit.id == danglingID })
            #expect(dangling.hit.endReason == .interrupted)
            #expect(dangling.hit.endedAt != nil)
            let path = try #require(oldFile.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        expectCleanStop(outcome)
    }

    @Test func startFailureThrowsAndStops() async throws {
        var setup = Setup()
        setup.startRunner = false
        let outcome = try await withRunner(setup) { rig, _ in
            await rig.mock.control.setAnswering(false)  // MDL goes unanswered
            await #expect(throws: (any Error).self) { try await rig.runner.start() }
            let events = rig.events
            try await eventually(.seconds(3)) { events.isFinished }
            #expect(events.all.last == .stopped)
            #expect(!events.all.contains { if case .connected = $0 { true } else { false } })
        }
        #expect(outcome.leaked == [])
        // No subscription was started, but stop still sends PSI,0 (harmless, and always safe).
        #expect(!outcome.commands.contains { $0.hasPrefix("PSI") && $0 != "PSI,0" }, "\(outcome.commands)")
        #expect(outcome.commands.last == "PSI,0", "\(outcome.commands)")
        #expect(outcome.events.last == .stopped)
    }

    // MARK: A hit already on air when audio starts (Task 10b)

    /// A setup whose transmission is on air from the start and whose audio takes the hardware's
    /// ~1.35 s to start, so the hit begins before audio streams.
    private static func onAirAtStart(_ saveAudio: SaveAudio) -> Setup {
        var setup = Setup()
        setup.saveAudio = saveAudio
        setup.clockStart = talkgroup.at + 0.01
        setup.replyDelays = MockSDS200.Options.realisticReplyDelays
        return setup
    }

    private static func wavFiles(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".wav") }
    }

    @Test func hitInProgressAtStartIsRecordedOnceAudioStreams() async throws {
        let outcome = try await withRunner(Self.onAirAtStart(.everyTransmission)) { rig, _ in
            let events = rig.events
            try await rig.waitForStreaming()
            // The hit started before audio streamed, so it began without a file.
            let started = try #require(events.started.first)
            #expect(started.audioPath == nil)
            // Once audio streams, the log row gets the file's path while the hit is still open.
            let log = rig.log
            let id = started.hit.id
            try await eventually(.seconds(5)) {
                (try? await log.transmissions(HitFilter()))?.first { $0.hit.id == id }?.audioPath != nil
            }
            let open = try #require(try await rig.rows().first { $0.hit.id == id })
            #expect(open.hit.endedAt == nil)
            let path = try #require(open.audioPath)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect((path as NSString).lastPathComponent == RecordingName.fileName(for: started.hit))
            try await Task.sleep(for: .seconds(1))
            rig.clock.set(0)
            try await rig.waitForEnded(1)

            let row = try #require(try await rig.rows().first { $0.hit.id == id })
            #expect(row.audioPath == path)
            #expect(row.audioError == nil)
            let seconds = try wavSeconds(path)
            #expect(seconds >= 0.8, "\(path) is \(seconds) s")
            #expect(events.ended.first?.audioPath == path)
            #expect(Self.wavFiles(rig.folder).count == 1)
        }
        expectCleanStop(outcome)
    }

    @Test func onlyNewLeavesAKnownTalkgroupInProgressUnrecorded() async throws {
        var setup = Self.onAirAtStart(.onlyNew)
        // The talkgroup was seen before, so this hit isn't new.
        setup.prepare = { log, _, _ in
            let key = HitKey(system: "Testville County P25", talkgroupID: "4711", frequencyMHz: nil)
            let earlier = Hit(id: UUID(), key: key, startedAt: Date().addingTimeInterval(-3600),
                              endedAt: Date().addingTimeInterval(-3598), startInstant: .now, endInstant: .now,
                              channel: "Testville Fire Dispatch", endReason: .signalLost)
            try await log.begin(earlier)
            try await log.end(earlier, audioPath: nil, audioError: nil)
        }
        let outcome = try await withRunner(setup) { rig, _ in
            try await rig.waitForStreaming()
            let events = rig.events
            try await eventually { !events.started.isEmpty }
            #expect(events.started.first?.isNew == false)
            try await Task.sleep(for: .milliseconds(1500))
            rig.clock.set(0)
            try await rig.waitForEnded(1)
            let ended = try #require(events.ended.first)
            #expect(ended.audioPath == nil && ended.audioError == nil)
            #expect(try await rig.rows().first { $0.hit.id == ended.hit.id }?.audioPath == nil)
            #expect(Self.wavFiles(rig.folder).isEmpty)
        }
        expectCleanStop(outcome)
    }

    @Test func neverLeavesAHitInProgressUnrecorded() async throws {
        let outcome = try await withRunner(Self.onAirAtStart(.never)) { rig, _ in
            let events = rig.events
            try await eventually { !events.started.isEmpty }
            try await Task.sleep(for: .milliseconds(1500))
            rig.clock.set(0)
            try await rig.waitForEnded(1)
            #expect(events.ended.first?.audioPath == nil)
            #expect(try await rig.rows().first?.audioPath == nil)
            #expect(Self.wavFiles(rig.folder).isEmpty)
            #expect(events.audioStates.isEmpty)
        }
        expectCleanStop(outcome)
    }

    @Test func audioRecoveryDuringARecordingHitKeepsOneFile() async throws {
        var setup = Self.onAirAtStart(.everyTransmission)
        setup.keepaliveInterval = .milliseconds(300)
        let outcome = try await withRunner(setup) { rig, _ in
            let events = rig.events
            try await rig.waitForStreaming()
            let id = try #require(events.started.first).hit.id
            let log = rig.log
            try await eventually(.seconds(5)) {
                (try? await log.transmissions(HitFilter()))?.first { $0.hit.id == id }?.audioPath != nil
            }
            // The next keepalive fails (454): streaming -> recovering -> streaming, mid-hit.
            await rig.mock.setFaults(MockFaults(keepaliveStatus: 454))
            try await eventually(.seconds(10)) {
                events.audioStates.filter { $0 == .streaming }.count >= 2
            }
            #expect(events.audioStates.contains(.recovering(attempt: 1)))
            try await Task.sleep(for: .milliseconds(500))
            rig.clock.set(0)
            try await rig.waitForEnded(1)

            #expect(events.started.count == 1)
            let row = try #require(try await rig.rows().first { $0.hit.id == id })
            let path = try #require(row.audioPath)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(Self.wavFiles(rig.folder) == [(path as NSString).lastPathComponent])
            let recordings = events.all.compactMap { if case .recording(let r) = $0 { r } else { nil } }
            #expect(recordings.count == 1)
        }
        expectCleanStop(outcome)
    }

    // MARK: App hooks (Plan 4 Task 3)

    @Test func liveStatusCarriesPushes() async throws {
        let outcome = try await withRunner { rig, _ in
            let stream = rig.runner.liveStatus
            // Idle pushes first, then the transmission's.
            let idleInfo = try await bounded(.seconds(5)) {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            #expect(try #require(idleInfo).system?.name == "Testville County P25")
            rig.clock.set(talkgroup.at + 0.01)
            let onAir = try await bounded(.seconds(5)) { () async -> ScannerInfo? in
                for await info in stream where info.talkgroupID == "4711" { return info }
                return nil
            }
            #expect(try #require(onAir).channel?.name == "Testville Fire Dispatch")
            rig.clock.set(0)
            // The stream finishes with `events`, at stop.
            await rig.runner.stop()
            try await bounded(.seconds(3)) { for await _ in stream {} }
        }
        expectCleanStop(outcome)
    }

    @Test func droppingAudioTapKeepsSession() async throws {
        let outcome = try await withRunner { rig, _ in
            try await rig.waitForStreaming()
            let runner = rig.runner
            // A tap delivers chunks, then is dropped.
            let first = try await bounded(.seconds(5)) {
                var iterator = await runner.liveAudio().makeAsyncIterator()
                return await iterator.next()
            }
            #expect(!(try #require(first)).samples.isEmpty)
            // A second tap finishes the one before it.
            let older = await runner.liveAudio()
            _ = await runner.liveAudio()
            try await bounded(.seconds(3)) { for await _ in older {} }
            try await Task.sleep(for: .milliseconds(300))

            try await rig.play(talkgroup)
            try await rig.waitForEnded(1)
            let row = try #require(try await rig.rows().first)
            let path = try #require(row.audioPath)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try wavSeconds(path) >= 1.0)
            #expect(!rig.events.audioStates.contains(.stopped))
            #expect(rig.events.audioStates.last == .streaming)
        }
        expectCleanStop(outcome)
        #expect(outcome.events.filter { $0 == .audio(.streaming) }.count == 1)
    }

    @Test func controlIsNilAfterStop() async throws {
        var setup = Setup()
        setup.startRunner = false
        let outcome = try await withRunner(setup) { rig, _ in
            #expect(await rig.runner.control() == nil)
            try await rig.runner.start()
            let client = try #require(await rig.runner.control())
            #expect(try await client.modelInfo().reported == "SDS200")
            await rig.runner.stop()
            #expect(await rig.runner.control() == nil)
        }
        expectCleanStop(outcome)
    }

    @Test func pausedLoggingSkipsHits() async throws {
        let outcome = try await withRunner(limit: .seconds(60)) { rig, _ in
            try await rig.waitForStreaming()
            let events = rig.events
            let runner = rig.runner
            // A hit already open when logging pauses finishes normally, with its recording.
            rig.clock.set(talkgroup.at + 0.01)
            try await eventually { events.started.count == 1 }
            await runner.setLoggingPaused(true)
            try await Task.sleep(for: .seconds(1))
            rig.clock.set(0)
            try await rig.waitForEnded(1)
            let open = try #require(try await rig.rows().first)
            #expect(open.hit.key.talkgroupID == "4711")
            #expect(open.audioPath != nil)

            // While paused: no row, no file, no hit events. Pushes keep coming.
            let wavsBefore = Self.wavFiles(rig.folder)
            try await rig.play(conventional)
            try await Task.sleep(for: .seconds(3))
            #expect(try await rig.rows().count == 1)
            #expect(Self.wavFiles(rig.folder) == wavsBefore)
            #expect(events.started.count == 1 && events.ended.count == 1)
            let status = try await bounded(.seconds(3)) {
                var iterator = runner.liveStatus.makeAsyncIterator()
                return await iterator.next()
            }
            #expect(status != nil)

            // After resuming, the next hit is logged and recorded.
            await runner.setLoggingPaused(false)
            try await rig.play(conventional)
            try await rig.waitForEnded(2)
            let rows = try await rig.rows()
            #expect(rows.count == 2)
            let conv = try #require(rows.first { $0.hit.key.talkgroupID == nil })
            #expect(conv.audioPath != nil)
            #expect(Self.wavFiles(rig.folder).count == wavsBefore.count + 1)
        }
        expectCleanStop(outcome)
    }

    @Test func restartHintOnWedgedAudio() async throws {
        var setup = Setup()
        setup.faults = MockFaults(wedgeAudio: true)  // SETUP answers 503
        let outcome = try await withRunner(setup) { rig, _ in
            let events = rig.events
            try await eventually { events.audioStates.contains { if case .failed = $0 { true } else { false } } }
            // The runner's MDL probe answers, so a remote restart can help.
            #expect(await rig.runner.audioRestartHint() == .canRestart)
        }
        expectCleanStop(outcome)
    }
}
