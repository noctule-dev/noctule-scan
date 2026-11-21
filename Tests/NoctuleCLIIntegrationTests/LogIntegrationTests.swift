// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Darwin
import Foundation
import Testing

// `noctule station`, `log`, and `hits` against the `noctule-mock-scanner` executable, both
// launched as subprocesses on loopback (ephemeral ports), with temporary settings, recordings,
// and cooldown-store paths and a 1 s cooldown. Every wait is bounded, and every subprocess is
// stopped (then killed if needed) on every path. All names and values are fictional.

private func le32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
}

private func le16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

/// A programmed talkgroup, then an unprogrammed conventional channel; one pass is 6.5 s.
private let scenarioJSON = """
    {
      "model": "SDS200",
      "firmware": "1.26.01",
      "loop": true,
      "mode": "trunk",
      "idle": { "system": "Testville County P25", "site": "Testville Simulcast", "frequencyMHz": 851.0125,
                "modulation": "NFM", "rssi": -999 },
      "transmissions": [
        { "at": 1.5, "duration": 1.5, "system": "Testville County P25", "department": "Testville Fire",
          "channel": "Testville Fire Dispatch", "tgid": "4711", "unitID": "5101", "frequencyMHz": 851.2375,
          "modulation": "NFM", "toneOrCode": "NAC 2A1h", "rssi": -62, "programmed": true, "toneHz": 440 },
        { "at": 3.5, "duration": 1.5, "system": "Testville Marine", "department": "Testville Harbor",
          "channel": "Testville Marina", "frequencyMHz": 155.1234, "modulation": "FM", "rssi": -60,
          "programmed": false, "toneHz": 660 }
      ]
    }
    """

/// Temporary settings, recordings, and cooldown-store paths, removed by `cleanUp()`.
private struct Dirs {
    let root: URL
    var settings: URL { root.appending(path: "settings") }
    var recordings: URL { root.appending(path: "recordings") }
    var cooldownStore: URL { root.appending(path: "cooldown.json") }
    var scenario: URL { root.appending(path: "scenario.json") }

    init() throws {
        root = try temporaryDirectory()
        try scenarioJSON.write(to: scenario, atomically: true, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    var settingsFlags: [String] { ["--settings-dir", settings.path] }
    var logFlags: [String] {
        settingsFlags + ["--recordings", recordings.path, "--cooldown-seconds", "1", "--cooldown-store", cooldownStore.path]
    }
}

private func addStation(_ dirs: Dirs, mock: MockScanner) async throws {
    let add = try await noctule(["station", "add", "--name", "Test Station", "--host", "127.0.0.1",
                                 "--udp-port", String(mock.udpPort), "--rtsp-port", String(mock.rtspPort)] + dirs.settingsFlags)
    #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
}

private func wavCount(_ dirs: Dirs) -> Int {
    let folder = dirs.recordings.appending(path: "Test Station")
    return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "wav" }.count
}

/// Data rows of a `hits` table (the header is the first line).
private func rows(_ table: String) -> [String] {
    Array(table.split(separator: "\n").map(String.init).dropFirst())
}

@Suite(.timeLimit(.minutes(1))) struct LogIntegrationTests {
    @Test func stationAddListRemove() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let settings = dirs.settingsFlags

        let add = try await noctule(["station", "add", "--name", "Test Station", "--host", "127.0.0.1",
                                     "--udp-port", "50000", "--save-audio", "new"] + settings)
        #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
        #expect(add.stdout.contains("added station \"Test Station\""), "\(add.stdout)")

        let duplicate = try await noctule(["station", "add", "--name", "test STATION", "--host", "127.0.0.2"] + settings)
        #expect(duplicate.exited && duplicate.status == 1, "\(duplicate.stdout) \(duplicate.stderr)")
        #expect(duplicate.stderr.contains("a station named \"Test Station\" already exists"), "\(duplicate.stderr)")

        let invalid = try await noctule(["station", "add", "--name", "Other"] + settings)
        #expect(invalid.exited && invalid.status == 1, "\(invalid.stdout) \(invalid.stderr)")
        #expect(invalid.stderr.contains("the station needs a host (--host)"), "\(invalid.stderr)")

        let list = try await noctule(["station", "list"] + settings)
        #expect(list.exited && list.status == 0, "\(list.stderr)")
        #expect(list.stdout == "  Test Station  127.0.0.1  udp 50000  rtsp 554  save audio: new\n", "\(list.stdout)")

        let missing = try await noctule(["station", "remove", "--name", "Nope"] + settings)
        #expect(missing.exited && missing.status == 1, "\(missing.stdout) \(missing.stderr)")
        #expect(missing.stderr.contains("no station named \"Nope\""), "\(missing.stderr)")

        let remove = try await noctule(["station", "remove", "--name", "TEST STATION"] + settings)
        #expect(remove.exited && remove.status == 0, "\(remove.stdout) \(remove.stderr)")
        #expect(remove.stdout.contains("removed station \"Test Station\""), "\(remove.stdout)")

        let empty = try await noctule(["station", "list"] + settings)
        #expect(empty.exited && empty.status == 0 && empty.stdout == "no stations\n", "\(empty.stdout) \(empty.stderr)")

        let noStation = try await noctule(["hits"] + settings)
        #expect(noStation.exited && noStation.status == 1, "\(noStation.stdout) \(noStation.stderr)")
        #expect(noStation.stderr.contains("no stations; add one with"), "\(noStation.stderr)")
    }

