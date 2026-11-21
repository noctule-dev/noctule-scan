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

@MainActor
@Suite(.serialized) struct StationSessionTests {
    @Test func connectsAndShowsLiveState() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            guard case .connected(let model, let firmware) = rig.session.phase else {
                Issue.record("phase \(rig.session.phase)"); return
            }
            #expect(model == "SDS200")
            #expect(firmware == "1.26.01")
            try await waitUntil("info") { rig.session.info != nil }
            try await waitUntil("display") { rig.session.display != nil }
            #expect(rig.session.display?.softKeys.count == 3)
            try await rig.waitStreaming()
            try await waitUntil("start() to return") { rig.startReturned }
        }
        #expect(outcome.leaked == [])
        #expect(outcome.phase == .stopped)
    }

    @Test func stopTearsDownAndReleases() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            #expect(!lockIsFree(rig.station, rig.dir), "the session holds the station lock while running")
            try await rig.stopSession()
            #expect(rig.session.phase == .stopped)
            #expect(lockIsFree(rig.station, rig.dir), "stop releases the station lock")
            #expect(await rig.mock.leakedSessions == [])
            let commands = await rig.commands
            #expect(commands.contains("PSI,0"))
            #expect(commands.last == "PSI,0", "commands: \(commands.suffix(5))")
            // Idempotent: a second stop changes nothing and sends nothing.
            let before = commands.count
            try await rig.stopSession()
            #expect(await rig.commands.count == before)
            #expect(rig.session.phase == .stopped)
        }
        #expect(outcome.leaked == [])
        #expect(outcome.commands.last == "PSI,0")
    }

    /// The battery (`GCS`) is a USB model's: a network SDS200 never gets one (Plan 8 Task 6).
    @Test func networkStationSendsNoGCS() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("display") { rig.session.display != nil }
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.session.battery == nil)
            #expect(rig.session.batteryTask == nil)
        }
        #expect(!outcome.commands.contains { $0.uppercased().hasPrefix("GCS") }, "\(outcome.commands)")
        #expect(outcome.leaked == [])
    }

    @Test func waitsOutCooldownFirst() async throws {
        var setup = Setup()
        setup.cooldown = .seconds(2)
        setup.prepare = { await $0.recordClosed(host: "127.0.0.1", at: Date()) }
        let outcome = try await withSession(setup) { rig in
            let began = ContinuousClock.now
            rig.start()
            var seen: [Int] = []
            try await waitUntil("connected after the cooldown", .seconds(10)) {
                if case .waitingForCooldown(let left) = rig.session.phase {
                    if seen.last != left { seen.append(left) }
                    #expect(await rig.commands.isEmpty, "no control traffic during the wait")
                    #expect(await rig.mock.rtsp.acceptedConnections == 0, "no RTSP traffic during the wait")
                }
                return rig.isConnected
            }
            #expect(seen == [2, 1], "countdown: \(seen)")
            let first = try #require(rig.commandTimes.first)
            #expect(first - began >= .milliseconds(1900), "first command after \(first - began)")
            try await rig.waitStreaming()
        }
        #expect(outcome.leaked == [])
        #expect(outcome.commands.last == "PSI,0")
    }

    // MARK: The station's reconnect wait (Plan 5 Task 2)

    /// A station with a 0 s reconnect wait, a 3 s full cooldown, and a mock that arms its hazard
    /// only after unclean closes (`--cooldown-after unclean`).
    private static func cleanZeroSetup() -> Setup {
        var setup = Setup()
        setup.cooldown = .seconds(3)
        setup.mockCooldown = .seconds(3)
        setup.cooldownAfter = .unclean
        setup.stationCooldownSeconds = 0
        return setup
    }

    /// Starts `rig` and returns whether the session showed a cooldown wait before connecting.
    private static func startAndWatch(_ rig: Rig) async throws -> Bool {
        var waited = false
        rig.start()
        try await waitUntil("connected", .seconds(10)) {
            if case .waitingForCooldown = rig.session.phase { waited = true }
            return rig.isConnected
        }
        try await rig.waitStreaming()
        return waited
    }

    @Test func cleanStopRestartsWithoutACooldownWait() async throws {
        let outcome = try await withSession(Self.cleanZeroSetup()) { rig in
            #expect(try await !Self.startAndWatch(rig))
            try await rig.stopSession()
            #expect(await rig.store.lastClose(host: "127.0.0.1")?.clean == true)
            let began = ContinuousClock.now
            #expect(try await !Self.startAndWatch(rig), "no wait after a clean stop")
            #expect(ContinuousClock.now - began < .seconds(2))
            #expect(await rig.mock.wedgeCount == 0)
        }
        #expect(outcome.leaked == [])
    }

    /// After an unclean close (a power cycle drops the connection) the full cooldown applies,
    /// whatever the station's setting.
    @Test func uncleanStopWaitsTheFullCooldown() async throws {
        let outcome = try await withSession(Self.cleanZeroSetup()) { rig in
            #expect(try await !Self.startAndWatch(rig))
            await rig.mock.powerCycle()
            try await waitUntil("an unclean close") { await rig.store.lastClose(host: "127.0.0.1")?.clean == false }
            try await rig.stopSession()
            #expect(await rig.store.lastClose(host: "127.0.0.1")?.clean == false)
            let began = ContinuousClock.now
            #expect(try await Self.startAndWatch(rig), "the full cooldown after an unclean close")
            #expect(ContinuousClock.now - began >= .seconds(1), "waited \(ContinuousClock.now - began)")
            #expect(await rig.mock.wedgeCount == 0)
        }
        #expect(outcome.leaked == [])
    }

    @Test func stopDuringCooldownWaitSendsNothing() async throws {
        var setup = Setup()
        setup.cooldown = .seconds(5)
        setup.prepare = { await $0.recordClosed(host: "127.0.0.1", at: Date()) }
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await waitUntil("waiting for the cooldown") {
                if case .waitingForCooldown = rig.session.phase { return true }
                return false
            }
            let began = ContinuousClock.now
            try await rig.stopSession(limit: .seconds(2))
            #expect(ContinuousClock.now - began < .seconds(1), "stop interrupts the wait")
            try await waitUntil("start() to return", .seconds(2)) { rig.startReturned }
            #expect(rig.session.phase == .stopped)
            #expect(lockIsFree(rig.station, rig.dir))
        }
        #expect(outcome.commands == [])
        #expect(outcome.leaked == [])
    }

    @Test func secondProcessLockGivesInUse() async throws {
        let outcome = try await withSession { rig in
            // Another open file description holds the lock (flock is per description).
            let held = try StationLock.acquire(stationID: rig.station.id, settingsDirectory: rig.dir)
            defer { held.release() }
            rig.start()
            try await waitUntil("in use") { rig.startReturned }
            #expect(rig.session.phase == .inUse(pid: getpid()))
            let logURL = rig.dir.appendingPathComponent("Stations/\(rig.station.id.uuidString)/hits.sqlite")
            #expect(!FileManager.default.fileExists(atPath: logURL.path), "nothing is opened")
            #expect(await rig.commands.isEmpty)
        }
        #expect(outcome.commands == [])
        #expect(outcome.phase == .inUse(pid: getpid()), "stop keeps the failure visible")
    }

    @Test func noAnswerOnDeadHost() async throws {
        let port = try silentUDPPort()
        var setup = Setup()
        setup.udpPort = port
        let outcome = try await withSession(setup) { rig in
            let began = ContinuousClock.now
            rig.start()
            try await waitUntil("no answer", .seconds(3)) {
                if case .noAnswer = rig.session.phase { return true }
                return false
            }
            #expect(ContinuousClock.now - began < .seconds(3))
            let expected = "No answer from 127.0.0.1:\(port). Check the address, your VPN, and that Noctule Scan is allowed under Privacy & Security › Local Network."
            #expect(rig.session.phase == .noAnswer(expected))
            #expect(StationSession.noAnswerMessage(host: "127.0.0.1", port: port) == expected)
            try await waitUntil("start() to return", .seconds(2)) { rig.startReturned }
            #expect(lockIsFree(rig.station, rig.dir), "a failed start releases the lock")
        }
        #expect(outcome.commands == [], "the mock's port wasn't used")
        #expect(outcome.leaked == [])
    }

    @Test func listeningTogglesPlaybackOnly() async throws {
        let outcome = try await withSession { rig in
            #expect(rig.session.listening, "listening is on by default")
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            try await waitUntil("chunks reach the output") { rig.output.chunks > 10 }

            rig.session.listening = false
            try await Task.sleep(for: .milliseconds(300))
            let chunksOff = rig.output.chunks
            let packetsOff = rig.session.packets
            #expect(rig.output.stops >= 1, "turning listening off stops the output")
            try await Task.sleep(for: .seconds(1))
            #expect(rig.output.chunks == chunksOff, "no chunks reach the output while not listening")
            #expect(rig.session.packets > packetsOff + 10, "the session keeps receiving audio")
            #expect(rig.isConnected)
            #expect(rig.session.audio == .streaming)

            rig.session.listening = true
            try await waitUntil("chunks again") { rig.output.chunks > chunksOff + 10 }
            #expect(rig.output.plays == 2)
            #expect(await rig.mock.rtsp.acceptedConnections == 1, "playback never reconnects audio")
        }
        #expect(outcome.leaked == [])
        #expect(outcome.commands.last == "PSI,0")
    }

    /// The app's own playback level reaches the output (set before playback starts, and live),
    /// clamped to 0...1, and never touches the scanner's volume.
    @Test func appVolumeForwardsToTheOutput() async throws {
        let outcome = try await withSession { rig in
            #expect(rig.session.appVolume == 1, "full volume by default")
            rig.session.appVolume = 0.25
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            try await waitUntil("playback") { rig.output.plays >= 1 }
            #expect(rig.output.volume == 0.25, "a level set before playback applies to the new output")
            rig.session.appVolume = 0.6
            #expect(rig.output.volume == 0.6)
            rig.session.appVolume = 3
            #expect(rig.session.appVolume == 1)
            #expect(rig.output.volume == 1)
            rig.session.appVolume = -1
            #expect(rig.session.appVolume == 0)
            #expect(rig.output.volume == 0)
            rig.session.appVolume = .nan
            #expect(rig.session.appVolume == 0)
            #expect(!(await rig.commands).contains { $0.hasPrefix("VOL,") }, "app volume isn't the scanner's")
        }
        #expect(outcome.leaked == [])
    }

    /// On the SDS200 (`minInterval` 100 ms) a read of the screen follows each screen change, so the
    /// reads track the 10 changes below, not the ~50 pushes that arrive at `PSI,100`.
    @Test func stsRateBounded() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("display") { rig.session.display != nil }
            let before = stsCount(await rig.commands)
            // Change the screen every 0.5 s for 5 s: two transmissions and idle, in turn.
            let moments: [Double] = [3, 10, 1]
            for step in 0..<10 {
                rig.clock.set(moments[step % moments.count])
                try await Task.sleep(for: .milliseconds(500))
            }
            let fetched = stsCount(await rig.commands) - before
            #expect((8...12).contains(fetched), "STS sent \(fetched) times in 5 s")
        }
        #expect(outcome.leaked == [])
        #expect(outcome.commands.last == "PSI,0")
    }

    @Test func noAddressSaysSo() async throws {
        var setup = Setup()
        setup.host = nil
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await waitUntil("start() to return", .seconds(3)) { rig.startReturned }
            #expect(rig.session.phase == .noAnswer("Test Station has no address."))
            #expect(lockIsFree(rig.station, rig.dir))
        }
        #expect(outcome.commands == [])
        #expect(outcome.phase == .noAnswer("Test Station has no address."))
    }

    /// A `.connected` event from the current runner that lands after the registry retired the
    /// session (`markRetired()` is synchronous; the stop flag is set later, inside the stop's task)
    /// never moves the phase or calls `onConnected`, so a retired station is never recorded.
    @Test func connectedAfterRetireIgnored() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let silent = SimulatedScannerTransport { _ in [] }
        let output = FakeOutput()
        let environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: InMemoryRTSPCooldownStore(),
                                             makeTransport: { _, _ in silent }, makeAudioOutput: { output })
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        let session = StationSession(station: station, environment: environment)
        var connectedCalls = 0
        session.onConnected = { _ in connectedCalls += 1 }
        let done = Done()
        Task { await session.start(); done.value = true }
        try await waitUntil("the runner", .seconds(2)) { session.runner != nil && session.phase == .connecting }

        session.markRetired()
        session.handle(.connected(model: "SDS200", firmware: "1.26.01"), from: session.runner)
        #expect(session.phase == .connecting, "\(session.phase)")
        #expect(connectedCalls == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(output.plays == 0, "no live loops for a retired session")
        await session.stop()
        try await waitUntil("start() to return", .seconds(5)) { done.value }
        #expect(connectedCalls == 0)
    }

    /// A `.connected` event that isn't from the current runner (a late event drained while a failed
    /// start tears down, or a stale runner's) never moves the phase or starts the live loops.
    @Test func connectedFromAnotherRunnerIgnored() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A scanner that never answers: the runner sits in MDL (phase .connecting) for 2 s.
        let silent = SimulatedScannerTransport { _ in [] }
        let output = FakeOutput()
        let environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: InMemoryRTSPCooldownStore(),
                                             makeTransport: { _, _ in silent }, makeAudioOutput: { output })
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        let session = StationSession(station: station, environment: environment)
        let done = Done()
        Task { await session.start(); done.value = true }
        try await waitUntil("the runner", .seconds(2)) { session.runner != nil && session.phase == .connecting }

        let otherLog = try HitLog(url: dir.appendingPathComponent("other.sqlite"))
        let other = StationRunner(station: station, device: StationDeviceSettings(stationID: station.id), log: otherLog,
                                  recordingsRoot: dir, cooldownStore: InMemoryRTSPCooldownStore(),
                                  transportFactory: StationTransportFactory(ports: FixedSerialPortListing.empty,
                                                                            makeNetworkTransport: { _, _ in silent }))
        session.handle(.connected(model: "SDS200", firmware: "1.26.01"), from: other)
        session.handle(.connected(model: "SDS200", firmware: "1.26.01"))
        #expect(session.phase == .connecting)
        session.handle(.audio(.streaming), from: other)
        session.handle(.audio(.failed("stale")))
        #expect(session.audio == .idle, "a stale runner's audio state doesn't count")
        try await Task.sleep(for: .milliseconds(300))
        #expect(output.plays == 0, "no live loops for a stale .connected")
        await session.stop()
        try await waitUntil("start() to return", .seconds(5)) { done.value }
        await otherLog.close()
        #expect(output.plays == 0)
    }

    /// Every warning the session adds is handed to `environment.onWarning` with the station's name,
    /// in order (the app writes them to stderr).
    @Test func warningsAreReported() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: InMemoryRTSPCooldownStore(),
                                             makeAudioOutput: { FakeOutput() })
        let reported = Mutex<[String]>([])
        environment.onWarning = { station, text in reported.withLock { $0.append("\(station)|\(text)") } }
        var station = Station()
        station.name = "Test Station"
        let session = StationSession(station: station, environment: environment)
        session.handle(.warning("first"))
        session.handle(.warning("second"))
        #expect(reported.withLock { $0 } == ["Test Station|first", "Test Station|second"])
        #expect(session.warnings == ["first", "second"])
        await session.stop()
    }

    /// The line the app writes for a warning: local time to the second, the station, the text.
    @Test func warningLogLine() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let at = Date(timeIntervalSince1970: 1_794_591_012)  // 2026-11-13 09:30:12 PST
        #expect(SessionWarningLog.line(station: "Test Station", text: "the scanner stopped", at: at, timeZone: zone)
                == "NoctuleScan: 09:30:12 warning: Test Station: the scanner stopped")
    }

    @Test func recentHitsCappedAt50() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let environment = SessionEnvironment(settings: LocalSettingsStore(directory: dir), settingsDirectory: dir,
                                             recordingsRoot: dir, cooldownStore: InMemoryRTSPCooldownStore(),
                                             makeAudioOutput: { FakeOutput() })
        let session = StationSession(station: Station(), environment: environment)
        func hit(_ i: Int) -> LoggedHit {
            LoggedHit(hit: Hit(id: UUID(), key: HitKey(system: "Testville", talkgroupID: "\(i)", frequencyMHz: nil),
                               startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                               startInstant: .now, channel: "Channel \(i)"),
                      audioPath: nil, audioError: nil, isNew: false)
        }
        let hits = (0..<60).map(hit)
        for h in hits { session.handle(.hitStarted(h)) }
        #expect(session.recentHits.count == 50)
        #expect(session.recentHits.first == hits[59], "newest first")
        #expect(session.recentHits.last == hits[10])

        // An end replaces the started hit in place, by id.
        var ended = hits[30]
        ended.hit.endedAt = ended.hit.startedAt.addingTimeInterval(2)
        ended.audioPath = "/tmp/x.wav"
        session.handle(.hitEnded(ended))
        #expect(session.recentHits.count == 50)
        let index = try #require(session.recentHits.firstIndex { $0.hit.id == ended.hit.id })
        #expect(index == 29)
        #expect(session.recentHits[index] == ended)

        for i in 0..<25 { session.handle(.warning("warning \(i)")) }
        #expect(session.warnings.count == 20)
        #expect(session.warnings.last == "warning 24")
        #expect(session.warnings.first == "warning 5")

        await session.stop()
        #expect(session.phase == .stopped)
    }
}
