// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleMockScanner
@testable import NoctuleStore

// StationRunner on a USB station, against an in-process MockSerialScanner (a mock SDS150 on a
// pseudo-terminal). The station's port is the mock's link path in a temporary directory, and the
// factory gets an empty fake port listing, so nothing here can find or open a real serial port:
// while the mock is unplugged the link is gone and the runner finds nothing at all. Scenario time
// is a stepped clock; pushes, polls and reply delays run in real time, so every wait is a bounded
// poll. Every test stops the runner and the mock, and checks that the runner never touched the
// RTSP cooldown store, never started audio, never sent `MSM`, left no `PSI` subscription running
// and left the port closed. All names and values are fictional (the mock's default scenario).

/// The default scenario's first two transmissions (scenario seconds): talkgroups 1201 and 2305.
private let firstAt = 2.0
private let secondAt = 9.0
private let pollInterval: Duration = .milliseconds(50)
/// The runner's `ScannerClient` default.
private let commandTimeout: Duration = .seconds(2)

private struct TimedOut: Error {}

/// Runs `body` in an unstructured task and gives up after `limit`, even if `body` never returns,
/// so a hung runner fails the test instead of hanging it.
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
    var connections: [RunnerEvent] { all.filter { if case .connected = $0 { true } else { false } } }
    /// The hint of every `.disconnected`.
    var disconnects: [String] { all.compactMap { if case .disconnected(let hint) = $0 { hint } else { nil } } }
}

/// Counts the pushes the runner has handled (its `liveStatus` keeps only the newest, so the count
/// can run low, but it is 0 only while the runner has handled none), and keeps the channel names
/// they carried.
private final class PushLog: Sendable {
    private let handled = Mutex(0)
    private let names = Mutex<Set<String>>([])

    init(_ stream: AsyncStream<ScannerInfo>) {
        Task { [self] in
            for await info in stream {
                handled.withLock { $0 += 1 }
                if let name = info.channel?.name, !name.isEmpty { names.withLock { _ = $0.insert(name) } }
            }
        }
    }

    var count: Int { handled.withLock { $0 } }
    /// Every channel name a handled push carried.
    var channelNames: Set<String> { names.withLock { $0 } }
}

/// A cooldown store that records every call made to it. A USB station must make none.
private final class CooldownSpy: RTSPCooldownStore {
    private let recorded = Mutex<[String]>([])

    var calls: [String] { recorded.withLock { $0 } }
    private func note(_ call: String) { recorded.withLock { $0.append(call) } }

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

/// A fake port listing a test can change while the runner waits (the registry's view of which
/// Uniden ports are plugged in). Its paths are the mocks' links, never a real port.
private final class SwitchablePorts: SerialPortListing {
    private let paths: Mutex<[String]>

    init(_ paths: [String]) { self.paths = Mutex(paths) }

    func set(_ paths: [String]) { self.paths.withLock { $0 = paths } }

    func unidenPorts() -> [SerialPortInfo] {
        paths.withLock { $0 }.map {
            SerialPortInfo(path: $0, productName: "SDS150 Serial Port", vendorID: SerialPort.unidenVendorID,
                           productID: 0x001A, serialNumber: nil)
        }
    }
}

/// Every transport after the first fails to write `PSI,<interval>` (`.writeFailed`, nothing sent),
/// as a short write would; `PSI,0` and everything else go through.
private final class LaterPSIWriteFails: Sendable {
    private let made = Mutex(0)

    func make(_ path: String) -> any ScannerTransport {
        let number = made.withLock { n in
            n += 1
            return n
        }
        return PSIWriteFailing(SerialTransport(path: path), failing: number > 1)
    }

    private final class PSIWriteFailing: ScannerTransport {
        let base: SerialTransport
        let failing: Bool

        init(_ base: SerialTransport, failing: Bool) {
            self.base = base
            self.failing = failing
        }

        func open() async throws { try await base.open() }
        func close() async { await base.close() }
        var responses: AsyncStream<ScannerResponse> { base.responses }

        func send(_ command: ScannerCommand) async throws {
            if failing, command.name == "PSI", command.arguments != ["0"] {
                throw SerialTransportError.writeFailed("short write: 2 of 8 bytes")
            }
            try await base.send(command)
        }
    }
}

/// The first `KAL` written through any of its transports fails (`.writeFailed`, nothing sent), as
/// a short write would; every other write, later `KAL`s included, goes through.
private final class FirstKeepAliveWriteFails: Sendable {
    static let error = SerialTransportError.writeFailed("short write: 1 of 4 bytes")
    private let failed = Mutex(false)

    func make(_ path: String) -> any ScannerTransport {
        KeepAliveWriteFailing(SerialTransport(path: path), owner: self)
    }

    /// True once: the write it is asked about is the one to fail.
    fileprivate func takeFailure() -> Bool {
        failed.withLock { done in
            defer { done = true }
            return !done
        }
    }

    private final class KeepAliveWriteFailing: ScannerTransport {
        let base: SerialTransport
        let owner: FirstKeepAliveWriteFails

        init(_ base: SerialTransport, owner: FirstKeepAliveWriteFails) {
            self.base = base
            self.owner = owner
        }

        func open() async throws { try await base.open() }
        func close() async { await base.close() }
        var responses: AsyncStream<ScannerResponse> { base.responses }

        func send(_ command: ScannerCommand) async throws {
            if command.name == "KAL", owner.takeFailure() { throw FirstKeepAliveWriteFails.error }
            try await base.send(command)
        }
    }
}

/// Every transport passes on the first non-zero `PSI` written through it (the subscription) and
/// drops every later one (a renewal) without sending it, as if each renewal were lost on the way:
/// the scanner's pushes then stop at its lifetime. `PSI,0` and everything else go through.
private final class RenewalsVanish: Sendable {
    private let dropped = Mutex(0)

    /// The renewals dropped so far, across every transport.
    var renewalsDropped: Int { dropped.withLock { $0 } }

    func make(_ path: String) -> any ScannerTransport {
        RenewalDropping(SerialTransport(path: path), owner: self)
    }

    fileprivate func noteDropped() { dropped.withLock { $0 += 1 } }

    private final class RenewalDropping: ScannerTransport {
        let base: SerialTransport
        let owner: RenewalsVanish
        private let subscribed = Mutex(false)

        init(_ base: SerialTransport, owner: RenewalsVanish) {
            self.base = base
            self.owner = owner
        }

        func open() async throws { try await base.open() }
        func close() async { await base.close() }
        var responses: AsyncStream<ScannerResponse> { base.responses }

        func send(_ command: ScannerCommand) async throws {
            if command.name == "PSI", command.arguments != ["0"] {
                let renewal = subscribed.withLock { done in
                    defer { done = true }
                    return done
                }
                if renewal {
                    owner.noteDropped()
                    return
                }
            }
            try await base.send(command)
        }
    }
}

private let differentScannerWarning = "a different scanner answered (SDS200); still waiting for the SDS150"
private let notAnsweringWarning = "the scanner isn't answering; unplug it and plug it in again"

private func isAudio(_ event: RunnerEvent) -> Bool {
    switch event {
    case .audio, .recording: true
    default: false
    }
}

private struct Rig: Sendable {
    let mock: MockSerialScanner
    let clock: MockClock
    /// The station's port: the mock's link path, or (`Setup.ownStationLink`) the test's own link to it.
    let port: String
    /// The mock's link path.
    let mockPort: String
    /// The fake port listing, with `Setup.listsPort`.
    let listing: SwitchablePorts?
    let runner: StationRunner
    let log: HitLog
    let events: EventLog
    let pushes: PushLog
    let cooldown: CooldownSpy
    let dir: URL

    /// Waits until the runner has handled a push on its first connection. (For a later
    /// connection, wait for a hit to start: the count can't tell the connections apart.)
    func waitForPush() async throws {
        let pushes = self.pushes
        try await eventually { pushes.count >= 1 }
    }

    /// Moves the scenario into the transmission that starts at `start` for `hold` of real time,
    /// then back to idle.
    func play(at start: Double, hold: Duration = .seconds(1), backTo idle: Double = 0) async throws {
        clock.set(start + 0.01)
        try await Task.sleep(for: hold)
        clock.set(idle)
    }

    func waitForEnded(_ count: Int, limit: Duration = .seconds(10)) async throws {
        let events = self.events
        try await eventually(limit) { events.ended.count >= count }
    }

    func waitForDisconnects(_ count: Int) async throws {
        let events = self.events
        try await eventually { events.disconnects.count >= count }
    }

    func waitForConnections(_ count: Int, limit: Duration = .seconds(10)) async throws {
        let events = self.events
        try await eventually(limit) { events.connections.count >= count }
    }

    func rows() async throws -> [LoggedHit] {
        try await log.transmissions(HitFilter()).sorted { $0.hit.startedAt < $1.hit.startedAt }
    }

    /// How many commands named `name` (with or without arguments) the mock has received.
    func received(_ name: String) async -> Int {
        await mock.receivedCommands.filter { $0 == name || $0.hasPrefix(name + ",") }.count
    }

    /// Records an issue if anything still holds the station's port: opening it again is refused
    /// (`.busy`) while a transport the runner left behind has it. Opens only the mock's pty.
    func expectPortFree(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) async {
        let probe = SerialTransport(path: port)
        do {
            try await probe.open()
        } catch {
            Issue.record("the port is still held: \(error)\(comment.map { " (\($0))" } ?? "")", sourceLocation: sourceLocation)
        }
        await probe.close()
    }