    /// An unreadable `stations.json` (not missing) is reported, exits 1, and is never
    /// overwritten by `station add`/`remove` or touched by `log` (final review I2).
    @Test func unreadableStationsFileIsReportedAndKept() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let settings = dirs.settingsFlags
        let add = try await noctule(["station", "add", "--name", "Test Station", "--host", "127.0.0.1"] + settings)
        #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
        let url = dirs.settings.appending(path: "stations.json")
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let runs: [[String]] = [
            ["station", "add", "--name", "Other", "--host", "127.0.0.2"] + settings,
            ["station", "list"] + settings,
            ["station", "remove", "--name", "Test Station"] + settings,
            ["log", "--seconds", "1"] + dirs.logFlags,
        ]
        for arguments in runs {
            let result = try await noctule(arguments)
            #expect(result.exited && result.status == 1, "\(arguments) \(result.stdout) \(result.stderr)")
            #expect(result.stderr.contains("can't read "), "\(arguments) \(result.stderr)")
            #expect(result.stderr.contains("stations.json"), "\(arguments) \(result.stderr)")
            #expect(result.stdout.isEmpty, "\(arguments) \(result.stdout)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: dirs.settings.appending(path: "Stations").path))
    }

    @Test func logRecordsScenarioThenHitsLists() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let mock = try await MockScanner.launch(["--scenario", dirs.scenario.path, "--cooldown-seconds", "1", "--no-delays"])
        do {
            try await addStation(dirs, mock: mock)
            let log = try await noctule(["log", "--seconds", "6"] + dirs.logFlags, limit: 30)
            #expect(log.exited && log.status == 0, "\(log.stdout) \(log.stderr)")
            #expect(log.stderr.contains("log: connected to SDS200 (firmware 1.26.01)"), "\(log.stderr)")
            #expect(log.stderr.contains("audio: streaming"), "\(log.stderr)")
            #expect(log.stdout.contains("  + TG4711 Testville Fire Dispatch"), "\(log.stdout)")
            #expect(log.stdout.contains("  + 155.1234MHz Testville Marina  (new)"), "\(log.stdout)")
            #expect(log.stdout.contains("  - 155.1234MHz Testville Marina  "), "\(log.stdout)")
            #expect(log.stdout.contains(".wav"), "\(log.stdout)")

            // At least two valid WAVs (16-bit PCM, 8 kHz mono, non-empty data) in the station's folder.
            let folder = dirs.recordings.appending(path: "Test Station")
            let wavs = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "wav" }
            #expect(wavs.count >= 2, "\(wavs.map(\.lastPathComponent)) \(log.stdout) \(log.stderr)")
            for wav in wavs {
                let data = try Data(contentsOf: wav)
                try #require(data.count >= 44, "\(wav.lastPathComponent)")
                #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
                #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
                #expect(le16(data, at: 20) == 1 && le16(data, at: 22) == 1)
                #expect(le32(data, at: 24) == 8000 && le16(data, at: 34) == 16)
                let dataSize = Int(le32(data, at: 40))
                #expect(dataSize > 0, "\(wav.lastPathComponent)")
                #expect(dataSize == data.count - 44, "\(wav.lastPathComponent)")
                #expect(Int(le32(data, at: 4)) == dataSize + 36)
            }

