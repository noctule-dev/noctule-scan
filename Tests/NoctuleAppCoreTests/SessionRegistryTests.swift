// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleKitTestSupport
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

// SessionRegistry against in-process MockSDS200s on loopback (one per station), with the short
// cooldown from SessionTestSupport, a temporary settings directory and an in-memory cooldown store.
// Every wait is bounded; every test stops the registry and each session it opened (bounded), then
// the mocks, and checks that no mock saw a leaked RTSP session. All names and values are fictional.

@MainActor
final class RegistryRig {
    let registry: SessionRegistry
    let settings: LocalSettingsStore
    let mocks: [MockSDS200]
    let stations: [Station]
    let dir: URL
    var opened: [StationSession] = []

    init(registry: SessionRegistry, settings: LocalSettingsStore, mocks: [MockSDS200], stations: [Station], dir: URL) {
        self.registry = registry; self.settings = settings; self.mocks = mocks
        self.stations = stations; self.dir = dir
    }

    /// `registry.open(_:)`, remembering the session so the rig can stop it however the test ends.
    func open(_ station: Station) -> StationSession {
        let session = registry.open(station)
        if !opened.contains(where: { $0 === session }) { opened.append(session) }
        return session
    }

    func commands(_ i: Int) async -> [String] { await mocks[i].control.receivedCommands }
}

@MainActor
func isConnected(_ session: StationSession) -> Bool {
    if case .connected = session.phase { return true }
    return false
}

@MainActor
func waitConnected(_ session: StationSession, _ limit: Duration = .seconds(10)) async throws {
    try await waitUntil("connected (phase \(session.phase))", limit) { isConnected(session) }
}

@MainActor
func waitStreaming(_ session: StationSession, _ limit: Duration = .seconds(10)) async throws {
    try await waitUntil("streaming (audio \(session.audio))", limit) { session.audio == .streaming }
}

@MainActor
func isInUse(_ session: StationSession) -> Bool {
    if case .inUse = session.phase { return true }
    return false
}

/// Waiting for the cooldown, connecting, connected or stopping: a runner may be live.
@MainActor
func isActive(_ session: StationSession) -> Bool {
    switch session.phase {
    case .idle, .stopped, .noAnswer, .inUse, .scannerInUse: false
    case .waitingForCooldown, .waitingForScanner, .connecting, .connected, .stopping: true
    }
}

/// Polls every 5 ms until stopped: records two active sessions for one station, any `.inUse`,
/// and the most live RTSP sessions and PSI subscribers the mock saw at once.
@MainActor
final class OverlapWatch {
    var violations: [String] = []
    var maxLive = 0
    var maxSubscribers = 0
    private var running = true
    private var task: Task<Void, Never>?