    /// A second mock scanner behind the same link (start it after the first is unplugged), or
    /// behind `link`.
    func otherScanner(reporting model: String, link: String? = nil) -> MockSerialScanner {
        var personality = MockPersonality.sds150
        personality.reportedModel = model
        return MockSerialScanner(scenario: .default, clock: clock, personality: personality, linkPath: link ?? port)
    }
}

private struct Outcome {
    /// Every command the mock received, read after the runner and then the mock stopped.
    let commands: [String]
    /// `PSI` subscriptions still running when the mock stopped (after the runner had).
    let subscribers: Int
    let events: [RunnerEvent]
    let eventsFinished: Bool
    let cooldownCalls: [String]
}

private struct Setup {
    var resume = true
    var saveAudio: SaveAudio = .everyTransmission
    var faults: MockFaults = .none
    /// The mock's reply delays by command name (real time).
    var replyDelays: [String: Duration] = [:]
    var startRunner = true
    /// The station's port is a link of the test's own (`station-port`) to the mock's link, so a
    /// test can take the mock's port before the station's path leads to it.
    var ownStationLink = false
    /// No port is configured: the station's port is the only one a `SwitchablePorts` lists (the
    /// mock's link to begin with).
    var listsPort = false
    /// Every connection after the first fails to write its `PSI` (`LaterPSIWriteFails`).
    var laterPSIWriteFails = false
    var scenario: MockScenario = .default
    /// The runner's keep-alive interval in place of the model's 60 s (`keepAliveInterval`).
    var keepAliveInterval: Duration? = nil
    /// What the mock's `MDL` reports in place of `SDS150` (its answers stay the SDS150's).
    var reportedModel: String? = nil
    /// The mock's push lifetime (scenario seconds) in place of the SDS150's 183.
    var pushLifetime: Double? = nil
    /// Whether a `KAL` after the mock's pushes stopped starts them again
    /// (`MockPersonality.keepAliveRevivesStoppedPushes`).
    var lateKeepAliveRevives = true
    /// The first `KAL` write fails (`FirstKeepAliveWriteFails`).
    var firstKeepAliveWriteFails = false
    /// The runner's push interval (`PSI,<ms>`); nil: the model's.
    var pushInterval: Duration? = .milliseconds(100)
    /// The mock's answers (`reportedModel`, `pushLifetime` and `lateKeepAliveRevives` apply on top).
    var personality: MockPersonality = .sds150
    /// Every renewal written through the station's transports is dropped (`RenewalsVanish`).
    var renewalsVanish: RenewalsVanish? = nil
}

/// Fictional conventional traffic (no talkgroups): one channel with no tone at 2-5 s, one
/// unprogrammed channel with a tone at 9-12 s (the scenario seconds of `firstAt` and `secondAt`).
private let conventionalScenario = MockScenario(
    idle: MockIdle(system: "County Roads", site: "County Roads Site", frequencyMHz: 155.0125),
    transmissions: [
        MockTransmission(at: firstAt, duration: 3, system: "County Roads", department: "Road Crews",
                         channel: "Plow Dispatch", frequencyMHz: 155.0125, rssi: -70),
        MockTransmission(at: secondAt, duration: 3, system: "County Roads", department: "Road Crews",
                         channel: "Grader Ops", frequencyMHz: 155.1625, modulation: "FM",
                         toneOrCode: "CTCSS 100.0Hz", rssi: -84, programmed: false),
    ])

/// Starts a mock SDS150 behind a link path and a runner for a USB station on that path, runs
/// `body`, then always stops the runner (bounded) and the mock, and checks what must hold for
/// every USB run (`expectUSBRules`).
@discardableResult
private func withUSBRunner(
    _ setup: Setup = Setup(), limit: Duration = .seconds(40),
    _ body: @escaping @Sendable (Rig) async throws -> Void
) async throws -> Outcome {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-usb-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let clock = MockClock.stepped(at: 0)
    var personality = setup.personality
    if let reportedModel = setup.reportedModel { personality.reportedModel = reportedModel }
    if let pushLifetime = setup.pushLifetime { personality.pushLifetime = pushLifetime }
    personality.keepAliveRevivesStoppedPushes = setup.lateKeepAliveRevives
    let mock = MockSerialScanner(scenario: setup.scenario, clock: clock, personality: personality,
                                 linkPath: dir.appendingPathComponent("port").path, replyDelays: setup.replyDelays)
    await mock.setFaults(setup.faults)
    let mockPort = try await mock.start()
    var port = mockPort
    if setup.ownStationLink {
        port = dir.appendingPathComponent("station-port").path
        try FileManager.default.createSymbolicLink(atPath: port, withDestinationPath: mockPort)
    }

    var station = Station()
    station.name = "Test Handheld"
    station.connection.transport = .usbSerial
    station.recording.saveAudio = setup.saveAudio
    var device = StationDeviceSettings(stationID: station.id)
    device.usbPort = setup.listsPort ? nil : port
    // Always a fake port listing: empty (the only port this runner can ever resolve is the
    // configured link), or the test's own list of mock links.
    let listing = setup.listsPort ? SwitchablePorts([mockPort]) : nil
    let factory = setup.laterPSIWriteFails
        ? StationTransportFactory(ports: listing ?? FakePorts([]), makeSerialTransport: LaterPSIWriteFails().make)
        : setup.firstKeepAliveWriteFails
        ? StationTransportFactory(ports: listing ?? FakePorts([]), makeSerialTransport: FirstKeepAliveWriteFails().make)
        : setup.renewalsVanish.map { StationTransportFactory(ports: listing ?? FakePorts([]), makeSerialTransport: $0.make) }
        ?? StationTransportFactory(ports: listing ?? FakePorts([]))

    let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))
    let cooldown = CooldownSpy()
    // The audio config carries the spy too: whatever store an AudioSession used would show.
    let config = AudioSessionConfig(reconnectCooldown: .milliseconds(300), requestTimeout: .seconds(1),
                                    cooldownStore: cooldown, rtpCloseDelay: .milliseconds(50))
    let runner = StationRunner(station: station, device: device, log: log,
                               recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
                               cooldownStore: cooldown, transportFactory: factory,
                               resumeAfterDisconnect: setup.resume, portPollInterval: pollInterval,
                               audioConfig: config, pushInterval: setup.pushInterval,
                               keepAliveInterval: setup.keepAliveInterval)
    let events = EventLog(runner.events)
    let rig = Rig(mock: mock, clock: clock, port: port, mockPort: mockPort, listing: listing, runner: runner, log: log, events: events,
                  pushes: PushLog(runner.liveStatus), cooldown: cooldown, dir: dir)

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
    // The runner left the port closed: a new transport can take it.
    if await mock.isPluggedIn, FileManager.default.fileExists(atPath: port), failure == nil { await rig.expectPortFree() }
    // The mock is read only once it has stopped: stopping drains what the runner wrote last (its
    // `PSI,0` is written a moment before the port closes, and the mock logs it on its own queue),
    // and `activeSubscribers` is then the count at that moment.
    await mock.stop()
    let outcome = Outcome(commands: await mock.receivedCommands, subscribers: await mock.activeSubscribers,
                          events: events.all, eventsFinished: events.isFinished, cooldownCalls: cooldown.calls)
    await log.close()
    if let failure { throw failure }
    expectUSBRules(outcome)
    return outcome
}

/// What holds after every USB run, whatever happened in it: the cooldown store was never touched,
/// no audio event or recording, no `MSM`, no subscription left running, `.stopped` last.
private func expectUSBRules(_ outcome: Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(outcome.cooldownCalls == [], sourceLocation: sourceLocation)
    #expect(!outcome.events.contains(where: isAudio), sourceLocation: sourceLocation)
    #expect(!outcome.commands.contains { $0.hasPrefix("MSM") }, sourceLocation: sourceLocation)
    #expect(outcome.subscribers == 0, "commands: \(outcome.commands.suffix(5))", sourceLocation: sourceLocation)
    #expect(outcome.events.last == .stopped, sourceLocation: sourceLocation)
    #expect(outcome.events.filter { $0 == .stopped }.count == 1, sourceLocation: sourceLocation)
    #expect(outcome.eventsFinished, sourceLocation: sourceLocation)
}

/// The default scenario's length: the scenario repeats, so `k * period + 0.5` is idle and
/// `k * period + firstAt` is its first transmission again.
private let period = MockScenario.default.period

extension Rig {
    /// Moves the scenario to `time` (idle there) and waits until the mock has received a `KAL`
    /// written after that: the mock's 183 s then count from `time` (that each `KAL` restarts the count
    /// is the mock's assumption; `MockPersonality`).
    func stepWithKeepAlive(to time: Double, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        clock.set(time)
        let before = await received("KAL")
        do {
            try await eventually(.seconds(3)) { await self.received("KAL") > before }
        } catch {
            Issue.record("no KAL reached the mock after scenario time \(time)", sourceLocation: sourceLocation)
            throw error
        }
    }
}

extension Rig {
    /// Moves the scenario to `time` (idle there) and waits until the mock has received a renewal
    /// (`PSI,100`) written after that: the SDS100 mock's 183 s then count from `time` (that each
    /// `PSI` restarts the count is the mock's assumption; `MockPersonality.sds100`).
    func stepWithRenewal(to time: Double, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        clock.set(time)
        let renewals = { @Sendable in await self.mock.receivedCommands.filter { $0 == "PSI,100" }.count }
        let before = await renewals()
        do {
            try await eventually(.seconds(3)) { await renewals() > before }
        } catch {
            Issue.record("no renewal reached the mock after scenario time \(time)", sourceLocation: sourceLocation)
            throw error
        }
    }
}