            // `log` remembered the station.
            let list = try await noctule(["station", "list"] + dirs.settingsFlags)
            #expect(list.stdout.hasPrefix("* Test Station  127.0.0.1"), "\(list.stdout)")

            let all = try await noctule(["hits"] + dirs.settingsFlags)
            #expect(all.exited && all.status == 0, "\(all.stderr)")
            #expect(all.stdout.hasPrefix("   STARTED              DURATION  SOURCE"), "\(all.stdout)")
            #expect(rows(all.stdout).count >= 2, "\(all.stdout)")

            let groups = try await noctule(["hits", "--groups"] + dirs.settingsFlags)
            #expect(groups.exited && groups.status == 0, "\(groups.stderr)")
            #expect(groups.stdout.hasPrefix("   SOURCE"), "\(groups.stdout)")
            #expect(rows(groups.stdout).contains { $0.contains("TG4711 Testville Fire Dispatch") }, "\(groups.stdout)")
            #expect(rows(groups.stdout).contains { $0.hasPrefix("*  155.1234MHz Testville Marina") }, "\(groups.stdout)")

            let new = try await noctule(["hits", "--new"] + dirs.settingsFlags)
            #expect(new.exited && new.status == 0, "\(new.stderr)")
            #expect(rows(new.stdout).contains { $0.contains("155.1234MHz Testville Marina") }, "\(new.stdout)")
            #expect(rows(new.stdout).allSatisfy { $0.hasPrefix("*  ") }, "\(new.stdout)")

            let today = try await noctule(["hits", "--groups", "--new", "--since", "2000-01-01"] + dirs.settingsFlags)
            #expect(today.exited && today.status == 0, "\(today.stderr)")
            #expect(rows(today.stdout).contains { $0.hasPrefix("*  155.1234MHz Testville Marina") }, "\(today.stdout)")