    func start(_ mock: MockSDS200, _ sessions: @escaping @MainActor () -> [StationSession]) {
        task = Task { @MainActor in
            while self.running {
                let current = sessions()
                if current.filter(isActive).count > 1 { self.violations.append("two active: \(current.map(\.phase))") }
                if current.contains(where: isInUse) { self.violations.append("inUse: \(current.map(\.phase))") }
                self.maxLive = max(self.maxLive, await mock.leakedSessions.count)
                self.maxSubscribers = max(self.maxSubscribers, await mock.control.activeSubscribers)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func stop() async {
        running = false
        await task?.value
    }
}

func psiSubscriptions(_ commands: [String]) -> Int {
    commands.filter { $0.uppercased().hasPrefix("PSI,") && $0 != "PSI,0" }.count
}

/// What each mock saw, read after it stopped.
struct RegistryOutcome {
    let leaked: [[String]]
    let commands: [[String]]
}

/// Builds `mocks` mocks and one station per mock, a registry over them, runs `body`, then always
/// stops the registry and every session the test opened (bounded) and the mocks.
@MainActor @discardableResult
func withRegistry(mocks count: Int = 1, replyDelays: [String: Duration] = [:],
                  requestTimeout: Duration = .seconds(1), cooldown: Duration = shortCooldown,
                  mockCooldown: Duration = shortCooldown, cooldownAfter: MockCooldownAfter = .any,
                  prepare: ((InMemoryRTSPCooldownStore) async -> Void)? = nil,
                  _ body: (RegistryRig) async throws -> Void) async throws -> RegistryOutcome {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var mocks: [MockSDS200] = []
    var stations: [Station] = []
    for i in 0..<count {
        let options = MockSDS200.Options(clock: .stepped(at: 1), reconnectCooldown: mockCooldown,
                                         cooldownAfter: cooldownAfter,
                                         rebootDuration: .milliseconds(300), replyDelays: replyDelays)
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        mocks.append(mock)
        var station = Station()
        station.name = "Test Station \(i + 1)"
        station.connection.host = "127.0.0.1"
        station.connection.udpPort = ports.udpPort
        station.connection.rtspPort = ports.rtspPort
        stations.append(station)
    }

    let settings = LocalSettingsStore(directory: dir)
    let cooldownStore = InMemoryRTSPCooldownStore()
    await prepare?(cooldownStore)
    let environment = SessionEnvironment(
        settings: settings, settingsDirectory: dir,
        recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
        cooldownStore: cooldownStore, cooldown: cooldown,
        audioConfig: AudioSessionConfig(requestTimeout: requestTimeout, rtpCloseDelay: .milliseconds(50)),
        makeAudioOutput: { FakeOutput() }, reconnectBackoff: [.milliseconds(200)])
    let registry = SessionRegistry(environment: environment)
    let rig = RegistryRig(registry: registry, settings: settings, mocks: mocks, stations: stations, dir: dir)

    var failure: (any Error)?
    do { try await body(rig) } catch { failure = error }
    // Cleanup: the registry, then each session directly (a stopAll that missed one must not leak it).
    do {
        let done = Done()
        Task { _ = await registry.stopAll(deadline: .seconds(15)); done.value = true }
        try await waitUntil("stopAll in cleanup", .seconds(20)) { done.value }
        for session in rig.opened {
            let stopped = Done()
            Task { await session.stop(); stopped.value = true }
            try await waitUntil("session stop in cleanup", .seconds(15)) { stopped.value }
        }
    } catch {
        if failure == nil { failure = error }
    }
    var leaked: [[String]] = []
    var commands: [[String]] = []
    for mock in mocks {
        await mock.stop()
        leaked.append(await mock.leakedSessions)
        commands.append(await mock.control.receivedCommands)
    }
    if let failure { throw failure }
    return RegistryOutcome(leaked: leaked, commands: commands)
}

// MARK: - USB stations on MockSerialScanners

// SessionRegistry with USB stations against in-process MockSerialScanners (mock SDS150s on
// pseudo-terminals), each behind a link path in the test's temporary directory. Stations save those
// links as their ports, and the environment's port listing is empty, so nothing here can find or
// open a real serial port. Every test stops the registry and each session it opened (bounded), then
// the mocks, and checks that no `PSI` subscription was left running, that no `MSM` or `POF` was
// sent, and that the RTSP cooldown store was never called. All names and values are fictional.

@MainActor
final class USBRegistryRig {
    let registry: SessionRegistry
    let settings: LocalSettingsStore
    let mocks: [MockSerialScanner]
    /// Each mock's link path, by index.
    let links: [String]
    let dir: URL
    var opened: [StationSession] = []

    init(registry: SessionRegistry, settings: LocalSettingsStore, mocks: [MockSerialScanner], links: [String], dir: URL) {
        self.registry = registry; self.settings = settings; self.mocks = mocks
        self.links = links; self.dir = dir
    }

    /// `registry.open(_:)`, remembering the session so the rig can stop it however the test ends.
    func open(_ station: Station) -> StationSession {
        let session = registry.open(station)
        remember(session)
        return session
    }

    /// Remembers a session the registry made by itself (a replacement), for the cleanup.
    func remember(_ session: StationSession) {
        if !opened.contains(where: { $0 === session }) { opened.append(session) }
    }

    /// Saves a USB station named `name` whose device settings name `port` (nil: automatic).
    func addStation(_ name: String, port: String?) async throws -> Station {
        var station = Station()
        station.name = name
        station.connection.transport = .usbSerial
        try await settings.save(station)
        var device = StationDeviceSettings(stationID: station.id)
        device.usbPort = port
        try await settings.saveDeviceSettings(device)
        return station
    }

    /// How many `MDL`s mock `i` has received.
    func mdlCount(_ i: Int) async -> Int {
        await mocks[i].receivedCommands.filter { $0 == "MDL" }.count
    }
}

struct USBRegistryOutcome {
    /// What each mock received, read after the sessions and then the mock stopped.
    let commands: [[String]]
}

/// Builds `count` mock SDS150s behind link paths and a registry over an empty port listing, runs
/// `body`, then always stops the registry and every session the test opened (bounded) and the mocks,
/// and checks what must hold for every USB run.
@MainActor @discardableResult
func withUSBRegistry(mocks count: Int = 1,
                     _ body: (USBRegistryRig) async throws -> Void) async throws -> USBRegistryOutcome {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-usb-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var mocks: [MockSerialScanner] = []
    var links: [String] = []
    for i in 0..<count {
        let link = dir.appendingPathComponent("port-\(i + 1)").path
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 0), personality: .sds150, linkPath: link)
        _ = try await mock.start()
        mocks.append(mock)
        links.append(link)
    }

    let settings = LocalSettingsStore(directory: dir)
    let cooldown = CooldownSpy()
    var environment = SessionEnvironment(
        settings: settings, settingsDirectory: dir,
        recordingsRoot: dir.appendingPathComponent("Recordings", isDirectory: true),
        cooldownStore: cooldown, cooldown: shortCooldown,
        audioConfig: AudioSessionConfig(requestTimeout: .seconds(1), rtpCloseDelay: .milliseconds(50)),
        makeAudioOutput: { FakeOutput() }, reconnectBackoff: [.milliseconds(200)])
    // Always the empty listing: the only ports these sessions can resolve are the saved links.
    environment.serialPorts = FixedSerialPortListing.empty
    environment.portPollInterval = .milliseconds(50)
    let registry = SessionRegistry(environment: environment)
    let rig = USBRegistryRig(registry: registry, settings: settings, mocks: mocks, links: links, dir: dir)

    var failure: (any Error)?
    do { try await body(rig) } catch { failure = error }
    do {
        let done = Done()
        Task { _ = await registry.stopAll(deadline: .seconds(15)); done.value = true }
        try await waitUntil("stopAll in cleanup", .seconds(20)) { done.value }
        for session in rig.opened {
            let stopped = Done()
            Task { await session.stop(); stopped.value = true }
            try await waitUntil("session stop in cleanup", .seconds(15)) { stopped.value }
        }
    } catch {
        if failure == nil { failure = error }
    }
    var commands: [[String]] = []
    var subscribers: [Int] = []
    for mock in mocks {
        await mock.stop()
        commands.append(await mock.receivedCommands)
        subscribers.append(await mock.activeSubscribers)
    }
    if let failure { throw failure }
    #expect(subscribers.allSatisfy { $0 == 0 }, "a PSI subscription was left running: \(subscribers)")
    #expect(!commands.joined().contains { $0.hasPrefix("MSM") || $0.hasPrefix("POF") }, "\(commands)")
    #expect(cooldown.calls == [], "a USB station touched the cooldown store")
    return USBRegistryOutcome(commands: commands)
}

@MainActor
@Suite(.serialized) struct SessionRegistryTests {
    @Test func twoOpensShareOneRunner() async throws {
        let outcome = try await withRegistry { rig in
            let station = rig.stations[0]
            let first = rig.open(station)
            let second = rig.open(station)
            #expect(first === second, "one session per station")
            #expect(rig.registry.session(for: station.id) === first)
            #expect(rig.registry.sessions.count == 1)
            try await waitConnected(first)
            try await waitStreaming(first)
            // A third open after it's running shares it too, and starts nothing new.
            let third = rig.open(station)
            #expect(third === first)
            try await Task.sleep(for: .milliseconds(500))
            let commands = await rig.commands(0)
            #expect(psiSubscriptions(commands) == 1, "commands: \(commands)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1)
            #expect(await rig.mocks[0].control.activeSubscribers == 1)
        }
        #expect(outcome.leaked == [[]])
        #expect(outcome.commands[0].last == "PSI,0")
    }

    @Test func lastReleaseStops() async throws {
        let outcome = try await withRegistry { rig in
            let station = rig.stations[0]
            let session = rig.open(station)
            _ = rig.open(station)
            try await waitConnected(session)
            try await waitStreaming(session)

            await rig.registry.release(station.id)
            try await Task.sleep(for: .milliseconds(300))
            #expect(isConnected(session), "one window still shows it")
            #expect(rig.registry.session(for: station.id) === session)

            await rig.registry.release(station.id)
            #expect(session.phase == .stopped, "the last release awaits the stop")
            #expect(rig.registry.session(for: station.id) == nil)
            #expect(rig.registry.sessions.isEmpty)
            #expect(lockIsFree(station, rig.dir))
            #expect(await rig.mocks[0].leakedSessions == [])
            #expect(await rig.commands(0).last == "PSI,0")

            // Releasing an unknown (or already released) id is a no-op.
            await rig.registry.release(station.id)
            await rig.registry.release(UUID())
            #expect(rig.registry.sessions.isEmpty)
        }
        #expect(outcome.leaked == [[]])
    }

    @Test func stopAllStopsEverySession() async throws {
        let outcome = try await withRegistry(mocks: 2) { rig in
            let a = rig.open(rig.stations[0])
            let b = rig.open(rig.stations[1])
            #expect(a !== b)
            try await waitConnected(a)
            try await waitConnected(b)
            try await waitStreaming(a)
            try await waitStreaming(b)

            let finished = await rig.registry.stopAll()
            #expect(finished)
            #expect(a.phase == .stopped)
            #expect(b.phase == .stopped)
            #expect(rig.registry.sessions.isEmpty)
            #expect(await rig.mocks[0].leakedSessions == [])
            #expect(await rig.mocks[1].leakedSessions == [])
            #expect(await rig.commands(0).last == "PSI,0")
            #expect(await rig.commands(1).last == "PSI,0")
        }
        #expect(outcome.leaked == [[], []])
    }

