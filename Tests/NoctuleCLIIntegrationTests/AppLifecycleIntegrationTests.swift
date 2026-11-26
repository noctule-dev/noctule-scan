// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import NoctuleKit
import NoctuleStore
import Testing

// The `NoctuleScan` app executable against the `noctule-mock-scanner` executable, both launched
// as subprocesses on loopback. The app gets a temporary settings directory (pre-seeded with one
// fictional station at the mock's ports, set as the last station), a temporary recordings
// folder, a private cooldown store and a 1 s cooldown, all through the test-only environment
// overrides; it never sees the owner's settings. A GUI app launched this way shows its window
// briefly. Every wait is bounded, and every subprocess is stopped (then killed) on every path.

/// Launches the app on a mock, waits until audio plays, sends `signal`, and checks the orderly
/// stop: the app exits within 15 s, and before it does the mock has seen TEARDOWN and `PSI,0`;
/// at the end the mock reports no leaked session (Review Focus 1). With `sheet`, the station
/// window presents a sheet first (`NOCTULE_TEST_PRESENT_SHEET`): AppKit then refuses
/// `terminate`, and the app must still stop the session and exit 0. With `menu`, the test puts the
/// mock's scanner into its menu (`KEY,M,P` from a second UDP client) and waits until the app has
/// read the menu (`MSI`) before the signal; quitting must send the scanner nothing more: the
/// mock's log then holds exactly the test's own `KEY` and no `MSV` (Plan 6, remote-menus design 5.6).
private func appTearsDown(on signal: Int32, sheet: Bool = false, menu: Bool = false) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appending(path: "settings")
    let recordings = root.appending(path: "recordings")
    let cooldownStore = root.appending(path: "cooldown.json")

    let mock = try await MockScanner.launch(["--cooldown-seconds", "1"])
    var app: Subprocess?
    do {
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        station.connection.udpPort = mock.udpPort
        station.connection.rtspPort = mock.rtspPort
        let store = LocalSettingsStore(directory: settings)
        try await store.save(station)
        await store.setLastStationID(station.id)

        var environment = [
            "NOCTULE_SETTINGS_DIR": settings.path,
            "NOCTULE_RECORDINGS_DIR": recordings.path,
            "NOCTULE_COOLDOWN_STORE": cooldownStore.path,
            "NOCTULE_COOLDOWN_SECONDS": "1",
        ]
        if sheet { environment["NOCTULE_TEST_PRESENT_SHEET"] = "1" }
        let launched = try Subprocess(try builtBinary("NoctuleScan"), [], environment: environment)
        app = launched
        let playing = await mock.process.waitForStderr(within: 30) { $0.contains("rtsp: PLAY") }
        guard playing else {
            Issue.record("mock never saw PLAY; mock: \(mock.process.stderr) app: \(launched.stderr)")
            throw CocoaError(.featureUnsupported)
        }

        if sheet {
            let shown = await launched.waitForStderr(within: 15) { $0.contains("test sheet presented") }
            guard shown else {
                Issue.record("the app never presented the test sheet; app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
        }
        if menu {
            sendUDP("KEY,M,P\r", toPort: mock.udpPort)
            let read = await mock.process.waitForStderr(within: 15) { $0.contains("control: MSI") }
            guard read else {
                Issue.record("the app never read the menu (MSI); mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
        }
        launched.send(signal)
        let exited = await launched.waitForExit(within: 15)
        // What the mock had seen by the time the app was gone.
        let seen = mock.process.stderr
        launched.kill()
        let result = await launched.finish()
        app = nil
        #expect(exited, "the app didn't exit within 15 s; app: \(result.stderr)")
        // A signal-initiated quit goes through `NSApp.terminate`, which exits 0 (AGENTS.md).
        #expect(result.status == 0, "exit status \(result.status); app: \(result.stderr)")
        #expect(seen.contains("rtsp: TEARDOWN"), "mock: \(seen) app: \(result.stderr)")
        #expect(seen.contains("control: PSI,0"), "mock: \(seen) app: \(result.stderr)")
        if let teardown = seen.range(of: "rtsp: TEARDOWN"), let play = seen.range(of: "rtsp: PLAY") {
            #expect(play.lowerBound < teardown.lowerBound)
        }
        if menu {
            let lines = seen.split(separator: "\n").map(String.init)
            let keys = lines.filter { $0.contains("control: KEY") }
            #expect(keys.count == 1, "expected only the test's KEY,M,P; mock: \(seen)")
            #expect(!lines.contains { $0.contains("control: MSV") }, "mock: \(seen)")
        }
        let record = (try? String(contentsOf: cooldownStore, encoding: .utf8)) ?? ""
        #expect(record.contains("127.0.0.1"), "cooldown store: \(record)")
    } catch let error as CocoaError where error.code == .featureUnsupported {
        // Already recorded.
    } catch {
        Issue.record(error)
    }
    if let app {
        app.kill()
        _ = await app.finish()
    }
    let result = await mock.shutdown()
    #expect(result.exited && result.status == 0, "\(result.stderr)")
    #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
}

/// One datagram to the mock's control port from a throwaway client.
private func sendUDP(_ text: String, toPort port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bytes = Array(text.utf8)
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

// MARK: A USB station (Plan 8 Task 11)
//
// **Hardware safety.** The owner's real SDS150 may be plugged into this Mac. Every launch of the
// app below goes through `USBAppRun.launchApp`, which always passes a private settings directory
// whose only station is one USB station whose saved port is the mock's link in the test's own
// temporary directory (checked before launch), the USB detection kill-switch, a private
// recordings folder and cooldown store, and a decoy port listing, and launches the app from that
// directory. A saved port never falls back to a detected one (Plan 8 Task 4), and with the
// kill-switch the app's listing is empty, so the only port the app can open is the mock's.

/// One run of the app on a USB station: a temporary directory holding the mock's link (the
/// station's saved port; nothing is there until a mock starts), the seeded settings, recordings, a
/// cooldown store a USB station must never create, and a decoy "detected" port.
private struct USBAppRun {
    let root: URL
    let stationID: UUID
    /// A short directory of its own for the mock's headphone jack: a Unix-domain socket's path
    /// must fit in 104 bytes, and one under `root` doesn't.
    let jackRoot: URL
    var link: URL { root.appending(path: "port") }
    /// The mock's `--line-out` socket (nothing is there until a mock serves it).
    var jack: URL { jackRoot.appending(path: "jack.sock") }
    var settings: URL { root.appending(path: "settings") }
    var recordings: URL { root.appending(path: "recordings") }
    var cooldownStore: URL { root.appending(path: "cooldown.json") }
    var decoy: URL { root.appending(path: "decoy-port") }

    /// Seeds the settings: the one USB station "Test Handheld" on the link, set as the last
    /// station (`app.json`), its port (and `lineIn`, a fictional audio input, when given) saved
    /// before the station (as the editor and the CLI do). Then reads them back and requires exactly that.
    static func make(lineIn: (uid: String, name: String)? = nil) async throws -> USBAppRun {
        let root = try temporaryDirectory()
        let jackRoot = FileManager.default.temporaryDirectory.appending(path: "nl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: jackRoot, withIntermediateDirectories: true)
        var station = Station()
        station.name = "Test Handheld"
        station.connection.transport = .usbSerial
        let run = USBAppRun(root: root, stationID: station.id, jackRoot: jackRoot)
        do {
            var device = StationDeviceSettings(stationID: station.id)
            device.usbPort = run.link.path
            if let lineIn {
                device.audioInputDevice = lineIn.uid
                device.audioInputName = lineIn.name
                device.audioInputChannel = .both
            }
            let store = LocalSettingsStore(directory: run.settings)
            try await store.saveDeviceSettings(device)
            try await store.save(station)
            await store.setLastStationID(station.id)

            let stations = try await store.stations()
            try #require(stations.map(\.id) == [station.id], "\(stations)")
            try #require(stations[0].connection.transport == .usbSerial)
            let saved = try await store.deviceSettings(for: station.id).usbPort
            try #require(saved == run.link.path && saved?.hasPrefix(root.path + "/") == true, "\(saved ?? "nil")")
            try #require(await store.lastStationID() == station.id)
        } catch {
            run.cleanUp()
            throw error
        }
        return run
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: jackRoot)
    }

    /// What every launch gets, whatever else a test adds (these win).
    var safetyEnvironment: [String: String] {
        [
            "NOCTULE_SETTINGS_DIR": settings.path,
            "NOCTULE_NO_USB_DETECTION": "1",
            "NOCTULE_RECORDINGS_DIR": recordings.path,
            "NOCTULE_COOLDOWN_STORE": cooldownStore.path,
            // Ignored under the kill-switch; were that ever broken, the listing is this path.
            "NOCTULE_TEST_SERIAL_PORTS": decoy.path,
        ]
    }

    /// The one place this suite launches the app on a USB station: the safety environment (plus
    /// `extra`), from the temporary directory.
    func launchApp(extra: [String: String] = [:]) throws -> Subprocess {
        let environment = extra.merging(safetyEnvironment) { _, safe in safe }
        try #require(environment["NOCTULE_NO_USB_DETECTION"] == "1"
                     && environment["NOCTULE_SETTINGS_DIR"]?.hasPrefix(root.path + "/") == true)
        return try Subprocess(try builtBinary("NoctuleScan"), [], environment: environment, currentDirectory: root)
    }

    /// Whether process `pid` holds the station's lock, which a session takes when it starts,
    /// before it looks for the port (a station the app refused to run never takes it). Tried
    /// with a non-blocking `flock`; a lock this takes is released at once. Only once the app has
    /// taken it, or after the app is gone: a probe while the app starts could take the lock just
    /// as the app tries to (`waitForLock` waits without locking).
    func lockIsHeld(by pid: Int32) -> Bool {
        do {
            let lock = try StationLock.acquire(stationID: stationID, settingsDirectory: settings)
            lock.release()
            return false
        } catch {
            return error == .inUse(pid: pid)
        }
    }

    /// Waits at most `seconds` for process `pid` to hold the station's lock: first for its pid in
    /// the lock file (which the holder writes once it has the lock; read without locking), then
    /// one `lockIsHeld`.
    func waitForLock(by pid: Int32, within seconds: Double) async -> Bool {
        let url = StationLock.lockURL(stationID: stationID, settingsDirectory: settings)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == pid { return lockIsHeld(by: pid) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// The files named like the cooldown store (the store, its lock); a USB station creates none.
    var cooldownFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("cooldown") }
    }

    /// Every WAV under the recordings folder, symlinks resolved.
    var recordedFiles: [String] {
        guard let walk = FileManager.default.enumerator(at: recordings, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { ($0 as? URL)?.resolvingSymlinksInPath() }
            .filter { $0.pathExtension == "wav" }.map(\.path).sorted()
    }

    /// The station's hit log as it stands (`Stations/<id>/hits.sqlite`), or nil before the app has
    /// made it (this never creates it) or while it can't be read.
    func loggedHits() async -> [LoggedHit]? {
        let url = settings.appending(path: "Stations").appending(path: stationID.uuidString).appending(path: "hits.sqlite")
        guard FileManager.default.fileExists(atPath: url.path), let log = try? HitLog(url: url) else { return nil }
        return try? await log.transmissions(HitFilter())
    }

    /// Waits at most `seconds` for a logged hit that has ended and satisfies `condition`.
    func waitForEndedHit(within seconds: Double, _ condition: (LoggedHit) -> Bool) async -> LoggedHit? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let hit = await loggedHits()?.first(where: { $0.hit.endedAt != nil && condition($0) }) { return hit }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }
}

/// SIGTERM to the app, then waits at most `limit` s for it to exit. Returns whether it did, its
/// status and stderr, and `log()` (the mock's log) as it stood once the app was gone.
private func terminate(_ app: Subprocess, within limit: Double, log: () -> String) async
    -> (exited: Bool, status: Int32, stderr: String, seen: String) {
    app.send(SIGTERM)
    let exited = await app.waitForExit(within: limit)
    let seen = log()
    app.kill()
    let result = await app.finish()
    return (exited, result.status, result.stderr, seen)
}

/// The lines of a mock's log, for ordering checks.
private func logLines(_ log: String) -> [String] { log.components(separatedBy: "\n") }

/// Commands the app must never send a USB scanner.
private func forbidden(_ commands: [String]) -> [String] {
    commands.filter { command in ["MSM", "POF", "KEY", "MSV"].contains { command.hasPrefix($0) } }
}

/// Waits at most `seconds` for `condition` on the mock's log.
private func waitForLog(_ mock: SerialMock, within seconds: Double, _ condition: ([String]) -> Bool) async -> Bool {
    await mock.process.waitForStderr(within: seconds) { condition(logLines($0)) }
}

/// The open files `lsof` lists for `pid` (nil if it couldn't run). `lsof` reads the kernel's
/// tables; it opens none of the listed files.
private func openFiles(of pid: Int32) async -> String? {
    guard let lsof = try? Subprocess(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-n", "-P", "-p", "\(pid)"]) else { return nil }
    let exited = await lsof.waitForExit(within: 10)
    lsof.kill()
    let result = await lsof.finish()
    return exited && result.status == 0 ? result.stdout : nil
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct AppLifecycleIntegrationTests {
    @Test func appTearsDownOnSIGTERM() async throws {
        try await appTearsDown(on: SIGTERM)
    }

    @Test func appTearsDownOnSIGHUP() async throws {
        try await appTearsDown(on: SIGHUP)
    }

    /// A sheet makes AppKit refuse `terminate`; the signal must still stop the session and exit.
    @Test func appTearsDownOnSIGTERMWithASheetOpen() async throws {
        try await appTearsDown(on: SIGTERM, sheet: true)
    }

    /// Quitting while the scanner is in a menu: the app has read the menu, and sends nothing more
    /// to it (no Menu key to leave it, no `MSV`). The log can't tell senders apart, so the test's
    /// own `KEY,M,P` is the one `KEY` allowed.
    @Test func quitWhileScannerIsInAMenu() async throws {
        try await appTearsDown(on: SIGTERM, menu: true)
    }

    // MARK: A USB station on the serial mock

    /// The app runs the USB station (subscription, display, battery), and SIGTERM ends it in
    /// order: exit 0 within 15 s, `PSI,0` the last command, no subscription left on the mock, no
    /// state-changing or forbidden command, and no cooldown record.
    @Test func usbAppTearsDownOnSIGTERM() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        let mock = try await SerialMock.launch(link: run.link)
        var app: Subprocess?
        do {
            let launched = try run.launchApp()
            app = launched
            let subscribed = await waitForLog(mock, within: 30) { $0.contains("control: PSI,100") }
            guard subscribed else {
                Issue.record("the mock never saw PSI,100; mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            // The display and the battery are read once connected.
            let read = await waitForLog(mock, within: 10) { $0.contains("control: STS") && $0.contains("control: GCS") }
            #expect(read, "mock: \(mock.process.stderr)")
            let stopped = await terminate(launched, within: 15) { mock.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            let seen = SerialMock.commands(in: stopped.seen)
            #expect(seen.last == "PSI,0", "\(seen)")
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        await mock.shutdown()  // `active-subscriptions=0`
        let commands = mock.commands
        #expect(Array(commands.prefix(3)) == ["MDL", "VER", "PSI,100"], "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(commands.filter { $0 == "PSI,100" }.count == 1, "\(commands)")
        #expect(forbidden(commands) == [], "\(commands)")
        #expect(commands.contains("STS") && commands.contains("GCS"), "\(commands)")
        #expect(run.cooldownFiles == [], "\(run.cooldownFiles)")
    }

    /// No scanner behind the saved port: the app starts the session (it holds the station's
    /// lock), waits, opens no serial device, and quits at once on SIGTERM. A mock started behind
    /// the link afterwards hears nothing (Review Focus 1, 2). Only the launch's guards keep the
    /// app off the real scanner here; `launchApp` requires them.
    @Test func usbAppWaitsForTheScannerAndQuitsCleanly() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        var linkInfo = stat()
        try #require(lstat(run.link.path, &linkInfo) != 0, "something is already at \(run.link.path)")
        var app: Subprocess?
        do {
            let launched = try run.launchApp()
            app = launched
            let pid = launched.process.processIdentifier
            let started = await run.waitForLock(by: pid, within: 30)
            guard started else {
                Issue.record("the app never started the station (its lock is free); app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            try? await Task.sleep(for: .seconds(3))
            #expect(launched.isRunning, "app: \(launched.stderr)")
            #expect(run.lockIsHeld(by: pid), "the session ended while waiting; app: \(launched.stderr)")
            let files = await openFiles(of: pid)
            #expect(files?.contains("NoctuleScan") == true, "lsof: \(files ?? "didn't run")")
            #expect(files.map { !$0.contains("/dev/cu.") && !$0.contains("usbmodem") } == true,
                    "the app has a serial device open: \(files ?? "")")
            let stopped = await terminate(launched, within: 5) { "" }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 5 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(!run.lockIsHeld(by: pid))
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        let mock = try await SerialMock.launch(link: run.link)
        try? await Task.sleep(for: .seconds(2))
        await mock.shutdown()
        #expect(mock.commands == [], "\(mock.process.stderr)")
        #expect(run.cooldownFiles == [], "\(run.cooldownFiles)")
    }

    /// The scanner goes away 4 s after the mock starts and comes back 3 s later: the app waits
    /// and connects again (a second `MDL` and `PSI,100` after the replug), then SIGTERM ends the
    /// new subscription. The app starts first and waits for the port, so it is connected well
    /// before the unplug however long it takes to launch.
    @Test func usbAppResumesAfterAReplug() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        var app: Subprocess?
        var mock: SerialMock?
        do {
            let launched = try run.launchApp()
            app = launched
            let started = await run.waitForLock(by: launched.process.processIdentifier, within: 30)
            guard started else {
                Issue.record("the app never started the station (its lock is free); app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            let scanner = try await SerialMock.launch(link: run.link, ["--fault", "unplug-after-psi=2:3"])  // counted from the app's PSI
            mock = scanner
            let resumed = await waitForLog(scanner, within: 20) { lines in
                guard let replug = lines.firstIndex(where: { $0.hasPrefix("mock: plugged in again") }) else { return false }
                let after = lines[replug...]
                return after.contains("control: MDL") && after.contains("control: PSI,100")
            }
            #expect(resumed, "mock: \(scanner.process.stderr) app: \(launched.stderr)")
            let stopped = await terminate(launched, within: 15) { scanner.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(SerialMock.commands(in: stopped.seen).last == "PSI,0", "\(stopped.seen)")
            // The first connection was made before the unplug.
            let lines = logLines(stopped.seen)
            if let unplug = lines.firstIndex(where: { $0.hasPrefix("mock: unplugged") }) {
                #expect(lines[..<unplug].contains("control: PSI,100"), "\(stopped.seen)")
            } else {
                Issue.record("the mock never unplugged: \(stopped.seen)")
            }
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        if let mock {
            await mock.shutdown()  // `active-subscriptions=0`
            let commands = mock.commands
            #expect(commands.filter { $0 == "MDL" }.count == 2, "\(commands)")
            #expect(commands.filter { $0 == "PSI,100" }.count == 2, "\(commands)")
            #expect(commands.last == "PSI,0", "\(commands)")
            #expect(forbidden(commands) == [], "\(commands)")
        }
        #expect(run.cooldownFiles == [], "\(run.cooldownFiles)")
    }

    /// The mock's pushes stop 2 s after the `PSI` or the latest `KAL`; with the test override's
    /// 0.5 s keep-alive the app's one subscription runs on: after 8 s (four lifetimes; about
    /// sixteen `KAL`s) at least six `KAL`s and no second `PSI,100` (kept, not replaced). Nothing
    /// follows `PSI,0` at the quit.
    @Test func usbAppKeepsItsSubscriptionAlive() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        let mock = try await SerialMock.launch(link: run.link, ["--push-lifetime", "2"])
        var app: Subprocess?
        do {
            let launched = try run.launchApp(extra: ["NOCTULE_TEST_KEEPALIVE_SECONDS": "0.5"])
            app = launched
            let subscribed = await waitForLog(mock, within: 30) { $0.contains("control: PSI,100") }
            guard subscribed else {
                Issue.record("the mock never saw PSI,100; mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            #expect(launched.stderr.contains("NoctuleScan: test override: NOCTULE_TEST_KEEPALIVE_SECONDS=0.5 "),
                    "app: \(launched.stderr)")
            try? await Task.sleep(for: .seconds(8))
            let during = mock.commands
            #expect(during.filter { $0 == "KAL" }.count >= 6, "\(during)")
            #expect(during.filter { $0 == "PSI,100" }.count == 1, "\(during)")
            #expect(!during.contains("PSI,0"), "\(during)")
            let stopped = await terminate(launched, within: 15) { mock.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        await mock.shutdown()  // `active-subscriptions=0`
        let commands = mock.commands
        #expect(commands.filter { $0 == "PSI,100" }.count == 1, "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        if let stop = commands.lastIndex(of: "PSI,0") {
            #expect(!commands[stop...].contains("KAL"), "\(commands)")
        }
        #expect(forbidden(commands) == [], "\(commands)")
    }

    /// An SDS100 has no `KAL`: the app renews the subscription's own `PSI,100` (every 0.5 s here,
    /// by the test override) against a mock whose pushes stop 2 s after the latest `PSI`. After
    /// 6 s the mock has seen several `PSI,100`, and the quit's `PSI,0` is last, with nothing
    /// after it and no `KAL`, `GCS`, `MSM`, `POF`, `KEY` or `MSV` anywhere.
    @Test func usbAppKeepsAnSDS100Pushing() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        let mock = try await SerialMock.launch(link: run.link, model: "sds100", ["--push-lifetime", "2"])
        var app: Subprocess?
        do {
            let launched = try run.launchApp(extra: ["NOCTULE_TEST_KEEPALIVE_SECONDS": "0.5"])
            app = launched
            let subscribed = await waitForLog(mock, within: 30) { $0.contains("control: PSI,100") }
            guard subscribed else {
                Issue.record("the mock never saw PSI,100; mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            try? await Task.sleep(for: .seconds(6))
            let during = mock.commands
            #expect(during.filter { $0 == "PSI,100" }.count > 1, "\(during)")
            #expect(!during.contains("PSI,0"), "\(during)")
            let stopped = await terminate(launched, within: 15) { mock.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(!stopped.stderr.contains("warning:"), "app: \(stopped.stderr)")
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        await mock.shutdown()  // `active-subscriptions=0`
        let commands = mock.commands
        #expect(commands.filter { $0 == "PSI,100" }.count > 1, "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(commands.filter { $0 == "PSI,0" }.count == 1, "\(commands)")
        #expect(forbidden(commands) == [], "\(commands)")
        #expect(!commands.contains("KAL") && !commands.contains("GCS"), "\(commands)")
        #expect(run.cooldownFiles.isEmpty, "\(run.cooldownFiles)")
    }

    // MARK: A BCD436HP on the serial mock (Plan 23 Task 10)

    /// What the app must never send a BCD436HP by itself: `KAL`, `GCS`, `MSM`, `POF`, and (it
    /// sends them only from a click) every `KEY`, `MSV`, `MNU`, `MSB` and `HLD`.
    private func bcdForbidden(_ commands: [String]) -> [String] {
        commands.filter { command in
            ["KAL", "GCS", "MSM", "POF", "KEY", "MSV", "MNU", "MSB", "HLD"].contains { command.hasPrefix($0) }
        }
    }

    /// The app on a mock BCD436HP: `MDL`, `VER`, `PSI,100`, the display's `STS`; SIGTERM ends it in
    /// order (exit 0 within 15 s, `PSI,0` last, no subscription left), with no `KAL`, `GCS`, `MSM`,
    /// `POF` or any state-changing command, and no cooldown record.
    @Test func usbAppRunsABCD436HPAndQuitsCleanly() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        let mock = try await SerialMock.launch(link: run.link, model: "bcd436hp")
        var app: Subprocess?
        do {
            let launched = try run.launchApp()
            app = launched
            let subscribed = await waitForLog(mock, within: 30) { $0.contains("control: PSI,100") }
            guard subscribed else {
                Issue.record("the mock never saw PSI,100; mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            let read = await waitForLog(mock, within: 10) { $0.contains("control: STS") }
            #expect(read, "mock: \(mock.process.stderr)")
            let stopped = await terminate(launched, within: 15) { mock.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(SerialMock.commands(in: stopped.seen).last == "PSI,0", "\(stopped.seen)")
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        await mock.shutdown()  // `active-subscriptions=0`
        let commands = mock.commands
        #expect(Array(commands.prefix(3)) == ["MDL", "VER", "PSI,100"], "\(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(commands.filter { $0 == "PSI,0" }.count == 1, "\(commands)")
        #expect(commands.contains("STS"), "\(commands)")
        #expect(bcdForbidden(commands) == [], "\(commands)")
        #expect(run.cooldownFiles == [], "\(run.cooldownFiles)")
    }

    /// The BCD436HP is in its menu when the app starts (the test puts it there with one `MNU,TOP,`
    /// on the mock's port before the app opens it): the app reads the menu (`GSI`, `MSI`) and
    /// quitting sends the scanner nothing to leave it: no `KEY,L,P`, no `MSB`, no `MSV`.
    @Test func usbAppQuitsWhileABCD436HPIsInItsMenu() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        let mock = try await SerialMock.launch(link: run.link, model: "bcd436hp")
        var app: Subprocess?
        do {
            // The mock's own pseudo-terminal behind the test's temporary link (never a real port).
            try #require(run.link.path.hasPrefix(run.root.path + "/"))
            let fd = open(run.link.path, O_RDWR | O_NOCTTY)
            try #require(fd >= 0, "couldn't open the mock's port")
            let command = Array("MNU,TOP,\r".utf8)
            _ = command.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            let entered = await waitForLog(mock, within: 10) { $0.contains("control: MNU,TOP,") }
            close(fd)
            guard entered else {
                Issue.record("the mock never saw MNU,TOP,; mock: \(mock.process.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            let launched = try run.launchApp()
            app = launched
            let read = await waitForLog(mock, within: 30) { $0.contains("control: MSI") }
            guard read else {
                Issue.record("the app never read the menu (MSI); mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            let stopped = await terminate(launched, within: 15) { mock.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        await mock.shutdown()  // `active-subscriptions=0`
        let commands = mock.commands
        #expect(commands.filter { $0 == "MNU,TOP," }.count == 1, "only the test's own: \(commands)")
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(!commands.contains("KEY,L,P"), "\(commands)")
        #expect(!commands.contains { $0.hasPrefix("MSB") || $0.hasPrefix("MSV") || $0.hasPrefix("KEY") || $0.hasPrefix("HLD") },
                "\(commands)")
        #expect(!commands.contains { $0.hasPrefix("KAL") || $0.hasPrefix("GCS") || $0.hasPrefix("MSM") || $0.hasPrefix("POF") },
                "\(commands)")
        #expect(run.cooldownFiles.isEmpty, "\(run.cooldownFiles)")
    }

    // MARK: A USB station with a line-in (Plan 18 Task 14)

    /// A fictional audio input saved in the station; nothing in Core Audio has it.
    private static let fictionalLineIn = (uid: "FictionalAudio:Test Line-in:0", name: "Test Line-in")

    /// The mock's headphone jack stands in for the station's input (`NOCTULE_TEST_LINE_IN`, with
    /// the kill-switch and a private settings directory): a transmission is recorded as a WAV in
    /// the private recordings folder, and the hit log's `audio_path` names it. SIGTERM ends the run
    /// in order (exit 0, `PSI,0` last, no subscription left) and nothing touches a cooldown record.
    @Test func usbLineInAppRecordsAHit() async throws {
        let run = try await USBAppRun.make(lineIn: Self.fictionalLineIn)
        defer { run.cleanUp() }
        let mock = try await SerialMock.launch(link: run.link, ["--line-out", run.jack.path])
        var app: Subprocess?
        do {
            let launched = try run.launchApp(extra: ["NOCTULE_TEST_LINE_IN": run.jack.path])
            app = launched
            let subscribed = await waitForLog(mock, within: 30) { $0.contains("control: PSI,100") }
            guard subscribed else {
                Issue.record("the mock never saw PSI,100; mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            #expect(launched.stderr.contains("NoctuleScan: test override: NOCTULE_TEST_LINE_IN=\(run.jack.path)"),
                    "app: \(launched.stderr)")
            let recorded = await run.waitForEndedHit(within: 40) { $0.audioPath != nil }
            let hits = await run.loggedHits()
            #expect(recorded != nil, "no recorded hit; hits: \(String(describing: hits)) app: \(launched.stderr)")
            let stopped = await terminate(launched, within: 15) { mock.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(SerialMock.commands(in: stopped.seen).last == "PSI,0", "\(stopped.seen)")
            #expect(!stopped.stderr.contains("audio input disabled"), "app: \(stopped.stderr)")
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        await mock.shutdown()  // `active-subscriptions=0`
        let files = run.recordedFiles
        let logged = await run.loggedHits() ?? []
        let paths = logged.compactMap(\.audioPath)
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        #expect(!paths.isEmpty, "no hit names a recording; hits: \(logged)")
        for path in paths {
            #expect(files.contains(path), "\(path) isn't among \(files)")
        }
        let commands = mock.commands
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(forbidden(commands) == [], "\(commands)")
        // Nothing here asks for Volume −1, the line-in's only command.
        #expect(!commands.contains { $0.hasPrefix("VOL") }, "\(commands)")
        #expect(run.cooldownFiles == [], "\(run.cooldownFiles)")
    }

    /// The same station without the test stream: the kill-switch opens no audio input, even the one
    /// saved in the station (line-in design §8). The app says why on stderr, logs hits without
    /// audio, records nothing, and quits in order.
    @Test func usbLineInAppUnderTheKillSwitchOpensNoInput() async throws {
        let run = try await USBAppRun.make(lineIn: Self.fictionalLineIn)
        defer { run.cleanUp() }
        let mock = try await SerialMock.launch(link: run.link, ["--line-out", run.jack.path])
        var app: Subprocess?
        do {
            let launched = try run.launchApp()
            app = launched
            let disabled = await launched.waitForStderr(within: 30) {
                $0.contains("warning: Test Handheld: audio input disabled by NOCTULE_NO_USB_DETECTION")
            }
            guard disabled else {
                Issue.record("no kill-switch warning; mock: \(mock.process.stderr) app: \(launched.stderr)")
                throw CocoaError(.featureUnsupported)
            }
            let logged = await run.waitForEndedHit(within: 40) { _ in true }
            #expect(logged != nil, "no hit logged; app: \(launched.stderr)")
            let stopped = await terminate(launched, within: 15) { mock.process.stderr }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(!stopped.stderr.contains("NOCTULE_TEST_LINE_IN"), "app: \(stopped.stderr)")
            #expect(SerialMock.commands(in: stopped.seen).last == "PSI,0", "\(stopped.seen)")
        } catch let error as CocoaError where error.code == .featureUnsupported {
            // Already recorded.
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
        await mock.shutdown()  // `active-subscriptions=0`
        #expect(run.recordedFiles == [], "\(run.recordedFiles)")
        let hits = await run.loggedHits() ?? []
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.audioPath == nil }, "\(hits)")
        let commands = mock.commands
        #expect(commands.last == "PSI,0", "\(commands)")
        #expect(forbidden(commands) == [], "\(commands)")
        // Nothing here asks for Volume −1, the line-in's only command.
        #expect(!commands.contains { $0.hasPrefix("VOL") }, "\(commands)")
        #expect(run.cooldownFiles == [], "\(run.cooldownFiles)")
    }

    // MARK: The update check

    /// A private settings directory with no test feed: the app never asks for a release, says so
    /// once at launch, logs no check, and quits in order. No scanner is behind the station's port.
    @Test func updateCheckOffWithPrivateSettings() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        var app: Subprocess?
        do {
            let launched = try run.launchApp()
            app = launched
            let started = await run.waitForLock(by: launched.process.processIdentifier, within: 30)
            #expect(started, "the app never started the station; app: \(launched.stderr)")
            // Long enough for a launch check (5 s after launch), had one started, to log its line.
            try? await Task.sleep(for: .seconds(8))
            let stopped = await terminate(launched, within: 15) { "" }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(stopped.stderr.contains(
                "NoctuleScan: test override: no update checks with a private NOCTULE_SETTINGS_DIR"),
                    "app: \(stopped.stderr)")
            #expect(!stopped.stderr.contains("update check:"), "app: \(stopped.stderr)")
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
    }

    /// A test feed (a file in the run's directory, fictional notes) newer than the version the
    /// test gives the app: the launch check finds it and logs it, the station still starts, and
    /// SIGTERM exits 0 with the Software Update window open. Nothing reaches the network.
    @Test func updateCheckUsesTheTestFeed() async throws {
        let run = try await USBAppRun.make()
        defer { run.cleanUp() }
        let feed = run.root.appending(path: "latest.json")
        let release: [String: Any] = [
            "tag_name": "v1.0.0", "prerelease": false, "draft": false,
            "html_url": "https://github.com/noctule-dev/noctule-scan/releases/tag/v1.0.0",
            "body": "## Fictional notes\n\n- A **made-up** change for the test.",
        ]
        try JSONSerialization.data(withJSONObject: release).write(to: feed)
        var app: Subprocess?
        do {
            let launched = try run.launchApp(extra: [
                "NOCTULE_TEST_UPDATE_FEED": feed.absoluteString,
                "NOCTULE_TEST_APP_VERSION": "0.9.0",
            ])
            app = launched
            // The launch check waits 5 s after launch.
            let found = await launched.waitForStderr(within: 30) {
                $0.contains("update check: Noctule Scan 1.0.0 is available")
            }
            #expect(found, "no update check line; app: \(launched.stderr)")
            let started = await run.waitForLock(by: launched.process.processIdentifier, within: 30)
            #expect(started, "the app never started the station; app: \(launched.stderr)")
            let stopped = await terminate(launched, within: 15) { "" }
            app = nil
            #expect(stopped.exited, "the app didn't exit within 15 s; app: \(stopped.stderr)")
            #expect(stopped.status == 0, "exit status \(stopped.status); app: \(stopped.stderr)")
            #expect(stopped.stderr.contains("NoctuleScan: test override: NOCTULE_TEST_UPDATE_FEED="),
                    "app: \(stopped.stderr)")
        } catch {
            Issue.record(error)
        }
        if let app {
            app.kill()
            _ = await app.finish()
        }
    }
}