/// What an SDS100 must never be sent by the runner (SDS100 design §5.2, constraints): no `KAL`
/// (its keep-alive is the renewal), no `GCS` (no charge status), and no `MSM`, `POF`, `KEY` or
/// `MSV`; and a run that ends connected ends with `PSI,0`.
private func expectSDS100Rules(_ commands: [String], endsWithPSI0: Bool = true,
                               sourceLocation: SourceLocation = #_sourceLocation) {
    let forbidden = ["KAL", "GCS", "MSM", "POF", "KEY", "MSV"]
    let sent = commands.filter { command in forbidden.contains { command == $0 || command.hasPrefix($0 + ",") } }
    #expect(sent == [], "\(commands)", sourceLocation: sourceLocation)
    if endsWithPSI0 { #expect(commands.last == "PSI,0", "\(commands)", sourceLocation: sourceLocation) }
}

private let connectedSDS150 = RunnerEvent.connected(model: "SDS150", firmware: "1.01.02")
private let connectedSDS100 = RunnerEvent.connected(model: "SDS100", firmware: "1.26.01")
/// What a runner sends to connect and subscribe (the tests' push interval is 100 ms).
private let startCommands = ["MDL", "VER", "PSI,100"]

@Suite struct StationRunnerUSBTests {
    @Test func usbStationLogsHitsWithoutAudio() async throws {
        // Save-audio says "every transmission": on a USB station it has no effect.
        let outcome = try await withUSBRunner { rig in
            #expect(await rig.runner.hasAudio == false)
            try await rig.play(at: firstAt)
            try await rig.waitForEnded(1)

            #expect(rig.events.all.first == connectedSDS150)
            let rows = try await rig.rows()
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.hit.key.talkgroupID == "1201")
            #expect(row.hit.channel == "Lakeview Fire Dispatch")
            #expect(row.hit.endedAt != nil)
            #expect(row.hit.endReason == .signalLost)
            #expect(row.audioPath == nil)
            #expect(row.audioError == nil)
            #expect(row.isNew)
            #expect(rig.events.started.count == 1)
            #expect(rig.events.started.first?.audioPath == nil)
            #expect(rig.events.ended.count == 1)
            #expect(rig.events.ended.first?.audioPath == nil)
            #expect(await rig.runner.audioRestartHint() == nil)
            #expect(await rig.runner.hasAudio == false)
            // No recording was written anywhere.
            let files = FileManager.default.enumerator(at: rig.dir, includingPropertiesForKeys: nil)?
                .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
            #expect(!files.contains { $0.hasSuffix(".wav") }, "\(files)")
        }
        #expect(outcome.cooldownCalls == [])
        #expect(!outcome.commands.contains { $0.hasPrefix("MSM") })
        #expect(!outcome.events.contains(where: isAudio))
        #expect(outcome.commands == startCommands + ["PSI,0"])
    }

    /// The SDS150's conventional shape (frequency on `ConvFrequency`, no `SiteFrequency`): each
    /// transmission is one hit with its channel and frequency, started and ended.
    @Test func usbStationLogsConventionalHits() async throws {
        var setup = Setup()
        setup.scenario = conventionalScenario
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.play(at: firstAt)
            try await rig.waitForEnded(1)
            try await rig.play(at: secondAt)
            try await rig.waitForEnded(2)

            let rows = try await rig.rows()
            #expect(rows.count == 2)
            let plow = try #require(rows.first).hit
            #expect(plow.channel == "Plow Dispatch")
            #expect(plow.system == "County Roads")
            #expect(plow.department == "Road Crews")
            #expect(plow.key == HitKey(system: "County Roads", talkgroupID: nil, frequencyMHz: 155.0125))
            #expect(plow.modulation == "NFM")
            #expect(plow.toneOrCode == nil)
            #expect(plow.unitIDs == [])
            #expect(plow.programmed)
            #expect(plow.endedAt != nil)
            #expect(plow.endReason == .signalLost)
            let grader = try #require(rows.dropFirst().first).hit
            #expect(grader.channel == "Grader Ops")
            #expect(grader.key == HitKey(system: "County Roads", talkgroupID: nil, frequencyMHz: 155.1625))
            #expect(grader.modulation == "FM")
            #expect(grader.toneOrCode == "CTCSS 100.0Hz")
            #expect(!grader.programmed)
            #expect(grader.endReason == .signalLost)
            #expect(rig.events.started.map(\.hit.channel) == ["Plow Dispatch", "Grader Ops"])
            #expect(rig.events.ended.map(\.hit.channel) == ["Plow Dispatch", "Grader Ops"])
        }
        #expect(outcome.commands == startCommands + ["PSI,0"])
    }

    /// The SDS150 idles stepping through its conventional channels, each named with its
    /// frequency and `Sig="0"` (as on hardware): nothing is logged, and the live status still
    /// shows each channel.
    @Test func usbStationIdlingOnConventionalChannelsLogsNothing() async throws {
        var setup = Setup()
        // Idle for the whole test.
        setup.scenario = MockScenario(idle: MockScenario.default.idle, transmissions: [
            MockTransmission(at: 100, duration: 1, system: "County Roads", department: "Road Crews",
                             channel: "Plow Dispatch", frequencyMHz: 155.0125),
        ])
        let outcome = try await withUSBRunner(setup) { rig in
            for (second, name) in ["Plow Dispatch", "Salt Shed", "Road Crew 2"].enumerated() {
                rig.clock.set(Double(second) + 0.5)
                let pushes = rig.pushes
                try await eventually { pushes.channelNames.contains(name) }
                try await Task.sleep(for: .seconds(1))
            }
            #expect(rig.pushes.channelNames == ["Plow Dispatch", "Salt Shed", "Road Crew 2"])
            #expect(rig.events.started.isEmpty)
            #expect(rig.events.ended.isEmpty)
            #expect(try await rig.rows().isEmpty)
        }
        #expect(!outcome.events.contains { if case .hitStarted = $0 { true } else { false } })
        #expect(!outcome.events.contains { if case .hitEnded = $0 { true } else { false } })
        #expect(outcome.commands == startCommands + ["PSI,0"])
    }

    // MARK: The push keep-alive

    /// The mock's pushes stop 183 s of scenario time after the `PSI` unless a `KAL` restarts the
    /// count. With the keep-alive (100 ms here) the station runs past that and logs a hit that
    /// starts after it, with no stall warning; nothing follows `PSI,0`. Without the keep-alive
    /// (`modelWithoutAKeepAliveGetsNone`) the same steps stop the pushes.
    @Test func usbStationRunsPastThePushLifetime() async throws {
        var setup = Setup()
        setup.keepAliveInterval = .milliseconds(100)
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            let late = 7 * period  // 203 s: past the 183 s since the PSI
            #expect(late > 183)
            try await rig.stepWithKeepAlive(to: 4 * period + 0.5)
            try await rig.stepWithKeepAlive(to: late + 0.5)
            try await rig.play(at: late + firstAt, hold: .seconds(1), backTo: late + 0.5)
            try await rig.waitForEnded(1)

            let row = try #require(try await rig.rows().first)
            #expect(row.hit.key.talkgroupID == "1201")
            #expect(row.hit.endReason == .signalLost)
            #expect(!rig.events.warnings.contains(StationRunner.stalledMessage), "\(rig.events.warnings)")
            #expect(rig.events.disconnects.isEmpty)
        }
        #expect(!outcome.events.contains(.warning(StationRunner.resubscribingMessage)))
        let commands = outcome.commands
        #expect(Array(commands.prefix(3)) == startCommands, "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(commands.dropFirst(3).dropLast().allSatisfy { $0 == "KAL" }, "\(commands)")
        #expect(commands.filter { $0 == "KAL" }.count >= 2, "\(commands)")
        #expect(!outcome.events.contains(.warning(StationRunner.stalledMessage)))
    }

    /// The resumed connection after a replug passes the keep-alive too.
    @Test func resumedConnectionKeepsItsPushAlive() async throws {
        var setup = Setup()
        setup.keepAliveInterval = .milliseconds(100)
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            _ = try await rig.mock.replug()
            try await rig.waitForConnections(2)
            let late = 7 * period
            try await rig.stepWithKeepAlive(to: 4 * period + 0.5)
            try await rig.stepWithKeepAlive(to: late + 0.5)
            try await rig.play(at: late + firstAt, hold: .seconds(1), backTo: late + 0.5)
            try await rig.waitForEnded(1)
            #expect(!rig.events.warnings.contains(StationRunner.stalledMessage), "\(rig.events.warnings)")
        }
        #expect(!outcome.events.contains(.warning(StationRunner.resubscribingMessage)))
        #expect(outcome.events.filter { if case .disconnected = $0 { true } else { false } }.count == 1)
        let commands = outcome.commands
        let resumed = try #require(commands.lastIndex(of: "MDL"))
        #expect(Array(commands[resumed...].prefix(3)) == startCommands, "\(commands)")
        #expect(commands[resumed...].filter { $0 == "KAL" }.count >= 2, "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
    }

    /// A scanner whose model has no keep-alive (here the mock says `BCD436HP`) is never sent one,
    /// even with the interval overridden; and so the mock's lifetime stops its pushes, which the
    /// runner reports as a stall.
    @Test func modelWithoutAKeepAliveGetsNone() async throws {
        var setup = Setup()
        setup.keepAliveInterval = .milliseconds(100)
        setup.reportedModel = "BCD436HP"
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            rig.clock.set(4 * period + 0.5)
            try await Task.sleep(for: .milliseconds(300))
            rig.clock.set(7 * period + 0.5)
            let events = rig.events
            try await eventually(.seconds(6)) { events.warnings.contains(StationRunner.stalledMessage) }
            #expect(await rig.received("KAL") == 0)
            // Past the tick on which a subscription with a keep-alive would have been replaced:
            // one without is never replaced, only warned about.
            try await Task.sleep(for: .milliseconds(1500))
            #expect(!events.warnings.contains(StationRunner.resubscribingMessage), "\(events.warnings)")
            #expect(events.disconnects.isEmpty)
        }
        #expect(!outcome.commands.contains("KAL"), "\(outcome.commands)")
        #expect(outcome.commands == ["MDL", "VER", "PSI,100", "PSI,0"], "\(outcome.commands)")
    }

    /// With no push interval given, the runner subscribes at the model's (`ModelProfile.pushInterval`):
    /// `PSI,100` to an SDS150 or an SDS100, `PSI,500` to a model that reports another name.
    @Test(arguments: [("SDS150", "PSI,100"), ("SDS100", "PSI,100"), ("BCD436HP", "PSI,500")])
    func subscribesAtTheModelsPushInterval(reported: String, subscribe: String) async throws {
        var setup = Setup()
        setup.pushInterval = nil
        setup.reportedModel = reported
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
        }
        #expect(outcome.commands.filter { $0 != "KAL" } == ["MDL", "VER", subscribe, "PSI,0"], "\(outcome.commands)")
    }

    // MARK: The SDS100: the subscription renewed in place of KAL (SDS100 design §5.2)

    /// The SDS150 is unchanged: `KAL` keeps its pushes past the lifetime, and its `PSI` is never
    /// repeated (exactly one non-zero `PSI` in the mock's log).
    @Test func sds150StillGetsKALAndNeverARepeatedPSI() async throws {
        var setup = Setup()
        setup.keepAliveInterval = .milliseconds(100)
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            let late = 7 * period
            try await rig.stepWithKeepAlive(to: 4 * period + 0.5)
            try await rig.stepWithKeepAlive(to: late + 0.5)
            try await rig.play(at: late + firstAt, hold: .seconds(1), backTo: late + 0.5)
            try await rig.waitForEnded(1)
            #expect(!rig.events.warnings.contains(StationRunner.stalledMessage), "\(rig.events.warnings)")
        }
        let commands = outcome.commands
        #expect(commands.filter { $0.hasPrefix("PSI,") && $0 != "PSI,0" } == ["PSI,100"], "\(commands)")
        #expect(commands.filter { $0 == "KAL" }.count >= 2, "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
    }

    /// The SDS100 mock's pushes stop 183 s after the latest `PSI`. The runner renews the
    /// subscription (its own `PSI,100` again; 300 ms here, so a push falls between two renewals,
    /// each of which restarts the mock's push timer) and the station runs past twice the
    /// lifetime and logs a hit there, with no stall and nothing replaced. Never a `KAL`.
    @Test func sds100RunsPastThePushLifetime() async throws {
        var setup = Setup()
        setup.personality = .sds100
        setup.keepAliveInterval = .milliseconds(300)
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            #expect(rig.events.all.first == connectedSDS100)
            let late = 14 * period  // 406 s: past twice the 183 s since the PSI
            #expect(late > 2 * 183)
            try await rig.stepWithRenewal(to: 6 * period + 0.5)
            try await rig.stepWithRenewal(to: 12 * period + 0.5)
            try await rig.stepWithRenewal(to: late + 0.5)
            try await rig.play(at: late + firstAt, hold: .seconds(1), backTo: late + 0.5)
            try await rig.waitForEnded(1)
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.key.talkgroupID == "1201")
            #expect(row.hit.endReason == .signalLost)
            #expect(rig.events.disconnects.isEmpty)
            #expect(rig.events.connections == [connectedSDS100])
        }
        #expect(!outcome.events.contains(.warning(StationRunner.stalledMessage)), "\(outcome.events)")
        #expect(!outcome.events.contains(.warning(StationRunner.resubscribingMessage)))
        let commands = outcome.commands
        #expect(Array(commands.prefix(3)) == startCommands, "\(commands)")
        #expect(commands.dropFirst(3).dropLast().allSatisfy { $0 == "PSI,100" }, "\(commands)")
        #expect(commands.filter { $0 == "PSI,100" }.count >= 4, "\(commands)")
        expectSDS100Rules(commands)
    }

    /// Renewals that never reach the scanner: its pushes stop at the lifetime, and the D6 rule
    /// replaces the subscription once (the stall warning, the resubscribe warning, `PSI,0`, the
    /// "connected but isn't sending" disconnect, `MDL`, `VER` and a fresh `PSI,100`); pushes
    /// then come again and a hit is logged.
    @Test func sds100DeadSubscriptionIsReplaced() async throws {
        var setup = Setup()
        setup.personality = .sds100
        setup.keepAliveInterval = .milliseconds(300)
        let vanish = RenewalsVanish()
        setup.renewalsVanish = vanish
        let late = 7 * period  // past the 183 s since the first connection's PSI
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            try await eventually(.seconds(3)) { vanish.renewalsDropped >= 1 }
            rig.clock.set(late + 0.5)
            try await rig.waitForConnections(2, limit: .seconds(15))
            let all = rig.events.all
            let stalled = try #require(all.firstIndex(of: .warning(StationRunner.stalledMessage)), "\(all)")
            let warned = try #require(all.firstIndex(of: .warning(StationRunner.resubscribingMessage)), "\(all)")
            let disconnected = try #require(all.firstIndex(of: .disconnected(hint: SerialPort.notSendingUpdatesHint)),
                                            "\(all)")
            let reconnected = try #require(all.lastIndex(of: connectedSDS100), "\(all)")
            #expect(stalled < warned && warned < disconnected && disconnected < reconnected, "\(all)")
            // The fresh subscription pushes: a transmission now is logged.
            try await rig.play(at: late + firstAt, hold: .seconds(1), backTo: late + 0.5)
            try await rig.waitForEnded(1)
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.key.talkgroupID == "1201")
            #expect(row.hit.endReason == .signalLost)
            // Replaced once: still the second connection a while later.
            try await Task.sleep(for: .seconds(1))
            #expect(rig.events.connections == [connectedSDS100, connectedSDS100])
            #expect(rig.events.disconnects == [SerialPort.notSendingUpdatesHint])
            #expect(rig.events.warnings.filter { $0 == StationRunner.resubscribingMessage }.count == 1)
            #expect(!rig.events.warnings.contains(StationRunner.notResumingMessage))
        }
        // Every renewal was dropped on its way, so the mock saw two subscriptions, each ended.
        let cycle = startCommands + ["PSI,0"]
        #expect(outcome.commands == cycle + cycle, "\(outcome.commands)")
        #expect(vanish.renewalsDropped >= 2)
        expectSDS100Rules(outcome.commands)
    }

    /// Review Focus 4: the scanner rejects a renewal (`PSI,NG` after the subscription has pushed).
    /// The earlier subscription still runs, so the push stays: one keep-alive warning, no
    /// disconnect, and no further renewal on that connection. When the pushes stop at the
    /// lifetime (which the rejected renewal didn't restart) the D6 rule replaces the subscription
    /// once, and the new one's renewals go out.
    @Test func sds100RejectedRenewalWarnsOnceAndIsReplaced() async throws {
        var setup = Setup()
        setup.personality = .sds100
        setup.keepAliveInterval = .seconds(1)
        let refused = "couldn't send the keep-alive (the scanner refused PSI); status updates may stop"
        let late = 7 * period
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await rig.waitForPush()
            // The first renewal is due a second after the PSI: it is the one rejected.
            await rig.mock.setFaults(MockFaults(dropCount: 1, rejectNext: "PSI"))
            try await eventually(.seconds(3)) { events.warnings.contains(refused) }
            #expect(await rig.mock.receivedCommands == startCommands + ["PSI,100"])
            // Over two more renewal intervals: pushes keep coming, nothing more is written, and
            // the station stays connected.
            let pushed = await rig.mock.pushesSent
            try await Task.sleep(for: .milliseconds(2500))
            #expect(await rig.mock.pushesSent > pushed + 10)
            #expect(await rig.mock.receivedCommands == startCommands + ["PSI,100"])
            #expect(events.disconnects.isEmpty)
            #expect(events.connections.count == 1)
            #expect(events.warnings == [refused], "\(events.warnings)")

            // Past the lifetime: replaced once.
            rig.clock.set(late + 0.5)
            try await rig.waitForConnections(2, limit: .seconds(15))
            let all = events.all
            let warned = try #require(all.firstIndex(of: .warning(StationRunner.resubscribingMessage)), "\(all)")
            let disconnected = try #require(all.firstIndex(of: .disconnected(hint: SerialPort.notSendingUpdatesHint)),
                                            "\(all)")
            #expect(warned < disconnected, "\(all)")
            // The new subscription's renewals go out (the fault was used up).
            let resumed = try #require(await rig.mock.receivedCommands.lastIndex(of: "MDL"))
            try await eventually(.seconds(4)) {
                await rig.mock.receivedCommands[resumed...].filter { $0 == "PSI,100" }.count >= 3
            }
            #expect(events.connections == [connectedSDS100, connectedSDS100])
            #expect(events.disconnects == [SerialPort.notSendingUpdatesHint])
            #expect(events.warnings.filter { $0 == refused }.count == 1, "\(events.warnings)")
            #expect(events.warnings.filter { $0 == StationRunner.resubscribingMessage }.count == 1)
        }
        let commands = outcome.commands
        // The first connection: its PSI, the rejected renewal, and the replacement's PSI,0.
        #expect(Array(commands.prefix(6)) == startCommands + ["PSI,100", "PSI,0", "MDL"], "\(commands)")
        #expect(commands.filter { $0 == "MDL" }.count == 2, "the port was reopened more than once: \(commands)")
        expectSDS100Rules(commands)
    }

    /// The SDS100 is resumed after a replug as the SDS150 is: the same model answers, a fresh
    /// `PSI,100`, and its renewals keep the new subscription going past the lifetime.
    @Test func sds100ResumesAfterAReplug() async throws {
        var setup = Setup()
        setup.personality = .sds100
        setup.keepAliveInterval = .milliseconds(300)
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            _ = try await rig.mock.replug()
            try await rig.waitForConnections(2)
            #expect(rig.events.connections == [connectedSDS100, connectedSDS100])
            let late = 7 * period
            try await rig.stepWithRenewal(to: 4 * period + 0.5)
            try await rig.stepWithRenewal(to: late + 0.5)
            try await rig.play(at: late + firstAt, hold: .seconds(1), backTo: late + 0.5)
            try await rig.waitForEnded(1)
            #expect(rig.events.disconnects == [SerialPort.noneFoundHint])
            #expect(rig.events.warnings == [], "\(rig.events.warnings)")
        }
        let commands = outcome.commands
        let resumed = try #require(commands.lastIndex(of: "MDL"))
        #expect(Array(commands[resumed...].prefix(3)) == startCommands, "\(commands)")
        #expect(commands[resumed...].dropFirst(3).dropLast().allSatisfy { $0 == "PSI,100" }, "\(commands)")
        #expect(commands[resumed...].filter { $0 == "PSI,100" }.count >= 3, "\(commands)")
        #expect(commands.filter { $0 == "MDL" }.count == 2, "\(commands)")
        expectSDS100Rules(commands)
    }

    /// Review Focus 5: after an unplug, an SDS150 turns up behind the SDS100 station's port. It is
    /// asked `MDL` once and left alone (no `PSI`, no `KAL`), with one warning; when it goes and
    /// the SDS100 is back, the station resumes on it.
    @Test func sds100StationRefusesAnSDS150OnResume() async throws {
        var setup = Setup()
        setup.personality = .sds100
        setup.keepAliveInterval = .milliseconds(300)
        let other = Mutex<MockSerialScanner?>(nil)
        var failure: (any Error)?
        do {
            let outcome = try await withUSBRunner(setup) { rig in
                let events = rig.events
                try await rig.waitForPush()
                await rig.mock.unplug()
                try await rig.waitForDisconnects(1)

                let handheld = MockSerialScanner(scenario: .default, clock: rig.clock, personality: .sds150,
                                                 linkPath: rig.port)
                other.withLock { $0 = handheld }
                #expect(try await handheld.start() == rig.port)
                try await eventually { !events.warnings.isEmpty }
                // Many polls later it has been asked `MDL` once, and is left alone.
                try await Task.sleep(for: .milliseconds(600))
                #expect(await handheld.receivedCommands == ["MDL"])
                #expect(events.warnings == ["a different scanner answered (SDS150); still waiting for the SDS100"])
                #expect(events.connections == [connectedSDS100])
                #expect(await rig.runner.control() == nil)

                // It goes, and the SDS100 is back.
                await handheld.unplug()
                try await Task.sleep(for: .milliseconds(250))
                _ = try await rig.mock.replug()
                try await rig.waitForConnections(2)
                #expect(events.connections == [connectedSDS100, connectedSDS100])
                #expect(events.warnings.count == 1, "\(events.warnings)")
            }
            expectSDS100Rules(outcome.commands)
            #expect(outcome.commands.filter { $0 == "MDL" }.count == 2, "\(outcome.commands)")
        } catch {
            failure = error
        }
        // Read the SDS150 once it has stopped (that drains whatever was written to it).
        let handheld = try #require(other.withLock { $0 })
        await handheld.stop()
        if let failure { throw failure }
        #expect(await handheld.receivedCommands == ["MDL"])
        #expect(await handheld.activeSubscribers == 0)
    }

    // MARK: A subscription that stops pushing

    /// The pushes stop before the first `KAL` (the mock's lifetime runs out while the keep-alive
    /// waits its interval), as after a pause longer than the SDS150's 183 s. If the late `KAL`
    /// doesn't start them again (`false`, the pessimistic answer), the runner warns, ends the
    /// subscription (`PSI,0`), reports the scanner as connected but not sending, and the bounded
    /// resume opens it again (one `MDL`) and subscribes afresh; a transmission after that is
    /// logged. If it does (`true`), nothing of that happens.
    @Test(arguments: [false, true])
    func deadSubscriptionIsReplaced(_ lateKeepAliveRevives: Bool) async throws {
        var setup = Setup()
        setup.keepAliveInterval = .seconds(2)
        setup.pushLifetime = 10
        setup.lateKeepAliveRevives = lateKeepAliveRevives
        let idle = period + 0.5  // past the lifetime of a PSI at scenario time 0, and idle
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            // The last push comes about a second after the PSI, the first KAL about two seconds
            // after it, and the threshold (no push for an interval, and at least the 3 s stall)
            // well after that: the KAL lands before the runner gives up on the subscription.
            try await Task.sleep(for: .seconds(1))
            rig.clock.set(idle)
            let events = rig.events
            if lateKeepAliveRevives {
                try await eventually(.seconds(5)) { await rig.received("KAL") >= 1 }
                let atKAL = rig.pushes.count
                let pushes = rig.pushes
                try await eventually(.seconds(3)) { pushes.count > atKAL }
                // Past the point where the runner would have replaced it.
                try await Task.sleep(for: .seconds(4))
                #expect(events.disconnects.isEmpty, "\(events.all)")
                #expect(!events.warnings.contains(StationRunner.resubscribingMessage), "\(events.warnings)")
                #expect(events.connections.count == 1)
            } else {
                try await rig.waitForConnections(2, limit: .seconds(15))
                let all = events.all
                let warned = try #require(all.firstIndex(of: .warning(StationRunner.resubscribingMessage)), "\(all)")
                let disconnected = try #require(all.firstIndex(of: .disconnected(hint: SerialPort.notSendingUpdatesHint)),
                                                "\(all)")
                let reconnected = try #require(all.lastIndex(of: connectedSDS150), "\(all)")
                #expect(warned < disconnected && disconnected < reconnected, "\(all)")
                #expect(events.disconnects == [SerialPort.notSendingUpdatesHint])
                #expect(events.warnings.filter { $0 == StationRunner.resubscribingMessage }.count == 1)
                #expect(!events.warnings.contains(StationRunner.notResumingMessage))
            }
            // A transmission now is logged (on the fresh subscription, or the revived one).
            try await rig.play(at: period + firstAt, hold: .seconds(1), backTo: idle)
            try await rig.waitForEnded(1)
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.key.talkgroupID == "1201")
            #expect(row.hit.endReason == .signalLost)
            guard !lateKeepAliveRevives else { return }
            // The resumed connection has pushed: when its pushes stop too (the clock moves past
            // its lifetime, which no KAL can restart once run out), it is replaced again.
            rig.clock.set(2 * period + 0.5)
            try await rig.waitForConnections(3, limit: .seconds(15))
            #expect(events.warnings.filter { $0 == StationRunner.resubscribingMessage }.count == 2, "\(events.warnings)")
            #expect(events.disconnects == [SerialPort.notSendingUpdatesHint, SerialPort.notSendingUpdatesHint])
        }
        let commands = outcome.commands.filter { $0 != "KAL" }
        if lateKeepAliveRevives {
            #expect(commands == startCommands + ["PSI,0"], "\(outcome.commands)")
        } else {
            // PSI,0 after each subscription, and one MDL (the resume's probe) before each new one.
            let cycle = startCommands + ["PSI,0"]
            #expect(commands == cycle + cycle + cycle, "\(outcome.commands)")
        }
        #expect(outcome.commands.contains("KAL"))
        #expect(outcome.subscribers == 0)
    }

    /// A keep-alive interval shorter than the push interval (a test override) never replaces a
    /// subscription that is pushing: the threshold is never less than the 3 s stall, so the gap
    /// between two pushes (up to 500 ms here, against a 100 ms keep-alive) is no reason.
    @Test func shortKeepAliveNeverReplacesAWorkingSubscription() async throws {
        var setup = Setup()
        setup.keepAliveInterval = .milliseconds(100)
        setup.pushInterval = .milliseconds(500)
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            try await Task.sleep(for: .seconds(5))  // at least four ticks
            #expect(rig.events.connections.count == 1)
            #expect(rig.events.disconnects.isEmpty)
            #expect(rig.events.warnings.isEmpty, "\(rig.events.warnings)")
        }
        #expect(outcome.commands.filter { $0 != "KAL" } == ["MDL", "VER", "PSI,500", "PSI,0"], "\(outcome.commands)")
        #expect(outcome.commands.contains("KAL"))
    }

    /// A connection whose subscription never delivered a push is not replaced, however long it
    /// stays silent: it stays connected with only the stall warning, and nothing but its
    /// keep-alive is sent until the stop's `PSI,0` (no reopen loop against a scanner that won't push).
    @Test func connectionThatNeverPushedIsNotReplaced() async throws {
        var setup = Setup()
        setup.keepAliveInterval = .milliseconds(100)
        setup.faults = MockFaults(stallPSIAfter: 0)  // the subscription stands, but no push comes
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await eventually(.seconds(6)) { events.warnings.contains(StationRunner.stalledMessage) }
            try await Task.sleep(for: .milliseconds(1500))
            #expect(rig.pushes.count == 0)
            #expect(events.warnings == [StationRunner.stalledMessage], "\(events.warnings)")
            #expect(events.disconnects.isEmpty)
            #expect(events.connections.count == 1)
            #expect(!(await rig.mock.receivedCommands.contains("PSI,0")))
        }
        #expect(outcome.commands.filter { $0 != "KAL" } == startCommands + ["PSI,0"], "\(outcome.commands)")
    }

    /// A `KAL` write that fails is a warning, once; the keep-alive then ends (never resent), so the
    /// pushes stop at the mock's lifetime and the subscription is replaced as above. The new
    /// subscription's keep-alive works.
    @Test func failedKeepAliveWriteWarns() async throws {
        var setup = Setup()
        setup.keepAliveInterval = .seconds(1)
        setup.pushLifetime = 10
        setup.firstKeepAliveWriteFails = true
        let failed = StationRunner.keepAliveFailedMessage(FirstKeepAliveWriteFails.error)
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            let events = rig.events
            try await eventually(.seconds(5)) { events.warnings.contains(failed) }
            #expect(await rig.received("KAL") == 0)
            rig.clock.set(period + 0.5)  // past the lifetime, which no KAL restarted
            try await rig.waitForConnections(2, limit: .seconds(15))
            #expect(events.warnings.contains(StationRunner.resubscribingMessage), "\(events.warnings)")
            #expect(events.disconnects == [SerialPort.notSendingUpdatesHint])
            // The new subscription's keep-alive reaches the mock.
            try await eventually(.seconds(5)) { await rig.received("KAL") >= 1 }
            #expect(events.warnings.filter { $0.hasPrefix("couldn't send the keep-alive") } == [failed],
                    "\(events.warnings)")
        }
        #expect(failed == "couldn't send the keep-alive (\(FirstKeepAliveWriteFails.error)); status updates may stop")
        #expect(outcome.commands.filter { $0 != "KAL" } == startCommands + ["PSI,0"] + startCommands + ["PSI,0"],
                "\(outcome.commands)")
    }

    @Test func stopSendsPSI0() async throws {
        let outcome = try await withUSBRunner { rig in
            // Stop in the middle of a transmission.
            rig.clock.set(firstAt + 0.01)
            let events = rig.events
            try await eventually { !events.started.isEmpty }
            #expect(await rig.mock.activeSubscribers == 1)
            await rig.runner.stop()
            // The mock logs the runner's last write on its own queue, a moment after the stop.
            try await eventually(.seconds(2)) { await rig.mock.receivedCommands.last == "PSI,0" }
            #expect(await rig.mock.activeSubscribers == 0)
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.endReason == .stopped)
            #expect(row.hit.endedAt != nil)
            #expect(await rig.runner.control() == nil)
        }
        #expect(outcome.commands.last == "PSI,0")
        #expect(outcome.subscribers == 0)
    }

    @Test func unplugClosesHitAndWaits() async throws {
        let outcome = try await withUSBRunner { rig in
            let events = rig.events
            rig.clock.set(firstAt + 0.01)
            try await eventually { !events.started.isEmpty }
            #expect(await rig.mock.receivedCommands == startCommands)

            await rig.mock.unplug()
            try await rig.waitForEnded(1)
            try await rig.waitForDisconnects(1)

            // The open hit ended as on any push end, and is in the log.
            #expect(events.ended.first?.hit.endReason == .stalled)
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.endReason == .stalled)
            #expect(row.hit.endedAt != nil)
            #expect(row.audioPath == nil)
            // The hit's end comes before the disconnect.
            let all = events.all
            let endedIndex = try #require(all.firstIndex { if case .hitEnded = $0 { true } else { false } })
            let disconnectedIndex = try #require(all.firstIndex(of: .disconnected(hint: SerialPort.noneFoundHint)))
            #expect(endedIndex < disconnectedIndex)
            // There is no scanner to control while it is away.
            #expect(await rig.runner.control() == nil)

            // Many polls later: still one disconnect, nothing else reported, nothing written.
            try await Task.sleep(for: .milliseconds(600))
            #expect(events.disconnects == [SerialPort.noneFoundHint])
            #expect(events.all.last == .disconnected(hint: SerialPort.noneFoundHint))
            #expect(events.connections.count == 1)
            #expect(await rig.mock.receivedCommands == startCommands)
        }
        #expect(outcome.events.filter { if case .disconnected = $0 { true } else { false } }.count == 1)
        // Nothing was written after the unplug, at stop either (`PSI,0` has nowhere to go).
        #expect(outcome.commands == startCommands)
    }

    @Test func resumesAfterReplug() async throws {
        let outcome = try await withUSBRunner { rig in
            let events = rig.events
            try await rig.play(at: firstAt)
            try await rig.waitForEnded(1)

            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            #expect(await rig.runner.control() == nil)
            #expect(try await rig.mock.replug() == rig.port)
            try await rig.waitForConnections(2)
            #expect(events.connections == [connectedSDS150, connectedSDS150])
            // The new connection is the one `control()` hands out.
            let client = try #require(await rig.runner.control())
            let model = try await client.modelInfo().reported
            #expect(model == "SDS150")

            // The scenario's next transmission is a new hit.
            try await rig.play(at: secondAt)
            try await rig.waitForEnded(2)
            let rows = try await rig.rows()
            #expect(rows.count == 2)
            #expect(rows.map(\.hit.key.talkgroupID) == ["1201", "2305"])
            #expect(rows.last?.hit.endReason == .signalLost)
            #expect(Set(rows.map(\.hit.id)).count == 2)
            #expect(events.disconnects.count == 1)
            #expect(events.warnings == [])
        }
        // One `MDL`, `VER` and `PSI` per connection (plus the test's own `MDL`), and `PSI,0` at stop.
        #expect(outcome.commands == startCommands + startCommands + ["MDL", "PSI,0"], "\(outcome.commands)")
        #expect(outcome.subscribers == 0)
    }

    @Test func secondDisconnectAfterAResumeRepeatsTheCycle() async throws {
        let outcome = try await withUSBRunner { rig in
            let events = rig.events
            try await rig.waitForPush()  // a working connection: only that is resumed
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            _ = try await rig.mock.replug()
            try await rig.waitForConnections(2)

            // Lost again, in the middle of a transmission this time.
            rig.clock.set(firstAt + 0.01)
            try await eventually { !events.started.isEmpty }
            await rig.mock.unplug()
            try await rig.waitForEnded(1)
            try await rig.waitForDisconnects(2)
            #expect(events.ended.first?.hit.endReason == .stalled)
            rig.clock.set(0)
            try await Task.sleep(for: .milliseconds(300))
            #expect(events.disconnects.count == 2)
            #expect(events.connections.count == 2)

            _ = try await rig.mock.replug()
            try await rig.waitForConnections(3)
            try await rig.play(at: secondAt)
            try await rig.waitForEnded(2)
            #expect(try await rig.rows().map(\.hit.key.talkgroupID) == ["1201", "2305"])
            #expect(events.disconnects == [SerialPort.noneFoundHint, SerialPort.noneFoundHint])
        }
        #expect(outcome.commands == startCommands + startCommands + startCommands + ["PSI,0"], "\(outcome.commands)")
    }

    // MARK: A port that appears gets a bounded number of probes

    @Test func busyPortIsRetriedUntilItIsFree() async throws {
        var setup = Setup()
        setup.ownStationLink = true
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)

            // The scanner comes back with another program holding its port: the test takes the
            // mock's port before the station's own link leads to it again.
            try FileManager.default.removeItem(atPath: rig.port)
            _ = try await rig.mock.replug()
            let holder = SerialTransport(path: rig.mockPort)
            try await holder.open()
            try FileManager.default.createSymbolicLink(atPath: rig.port, withDestinationPath: rig.mockPort)

            // Many polls, each refused (far more than the three probes a silent port gets):
            // nothing is sent, nothing is reported.
            try await Task.sleep(for: .milliseconds(600))
            #expect(events.connections.count == 1)
            #expect(events.disconnects.count == 1)
            #expect(events.warnings == [])
            #expect(await rig.mock.receivedCommands == startCommands)

            // The other program lets go: the same port, never gone in between, is asked now.
            await holder.close()
            try await rig.waitForConnections(2)
            #expect(events.warnings == [])
        }
        // One `MDL` in all: none while the port was busy.
        #expect(outcome.commands == startCommands + startCommands + ["PSI,0"], "\(outcome.commands)")
    }

    @Test func missedModelIsAskedAgain() async throws {
        let outcome = try await withUSBRunner { rig in
            let events = rig.events
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            // The first `MDL` after the scanner is back goes unanswered.
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MDL"))
            _ = try await rig.mock.replug()
            try await eventually { await rig.received("MDL") == 2 }
            // For the whole command timeout the attempt waits, and sends nothing else.
            try await Task.sleep(for: .milliseconds(1500))
            #expect(await rig.mock.receivedCommands == startCommands + ["MDL"])
            #expect(events.connections.count == 1)
            // It gives up, lets the port go, and the next poll asks again: once.
            try await rig.waitForConnections(2)
            #expect(events.disconnects.count == 1)
            #expect(events.warnings == [])
        }
        #expect(outcome.commands == startCommands + ["MDL"] + startCommands + ["PSI,0"], "\(outcome.commands)")
    }

    @Test func silentPortGetsThreeProbes() async throws {
        let outcome = try await withUSBRunner(limit: .seconds(60)) { rig in
            let events = rig.events
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            // A port comes back at the station's path and never answers `MDL`.
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MDL", dropCount: 100))
            _ = try await rig.mock.replug()

            // Three probes, one per poll (each waits out the 2 s command timeout), then the warning.
            try await eventually(.seconds(20)) { !events.warnings.isEmpty }
            #expect(events.warnings == [notAnsweringWarning])
            #expect(await rig.mock.receivedCommands == startCommands + ["MDL", "MDL", "MDL"])
            // Many polls later: the port is still there, and is left alone.
            try await Task.sleep(for: .milliseconds(600))
            #expect(await rig.mock.receivedCommands == startCommands + ["MDL", "MDL", "MDL"])
            #expect(events.warnings == [notAnsweringWarning])
            #expect(events.connections.count == 1)
            #expect(await rig.runner.control() == nil)

            // Unplugged (for a few polls) and plugged in again, answering: a fresh start.
            await rig.mock.unplug()
            try await Task.sleep(for: .milliseconds(250))
            await rig.mock.setFaults(.none)
            _ = try await rig.mock.replug()
            try await rig.waitForConnections(2)
            #expect(events.warnings == [notAnsweringWarning])
            #expect(events.disconnects.count == 1)
        }
        #expect(outcome.commands == startCommands + ["MDL", "MDL", "MDL"] + startCommands + ["PSI,0"], "\(outcome.commands)")
    }

    @Test func probesStartAfreshAfterAResume() async throws {
        // Two missed `MDL`s, then a resume. When that connection's push stream ends with the port
        // still there, the new wait doesn't inherit the two: another missed `MDL` is a first
        // failed probe, not the third.
        let outcome = try await withUSBRunner(limit: .seconds(60)) { rig in
            let events = rig.events
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MDL", dropCount: 2))
            _ = try await rig.mock.replug()
            try await rig.waitForConnections(2, limit: .seconds(20))
            #expect(events.warnings == [])

            // A hit starts on the resumed connection: it works. Then its subscription is ended
            // by the app's own client, with the port still there.
            rig.clock.set(firstAt + 0.01)
            try await eventually { !events.started.isEmpty }
            rig.clock.set(0)
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MDL"))
            let client = try #require(await rig.runner.control())
            try await client.stopPush()
            try await rig.waitForDisconnects(2)
            try await rig.waitForConnections(3, limit: .seconds(20))
            #expect(events.warnings == [])
        }
        #expect(outcome.commands == startCommands + ["MDL", "MDL"] + startCommands + ["PSI,0", "MDL"] + startCommands + ["PSI,0"],
                "\(outcome.commands)")
    }

    @Test func sameScannerThatStopsAnsweringGetsThreeProbesToo() async throws {
        // `MDL` is answered (it is our scanner) but `VER` never is: that counts as a probe too.
        let outcome = try await withUSBRunner(limit: .seconds(60)) { rig in
            let events = rig.events
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            await rig.mock.setFaults(MockFaults(dropNextRequest: "VER", dropCount: 100))
            _ = try await rig.mock.replug()
            try await eventually(.seconds(20)) { !events.warnings.isEmpty }
            #expect(events.warnings == [notAnsweringWarning])
            try await Task.sleep(for: .milliseconds(600))
            #expect(await rig.mock.receivedCommands == startCommands + ["MDL", "VER", "MDL", "VER", "MDL", "VER"])
            #expect(events.warnings == [notAnsweringWarning])
            #expect(events.connections.count == 1)
            #expect(await rig.runner.control() == nil)
        }
        // No subscription was ever started on those attempts, and stop sends nothing more.
        #expect(outcome.commands == startCommands + ["MDL", "VER", "MDL", "VER", "MDL", "VER"], "\(outcome.commands)")
    }

    /// The same scanner answers `MDL` and `VER`, but its `PSI` can't be written whole: part of it
    /// may have reached the scanner, so the port gets no second probe (and no second `PSI`) until
    /// it has gone, and the runner says so at once.
    @Test func unwrittenPSIOnResumeLeavesThePortAlone() async throws {
        var setup = Setup()
        setup.laterPSIWriteFails = true
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            _ = try await rig.mock.replug()
            try await eventually { !events.warnings.isEmpty }
            #expect(events.warnings == [notAnsweringWarning])
            // Many polls later: one `MDL` and one `VER`, and nothing more.
            try await Task.sleep(for: .milliseconds(600))
            #expect(await rig.mock.receivedCommands == startCommands + ["MDL", "VER"])
            #expect(events.warnings == [notAnsweringWarning])
            #expect(events.connections.count == 1)
            #expect(await rig.runner.control() == nil)
            await rig.expectPortFree()
        }
        #expect(outcome.commands == startCommands + ["MDL", "VER"], "\(outcome.commands)")
    }

    @Test func differentScannerDoesNotResume() async throws {
        let other = Mutex<MockSerialScanner?>(nil)
        var failure: (any Error)?
        do {
            let outcome = try await withUSBRunner { rig in
                let events = rig.events
                try await rig.waitForPush()  // a working connection: only that is resumed
                await rig.mock.unplug()
                try await rig.waitForDisconnects(1)

                // Another scanner turns up on the station's port.
                let second = rig.otherScanner(reporting: "SDS200")
                other.withLock { $0 = second }
                #expect(try await second.start() == rig.port)
                try await eventually { !events.warnings.isEmpty }
                // Many polls later it has been asked `MDL` once, and is left alone.
                try await Task.sleep(for: .milliseconds(600))
                #expect(await second.receivedCommands == ["MDL"])
                #expect(events.warnings == [differentScannerWarning])
                #expect(events.connections.count == 1)
                #expect(events.disconnects.count == 1)
                #expect(await rig.runner.control() == nil)
                // The harness stops the runner now.
            }
            #expect(outcome.commands == startCommands)
            #expect(outcome.events.filter { if case .warning = $0 { true } else { false } }.count == 1)
            #expect(outcome.events.filter { if case .connected = $0 { true } else { false } }.count == 1)
        } catch {
            failure = error
        }
        // Read the other scanner once it has stopped (that drains whatever was written to it):
        // one `MDL` and nothing else, not even at the runner's stop.
        let second = try #require(other.withLock { $0 })
        await second.stop()
        if let failure { throw failure }
        #expect(await second.receivedCommands == ["MDL"])
        #expect(await second.activeSubscribers == 0)
    }

    @Test func resumesOnceTheWrongScannerIsReplaced() async throws {
        let other = Mutex<MockSerialScanner?>(nil)
        var failure: (any Error)?
        do {
            let outcome = try await withUSBRunner { rig in
                let events = rig.events
                try await rig.waitForPush()
                await rig.mock.unplug()
                try await rig.waitForDisconnects(1)
                let second = rig.otherScanner(reporting: "SDS200")
                other.withLock { $0 = second }
                _ = try await second.start()
                try await eventually { !events.warnings.isEmpty }
                try await Task.sleep(for: .milliseconds(300))

                // The wrong scanner is unplugged (the port is gone for a few polls) and plugged in
                // again: a new appearance, so it is asked once more, but the warning isn't repeated.
                await second.unplug()
                try await Task.sleep(for: .milliseconds(250))
                _ = try await second.replug()
                try await eventually { await second.receivedCommands.count >= 2 }
                try await Task.sleep(for: .milliseconds(300))
                #expect(await second.receivedCommands == ["MDL", "MDL"])
                #expect(events.warnings == [differentScannerWarning])

                // It goes for good, and ours is back.
                await second.unplug()
                try await Task.sleep(for: .milliseconds(250))
                _ = try await rig.mock.replug()
                try await rig.waitForConnections(2)
                #expect(events.warnings == [differentScannerWarning])
                #expect(events.disconnects.count == 1)
            }
            #expect(outcome.commands == startCommands + startCommands + ["PSI,0"], "\(outcome.commands)")
        } catch {
            failure = error
        }
        let second = try #require(other.withLock { $0 })
        await second.stop()
        if let failure { throw failure }
        #expect(await second.receivedCommands == ["MDL", "MDL"])
    }

    @Test func portAtAnotherPathIsProbedAfresh() async throws {
        // No port is configured: the station's port is whichever one port the (fake) listing
        // holds. The wrong scanner's port is listed, then replaced in the listing by ours with no
        // poll in between at which nothing was listed: a different path is a new appearance.
        var setup = Setup()
        setup.listsPort = true
        let other = Mutex<MockSerialScanner?>(nil)
        var failure: (any Error)?
        do {
            let outcome = try await withUSBRunner(setup) { rig in
                let events = rig.events
                let listing = try #require(rig.listing)
                try await rig.waitForPush()
                listing.set([])
                await rig.mock.unplug()
                try await rig.waitForDisconnects(1)

                let otherPort = rig.dir.appendingPathComponent("other-port").path
                let second = rig.otherScanner(reporting: "SDS200", link: otherPort)
                other.withLock { $0 = second }
                _ = try await second.start()
                listing.set([otherPort])
                try await eventually { !events.warnings.isEmpty }
                try await Task.sleep(for: .milliseconds(300))
                #expect(await second.receivedCommands == ["MDL"])
                #expect(events.connections.count == 1)

                _ = try await rig.mock.replug()
                listing.set([rig.mockPort])
                try await rig.waitForConnections(2)
                #expect(events.warnings == [differentScannerWarning])
                #expect(await second.receivedCommands == ["MDL"])
            }
            #expect(outcome.commands == startCommands + startCommands + ["PSI,0"], "\(outcome.commands)")
        } catch {
            failure = error
        }
        let second = try #require(other.withLock { $0 })
        await second.stop()
        if let failure { throw failure }
        #expect(await second.receivedCommands == ["MDL"])
    }

    @Test func sameModelUnderAnotherNameResumes() async throws {
        // `MDL` may say SDS150 or SDS150GBT (the spec's name): both are the same scanner.
        let other = Mutex<MockSerialScanner?>(nil)
        var failure: (any Error)?
        do {
            try await withUSBRunner { rig in
                try await rig.waitForPush()  // a working connection: only that is resumed
                await rig.mock.unplug()
                try await rig.waitForDisconnects(1)
                let second = rig.otherScanner(reporting: "SDS150GBT")
                other.withLock { $0 = second }
                _ = try await second.start()
                try await rig.waitForConnections(2)
                #expect(rig.events.connections.last == .connected(model: "SDS150GBT", firmware: "1.01.02"))
                #expect(rig.events.warnings == [])
            }
        } catch {
            failure = error
        }
        let second = try #require(other.withLock { $0 })
        await second.stop()
        if let failure { throw failure }
        #expect(await second.receivedCommands == startCommands + ["PSI,0"])
        #expect(await second.activeSubscribers == 0)
    }

    @Test func sameScannerComparesModelsThenNames() {
        // Known models compare as models, whatever the spelling.
        #expect(StationRunner.isSameScanner("SDS150GBT", as: "SDS150"))
        #expect(StationRunner.isSameScanner("SDS150", as: "SDS150GBT"))
        #expect(StationRunner.isSameScanner(" sds150 ", as: "SDS150"))
        #expect(!StationRunner.isSameScanner("SDS200", as: "SDS150"))
        #expect(!StationRunner.isSameScanner("SDS100", as: "SDS150GBT"))
        // A name no model matches: the names decide.
        #expect(StationRunner.isSameScanner("UBC9000XLT", as: "UBC9000XLT"))
        #expect(!StationRunner.isSameScanner("UBC9000XLT", as: "UBC9001XLT"))
        #expect(!StationRunner.isSameScanner("UBC9000XLT", as: "SDS150"))
        #expect(!StationRunner.isSameScanner("SDS150", as: "UBC9000XLT"))
    }

    @Test func stopDuringWaitIsPrompt() async throws {
        let outcome = try await withUSBRunner { rig in
            let events = rig.events
            try await rig.waitForPush()  // a working connection: only that is resumed
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            try await Task.sleep(for: .milliseconds(120))  // in the wait, between polls

            let began = ContinuousClock.now
            try await bounded(.seconds(5)) { await rig.runner.stop() }
            let took = ContinuousClock.now - began
            #expect(took < .seconds(1), "stop took \(took)")
            try await eventually(.seconds(2)) { events.isFinished }
            let atStop = events.all
            #expect(atStop.last == .stopped)

            // No poll outlives the stop: a scanner that comes back now is left alone.
            _ = try await rig.mock.replug()
            try await Task.sleep(for: .milliseconds(400))
            #expect(events.all == atStop)
            #expect(await rig.mock.receivedCommands == startCommands)
        }
        #expect(outcome.commands == startCommands)
        #expect(outcome.events.filter { if case .connected = $0 { true } else { false } }.count == 1)
    }

    /// A runner let go of during its wait, without `stop()` (an owner that forgot, or crashed out
    /// of its own task), is released, and its wait ends: the scanner that comes back afterwards
    /// receives nothing, so no subscription is started that nobody would ever end.
    @Test func releasedDuringTheWaitStopsPolling() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-usb-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 0),
                                     linkPath: dir.appendingPathComponent("port").path)
        let port = try await mock.start()
        var station = Station()
        station.name = "Test Handheld"
        station.connection.transport = .usbSerial
        var device = StationDeviceSettings(stationID: station.id)
        device.usbPort = port
        let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))

        var failure: (any Error)?
        do {
            var runner: StationRunner? = StationRunner(
                station: station, device: device, log: log, recordingsRoot: dir, cooldownStore: CooldownSpy(),
                transportFactory: StationTransportFactory(ports: FakePorts([])), portPollInterval: pollInterval,
                pushInterval: .milliseconds(100))
            weak let released = runner
            let events = EventLog(try #require(runner).events)
            let pushes = PushLog(try #require(runner).liveStatus)
            try await runner?.start()
            try await eventually { pushes.count >= 1 }  // a working connection: only that is resumed
            await mock.unplug()
            try await eventually { events.disconnects.count == 1 }
            #expect(await runner?.willResume == true)
            try await Task.sleep(for: pollInterval * 3)  // in the wait, polling

            runner = nil
            let wasReleased = (try? await eventually(.seconds(2)) { released == nil }) != nil
            #expect(wasReleased, "the wait still holds the runner")
            _ = try await mock.replug()
            try await Task.sleep(for: pollInterval * 10)
            #expect(await mock.receivedCommands == startCommands)
            #expect(events.connections.count == 1)
        } catch {
            failure = error
        }
        await mock.stop()
        let commands = await mock.receivedCommands
        await log.close()
        if let failure { throw failure }
        #expect(commands == startCommands, "\(commands)")
    }

    @Test func stopAfterUnplugIsPrompt() async throws {
        var setup = Setup()
        setup.resume = false
        let outcome = try await withUSBRunner(setup) { rig in
            rig.clock.set(firstAt + 0.01)
            let events = rig.events
            try await eventually { !events.started.isEmpty }
            // Stop right after the unplug, whether or not the runner has noticed it yet.
            await rig.mock.unplug()
            let began = ContinuousClock.now
            try await bounded(.seconds(10)) { await rig.runner.stop() }
            let took = ContinuousClock.now - began
            #expect(took < commandTimeout + .seconds(1), "stop took \(took)")
            // The open hit is closed and logged all the same.
            let row = try #require(try await rig.rows().first)
            #expect(row.hit.endedAt != nil)
        }
        #expect(outcome.commands == startCommands)
        #expect(outcome.events.last == .stopped)
    }

    @Test func noResumeWhenSwitchedOff() async throws {
        var setup = Setup()
        setup.resume = false
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await rig.waitForPush()  // a working connection: only that is resumed
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            _ = try await rig.mock.replug()
            // The push-stall warning would come at the first 1 s tick that is 3 s past the last
            // push (pushes arrive up to the unplug, so by about 4.2 s after it, whatever the
            // tick's phase). Past that: the runner has done nothing more at all.
            try await Task.sleep(for: .milliseconds(4600))
            #expect(events.all == [connectedSDS150, .disconnected(hint: SerialPort.noneFoundHint)])
            #expect(await rig.runner.control() == nil)
            // The replugged mock received nothing.
            #expect(await rig.mock.receivedCommands == startCommands)
        }
        #expect(outcome.commands == startCommands)
        #expect(outcome.events == [connectedSDS150, .disconnected(hint: SerialPort.noneFoundHint), .stopped])
    }

    /// Without `resumeAfterDisconnect` a subscription that stops pushing is not replaced: ending
    /// it would leave the station disconnected for good, where it now stays connected and warns.
    @Test func noResubscribeWhenResumeIsSwitchedOff() async throws {
        var setup = Setup()
        setup.resume = false
        setup.keepAliveInterval = .seconds(2)
        setup.pushLifetime = 10
        setup.lateKeepAliveRevives = false
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            rig.clock.set(period + 0.5)  // past the lifetime; the late KAL does nothing
            let events = rig.events
            try await eventually(.seconds(6)) { events.warnings.contains(StationRunner.stalledMessage) }
            try await Task.sleep(for: .milliseconds(1500))
            #expect(events.warnings == [StationRunner.stalledMessage], "\(events.warnings)")
            #expect(events.disconnects.isEmpty)
            #expect(await rig.runner.control() != nil)
        }
        #expect(outcome.commands.filter { $0 != "KAL" } == startCommands + ["PSI,0"], "\(outcome.commands)")
    }

    @Test func inFlightCommandNotResent() async throws {
        let outcome = try await withUSBRunner { rig in
            await rig.mock.setFaults(MockFaults(dropNextRequest: "KEY"))
            let client = try #require(await rig.runner.control())
            var thrown: (any Error)?
            do { try await client.press(.menu) } catch { thrown = error }
            #expect(thrown as? ScannerClientError == .timeout(command: "KEY"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.mock.receivedCommands.filter { $0.hasPrefix("KEY") } == ["KEY,M,P"])
            #expect(!(await rig.mock.isInMenu))
            // The link is still up and the station keeps running.
            #expect(rig.events.disconnects == [])
            #expect(await rig.runner.control() != nil)
        }
        #expect(outcome.commands.filter { $0.hasPrefix("KEY") } == ["KEY,M,P"])
        #expect(outcome.commands.last == "PSI,0")
    }

    // MARK: Stop in the middle of a resume attempt

    @Test func stopBetweenOpenAndModelSendsNothingMore() async throws {
        var setup = Setup()
        setup.replyDelays = ["MDL": .milliseconds(1200)]
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()  // a working connection: only that is resumed
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            _ = try await rig.mock.replug()
            // The resume attempt has opened the port and asked `MDL`; the answer is held back.
            try await eventually { await rig.received("MDL") == 2 }

            let began = ContinuousClock.now
            try await bounded(.seconds(5)) { await rig.runner.stop() }
            let took = ContinuousClock.now - began
            #expect(took < .milliseconds(700), "stop waited for the MDL reply: \(took)")
            // The attempt's port is closed by the time stop returns, not when the reply would come.
            await rig.expectPortFree()
            // Past the held-back reply: nothing follows it.
            try await Task.sleep(for: .milliseconds(1400))
            #expect(await rig.mock.receivedCommands == startCommands + ["MDL"])
        }
        // The scanner was never confirmed to be ours, so nothing else was sent to it.
        #expect(outcome.commands == startCommands + ["MDL"])
        #expect(outcome.events.filter { if case .connected = $0 { true } else { false } }.count == 1)
    }

    @Test func stopBetweenModelAndPushSendsPSI0() async throws {
        var setup = Setup()
        setup.replyDelays = ["VER": .milliseconds(1200)]
        let outcome = try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()  // a working connection: only that is resumed
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            _ = try await rig.mock.replug()
            // The resume attempt knows it is the same scanner and has asked `VER`.
            try await eventually { await rig.received("VER") == 2 }

            let began = ContinuousClock.now
            try await bounded(.seconds(5)) { await rig.runner.stop() }
            let took = ContinuousClock.now - began
            #expect(took < .milliseconds(700), "stop waited for the VER reply: \(took)")
            await rig.expectPortFree()
            try await Task.sleep(for: .milliseconds(1400))
            #expect(await rig.mock.activeSubscribers == 0)
        }
        // No subscription was started, and the stop still ended with `PSI,0`.
        #expect(outcome.commands == startCommands + ["MDL", "VER", "PSI,0"], "\(outcome.commands)")
        #expect(outcome.events.filter { if case .connected = $0 { true } else { false } }.count == 1)
    }

    @Test func stopAtAnyMomentOfAResumeLeavesNoSubscription() async throws {
        // Stops spread across a resume: before the poll, during the open, `MDL` and `VER` (each
        // answered 30 ms late, so the attempt lasts long enough to land in), `PSI`, and just after.
        // Whatever the moment: what reached the scanner is the start of one normal connection,
        // `PSI,0` is last whenever a subscription was started, and (the harness) no subscription
        // is left running, the port is free and nothing follows `.stopped`.
        var setup = Setup()
        setup.replyDelays = ["MDL": .milliseconds(30), "VER": .milliseconds(30)]
        for step in 0..<14 {
            let delay = Duration.milliseconds(step * 12)
            let outcome = try await withUSBRunner(setup) { rig in
                try await rig.waitForPush()  // a working connection: only that is resumed
                await rig.mock.unplug()
                try await rig.waitForDisconnects(1)
                _ = try await rig.mock.replug()
                try await Task.sleep(for: delay)
                let began = ContinuousClock.now
                try await bounded(.seconds(5)) { await rig.runner.stop() }
                let took = ContinuousClock.now - began
                #expect(took < .seconds(1), "stop took \(took) at step \(step)")
                // No attempt outlives the stop.
                await rig.expectPortFree("step \(step)")
                try await Task.sleep(for: .milliseconds(150))
            }
            #expect(Array(outcome.commands.prefix(startCommands.count)) == startCommands, "step \(step)")
            let resumed = Array(outcome.commands.dropFirst(startCommands.count))
            let sent = resumed.filter { $0 != "PSI,0" }
            #expect(sent == Array(startCommands.prefix(sent.count)), "step \(step): \(resumed)")
            if resumed.contains("PSI,100") {
                #expect(resumed.last == "PSI,0", "step \(step): \(resumed)")
            }
            let connections = outcome.events.filter { if case .connected = $0 { true } else { false } }.count
            #expect(connections == 1 || (connections == 2 && resumed.contains("PSI,100")), "step \(step): \(resumed)")
        }
    }

    // MARK: Only a connection that was working is resumed

    @Test func rejectedPushDisconnectsAndWritesNothingMore() async throws {
        // The scanner answers the first `PSI` with `PSI,NG`: the push stream ends with the port
        // still there, before any push. Resume is on, and must not act.
        var setup = Setup()
        setup.faults = MockFaults(rejectNext: "PSI")
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await rig.waitForDisconnects(1)
            try await eventually { !events.warnings.isEmpty }
            // Many poll intervals later: one disconnect, one warning, and nothing more was written
            // (no `PSI,0`, no reopen, no `MDL`).
            try await Task.sleep(for: .milliseconds(600))
            // The port is still there: the hint isn't "plug the scanner in".
            #expect(events.all == [connectedSDS150, .disconnected(hint: SerialPort.notSendingUpdatesHint),
                                   .warning("the scanner isn't sending status updates; not reconnecting by itself")])
            #expect(await rig.mock.receivedCommands == startCommands)
            #expect(await rig.runner.control() == nil)

            let began = ContinuousClock.now
            try await bounded(.seconds(5)) { await rig.runner.stop() }
            let took = ContinuousClock.now - began
            #expect(took < .seconds(1), "stop took \(took)")
        }
        #expect(outcome.commands == startCommands)
        #expect(outcome.events.filter { if case .disconnected = $0 { true } else { false } }.count == 1)
        #expect(outcome.events.filter { if case .warning = $0 { true } else { false } }.count == 1)
    }

    @Test func rejectedPushWithResumeOffWarnsToo() async throws {
        var setup = Setup()
        setup.resume = false
        setup.faults = MockFaults(rejectNext: "PSI")
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await rig.waitForDisconnects(1)
            try await eventually { !events.warnings.isEmpty }
            try await Task.sleep(for: .milliseconds(300))
            #expect(events.all == [connectedSDS150, .disconnected(hint: SerialPort.notSendingUpdatesHint),
                                   .warning("the scanner isn't sending status updates; not reconnecting by itself")])
        }
        #expect(outcome.commands == startCommands)
    }

    @Test func resumedConnectionWhoseSubscriptionIsRejectedDoesNotResumeAgain() async throws {
        let outcome = try await withUSBRunner { rig in
            let events = rig.events
            // The first connection works, so its loss is followed by a resume...
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            #expect(events.warnings == [])
            // ...but the scanner rejects the resumed connection's `PSI`.
            await rig.mock.setFaults(MockFaults(rejectNext: "PSI"))
            _ = try await rig.mock.replug()
            try await rig.waitForConnections(2)
            try await rig.waitForDisconnects(2)
            try await eventually { !events.warnings.isEmpty }

            // Many poll intervals later, nothing more: the port is there and is left alone.
            try await Task.sleep(for: .milliseconds(600))
            #expect(events.connections.count == 2)
            #expect(events.disconnects == [SerialPort.noneFoundHint, SerialPort.notSendingUpdatesHint])
            #expect(events.warnings == ["the scanner isn't sending status updates; not reconnecting by itself"])
            #expect(events.all.last == .warning("the scanner isn't sending status updates; not reconnecting by itself"))
            #expect(await rig.mock.receivedCommands == startCommands + startCommands)
            #expect(await rig.runner.control() == nil)
        }
        // After the replug: one `MDL`, one `VER`, one `PSI`, and nothing at stop.
        #expect(outcome.commands == startCommands + startCommands, "\(outcome.commands)")
    }

    @Test func connectionLostBeforeItsFirstPushIsNotResumed() async throws {
        // The scanner takes the subscription but never pushes (the mock's stall fault, from the
        // start), then goes away: that connection never worked, so it isn't resumed.
        var setup = Setup()
        setup.faults = MockFaults(stallPSIAfter: 0)
        let outcome = try await withUSBRunner(setup) { rig in
            let events = rig.events
            try await Task.sleep(for: .milliseconds(350))  // several push intervals, no push
            #expect(rig.pushes.count == 0)
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            try await eventually { !events.warnings.isEmpty }
            _ = try await rig.mock.replug()
            try await Task.sleep(for: .milliseconds(500))
            #expect(events.all == [connectedSDS150, .disconnected(hint: SerialPort.noneFoundHint),
                                   .warning("the scanner isn't sending status updates; not reconnecting by itself")])
            // The replugged scanner received nothing.
            #expect(await rig.mock.receivedCommands == startCommands)
        }
        #expect(outcome.commands == startCommands)
    }

    @Test func pushEndWithThePortStillThereClosesItAndReconnects() async throws {
        let outcome = try await withUSBRunner { rig in
            // The connection works; then the app's own client ends the subscription, so the push
            // stream ends with the port still there.
            try await rig.waitForPush()
            let old = try #require(await rig.runner.control())
            try await old.stopPush()
            try await rig.waitForDisconnects(1)
            // The runner closed that connection, though the test still holds the client...
            var thrown: (any Error)?
            do { _ = try await old.modelInfo() } catch { thrown = error }
            #expect(thrown as? ScannerClientError == .notConnected)
            // ...so the port is free for the resume, which gets a new client.
            try await rig.waitForConnections(2)
            let new = try #require(await rig.runner.control())
            #expect(new !== old)
            #expect(rig.events.disconnects == [SerialPort.notSendingUpdatesHint])
            #expect(rig.events.warnings == [])
        }
        #expect(outcome.commands == startCommands + ["PSI,0"] + startCommands + ["PSI,0"], "\(outcome.commands)")
    }

    // MARK: Start

    @Test func stopBeforeTheFirstConnectCompletes() async throws {
        var setup = Setup()
        setup.startRunner = false
        setup.replyDelays = ["MDL": .milliseconds(1200)]
        let outcome = try await withUSBRunner(setup) { rig in
            let starting = Task { try await rig.runner.start() }
            // The port is open and `MDL` is on its way; the answer is held back.
            try await eventually { await rig.received("MDL") == 1 }
            let began = ContinuousClock.now
            try await bounded(.seconds(5)) { await rig.runner.stop() }
            let took = ContinuousClock.now - began
            #expect(took < .milliseconds(700), "stop waited for the MDL reply: \(took)")
            await rig.expectPortFree()
            let result = await starting.result
            #expect(throws: StationRunnerError.stopped) { try result.get() }
            #expect(await rig.runner.control() == nil)
            try await Task.sleep(for: .milliseconds(1400))
        }
        // As on a network station, a stop during start still ends with `PSI,0` (harmless, always safe).
        #expect(outcome.commands == ["MDL", "PSI,0"], "\(outcome.commands)")
        #expect(outcome.events == [.stopped])
    }

    @Test func networkStationWithoutAHostStillThrowsMissingHost() async throws {
        // The factory's `.missingHost` reaches callers as the runner's own error, as before.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-usb-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))
        for host in [nil, "", "  \n"] as [String?] {
            var station = Station()
            station.connection.host = host
            let runner = StationRunner(station: station, device: StationDeviceSettings(stationID: station.id), log: log,
                                       recordingsRoot: dir, cooldownStore: CooldownSpy(),
                                       transportFactory: StationTransportFactory(ports: FakePorts([])))
            let events = EventLog(runner.events)
            var thrown: (any Error)?
            do { try await bounded(.seconds(5)) { try await runner.start() } } catch { thrown = error }
            #expect(thrown as? StationRunnerError == .missingHost, "host \(host ?? "nil"): \(String(describing: thrown))")
            try await eventually(.seconds(2)) { events.isFinished }
            #expect(events.all == [.stopped])
        }
        await log.close()
    }

    @Test func startWithoutAPortThrowsTheHint() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-usb-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var station = Station()
        station.connection.transport = .usbSerial
        var device = StationDeviceSettings(stationID: station.id)
        device.usbPort = dir.appendingPathComponent("no-such-port").path
        let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))
        let cooldown = CooldownSpy()
        let runner = StationRunner(station: station, device: device, log: log, recordingsRoot: dir,
                                   cooldownStore: cooldown, transportFactory: StationTransportFactory(ports: FakePorts([])),
                                   portPollInterval: pollInterval)
        let events = EventLog(runner.events)
        var thrown: (any Error)?
        do { try await bounded(.seconds(5)) { try await runner.start() } } catch { thrown = error }
        #expect(thrown as? StationTransportError == .scannerNotFound(hint: SerialPort.noneFoundHint))
        // A failed start stops the runner: it doesn't wait for the port.
        try await eventually(.seconds(2)) { events.isFinished }
        #expect(events.all == [.stopped])
        #expect(await runner.control() == nil)
        #expect(cooldown.calls == [])
        await log.close()
    }

    // MARK: Audio only where the station and the model have it

    @Test func hasAudioNeedsANetworkStationThatSavesAudio() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-usb-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))

        func hasAudio(_ transport: TransportKind, _ saveAudio: SaveAudio) async -> Bool {
            var station = Station()
            station.connection.transport = transport
            station.connection.host = "192.0.2.10"
            station.recording.saveAudio = saveAudio
            // Never started: nothing is resolved, opened or sent.
            let runner = StationRunner(station: station, device: StationDeviceSettings(stationID: station.id), log: log,
                                       recordingsRoot: dir, cooldownStore: CooldownSpy(),
                                       transportFactory: StationTransportFactory(ports: FakePorts([])))
            let result = await runner.hasAudio
            await runner.stop()
            return result
        }

        #expect(await hasAudio(.network, .everyTransmission))
        #expect(await hasAudio(.network, .onlyNew))
        #expect(!(await hasAudio(.network, .never)))
        #expect(!(await hasAudio(.usbSerial, .everyTransmission)))
        #expect(!(await hasAudio(.usbSerial, .onlyNew)))
        #expect(!(await hasAudio(.bluetooth, .everyTransmission)))
        await log.close()
    }

    @Test func networkModelWithoutNetworkAudioStartsNoAudio() async throws {
        // A network station whose scanner says it is a model with no network audio (loopback mock).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-usb-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var scenario = MockScenario.default
        scenario.model = "SDS100"
        let mock = MockSDS200(scenario: scenario, options: MockSDS200.Options(clock: .stepped(at: 0)))
        let ports = try await mock.start()

        var station = Station()
        station.connection.host = "127.0.0.1"
        station.connection.udpPort = ports.udpPort
        station.connection.rtspPort = ports.rtspPort
        let log = try HitLog(url: dir.appendingPathComponent("hits.sqlite"))
        let cooldown = CooldownSpy()
        let runner = StationRunner(station: station, device: StationDeviceSettings(stationID: station.id), log: log,
                                   recordingsRoot: dir, cooldownStore: cooldown,
                                   transportFactory: StationTransportFactory(ports: FakePorts([])),
                                   audioConfig: AudioSessionConfig(cooldownStore: cooldown),
                                   pushInterval: .milliseconds(100))
        let events = EventLog(runner.events)
        var failure: (any Error)?
        do {
            #expect(await runner.hasAudio)  // not known yet: a network station that saves audio
            try await bounded(.seconds(10)) { try await runner.start() }
            #expect(events.all.first == .connected(model: "SDS100", firmware: "1.26.01"))
            #expect(await runner.hasAudio == false)
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            failure = error
        }
        try await bounded(.seconds(10)) { await runner.stop() }
        try await eventually(.seconds(2)) { events.isFinished }
        let accepted = await mock.rtsp.acceptedConnections
        await mock.stop()
        await log.close()
        if let failure { throw failure }
        #expect(accepted == 0)
        #expect(cooldown.calls == [])
        #expect(!events.all.contains(where: isAudio))
        #expect(await mock.control.receivedCommands.last == "PSI,0")
    }
}