    /// Ruling: a 1 s deadline against a session whose stop takes longer. The default stays 15 s.
    /// Silent control (the wedge-control fault) does not slow a stop: `PSI,0` is sent without
    /// waiting for a reply. So the mock answers TEARDOWN after 2 s (within the 4 s request
    /// timeout, so the session still ends cleanly), and the stop takes over 2 s.
    @Test func stopAllHonoursDeadline() async throws {
        let outcome = try await withRegistry(replyDelays: ["TEARDOWN": .seconds(2)], requestTimeout: .seconds(4)) { rig in
            let session = rig.open(rig.stations[0])
            try await waitConnected(session)
            try await waitStreaming(session)

            let began = ContinuousClock.now
            let finished = await rig.registry.stopAll(deadline: .seconds(1))
            let elapsed = ContinuousClock.now - began
            #expect(!finished, "the stop outlasted the deadline")
            #expect(elapsed >= .milliseconds(900), "returned after \(elapsed)")
            #expect(elapsed < .seconds(2), "returned after \(elapsed)")
            #expect(session.phase == .stopping, "still stopping")
            #expect(rig.registry.sessions.isEmpty)
            // The session keeps stopping in the background, and still tears down.
            try await waitUntil("the stop to finish", .seconds(15)) { session.phase == .stopped }
            #expect(await rig.mocks[0].leakedSessions == [])
        }
        #expect(outcome.leaked == [[]])
    }

    @Test func editRestartsSession() async throws {
        let outcome = try await withRegistry { rig in
            let station = rig.stations[0]
            let old = rig.open(station)
            try await waitConnected(old)
            try await waitStreaming(old)

            // Unchanged: nothing happens.
            rig.registry.stationsChanged([station])
            #expect(rig.registry.session(for: station.id) === old)

            var edited = station
            edited.name = "Renamed Station"
            rig.registry.stationsChanged([edited])
            let new = try #require(rig.registry.session(for: station.id))
            rig.opened.append(new)
            #expect(new !== old)
            #expect(new.station == edited)
            try await waitUntil("the old session to stop") { old.phase == .stopped }
            try await waitConnected(new)
            try await waitStreaming(new)
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 2)
            #expect(psiSubscriptions(await rig.commands(0)) == 2)
            #expect(await rig.mocks[0].wedgeCount == 0, "the new session waited out the cooldown")

            // The refcount carries over: one open, so one release stops it.
            await rig.registry.release(station.id)
            #expect(new.phase == .stopped)
            #expect(rig.registry.sessions.isEmpty)
        }
        #expect(outcome.leaked == [[]])
        #expect(outcome.commands[0].last == "PSI,0")
    }

