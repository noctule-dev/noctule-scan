// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleKitTestSupport
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

// StationSession against an in-process MockSDS200 on loopback, with a short cooldown (mock and
// session alike), a temporary settings directory, an in-memory cooldown store, and a fake
// AudioOutput. Every wait is bounded; every test stops the session (bounded) and the mock in all
// paths, and checks that the mock saw no leaked RTSP session. All names and values are fictional.

let shortCooldown: Duration = .milliseconds(300)

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` every 20 ms on the main actor until it holds, or throws after `limit`.
@MainActor
func waitUntil(_ what: String, _ limit: Duration = .seconds(10),
                       _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
final class Done { var value = false }

/// Counts what reaches the output. Records chunks however playback was started.
final class FakeOutput: AudioOutput, Sendable {
    struct State {
        var chunks = 0
        var plays = 0
        var stops = 0
        var volume: Float = 1
    }
    let state = Mutex(State())

    var chunks: Int { state.withLock { $0.chunks } }
    var plays: Int { state.withLock { $0.plays } }
    var stops: Int { state.withLock { $0.stops } }

    func play(_ chunks: AsyncStream<AudioChunk>) async throws {
        state.withLock { $0.plays += 1 }
        for await _ in chunks { state.withLock { $0.chunks += 1 } }
    }

    func stop() { state.withLock { $0.stops += 1 } }

    var volume: Float {
        get { state.withLock { $0.volume } }
        set { state.withLock { $0.volume = newValue } }
    }
}

/// Instants of the control commands the mock received, in order.
final class CommandTimes: Sendable {
    let items = Mutex<[(String, ContinuousClock.Instant)]>([])
    func record(_ command: String) { items.withLock { $0.append((command, .now)) } }
    var first: ContinuousClock.Instant? { items.withLock { $0.first?.1 } }
}

struct Setup {
    var cooldown: Duration = shortCooldown
    /// Runs before the session starts (e.g. to record a recent close).
    var prepare: (@Sendable (InMemoryRTSPCooldownStore) async -> Void)? = nil
    /// Point the station's UDP port here instead of the mock's (a closed port).
    var udpPort: UInt16? = nil
    /// The station's host (nil: no address).
    var host: String? = "127.0.0.1"
    /// The session's control retry backoff after wake (short in tests).
    var backoff: [Duration] = [.milliseconds(200)]
    /// `restartScanner()`'s waits (short in tests; the mock reboots in 300 ms).
    var restartTiming = ScannerRestartTiming(timeout: .seconds(10), pollInterval: .milliseconds(200),
                                             silenceGrace: .seconds(3), pollTimeout: .milliseconds(300))
    /// Faults the mock starts with.
    var faults: MockFaults = .none
    /// Mock reply delays by command or RTSP method (e.g. a slow TEARDOWN keeps a stop in flight).
    var replyDelays: [String: Duration] = [:]
    /// The session's RTSP request timeout (longer than any reply delay).
    var requestTimeout: Duration = .seconds(1)
    /// The mock's reconnect hazard window, and which closes start it.
    var mockCooldown: Duration = shortCooldown
    var cooldownAfter: MockCooldownAfter = .any
    /// The station's clean-close reconnect wait (`StationConnection.reconnectCooldownSeconds`).
    var stationCooldownSeconds = 120
    /// How often an open `session.quickKeys` polls, in place of the environment's 2 s.
    var quickKeysPollInterval: Duration? = nil
}

@MainActor
final class Rig {
    let mock: MockSDS200
    let session: StationSession
    let output: FakeOutput
    let store: InMemoryRTSPCooldownStore
    let station: Station
    let dir: URL
    let commandTimes = CommandTimes()
    var startDone: Done?

    init(mock: MockSDS200, session: StationSession, output: FakeOutput, store: InMemoryRTSPCooldownStore,
         station: Station, dir: URL) {
        self.mock = mock; self.session = session; self.output = output; self.store = store
        self.station = station; self.dir = dir
    }

    var clock: MockClock { mock.clock }

    /// Calls `session.start()` in the background (it returns only once connected or failed).
    func start() {
        let done = Done()
        startDone = done
        let session = self.session
        Task { await session.start(); done.value = true }
    }

    var startReturned: Bool { startDone?.value ?? true }

    func stopSession(limit: Duration = .seconds(15)) async throws {
        let done = Done()
        let session = self.session
        Task { await session.stop(); done.value = true }
        try await waitUntil("stop", limit) { done.value }
    }

    var isConnected: Bool {
        if case .connected = session.phase { return true }
        return false
    }

    func waitConnected(_ limit: Duration = .seconds(10)) async throws {
        try await waitUntil("connected (phase \(session.phase))", limit) { self.isConnected }
    }

    func waitStreaming(_ limit: Duration = .seconds(10)) async throws {
        try await waitUntil("audio streaming (audio \(session.audio))", limit) { self.session.audio == .streaming }
    }

    var commands: [String] { get async { await mock.control.receivedCommands } }
}

struct Outcome {
    let leaked: [String]
    let commands: [String]
    let phase: SessionPhase
}

/// Builds a mock and a session, runs `body`, then always stops the session (bounded), waits for a
/// start in flight to return, and stops the mock.
@MainActor @discardableResult
func withSession(_ setup: Setup = Setup(), _ body: (Rig) async throws -> Void) async throws -> Outcome {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let options = MockSDS200.Options(clock: .stepped(at: 1), reconnectCooldown: setup.mockCooldown,
                                     cooldownAfter: setup.cooldownAfter,
                                     rebootDuration: .milliseconds(300), replyDelays: setup.replyDelays)
    let mock = MockSDS200(scenario: .default, faults: setup.faults, options: options)
    let ports = try await mock.start()

    var station = Station()
    station.name = "Test Station"
    station.connection.host = setup.host
    station.connection.udpPort = setup.udpPort ?? ports.udpPort
    station.connection.rtspPort = ports.rtspPort
    station.connection.reconnectCooldownSeconds = setup.stationCooldownSeconds

    let store = InMemoryRTSPCooldownStore()
    await setup.prepare?(store)
    let output = FakeOutput()
    var environment = SessionEnvironment(
        settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
        recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
        cooldownStore: store, cooldown: setup.cooldown,
        audioConfig: AudioSessionConfig(requestTimeout: setup.requestTimeout, rtpCloseDelay: .milliseconds(50)),
        makeAudioOutput: { output }, reconnectBackoff: setup.backoff, restartTiming: setup.restartTiming)
    if let interval = setup.quickKeysPollInterval { environment.quickKeysPollInterval = interval }
    let session = StationSession(station: station, environment: environment)
    let rig = Rig(mock: mock, session: session, output: output, store: store, station: station, dir: dir)
    let times = rig.commandTimes
    await mock.control.setCommandObserver { times.record($0) }

    var failure: (any Error)?
    do { try await body(rig) } catch { failure = error }
    do {
        try await rig.stopSession()
        try await waitUntil("start() to return") { rig.startReturned }
    } catch {
        if failure == nil { failure = error }
    }
    await mock.stop()
    let outcome = Outcome(leaked: await mock.leakedSessions, commands: await mock.control.receivedCommands,
                          phase: session.phase)
    if let failure { throw failure }
    return outcome
}

/// A loopback UDP port that never answers: a socket bound to it and held, never read, until the
/// test process exits. Binding a port and closing it again (as this helper used to) left the port
/// free for a mock starting at the same moment to bind and answer: CI run 44958491347 saw
/// `StationEditorModelTests.testConnectionNoAnswer` get `.ok(SDS200)` from such a port. A
/// datagram to a held port is queued and ignored, so a request times out, as it would at a closed
/// port (where an ICMP refusal also ends in a timeout).
func silentUDPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    try #require(fd >= 0)  // held until the process exits: see above
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    try #require(bound)
    return UInt16(bigEndian: addr.sin_port)
}

func lockIsFree(_ station: Station, _ dir: URL) -> Bool {
    guard let lock = try? StationLock.acquire(stationID: station.id, settingsDirectory: dir) else { return false }
    lock.release()
    return true
}

func stsCount(_ commands: [String]) -> Int {
    commands.filter { $0.uppercased() == "STS" }.count
}


/// How many control commands the mock has received so far: a mark for `menuCommands(_:since:)`.
func commandMark(_ mock: MockSDS200) async -> Int {
    await mock.control.receivedCommands.count
}

/// The mock's received `KEY`, `MSV` and `MSI` commands since `mark` (`commandMark(_:)`), in order.
func menuCommands(_ mock: MockSDS200, since mark: Int = 0) async -> [String] {
    await mock.control.receivedCommands.dropFirst(mark).filter { command in
        let name = command.uppercased()
        return ["KEY", "MSV", "MSI"].contains { name == $0 || name.hasPrefix($0 + ",") }
    }
}

/// A cooldown store that records every call made to it. A USB station must make none.
final class CooldownSpy: RTSPCooldownStore {
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

// MARK: - A USB station on MockSerialScanner

// StationSession on a USB station, against an in-process MockSerialScanner (a mock SDS150 on a
// pseudo-terminal) behind a link path in the test's temporary directory. The station's saved port
// is that link, and the environment's port listing is empty, so nothing here can find or open a
// real serial port: while the mock is unplugged (or not started) the link is gone and the session
// finds nothing at all. Scenario time is a stepped clock; pushes, polls and reply delays run in
// real time, so every wait is a bounded poll. Every test stops the session (bounded) and the mock,
// and checks that no `PSI` subscription was left running, that no `MSM` or `POF` was ever sent, and
// that the RTSP cooldown store was never called. All names and values are fictional.

/// The default scenario's first transmission (scenario seconds): talkgroup 1201.
let usbFirstTransmissionAt = 2.0

struct USBSetup {
    /// Start the mock before the session (false: the station opens unplugged).
    var startMock = true
    var faults: MockFaults = .none
    /// The mock's reply delays by command name (real time).
    var replyDelays: [String: Duration] = [:]
    /// The session's keep-alive interval in place of the model's 60 s.
    var keepAliveInterval: Duration? = nil
    /// The mock's push lifetime (scenario seconds) in place of the SDS150's 183.
    var pushLifetime: Double? = nil
    var transport: TransportKind = .usbSerial
    /// The session's battery reading interval in place of the environment's 60 s.
    var batteryPollInterval: Duration? = nil
    /// The mock's personality (`pushLifetime` is applied on top of it).
    var personality: MockPersonality = .sds150
    /// The station's model override (nil: none).
    var modelOverride: ScannerModel? = nil
    /// The input saved in the station's device settings (nil: none).
    var lineIn: LineInConfig? = nil
    /// The environment's line-in factory (tests: `FakeLineInSources`; nil: none).
    var lineInSources: LineInSourceFactory? = nil
    /// The environment's `onWarning`.
    var onWarning: (@Sendable (_ station: String, _ text: String) -> Void)? = nil
    /// Line-in playback goes to `USBRig.lineInOutput` (`makeLineInAudioOutput`) instead of
    /// `output`, which then gets nothing.
    var separateLineInOutput = false
    /// How often an open `session.quickKeys` polls, in place of the environment's 2 s.
    var quickKeysPollInterval: Duration? = nil
}

/// Every line-in source a factory made, so a test's end can check that each was stopped.
final class LineInSourceLog: Sendable {
    private let made = Mutex<[any LineInSource]>([])
    var sources: [any LineInSource] { made.withLock { $0 } }
    func wrap(_ factory: @escaping LineInSourceFactory) -> LineInSourceFactory {
        { [self] config in
            let source = factory(config)
            made.withLock { $0.append(source) }
            return source
        }
    }
}

@MainActor
final class USBRig {
    let mock: MockSerialScanner
    /// The station's port: the mock's link path.
    let link: String
    let session: StationSession
    let output: FakeOutput
    /// Where line-in playback goes with `USBSetup.separateLineInOutput`.
    let lineInOutput: FakeOutput
    let cooldown: CooldownSpy
    let station: Station
    let dir: URL
    /// The session's environment, for a registry of the test's own on the same mock.
    let environment: SessionEnvironment
    var startDone: Done?

    init(mock: MockSerialScanner, link: String, session: StationSession, output: FakeOutput, lineInOutput: FakeOutput,
         cooldown: CooldownSpy, station: Station, dir: URL, environment: SessionEnvironment) {
        self.mock = mock; self.link = link; self.session = session; self.output = output
        self.lineInOutput = lineInOutput
        self.cooldown = cooldown; self.station = station; self.dir = dir; self.environment = environment
    }

    var clock: MockClock { mock.clock }

    /// Calls `session.start()` in the background (it returns only once connected, failed, or stopped).
    func start() {
        let done = Done()
        startDone = done
        let session = self.session
        Task { await session.start(); done.value = true }
    }

    var startReturned: Bool { startDone?.value ?? true }

    func stopSession(limit: Duration = .seconds(15)) async throws {
        let done = Done()
        let session = self.session
        Task { await session.stop(); done.value = true }
        try await waitUntil("stop", limit) { done.value }
    }

    var isConnected: Bool {
        if case .connected = session.phase { return true }
        return false
    }

    var isWaitingForScanner: Bool {
        if case .waitingForScanner = session.phase { return true }
        return false
    }

    func waitConnected(_ limit: Duration = .seconds(10)) async throws {
        try await waitUntil("connected (phase \(session.phase))", limit) { self.isConnected }
    }

    /// Waits for the first push of the current connection (`info`), which a resume needs.
    func waitForPush(_ limit: Duration = .seconds(10)) async throws {
        try await waitUntil("a push (info)", limit) { self.session.info != nil }
    }

    func waitPhase(_ phase: SessionPhase, _ limit: Duration = .seconds(10)) async throws {
        try await waitUntil("phase \(phase) (now \(session.phase))", limit) { self.session.phase == phase }
    }

    /// Every command the mock received so far (across every plug-in), oldest first.
    var commands: [String] { get async { await mock.receivedCommands } }

    /// How many commands named `name` (with or without arguments) the mock has received.
    func received(_ name: String) async -> Int {
        await mock.receivedCommands.filter { $0 == name || $0.hasPrefix(name + ",") }.count
    }

    /// The commands received since `mark` (a `commands.count` taken earlier).
    func commands(since mark: Int) async -> [String] {
        Array(await mock.receivedCommands.dropFirst(mark))
    }

    /// A second mock scanner behind the same link, answering `MDL` with `model` (start it after the
    /// first is unplugged; stop it yourself).
    func otherScanner(reporting model: String) -> MockSerialScanner {
        var personality = MockPersonality.sds150
        personality.reportedModel = model
        return MockSerialScanner(scenario: .default, clock: clock, personality: personality, linkPath: link)
    }
}

struct USBOutcome {
    /// Every command the mock received, read after the session and then the mock stopped.
    let commands: [String]
    /// `PSI` subscriptions still running when the mock stopped (after the session had).
    let subscribers: Int
    let phase: SessionPhase
    let cooldownCalls: [String]
}

/// Builds a mock SDS150 behind a link path and a session for a USB station saved on that path,
/// runs `body`, then always stops the session (bounded), waits for a start in flight to return,
/// stops the mock, and checks what must hold for every USB run: no subscription left, no `MSM` or
/// `POF`, no call on the cooldown store.
@MainActor @discardableResult
func withUSBSession(_ setup: USBSetup = USBSetup(), _ body: (USBRig) async throws -> Void) async throws -> USBOutcome {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-usb-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var personality = setup.personality
    if let lifetime = setup.pushLifetime { personality.pushLifetime = lifetime }
    let link = dir.appendingPathComponent("port").path
    let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 0), personality: personality,
                                 linkPath: link, replyDelays: setup.replyDelays)
    await mock.setFaults(setup.faults)
    if setup.startMock { _ = try await mock.start() }

    var station = Station()
    station.name = "Test Handheld"
    station.connection.transport = setup.transport
    station.connection.modelOverride = setup.modelOverride
    let settings = LocalSettingsStore(directory: dir)
    try await settings.save(station)
    var device = StationDeviceSettings(stationID: station.id)
    device.usbPort = link
    if let lineIn = setup.lineIn {
        device.audioInputDevice = lineIn.deviceUID
        device.audioInputName = lineIn.deviceName
        device.audioInputChannel = lineIn.channel
    }
    try await settings.saveDeviceSettings(device)

    let cooldown = CooldownSpy()
    let output = FakeOutput()
    var environment = SessionEnvironment(
        settings: settings, settingsDirectory: dir,
        recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
        cooldownStore: cooldown, cooldown: shortCooldown,
        audioConfig: AudioSessionConfig(requestTimeout: .seconds(1), rtpCloseDelay: .milliseconds(50)),
        makeAudioOutput: { output }, reconnectBackoff: [.milliseconds(200)])
    // Always the empty listing: the only port this session can ever resolve is the saved link.
    environment.serialPorts = FixedSerialPortListing.empty
    environment.portPollInterval = .milliseconds(50)
    environment.keepAliveInterval = setup.keepAliveInterval
    if let interval = setup.batteryPollInterval { environment.batteryPollInterval = interval }
    if let interval = setup.quickKeysPollInterval { environment.quickKeysPollInterval = interval }
    let lineIns = LineInSourceLog()
    environment.lineInSources = setup.lineInSources.map { lineIns.wrap($0) }
    environment.onWarning = setup.onWarning
    let lineInOutput = FakeOutput()
    if setup.separateLineInOutput { environment.makeLineInAudioOutput = { lineInOutput } }
    let session = StationSession(station: station, environment: environment)
    let rig = USBRig(mock: mock, link: link, session: session, output: output, lineInOutput: lineInOutput,
                     cooldown: cooldown, station: station, dir: dir, environment: environment)

    var failure: (any Error)?
    do { try await body(rig) } catch { failure = error }
    do {
        try await rig.stopSession()
        try await waitUntil("start() to return") { rig.startReturned }
    } catch {
        if failure == nil { failure = error }
    }
    await mock.stop()
    let outcome = USBOutcome(commands: await mock.receivedCommands, subscribers: await mock.activeSubscribers,
                             phase: session.phase, cooldownCalls: cooldown.calls)
    if let failure { throw failure }
    #expect(outcome.subscribers == 0, "a PSI subscription was left running")
    let running = lineIns.sources.compactMap { $0 as? FakeLineInSource }.filter { !$0.stopped }
    #expect(running.isEmpty, "a line-in source was left running: \(running.map(\.config))")
    #expect(!outcome.commands.contains { $0.hasPrefix("MSM") || $0.hasPrefix("POF") }, "\(outcome.commands)")
    #expect(outcome.cooldownCalls == [], "a USB station touched the cooldown store")
    if setup.lineIn == nil || setup.lineInSources == nil {
        #expect(rig.output.plays == 0, "a USB station with no line-in started playback")
    }
    return outcome
}