/// `willResume` tells a caller (`noctule log`) whether the runner is going to wait for the scanner
/// after a `.disconnected`. It is set before the event is emitted.
@Suite struct StationRunnerWillResumeTests {
    @Test func willResumeAfterAWorkingConnection() async throws {
        try await withUSBRunner { rig in
            #expect(await rig.runner.willResume == false)  // nothing has disconnected yet
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            #expect(await rig.runner.willResume)
        }
    }

    @Test func willNotResumeAConnectionThatNeverPushed() async throws {
        var setup = Setup()
        setup.faults = MockFaults(stallPSIAfter: 0)
        try await withUSBRunner(setup) { rig in
            try await Task.sleep(for: .milliseconds(350))  // several push intervals, no push
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            #expect(await rig.runner.willResume == false)
        }
    }

    @Test func willNotResumeWhenSwitchedOff() async throws {
        var setup = Setup()
        setup.resume = false
        try await withUSBRunner(setup) { rig in
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            #expect(await rig.runner.willResume == false)
        }
    }

    /// A resumed connection that is lost before its first push isn't resumed again: the flag
    /// follows the latest disconnect.
    @Test func followsTheLatestDisconnect() async throws {
        try await withUSBRunner { rig in
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitForDisconnects(1)
            #expect(await rig.runner.willResume)
            await rig.mock.setFaults(MockFaults(stallPSIAfter: 0))
            _ = try await rig.mock.replug()
            try await rig.waitForConnections(2)
            await rig.mock.unplug()
            try await rig.waitForDisconnects(2)
            #expect(await rig.runner.willResume == false)
        }
    }
}