    /// Switching the window's view saves `preferredView`; that alone must not restart the session
    /// (a restart is a TEARDOWN and, on hardware, a 120 s cooldown).
    @Test func preferredViewChangeKeepsTheSession() async throws {
        let outcome = try await withRegistry { rig in
            let station = rig.stations[0]
            let session = rig.open(station)
            try await waitConnected(session)
            try await waitStreaming(session)

            var switched = station
            switched.preferredView = station.preferredView == .scanner ? .macStyle : .scanner
            rig.registry.stationsChanged([switched])
            #expect(rig.registry.session(for: station.id) === session, "same session")
            try await Task.sleep(for: .milliseconds(300))
            #expect(isConnected(session))
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1, "no reconnect")
            #expect(!(await rig.commands(0)).contains("PSI,0"), "no stop")

            // A real edit together with a view switch still restarts it.
            var edited = switched
            edited.name = "Renamed Station"
            rig.registry.stationsChanged([edited])
            let fresh = try #require(rig.registry.session(for: station.id))
            rig.opened.append(fresh)
            #expect(fresh !== session)
            #expect(fresh.station == edited)
        }
        #expect(outcome.leaked == [[]])
    }

    /// The reconnect wait is read at the next start: changing it alone neither restarts nor
    /// reconnects an open session, and the session's next start (after a clean stop) uses it.
    /// The full cooldown is 3 s here (the mock's window too, `.unclean`), so a wait would show.
    @Test func cooldownOnlyEditKeepsTheSessionAndTheNextStartUsesIt() async throws {
        let outcome = try await withRegistry(cooldown: .seconds(3), mockCooldown: .seconds(3),
                                             cooldownAfter: .unclean) { rig in
            let station = rig.stations[0]
            let session = rig.open(station)
            try await waitConnected(session)
            try await waitStreaming(session)

            var edited = station
            edited.connection.reconnectCooldownSeconds = 0
            #expect(!SessionRegistry.editRestartsSession(from: station, to: edited))
            rig.registry.stationsChanged([edited])
            #expect(rig.registry.session(for: station.id) === session, "same session")
            #expect(session.station.connection.reconnectCooldownSeconds == 0)
            try await Task.sleep(for: .milliseconds(300))
            #expect(isConnected(session))
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1, "no reconnect")

            await session.stop()
            let began = ContinuousClock.now
            var waited = false
            Task { await session.start() }
            try await waitUntil("connected again") {
                if case .waitingForCooldown = session.phase { waited = true }
                return isConnected(session)
            }
            try await waitStreaming(session)
            #expect(!waited, "no cooldown wait after a clean stop")
            #expect(ContinuousClock.now - began < .seconds(2))
            #expect(await rig.mocks[0].wedgeCount == 0)
        }
        #expect(outcome.leaked == [[]])
    }

    /// Settings › Stations applies key map and color mode edits at once: the open session takes the
    /// new station (so the window's router and palette follow) without a TEARDOWN. A recording rule
    /// change still restarts it, since the runner reads those rules at start.
    @Test func liveChangesUpdateTheSessionWithoutARestart() async throws {
        let outcome = try await withRegistry { rig in
            let station = rig.stations[0]
            let session = rig.open(station)
            try await waitConnected(session)
            try await waitStreaming(session)

            var live = station
            live.keyMap.overrides[FrontPanelKey.avoid.rawValue] = "⌘l"
            live.appearance.colorMode = .whiteOnBlack
            var filter = HitFilter(); filter.name = "Saved elsewhere"
            live.savedFilters = [filter]
            live.countsResetAt = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(!SessionRegistry.editRestartsSession(from: station, to: live))
            rig.registry.stationsChanged([live])
            #expect(rig.registry.session(for: station.id) === session, "same session")
            #expect(session.station == live, "the session shows the edit")
            try await Task.sleep(for: .milliseconds(300))
            #expect(isConnected(session))
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1, "no reconnect")
            #expect(!(await rig.commands(0)).contains("PSI,0"), "no stop")

            var rules = live
            rules.recording.minimumDuration = 2
            #expect(SessionRegistry.editRestartsSession(from: live, to: rules))
            rig.registry.stationsChanged([rules])
            let fresh = try #require(rig.registry.session(for: station.id))
            rig.opened.append(fresh)
            #expect(fresh !== session)
            #expect(fresh.station == rules)
            try await waitUntil("the old session to stop") { session.phase == .stopped }
        }
        #expect(outcome.leaked == [[]])
    }

    /// The editor's connection fields restart an open session (the runner reads them at start):
    /// a move to another scanner's ports connects there, through the cooldown gate. Each
    /// connection field alone is a restart; the name and recording rules too.
    @Test func connectionChangeRestartsTheSession() async throws {
        let outcome = try await withRegistry(mocks: 2) { rig in
            let station = rig.stations[0]
            for edit in [{ (s: inout Station) in s.connection.host = "localhost" },
                         { (s: inout Station) in s.connection.udpPort &+= 1 },
                         { (s: inout Station) in s.connection.rtspPort &+= 1 },
                         { (s: inout Station) in s.connection.modelOverride = .sds150 },
                         { (s: inout Station) in s.connection.transport = .usbSerial },
                         { (s: inout Station) in s.name = "Renamed Station" },
                         { (s: inout Station) in s.recording.saveAudio = .never }] {
                var edited = station
                edit(&edited)
                #expect(SessionRegistry.editRestartsSession(from: station, to: edited), "\(edited)")
            }

            let old = rig.open(station)
            try await waitConnected(old)
            try await waitStreaming(old)
            var moved = station
            moved.connection.udpPort = rig.stations[1].connection.udpPort
            moved.connection.rtspPort = rig.stations[1].connection.rtspPort
            rig.registry.stationChanged(moved)
            let fresh = try #require(rig.registry.session(for: station.id))
            rig.opened.append(fresh)
            #expect(fresh !== old)
            #expect(fresh.station == moved)
            try await waitUntil("the old session to stop") { old.phase == .stopped }
            try await waitConnected(fresh)
            try await waitStreaming(fresh)
            #expect(await rig.commands(0).last == "PSI,0", "the first scanner was let go")
            #expect(await rig.mocks[1].rtsp.acceptedConnections == 1, "the session moved to the second scanner")
        }
        #expect(outcome.leaked == [[], []])
    }

    /// `stationChanged` touches only that station: another open station is left alone even
    /// though it isn't in any list passed along.
    @Test func stationChangedLeavesOtherStationsAlone() async throws {
        let outcome = try await withRegistry(mocks: 2) { rig in
            let a = rig.open(rig.stations[0])
            let b = rig.open(rig.stations[1])
            try await waitConnected(a)
            try await waitConnected(b)
            var live = rig.stations[0]
            live.appearance.colorMode = .blackOnWhite
            rig.registry.stationChanged(live)
            #expect(rig.registry.session(for: rig.stations[0].id) === a)
            #expect(a.station == live)
            #expect(rig.registry.session(for: rig.stations[1].id) === b)
            try await Task.sleep(for: .milliseconds(200))
            #expect(isConnected(a) && isConnected(b))
        }
        #expect(outcome.leaked == [[], []])
    }

    /// QA minor 3: the store writes `stations.json` and then fails on `device.json`. The station
    /// is gone, so its session must stop even though `delete` throws.
    @Test func directoryDeleteStopsTheSessionWhenTheStoreThrowsAfterTheWrite() async throws {
        let outcome = try await withRegistry { rig in
            let station = rig.stations[0]
            try await rig.settings.save(station)
            var device = StationDeviceSettings(stationID: station.id)
            device.recordingsFolder = rig.dir.appendingPathComponent("Elsewhere").path
            try await rig.settings.saveDeviceSettings(device)
            let directory = StationDirectory(settings: rig.settings, registry: rig.registry)
            let session = rig.open(station)
            try await waitConnected(session)

            let deviceFile = rig.dir.appendingPathComponent("device.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: deviceFile.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: deviceFile.path) }
            await #expect(throws: (any Error).self) { try await directory.delete(id: station.id) }
            #expect(try await rig.settings.stations().isEmpty, "stations.json was written")
            #expect(rig.registry.session(for: station.id) == nil)
            try await waitUntil("the deleted station to stop") { session.phase == .stopped }
        }
        #expect(outcome.leaked == [[]])
    }

    /// The picker's Delete: the station's settings go, its open session stops, its hit log stays.
    /// A store that can't be read never reaches the registry (an empty list would stop everything).
    @Test func directoryDeleteStopsTheSessionAndKeepsTheHitLog() async throws {
        let outcome = try await withRegistry(mocks: 2) { rig in
            for s in rig.stations { try await rig.settings.save(s) }
            let directory = StationDirectory(settings: rig.settings, registry: rig.registry)
            let a = rig.open(rig.stations[0])
            let b = rig.open(rig.stations[1])
            try await waitConnected(a)
            try await waitConnected(b)

            let stationsFile = rig.dir.appendingPathComponent("stations.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stationsFile.path)
            await directory.reloadAndApply()
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stationsFile.path)
            #expect(directory.problem != nil)
            #expect(rig.registry.session(for: rig.stations[0].id) === a, "an unreadable store stops nothing")
            #expect(rig.registry.session(for: rig.stations[1].id) === b)

            try await directory.delete(id: rig.stations[0].id)
            #expect(directory.stations.map(\.id) == [rig.stations[1].id])
            #expect(rig.registry.session(for: rig.stations[0].id) == nil)
            try await waitUntil("the deleted station to stop") { a.phase == .stopped }
            #expect(isConnected(b))
            let hitLog = StationSession.hitLogURL(settingsDirectory: rig.dir, stationID: rig.stations[0].id)
            #expect(FileManager.default.fileExists(atPath: hitLog.path), "the hit log is kept")
        }
        #expect(outcome.leaked == [[], []])
    }

    @Test func deletedStationStops() async throws {
        let outcome = try await withRegistry(mocks: 2) { rig in
            let a = rig.open(rig.stations[0])
            let b = rig.open(rig.stations[1])
            try await waitConnected(a)
            try await waitConnected(b)
            rig.registry.stationsChanged([rig.stations[1]])
            #expect(rig.registry.session(for: rig.stations[0].id) == nil)
            #expect(rig.registry.session(for: rig.stations[1].id) === b)
            try await waitUntil("the deleted station to stop") { a.phase == .stopped }
            #expect(isConnected(b))
            #expect(await rig.commands(0).last == "PSI,0")
        }
        #expect(outcome.leaked == [[], []])
    }

    @Test func suspendAndResumeEverySession() async throws {
        let outcome = try await withRegistry(mocks: 2) { rig in
            let a = rig.open(rig.stations[0])
            let b = rig.open(rig.stations[1])
            try await waitConnected(a)
            try await waitConnected(b)
            try await waitStreaming(a)
            try await waitStreaming(b)

            await rig.registry.suspendAll()
            #expect(a.phase == .stopped)
            #expect(b.phase == .stopped)
            #expect(await rig.mocks[0].leakedSessions == [])
            #expect(await rig.mocks[1].leakedSessions == [])
            #expect(await rig.commands(0).last == "PSI,0")
            #expect(await rig.commands(1).last == "PSI,0")
            #expect(rig.registry.sessions.count == 2, "suspended sessions stay open")

            await rig.registry.resumeAll()
            try await waitConnected(a)
            try await waitConnected(b)
            #expect(rig.registry.session(for: rig.stations[0].id) === a)
        }
        #expect(outcome.leaked == [[], []])
    }

    /// Review Focus 2: a reopen while the last release's stop is still in flight (TEARDOWN answered
    /// after 2 s) waits for it: the new session stays `.idle`, never `.inUse`, one RTSP session at most.
    @Test func reopenAfterSlowReleaseWaits() async throws {
        let outcome = try await withRegistry(replyDelays: ["TEARDOWN": .seconds(2)], requestTimeout: .seconds(4)) { rig in
            let station = rig.stations[0]
            let old = rig.open(station)
            try await waitStreaming(old)
            let watch = OverlapWatch()
            var new: StationSession?
            watch.start(rig.mocks[0]) { [old] + (new.map { [$0] } ?? []) }
            let release = Task { await rig.registry.release(station.id) }
            try await waitUntil("the release to drop it") { rig.registry.session(for: station.id) == nil }
            let reopened = rig.open(station)
            new = reopened
            rig.opened.append(reopened)
            #expect(reopened !== old)
            try await Task.sleep(for: .milliseconds(500))
            #expect(old.phase == .stopping, "the old stop is still in flight: \(old.phase)")
            #expect(reopened.phase == .idle, "the new session waits for it: \(reopened.phase)")
            try await waitConnected(reopened, .seconds(15))
            try await waitStreaming(reopened)
            #expect(old.phase == .stopped)
            await release.value
            await watch.stop()
            #expect(watch.violations.isEmpty, "\(watch.violations.prefix(3))")
            #expect(watch.maxLive <= 1, "live RTSP sessions at once: \(watch.maxLive)")
            #expect(watch.maxSubscribers <= 1, "PSI subscribers at once: \(watch.maxSubscribers)")
            #expect(await rig.mocks[0].wedgeCount == 0)
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 2)
        }
        #expect(outcome.leaked == [[]])
    }

    /// Review Focus 2: a reopen after a `stopAll` that missed its deadline waits for that stop.
    @Test func reopenAfterTimedOutStopAllWaits() async throws {
        let outcome = try await withRegistry(replyDelays: ["TEARDOWN": .seconds(2)], requestTimeout: .seconds(4)) { rig in
            let station = rig.stations[0]
            let old = rig.open(station)
            try await waitStreaming(old)
            let watch = OverlapWatch()
            var new: StationSession?
            watch.start(rig.mocks[0]) { [old] + (new.map { [$0] } ?? []) }
            let finished = await rig.registry.stopAll(deadline: .milliseconds(300))
            #expect(!finished)
            #expect(old.phase == .stopping)
            let reopened = rig.open(station)
            new = reopened
            rig.opened.append(reopened)
            try await Task.sleep(for: .milliseconds(500))
            #expect(old.phase == .stopping, "the old stop is still in flight: \(old.phase)")
            #expect(reopened.phase == .idle, "the new session waits for it: \(reopened.phase)")
            try await waitConnected(reopened, .seconds(15))
            try await waitStreaming(reopened)
            await watch.stop()
            #expect(watch.violations.isEmpty, "\(watch.violations.prefix(3))")
            #expect(watch.maxLive <= 1, "live RTSP sessions at once: \(watch.maxLive)")
            #expect(watch.maxSubscribers <= 1, "PSI subscribers at once: \(watch.maxSubscribers)")
            #expect(await rig.mocks[0].wedgeCount == 0)
        }
        #expect(outcome.leaked == [[]])
    }

    /// A sleep while a wake's resume is still waiting out the cooldown (a quick lid close and
    /// open): the suspend interrupts the wait, nothing reconnects afterwards, and the next wake
    /// starts the session again (the app's `PowerGate` runs the suspend without waiting for the
    /// resume; Task 11 QA).
    @Test func suspendDuringResumeCooldownStaysSuspended() async throws {
        let outcome = try await withRegistry { rig in
            let a = rig.open(rig.stations[0])
            try await waitStreaming(a)
            await rig.registry.suspendAll()
            #expect(a.phase == .stopped)

            let resumed = Done()
            Task { await rig.registry.resumeAll(); resumed.value = true }
            try await waitUntil("waiting for the cooldown", .seconds(5)) {
                if case .waitingForCooldown = a.phase { return true }
                return false
            }
            let before = await rig.commands(0).count
            await rig.registry.suspendAll()
            #expect(a.phase == .stopped, "\(a.phase)")
            try await waitUntil("the interrupted resume returns", .seconds(5)) { resumed.value }
            // Well past the 300 ms cooldown: still no traffic, no reconnect.
            try await Task.sleep(for: .seconds(1))
            #expect(a.phase == .stopped, "\(a.phase)")
            let after = await rig.commands(0)
            #expect(after.count == before, "\(after.suffix(5))")
            #expect(await rig.mocks[0].leakedSessions == [])

            await rig.registry.resumeAll()
            try await waitStreaming(a)
        }
        #expect(outcome.leaked == [[]])
    }

    /// Sleep, a dark wake (no full-wake notification, so no resume), sleep again, then a full
    /// wake: the session comes back (Task 11 QA, fix round 3).
    @Test func doubleSuspendThenWakeResumes() async throws {
        let outcome = try await withRegistry { rig in
            let a = rig.open(rig.stations[0])
            try await waitStreaming(a)
            await rig.registry.suspendAll()
            await rig.registry.suspendAll()
            #expect(a.phase == .stopped)
            await rig.registry.resumeAll()
            try await waitStreaming(a, .seconds(5))
        }
        #expect(outcome.leaked == [[]])
    }

    /// Only sessions that were running come back after wake; one that had failed stays as it was.
    /// A session opened while suspended waits for `resumeAll()`.
    @Test func resumeOnlyPreviouslyRunning() async throws {
        let outcome = try await withRegistry(mocks: 2) { rig in
            var dead = Station()
            dead.name = "Dead Station"
            dead.connection.host = "127.0.0.1"
            dead.connection.udpPort = try silentUDPPort()
            let a = rig.open(rig.stations[0])
            let b = rig.open(dead)
            try await waitStreaming(a)
            try await waitUntil("no answer", .seconds(15)) {
                if case .noAnswer = b.phase { return true }
                return false
            }
            let failed = b.phase

            await rig.registry.suspendAll()
            #expect(a.phase == .stopped)
            await rig.registry.resumeAll()
            try await waitStreaming(a)
            try await Task.sleep(for: .seconds(1))
            #expect(b.phase == failed, "a failed session stays as it was: \(b.phase)")

            await rig.registry.suspendAll()
            let c = rig.open(rig.stations[1])
            try await Task.sleep(for: .milliseconds(500))
            #expect(c.phase == .idle, "opened while suspended, it waits for the wake: \(c.phase)")
            #expect(await rig.commands(1).isEmpty)
            await rig.registry.resumeAll()
            try await waitStreaming(a)
            try await waitStreaming(c)
        }
        #expect(outcome.leaked == [[], []])
    }

    // MARK: A retired session stays down (final review C1)

    /// Closing the last window while that station's Reconnect is still tearing down (TEARDOWN
    /// answered after 2 s): the session stays stopped, and the reconnect opens nothing.
    @Test func reconnectThenReleaseStaysStopped() async throws {
        let outcome = try await withRegistry(replyDelays: ["TEARDOWN": .seconds(2)], requestTimeout: .seconds(4)) { rig in
            let station = rig.stations[0]
            let session = rig.open(station)
            try await waitStreaming(session)
            let reconnected = Done()
            Task { await session.reconnect(); reconnected.value = true }
            try await waitUntil("reconnect tearing down", .seconds(5)) { session.phase == .stopping }
            await rig.registry.release(station.id)
            try await waitUntil("reconnect to return", .seconds(10)) { reconnected.value }
            try await Task.sleep(for: .seconds(1))  // well past the 300 ms cooldown
            #expect(session.phase == .stopped, "\(session.phase)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1, "no new RTSP session")
            #expect(await rig.mocks[0].control.activeSubscribers == 0)
            #expect(rig.registry.sessions.isEmpty)
        }
        #expect(outcome.leaked == [[]])
    }

    /// Quit while a Reconnect is still tearing down: `stopAll` reports clean only if nothing is
    /// left running, and the session doesn't connect afterwards.
    @Test func reconnectThenStopAllStaysStopped() async throws {
        let outcome = try await withRegistry(replyDelays: ["TEARDOWN": .seconds(2)], requestTimeout: .seconds(4)) { rig in
            let session = rig.open(rig.stations[0])
            try await waitStreaming(session)
            let reconnected = Done()
            Task { await session.reconnect(); reconnected.value = true }
            try await waitUntil("reconnect tearing down", .seconds(5)) { session.phase == .stopping }
            let finished = await rig.registry.stopAll(deadline: .seconds(15))
            #expect(finished)
            try await waitUntil("reconnect to return", .seconds(10)) { reconnected.value }
            try await Task.sleep(for: .seconds(1))
            #expect(session.phase == .stopped, "\(session.phase)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1, "no new RTSP session")
            #expect(await rig.mocks[0].control.activeSubscribers == 0)
        }
        #expect(outcome.leaked == [[]])
    }

    /// A start that lands while the registry retires an idle session (its stop in flight), and
    /// any start, reconnect, restart or resume after that: nothing reaches the scanner.
    @Test func startWhileRetiringOpensNothing() async throws {
        let outcome = try await withRegistry { rig in
            let station = rig.stations[0]
            await rig.registry.suspendAll()
            let session = rig.open(station)  // held back until the wake: idle
            #expect(session.phase == .idle)
            let release = Task { await rig.registry.release(station.id) }
            let start = Task { await session.start() }
            await release.value
            await start.value
            try await Task.sleep(for: .milliseconds(800))
            #expect(!isActive(session), "\(session.phase)")
            let sent = await rig.commands(0)
            #expect(sent.isEmpty, "\(sent)")

            await session.start()
            await session.reconnect()
            let restart = await session.restartScanner()
            #expect(restart == .notAccepted(StationSession.restartCancelledReason))
            await session.suspend()
            await session.resume()
            await rig.registry.resumeAll()
            try await Task.sleep(for: .milliseconds(800))
            #expect(!isActive(session), "\(session.phase)")
            let sentLater = await rig.commands(0)
            #expect(sentLater.isEmpty, "\(sentLater)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 0)
        }
        #expect(outcome.leaked == [[]])
    }

    // MARK: One session per scanner address (final review I1)

    /// Two stations with the same scanner address (an import that kept both): the second shows
    /// the in-use state and opens nothing, also on Try Again while the first is open or still
    /// stopping (TEARDOWN answered after 1 s); once the first has stopped, Try Again connects it
    /// through the cooldown gate.
    @Test func sameAddressSecondStationIsRefused() async throws {
        let outcome = try await withRegistry(replyDelays: ["TEARDOWN": .seconds(1)], requestTimeout: .seconds(3)) { rig in
            var twin = rig.stations[0]
            twin.id = UUID()
            twin.name = "Test Station 1 (imported)"
            let first = rig.open(rig.stations[0])
            try await waitStreaming(first)
            let refused = SessionPhase.scannerInUse(byStation: rig.stations[0].name)
            let second = rig.open(twin)
            try await Task.sleep(for: .milliseconds(800))
            #expect(second.phase == refused, "\(second.phase)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1)
            #expect(await rig.mocks[0].control.activeSubscribers == 1)
            #expect(psiSubscriptions(await rig.commands(0)) == 1)

            // Try Again while the first is still open: refused again.
            await second.reconnect()
            #expect(second.phase == refused, "\(second.phase)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1)

            // Try Again while the first is still stopping: refused.
            let watch = OverlapWatch()
            watch.start(rig.mocks[0]) { [first, second] }
            let release = Task { await rig.registry.release(rig.stations[0].id) }
            try await waitUntil("the first stopping", .seconds(5)) { first.phase == .stopping }
            await second.reconnect()
            #expect(second.phase == refused, "\(second.phase)")
            await release.value
            #expect(first.phase == .stopped)

            // Try Again once the first has stopped: connects, after the cooldown.
            Task { await second.reconnect() }
            try await waitStreaming(second, .seconds(10))
            await watch.stop()
            #expect(watch.maxLive <= 1, "live RTSP sessions at once: \(watch.maxLive)")
            #expect(watch.maxSubscribers <= 1, "PSI subscribers at once: \(watch.maxSubscribers)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 2)
            #expect(await rig.mocks[0].wedgeCount == 0, "the second waited out the cooldown")
        }
        #expect(outcome.leaked == [[]])
    }

    /// Design §4.5's identity rule, case by case: network stations by normalized host and ports;
    /// USB stations by saved port, an automatic one (nil) conflicting with every USB station; a
    /// network and a USB identity never conflict.
    @Test func identityConflicts() {
        typealias Identity = SessionRegistry.ScannerIdentity
        func conflict(_ x: Identity?, _ y: Identity?) -> Bool {
            guard let x, let y else { return false }
            let forward = x.conflicts(with: y)
            #expect(forward == y.conflicts(with: x), "not symmetric: \(x) / \(y)")
            return forward
        }

        // Network, as today: host ignoring case and surrounding white space, UDP and RTSP port.
        var a = Station()
        a.connection.host = " Scanner.Example.Test \n"
        a.connection.udpPort = 50000
        a.connection.rtspPort = 554
        var b = a
        b.connection.host = "scanner.example.test"
        let net = SessionRegistry.scannerIdentity(of: b, usbPort: nil)
        #expect(net == .network(host: "scanner.example.test", udpPort: 50000, rtspPort: 554))
        #expect(SessionRegistry.scannerIdentity(of: a, usbPort: nil) == net)
        #expect(conflict(SessionRegistry.scannerIdentity(of: a, usbPort: nil), net))
        var otherPort = b
        otherPort.connection.udpPort = 50001
        #expect(!conflict(SessionRegistry.scannerIdentity(of: otherPort, usbPort: nil), net))
        var otherRTSP = b
        otherRTSP.connection.rtspPort = 8554
        #expect(!conflict(SessionRegistry.scannerIdentity(of: otherRTSP, usbPort: nil), net))
        var none = b
        none.connection.host = "  "
        #expect(SessionRegistry.scannerIdentity(of: none, usbPort: nil) == nil)
        // A network station's identity never depends on a port in its device settings.
        #expect(SessionRegistry.scannerIdentity(of: b, usbPort: "/tmp/noctule-test/a") == net)

        // USB: the saved port; nil is automatic, which may resolve to any port.
        var handheld = Station()
        handheld.connection.transport = .usbSerial
        let portA = SessionRegistry.scannerIdentity(of: handheld, usbPort: "/tmp/noctule-test/a")
        let portB = SessionRegistry.scannerIdentity(of: handheld, usbPort: "/tmp/noctule-test/b")
        let automatic = SessionRegistry.scannerIdentity(of: handheld, usbPort: nil)
        #expect(portA == .usb(port: "/tmp/noctule-test/a"))
        #expect(automatic == .usb(port: nil))
        #expect(conflict(automatic, automatic), "two automatic USB stations conflict")
        #expect(!conflict(portA, portB), "two different ports don't")
        #expect(conflict(portA, portA), "the same port does")
        #expect(conflict(portA, automatic), "a saved port and an automatic one do")
        // A host left on a USB station changes nothing: it is told apart by its port.
        var hostLeftOver = handheld
        hostLeftOver.connection.host = "scanner.example.test"
        #expect(SessionRegistry.scannerIdentity(of: hostLeftOver, usbPort: "/tmp/noctule-test/a") == portA)

        // Network against USB: never, whichever port.
        for usb in [portA, portB, automatic] { #expect(!conflict(net, usb)) }

        // Bluetooth: no identity.
        var bluetooth = Station()
        bluetooth.connection.transport = .bluetooth
        #expect(SessionRegistry.scannerIdentity(of: bluetooth, usbPort: nil) == nil)
    }

    /// Two USB stations whose device settings name the same port: the second opens nothing and shows
    /// the in-use state naming the first; the scanner saw one `MDL` in all.
    @Test func secondUSBStationOnTheSamePortIsRefused() async throws {
        try await withUSBRegistry { rig in
            let first = try await rig.addStation("Test Handheld 1", port: rig.links[0])
            let twin = try await rig.addStation("Test Handheld 2", port: rig.links[0])
            let a = rig.open(first)
            try await waitConnected(a)
            let b = rig.open(twin)
            try await waitUntil("the second settles (phase \(b.phase))") { b.phase != .idle && !isActive(b) }
            #expect(b.phase == .scannerInUse(byStation: first.name), "\(b.phase)")
            try await Task.sleep(for: .milliseconds(300))
            let seen = await rig.mocks[0].receivedCommands
            #expect(await rig.mdlCount(0) == 1, "\(seen)")
            #expect(await rig.mocks[0].activeSubscribers == 1)
            #expect(isConnected(a))
        }
    }

    /// The refused second station connects on Try Again once the first has been released (stopped:
    /// its `PSI,0` before the second's `MDL`).
    @Test func secondUSBStationStartsAfterTheFirstCloses() async throws {
        let outcome = try await withUSBRegistry { rig in
            let first = try await rig.addStation("Test Handheld 1", port: rig.links[0])
            let twin = try await rig.addStation("Test Handheld 2", port: rig.links[0])
            let a = rig.open(first)
            try await waitConnected(a)
            let b = rig.open(twin)
            try await waitUntil("the second settles (phase \(b.phase))") { b.phase != .idle && !isActive(b) }
            #expect(b.phase == .scannerInUse(byStation: first.name), "\(b.phase)")

            await rig.registry.release(first.id)
            #expect(a.phase == .stopped)
            Task { await b.reconnect() }
            try await waitConnected(b)
            #expect(await rig.mdlCount(0) == 2)
            #expect(await rig.mocks[0].activeSubscribers == 1)
        }
        let commands = outcome.commands[0]
        let stop = try #require(commands.firstIndex(of: "PSI,0"), "\(commands)")
        let secondMDL = try #require(commands.indices.filter { commands[$0] == "MDL" }.dropFirst().first, "\(commands)")
        #expect(stop < secondMDL, "the second opened before the first's PSI,0: \(commands)")
    }

    /// Two USB stations on different ports are two scanners: both connect, each scanner sees one
    /// `MDL`.
    @Test func twoUSBStationsOnDifferentPortsBothConnect() async throws {
        let outcome = try await withUSBRegistry(mocks: 2) { rig in
            let first = try await rig.addStation("Test Handheld 1", port: rig.links[0])
            let second = try await rig.addStation("Test Handheld 2", port: rig.links[1])
            let a = rig.open(first)
            try await waitConnected(a)
            let b = rig.open(second)
            try await waitConnected(b)
            #expect(isConnected(a))
            #expect(b.usbPort == rig.links[1])
            #expect(await rig.mdlCount(0) == 1)
            #expect(await rig.mdlCount(1) == 1)
            #expect(await rig.mocks[0].activeSubscribers == 1)
            #expect(await rig.mocks[1].activeSubscribers == 1)
        }
        #expect(outcome.commands.allSatisfy { $0.last == "PSI,0" }, "\(outcome.commands)")
    }

    /// A USB station opened while another on its port is still stopping waits for that stop and
    /// then connects; it is never refused. The first's `PSI,0` comes before the second's `MDL`.
    ///
    /// Nothing in a USB stop waits on the scanner (`PSI,0` awaits no reply, and the stop cancels
    /// every read in flight), so no reply delay can hold it the way a slow TEARDOWN holds a network
    /// one: it takes about 30 ms here, too short to catch by polling. So the first is let go of and
    /// the second opened in one main-actor step (`stationDeleted` retires it exactly as a last
    /// `release` does, without awaiting the stop). The test can't flake when the registry is right
    /// (the second waits however long the stop takes); it catches a registry that doesn't wait as
    /// long as the second's start reaches its scanner check before the stop ends (fix round 1).
    @Test func usbStationOpenedWhileAnotherStopsWaitsForIt() async throws {
        let outcome = try await withUSBRegistry { rig in
            let first = try await rig.addStation("Test Handheld 1", port: rig.links[0])
            let twin = try await rig.addStation("Test Handheld 2", port: rig.links[0])
            let a = rig.open(first)
            try await waitConnected(a)

            rig.registry.stationDeleted(first.id)
            #expect(a.isRetired && a.holdsScanner, "the first isn't still stopping: \(a.phase)")
            let b = rig.open(twin)
            var refused = false
            try await waitUntil("the second connected (phase \(b.phase))") {
                if case .scannerInUse = b.phase { refused = true }
                return isConnected(b) || refused
            }
            #expect(!refused, "the second was refused instead of waiting: \(b.phase)")
            #expect(a.phase == .stopped)
            #expect(await rig.mdlCount(0) == 2)
        }
        let commands = outcome.commands[0]
        let stop = try #require(commands.firstIndex(of: "PSI,0"), "\(commands)")
        let secondMDL = try #require(commands.indices.filter { commands[$0] == "MDL" }.dropFirst().first, "\(commands)")
        #expect(stop < secondMDL, "the second opened before the first's PSI,0: \(commands)")
    }

    /// A change to the station's saved port replaces its open session: the old scanner gets `PSI,0`,
    /// the new one a subscription, and the registry holds a new session. With no open session for
    /// the id, nothing happens.
    @Test func portChangeRestartsTheSession() async throws {
        let outcome = try await withUSBRegistry(mocks: 2) { rig in
            let station = try await rig.addStation("Test Handheld", port: rig.links[0])
            let old = rig.open(station)
            try await waitConnected(old)

            var device = try await rig.settings.deviceSettings(for: station.id)
            device.usbPort = rig.links[1]
            try await rig.settings.saveDeviceSettings(device)
            rig.registry.deviceSettingsChanged(station.id)

            let fresh = try #require(rig.registry.session(for: station.id))
            rig.remember(fresh)
            #expect(fresh !== old, "the session was not replaced")
            #expect(old.isRetired)
            try await waitConnected(fresh)
            #expect(old.phase == .stopped)
            #expect(fresh.usbPort == rig.links[1])
            let oldScanner = await rig.mocks[0].receivedCommands
            let newScanner = await rig.mocks[1].receivedCommands
            #expect(oldScanner.last == "PSI,0", "\(oldScanner)")
            #expect(await rig.mocks[0].activeSubscribers == 0)
            #expect(newScanner.contains("PSI,100"), "\(newScanner)")
            #expect(await rig.mocks[1].activeSubscribers == 1)

            // An id with no open session: nothing is made or stopped.
            rig.registry.deviceSettingsChanged(UUID())
            #expect(rig.registry.sessions.count == 1)
            #expect(rig.registry.session(for: station.id) === fresh)
        }
        #expect(outcome.commands[0].filter { $0.hasPrefix("PSI,") && $0 != "PSI,0" }.count == 1, "\(outcome.commands[0])")
        #expect(outcome.commands[1].filter { $0.hasPrefix("PSI,") && $0 != "PSI,0" }.count == 1, "\(outcome.commands[1])")
    }

    /// Two same-address stations opened at once: exactly one connects.
    @Test func sameAddressOpenedTogetherOneConnects() async throws {
        let outcome = try await withRegistry { rig in
            var twin = rig.stations[0]
            twin.id = UUID()
            twin.name = "Test Station 1 (imported)"
            let a = rig.open(rig.stations[0])
            let b = rig.open(twin)
            try await waitUntil("one streaming", .seconds(10)) { a.audio == .streaming || b.audio == .streaming }
            try await Task.sleep(for: .milliseconds(800))
            let phases = [a.phase, b.phase]
            #expect(phases.filter { if case .connected = $0 { return true }; return false }.count == 1, "\(phases)")
            #expect(phases.filter { if case .scannerInUse = $0 { return true }; return false }.count == 1, "\(phases)")
            #expect(await rig.mocks[0].rtsp.acceptedConnections == 1)
            #expect(await rig.mocks[0].control.activeSubscribers == 1)
        }
        #expect(outcome.leaked == [[]])
    }

    /// The launch station is the last one that connected, recorded when its session reaches
    /// `.connected`, not when it is opened.
    @Test func connectRecordsLastStation() async throws {
        // A recent close holds the first start in `.waitingForCooldown` for about a second: opened,
        // not connected, so nothing may be recorded yet.
        let outcome = try await withRegistry(mocks: 2, cooldown: .seconds(1),
                                             prepare: { await $0.recordClosed(host: "127.0.0.1", at: Date()) }) { rig in
            let a = rig.open(rig.stations[0])
            try await waitUntil("waiting for the cooldown", .seconds(5)) {
                if case .waitingForCooldown = a.phase { return true }
                return false
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!isConnected(a))
            #expect(await rig.settings.lastStationID() == nil, "opened but not connected: nothing recorded")
            try await waitConnected(a)
            try await waitUntil("last station recorded") { await rig.settings.lastStationID() == rig.stations[0].id }
            let b = rig.open(rig.stations[1])
            try await waitConnected(b)
            try await waitUntil("last station recorded") { await rig.settings.lastStationID() == rig.stations[1].id }
        }
        #expect(outcome.leaked == [[], []])
    }

    /// A station whose start fails (no answer) never becomes the launch station: the one that
    /// connected before it stays recorded.
    @Test func failedStartDoesNotRecordLastStation() async throws {
        let outcome = try await withRegistry { rig in
            var dead = Station()
            dead.name = "Dead Station"
            dead.connection.host = "127.0.0.1"
            dead.connection.udpPort = try silentUDPPort()
            let b = rig.open(dead)
            try await waitUntil("no answer", .seconds(15)) {
                if case .noAnswer = b.phase { return true }
                return false
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.settings.lastStationID() == nil, "opening alone records nothing")

            let a = rig.open(rig.stations[0])
            try await waitConnected(a)
            try await waitUntil("last station recorded") { await rig.settings.lastStationID() == rig.stations[0].id }
            await rig.registry.release(dead.id)
            let again = rig.open(dead)
            try await waitUntil("no answer again", .seconds(15)) {
                if case .noAnswer = again.phase { return true }
                return false
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.settings.lastStationID() == rig.stations[0].id)
        }
        #expect(outcome.leaked == [[]])
    }

    /// `recordConnected` records only a session the registry still holds and hasn't retired: a
    /// connect reported for a released (retired) session leaves `lastStationID` alone.
    @Test func recordConnectedIgnoresARetiredSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A scanner that never answers: the session sits in `.connecting`, so nothing else records.
        let silent = SimulatedScannerTransport { _ in [] }
        let settings = LocalSettingsStore(directory: dir)
        let environment = SessionEnvironment(settings: settings, settingsDirectory: dir, recordingsRoot: dir,
                                             cooldownStore: InMemoryRTSPCooldownStore(),
                                             makeTransport: { _, _ in silent }, makeAudioOutput: { FakeOutput() })
        let registry = SessionRegistry(environment: environment)
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        let session = registry.open(station)
        try await waitUntil("connecting", .seconds(2)) { session.phase == .connecting }

        // Held: recorded.
        registry.recordConnected(session)
        try await waitUntil("recorded while held") { await settings.lastStationID() == station.id }
        await settings.setLastStationID(nil)

        // Released, so retired and no longer held: not recorded.
        await registry.release(station.id)
        #expect(session.isRetired)
        registry.recordConnected(session)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await settings.lastStationID() == nil)
        _ = await registry.stopAll(deadline: .seconds(5))
    }

    /// A session released before it ever connected doesn't record its station.
    @Test func releasedBeforeConnectDoesNotRecord() async throws {
        let outcome = try await withRegistry { rig in
            let a = rig.open(rig.stations[0])
            await rig.registry.release(rig.stations[0].id)
            try await Task.sleep(for: .milliseconds(800))
            #expect(!isConnected(a))
            #expect(await rig.settings.lastStationID() == nil)
        }
        #expect(outcome.leaked == [[]])
    }
}