            let csv = try await noctule(["hits", "--csv", "--station", "test station"] + dirs.settingsFlags)
            #expect(csv.exited && csv.status == 0, "\(csv.stderr)")
            #expect(csv.stdout.hasPrefix(
                "started,ended,duration_s,system,department,channel,site,tgid,uids,frequency_mhz,mode,tone_or_code,rssi_max,programmed,new,audio_path,audio_clipped\r\n"),
                "\(csv.stdout)")
            #expect(csv.stdout.contains("Testville Marina"), "\(csv.stdout)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
        #expect(result.stderr.contains("control: PSI,0"), "\(result.stderr)")
        #expect(!result.stderr.contains("wedged"), "\(result.stderr)")
    }

    /// SIGTERM stops `log` through `runner.stop()`: `PSI,0`, TEARDOWN, the close in the cooldown
    /// store, exit 143. A second signal while closing only reports progress. The mock keeps its
    /// realistic reply delays here, so the TEARDOWN takes long enough for the second signal to land.
    @Test func logSigtermStopsCleanly() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let mock = try await MockScanner.launch(["--cooldown-seconds", "1"])
        do {
            try await addStation(dirs, mock: mock)
            let log = try Subprocess(try noctuleBinary(), ["log"] + dirs.logFlags, environment: noctuleTestEnvironment)
            let streaming = await log.waitForStderr(within: 15) { $0.contains("audio: streaming") }
            #expect(streaming, "\(log.stderr)")
            log.send(SIGTERM)
            try? await Task.sleep(for: .milliseconds(100))
            log.send(SIGINT)
            let exited = await log.waitForExit(within: 20)
            log.kill()
            let result = await log.finish()
            #expect(exited)
            #expect(result.status == 143, "\(result.status) \(result.stderr)")
            #expect(result.stderr.contains("log: still closing the scanner session…"), "\(result.stderr)")
            let record = (try? String(contentsOf: dirs.cooldownStore, encoding: .utf8)) ?? ""
            #expect(record.contains("127.0.0.1"), "cooldown store: \(record)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
        #expect(result.stderr.contains("control: PSI,0"), "\(result.stderr)")
        #expect(!result.stderr.contains("wedged"), "\(result.stderr)")
    }

    /// A second `noctule log` on a station another process is running is refused before any
    /// scanner traffic: exit 1 with the in-use line, and the mock sees one PSI subscription.
    @Test func secondLogOnSameStationRefused() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let mock = try await MockScanner.launch(["--cooldown-seconds", "1"])
        do {
            try await addStation(dirs, mock: mock)
            let first = try Subprocess(try noctuleBinary(), ["log"] + dirs.logFlags, environment: noctuleTestEnvironment)
            let streaming = await first.waitForStderr(within: 15) { $0.contains("audio: streaming") }
            #expect(streaming, "\(first.stderr)")
            // Point the last-station pointer at another station; a refused run must leave it alone.
            let appURL = dirs.settings.appending(path: "app.json")
            let otherID = UUID()
            var app = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: appURL)) as? [String: Any])
            app["lastStationID"] = otherID.uuidString
            try JSONSerialization.data(withJSONObject: app).write(to: appURL)
            let appBefore = try Data(contentsOf: appURL)
            let second = try await noctule(["log", "--station", "Test Station", "--seconds", "1"] + dirs.logFlags)
            #expect(second.exited && second.status == 1, "\(second.status) \(second.stdout) \(second.stderr)")
            #expect(second.stderr.contains(
                "log: Test Station is open in another Noctule Scan process (pid \(first.process.processIdentifier))"),
                "\(second.stderr)")
            #expect(!second.stderr.contains("audio: waiting"), "\(second.stderr)")
            #expect(try Data(contentsOf: appURL) == appBefore, "a refused run changed app.json")
            first.interrupt()
            let exited = await first.waitForExit(within: 20)
            first.kill()
            let firstResult = await first.finish()
            #expect(exited && firstResult.status == 130, "\(firstResult.status) \(firstResult.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        let subscriptions = result.stderr.components(separatedBy: "\n")
            .filter { $0.hasPrefix("control: PSI,") && !$0.hasPrefix("control: PSI,0") }
        #expect(subscriptions.count == 1, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
    }

    /// Back-to-back `log` runs: the second waits out the reconnect cooldown recorded by the first
    /// (store checked before anything is sent), then connects and records. A third run with a long
    /// cooldown is interrupted during its wait and exits 130 without sending anything. The mock's
    /// cooldown is 1 s; `log` uses 2 s, so the waiting line appears even on a slow machine.
    @Test func logWaitsOutCooldown() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let mock = try await MockScanner.launch(["--scenario", dirs.scenario.path, "--cooldown-seconds", "1", "--no-delays"])
        func count(_ needle: String) -> Int { mock.process.stderr.components(separatedBy: needle).count - 1 }
        do {
            try await addStation(dirs, mock: mock)
            let flags = dirs.settingsFlags + ["--recordings", dirs.recordings.path,
                                              "--cooldown-store", dirs.cooldownStore.path]

            // First run; note when the mock sees its TEARDOWN.
            let first = try Subprocess(try noctuleBinary(), ["log", "--seconds", "2", "--cooldown-seconds", "2"] + flags, environment: noctuleTestEnvironment)
            var tornDownAt: Date?
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, tornDownAt == nil || first.isRunning {
                if tornDownAt == nil, count("torn down") >= 1 { tornDownAt = Date() }
                try? await Task.sleep(for: .milliseconds(10))
            }
            first.kill()
            let firstResult = await first.finish()
            #expect(firstResult.status == 0, "\(firstResult.stderr)")
            let teardown = try #require(tornDownAt, "\(mock.process.stderr)")

            // Second run, at once: it must wait, then connect and record.
            let wavsBefore = wavCount(dirs)
            let second = try Subprocess(try noctuleBinary(), ["log", "--seconds", "6", "--cooldown-seconds", "2"] + flags, environment: noctuleTestEnvironment)
            var reconnectAt: Date?
            let deadline2 = Date().addingTimeInterval(30)
            while Date() < deadline2, reconnectAt == nil || second.isRunning {
                if reconnectAt == nil, count("rtsp: OPTIONS") >= 2 { reconnectAt = Date() }
                try? await Task.sleep(for: .milliseconds(10))
            }
            second.kill()
            let secondResult = await second.finish()
            #expect(secondResult.status == 0, "\(secondResult.stderr)")
            #expect(secondResult.stderr.contains("audio: waiting "), "\(secondResult.stderr)")
            #expect(secondResult.stderr.contains(" s before reconnecting (scanner cooldown)"), "\(secondResult.stderr)")
            #expect(secondResult.stderr.contains("audio: streaming"), "\(secondResult.stderr)")
            let reconnect = try #require(reconnectAt, "\(mock.process.stderr)")
            #expect(reconnect.timeIntervalSince(teardown) >= 1.0, "gap \(reconnect.timeIntervalSince(teardown))")
            #expect(wavCount(dirs) > wavsBefore, "\(secondResult.stdout)")

            // Third run with a long cooldown, interrupted while waiting: exit 130, nothing sent.
            let commandsBefore = count("control: ")
            let rtspBefore = count("rtsp: ")
            let third = try Subprocess(try noctuleBinary(), ["log", "--cooldown-seconds", "60"] + flags, environment: noctuleTestEnvironment)
            let waiting = await third.waitForStderr(within: 10) { $0.contains("before reconnecting (scanner cooldown)") }
            #expect(waiting, "\(third.stderr)")
            third.interrupt()
            let exited = await third.waitForExit(within: 10)
            third.kill()
            let thirdResult = await third.finish()
            #expect(exited)
            #expect(thirdResult.status == 130, "\(thirdResult.status) \(thirdResult.stderr)")
            try? await Task.sleep(for: .milliseconds(200))
            #expect(count("control: ") == commandsBefore, "\(mock.process.stderr)")
            #expect(count("rtsp: ") == rtspBefore, "\(mock.process.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
        #expect(!result.stderr.contains("wedged"), "\(result.stderr)")
    }

    /// A station with `--reconnect-cooldown 0` against a mock that arms its hazard only after
    /// unclean closes: a second `log` right after a clean stop connects at once (no waiting line,
    /// no wedge); after an unclean close (a seeded record without the clean flag) it still waits
    /// the full cooldown (5 s here, mock-only), and is interrupted during the wait.
    @Test func logReconnectsAtOnceAfterACleanClose() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let mock = try await MockScanner.launch(["--scenario", dirs.scenario.path, "--cooldown-seconds", "5",
                                                 "--cooldown-after", "unclean", "--no-delays"])
        do {
            let add = try await noctule(["station", "add", "--name", "Test Station", "--host", "127.0.0.1",
                                         "--udp-port", String(mock.udpPort), "--rtsp-port", String(mock.rtspPort),
                                         "--reconnect-cooldown", "0"] + dirs.settingsFlags)
            #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
            let list = try await noctule(["station", "list"] + dirs.settingsFlags)
            #expect(list.stdout.contains("reconnect wait 0 s"), "\(list.stdout)")
            let flags = dirs.settingsFlags + ["--recordings", dirs.recordings.path, "--cooldown-seconds", "5",
                                              "--cooldown-store", dirs.cooldownStore.path]
            for run in 1...2 {
                let result = try await noctule(["log", "--seconds", "2"] + flags, limit: 20)
                #expect(result.exited && result.status == 0, "run \(run): \(result.stderr)")
                #expect(result.stderr.contains("audio: streaming"), "run \(run): \(result.stderr)")
                #expect(!result.stderr.contains("before reconnecting"), "run \(run): \(result.stderr)")
            }
            let record = (try? String(contentsOf: dirs.cooldownStore, encoding: .utf8)) ?? ""
            #expect(record.contains("\"lastCloseClean\":true") || record.contains("\"lastCloseClean\" : true"),
                    "cooldown store: \(record)")

            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try Data("{\"127.0.0.1\":{\"lastClosed\":\"\(format.string(from: Date()))\"}}".utf8).write(to: dirs.cooldownStore)
            let third = try Subprocess(try noctuleBinary(), ["log"] + flags, environment: noctuleTestEnvironment)
            let waiting = await third.waitForStderr(within: 10) { $0.contains("before reconnecting (scanner cooldown)") }
            third.interrupt()
            let exited = await third.waitForExit(within: 10)
            third.kill()
            let thirdResult = await third.finish()
            #expect(waiting, "\(thirdResult.stderr)")
            #expect(exited && thirdResult.status == 130, "\(thirdResult.status) \(thirdResult.stderr)")
        } catch {
            Issue.record(error)
        }
        let result = await mock.shutdown()
        #expect(result.exited && result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("leaked-sessions=0"), "\(result.stdout)")
        #expect(!result.stderr.contains("wedged"), "\(result.stderr)")
    }

    /// A station added by host name waits out a cooldown the store recorded under the address
    /// the name resolves to, as `RTSPClient` keys it (final review minor 1). Nothing listens:
    /// the run is interrupted during its wait.
    @Test func logWaitsOutCooldownForAHostName() async throws {
        let dirs = try Dirs()
        defer { dirs.cleanUp() }
        let add = try await noctule(["station", "add", "--name", "Test Station", "--host", "localhost",
                                     "--udp-port", String(try silentUDPPort()), "--rtsp-port", String(try silentUDPPort())]
                                    + dirs.settingsFlags)
        #expect(add.exited && add.status == 0, "\(add.stdout) \(add.stderr)")
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seed = "{\"127.0.0.1\":{\"lastClosed\":\"\(format.string(from: Date()))\"}}"
        try Data(seed.utf8).write(to: dirs.cooldownStore)

        let run = try Subprocess(try noctuleBinary(), ["log", "--cooldown-seconds", "60", "--cooldown-store",
                                                       dirs.cooldownStore.path, "--recordings", dirs.recordings.path]
                                 + dirs.settingsFlags, environment: noctuleTestEnvironment)
        let waiting = await run.waitForStderr(within: 10) { $0.contains("before reconnecting (scanner cooldown)") }
        run.interrupt()
        let exited = await run.waitForExit(within: 10)
        run.kill()
        let result = await run.finish()
        #expect(waiting, "\(result.stderr)")
        #expect(exited)
        #expect(result.status == 130, "\(result.status) \(result.stderr)")
        #expect(!result.stderr.contains("log: connected"), "\(result.stderr)")
    }
}
