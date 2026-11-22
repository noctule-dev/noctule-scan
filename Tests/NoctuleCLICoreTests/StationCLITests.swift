// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleStore
@testable import NoctuleCLICore

// Parsing and formatting for `noctule station`, `log`, and `hits`. All names are fictional.

private let utc = TimeZone(identifier: "UTC")!

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Double, _ tz: TimeZone = utc) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tz
    let whole = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: Int(s)))!
    return whole.addingTimeInterval(s - Double(Int(s)))
}

private func trunkHit(start: Date, end: Date? = nil, channel: String? = "Lakeview Fire") -> Hit {
    Hit(id: UUID(), key: HitKey(system: "Testville P25", talkgroupID: "9", frequencyMHz: nil),
        startedAt: start, endedAt: end, startInstant: .now, system: "Testville P25", channel: channel)
}

private func conventionalHit(start: Date, end: Date? = nil) -> Hit {
    Hit(id: UUID(), key: HitKey(system: "Testville Marine", talkgroupID: nil, frequencyMHz: 155.1234),
        startedAt: start, endedAt: end, startInstant: .now, system: "Testville Marine", channel: "Testville Marina",
        programmed: false)
}

private func station(_ name: String, host: String = "192.0.2.10") -> Station {
    var s = Station()
    s.name = name
    s.connection.host = host
    return s
}

/// The `station add` options a command line parses to.
private func addOptions(_ args: [String]) throws -> StationAddOptions {
    guard case .station(.add(let options)) = try CLIArguments.parse(args).command else {
        Issue.record("not station add: \(args)")
        return StationAddOptions(name: "", host: "")
    }
    return options
}

@Suite(.timeLimit(.minutes(3))) struct StationCLIParsingTests {
    @Test func stationAddAllFlags() throws {
        let a = try CLIArguments.parse([
            "station", "add", "--name", "Test Station", "--host", "192.0.2.10", "--udp-port", "50000",
            "--rtsp-port", "8554", "--save-audio", "new", "--settings-dir", "/tmp/s",
        ])
        #expect(a.command == .station(.add(StationAddOptions(
            name: "Test Station", host: "192.0.2.10", udpPort: 50000, rtspPort: 8554, saveAudio: .onlyNew))))
        #expect(a.settingsDir == "/tmp/s")
    }

    @Test func stationAddReconnectCooldown() throws {
        for seconds in [0, 30, 120] {
            let a = try CLIArguments.parse(["station", "add", "--name", "A", "--host", "h",
                                            "--reconnect-cooldown", String(seconds)])
            #expect(a.command == .station(.add(StationAddOptions(name: "A", host: "h", reconnectCooldown: seconds))))
        }
        for bad in ["-1", "121", "x", "1.5", ""] {
            #expect(throws: CLIUsageError(message: "--reconnect-cooldown must be a whole number of seconds, 0-120"), "\(bad)") {
                try CLIArguments.parse(["station", "add", "--name", "A", "--host", "h", "--reconnect-cooldown", bad])
            }
        }
        let made = StationCLI.makeStation(StationAddOptions(name: "A", host: "h", reconnectCooldown: 0))
        #expect(made.connection.reconnectCooldownSeconds == 0)
        #expect(StationCLI.makeStation(StationAddOptions(name: "A", host: "h")).connection.reconnectCooldownSeconds == 120)
        #expect(StationCLI.issueText(.invalidReconnectCooldown) == "the reconnect wait must be 0-120 s (--reconnect-cooldown)")
        #expect(CLIUsageError.usage.contains("[--reconnect-cooldown S]"))
    }

    /// `listen` takes `--reconnect-cooldown` too; `log` reads the station's value instead.
    @Test func listenReconnectCooldown() throws {
        let a = try CLIArguments.parse(["listen", "--host", "h", "--reconnect-cooldown", "0"])
        #expect(a.reconnectCooldown == 0)
        #expect(try CLIArguments.parse(["listen", "--host", "h"]).reconnectCooldown == nil)
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["log", "--reconnect-cooldown", "0"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["info", "--reconnect-cooldown", "0"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["listen", "--reconnect-cooldown", "121"]) }
    }

    /// `listen`'s policy: the full value is 120 s unless the mock-only `--cooldown-seconds` sets
    /// it; the clean-close value is `--reconnect-cooldown` (default 120), clamped to the full one.
    @Test func listenCooldownPolicy() {
        #expect(ListenFormat.cooldownPolicy(cooldownSeconds: nil, reconnectCooldown: nil) == .standard)
        #expect(ListenFormat.cooldownPolicy(cooldownSeconds: nil, reconnectCooldown: 0)
                == RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero))
        #expect(ListenFormat.cooldownPolicy(cooldownSeconds: nil, reconnectCooldown: 30)
                == RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(30)))
        #expect(ListenFormat.cooldownPolicy(cooldownSeconds: 5, reconnectCooldown: nil) == .symmetric(.seconds(5)))
        #expect(ListenFormat.cooldownPolicy(cooldownSeconds: 5, reconnectCooldown: 0)
                == RTSPCooldownPolicy(full: .seconds(5), afterCleanClose: .zero))
        #expect(ListenFormat.cooldownPolicy(cooldownSeconds: 1.5, reconnectCooldown: 30) == .symmetric(.milliseconds(1500)))
    }

    @Test func stationAddUSB() throws {
        let options = try addOptions(["station", "add", "--name", "Truck", "--usb", "--serial-port", "/tmp/p"])
        #expect(options == StationAddOptions(name: "Truck", host: "", usb: true, serialPort: "/tmp/p"))
        let truck = StationCLI.makeStation(options)
        #expect(truck.validate().isEmpty)
        #expect(StationCLI.addProblems(truck, existing: []).isEmpty)
        #expect(truck.name == "Truck")
        #expect(truck.connection.transport == .usbSerial)
        #expect(truck.connection.host == nil)
        let device = try #require(StationCLI.deviceSettings(for: truck, options: options))
        #expect(device.stationID == truck.id && device.usbPort == "/tmp/p")
        // Without a port the station finds its scanner itself.
        let bare = try addOptions(["station", "add", "--name", "Truck", "--usb"])
        #expect(bare.usb && bare.serialPort == nil)
        let bareStation = StationCLI.makeStation(bare)
        #expect(bareStation.validate().isEmpty && bareStation.connection.transport == .usbSerial)
        #expect(StationCLI.deviceSettings(for: bareStation, options: bare) == nil)
        // Save-audio and the name still apply; the port is trimmed and an empty one is no port.
        let spaced = try addOptions(["station", "add", "--name", " Truck ", "--usb", "--serial-port", " /tmp/p ", "--save-audio", "never"])
        #expect(StationCLI.makeStation(spaced).name == "Truck" && StationCLI.makeStation(spaced).recording.saveAudio == .never)
        #expect(StationCLI.deviceSettings(for: StationCLI.makeStation(spaced), options: spaced)?.usbPort == "/tmp/p")
        let empty = try addOptions(["station", "add", "--name", "Truck", "--usb", "--serial-port", "  "])
        #expect(StationCLI.deviceSettings(for: StationCLI.makeStation(empty), options: empty) == nil)
        // A network station has no device settings to write, and stays a network station.
        let net = try addOptions(["station", "add", "--name", "A", "--host", "h"])
        #expect(!net.usb && net.serialPort == nil)
        #expect(StationCLI.makeStation(net).connection.transport == .network)
        #expect(StationCLI.deviceSettings(for: StationCLI.makeStation(net), options: net) == nil)
        // Still needs a name.
        let nameless = StationCLI.makeStation(try addOptions(["station", "add", "--usb"]))
        #expect(StationCLI.addProblems(nameless, existing: []) == [StationCLI.issueText(.emptyName)])
    }

    @Test func stationAddUSBConflicts() {
        let usb = ["station", "add", "--name", "Truck", "--usb"]
        for (flag, value) in [("--host", "h"), ("--udp-port", "50000"), ("--rtsp-port", "8554"), ("--reconnect-cooldown", "30")] {
            let expected = CLIUsageError(message: "--usb can't be combined with \(flag)")
            #expect(throws: expected, "\(flag) after --usb") { try CLIArguments.parse(usb + [flag, value]) }
            #expect(throws: expected, "\(flag) before --usb") {
                try CLIArguments.parse(["station", "add", "--name", "Truck", flag, value, "--usb"])
            }
        }
        #expect(throws: CLIUsageError(message: "--serial-port needs --usb")) {
            try CLIArguments.parse(["station", "add", "--name", "A", "--host", "h", "--serial-port", "/tmp/p"])
        }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["station", "add", "--name", "A", "--serial-port"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["station", "list", "--usb"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["station", "remove", "--name", "A", "--serial-port", "/tmp/p"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["info", "--usb"]) }
    }

    @Test func stationAddMissingNameAndHostLeftForValidate() throws {
        let a = try CLIArguments.parse(["station", "add"])
        #expect(a.command == .station(.add(StationAddOptions(name: "", host: ""))))
    }

    @Test func saveAudioValues() throws {
        for (text, value) in [("every", SaveAudio.everyTransmission), ("new", .onlyNew), ("never", .never)] {
            let a = try CLIArguments.parse(["station", "add", "--name", "A", "--host", "h", "--save-audio", text])
            #expect(a.command == .station(.add(StationAddOptions(name: "A", host: "h", saveAudio: value))))
        }
        #expect(throws: CLIUsageError.self) {
            try CLIArguments.parse(["station", "add", "--name", "A", "--host", "h", "--save-audio", "always"])
        }
    }

    @Test func stationListAndRemove() throws {
        #expect(try CLIArguments.parse(["station", "list"]).command == .station(.list))
        let r = try CLIArguments.parse(["station", "remove", "--name", "Test Station", "--settings-dir", "/tmp/s"])
        #expect(r.command == .station(.remove(name: "Test Station")))
        #expect(r.settingsDir == "/tmp/s")
    }

    @Test func logAllFlags() throws {
        let a = try CLIArguments.parse([
            "log", "--station", "Test Station", "--seconds", "6", "--settings-dir", "/tmp/s",
            "--recordings", "/tmp/r", "--cooldown-seconds", "1", "--cooldown-store", "/tmp/c.json",
        ])
        #expect(a == CLIInvocation(command: .log(station: "Test Station", seconds: 6), cooldownSeconds: 1,
                                   cooldownStore: "/tmp/c.json", settingsDir: "/tmp/s", recordings: "/tmp/r"))
        #expect(try CLIArguments.parse(["log"]).command == .log(station: nil, seconds: nil))
        // The clamp applies to log too.
        #expect(try CLIArguments.parse(["log", "--cooldown-seconds", "1e12"]).cooldownSeconds == 86_400)
    }

    @Test func hitsAllFlags() throws {
        let a = try CLIArguments.parse([
            "hits", "--station", "Test Station", "--groups", "--new", "--since", "2026-11-08", "--settings-dir", "/tmp/s",
        ])
        #expect(a.command == .hits(HitsOptions(station: "Test Station", groups: true, onlyNew: true,
                                               since: date(2026, 11, 8, 0, 0, 0, .current), csv: false)))
        #expect(a.settingsDir == "/tmp/s")
        #expect(try CLIArguments.parse(["hits"]).command == .hits(HitsOptions()))
        #expect(try CLIArguments.parse(["hits", "--csv"]).command == .hits(HitsOptions(csv: true)))
    }

    @Test func rejectsMisplacedOrBadFlags() {
        for bad in [
            ["station"], ["station", "bogus"], ["station", "remove"], ["station", "list", "extra"],
            ["station", "add", "--name"], ["station", "add", "--udp-port", "70000"], ["station", "add", "--udp-port", "x"],
            ["station", "list", "--seconds", "3"], ["station", "add", "--station", "A"],
            ["log", "--name", "A"], ["log", "--groups"], ["log", "--seconds", "0"], ["log", "--host", "h"],
            ["log", "--record", "/tmp/x.wav"], ["log", "list"],
            ["hits", "--seconds", "3"], ["hits", "--since", "2026-13-01"], ["hits", "--since", "yesterday"],
            ["hits", "--since", "2026-11-8x"], ["hits", "--csv", "--groups"], ["hits", "--recordings", "/tmp/r"],
            ["hits", "--cooldown-store", "/tmp/c"],
            ["info", "--settings-dir", "/tmp/s"], ["listen", "--groups"],
            ["info", "--name", "A"], ["watch", "--recordings", "/tmp/r"],
        ] {
            #expect(throws: CLIUsageError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
    }

    @Test func usageMentionsNewCommands() {
        let usage = CLIUsageError.usage
        #expect(usage.contains("noctule station add --name N --host H"))
        #expect(usage.contains("noctule log"))
        #expect(usage.contains("noctule hits"))
    }

    @Test func parseDayIsLocalMidnight() {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        #expect(StationCLI.parseDay("2026-11-08", timeZone: tz) == date(2026, 11, 8, 0, 0, 0, tz))
        #expect(StationCLI.parseDay("2026-02-30", timeZone: tz) == nil)
        #expect(StationCLI.parseDay("2026-11-08T00:00", timeZone: tz) == nil)
        #expect(StationCLI.parseDay("26-11-08", timeZone: tz) == nil)
    }

    @Test func saveAudioNamesRoundTrip() {
        for v in [SaveAudio.everyTransmission, .onlyNew, .never] {
            #expect(StationCLI.parseSaveAudio(StationCLI.saveAudioName(v)) == v)
        }
        #expect(StationCLI.saveAudioName(.everyTransmission) == "every")
    }
}

@Suite(.timeLimit(.minutes(3))) struct StationCLIStationTests {
    @Test func defaultPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(StationCLI.defaultSettingsDirectory.path == home + "/Library/Application Support/NoctuleScan")
        #expect(StationCLI.defaultRecordingsRoot.path == home + "/Music/Noctule Scan")
        #expect(StationCLI.settingsDirectory(nil) == StationCLI.defaultSettingsDirectory)
        #expect(StationCLI.settingsDirectory("/tmp/s").path == "/tmp/s")
        #expect(StationCLI.recordingsRoot(nil) == StationCLI.defaultRecordingsRoot)
        #expect(StationCLI.recordingsRoot("/tmp/r").path == "/tmp/r")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        #expect(StationCLI.hitLogURL(settingsDirectory: URL(fileURLWithPath: "/tmp/s"), stationID: id).path
            == "/tmp/s/Stations/00000000-0000-0000-0000-000000000001/hits.sqlite")
    }

    @Test func makeStationAppliesOptions() {
        let s = StationCLI.makeStation(StationAddOptions(name: " Test Station ", host: " 192.0.2.10 ", udpPort: 50000,
                                                         rtspPort: 8554, saveAudio: .never))
        #expect(s.name == "Test Station")
        #expect(s.connection.host == "192.0.2.10")
        #expect(s.connection.udpPort == 50000 && s.connection.rtspPort == 8554)
        #expect(s.recording.saveAudio == .never)
        let d = StationCLI.makeStation(StationAddOptions(name: "A", host: "h"))
        #expect(d.connection.udpPort == 50536 && d.connection.rtspPort == 554)
        #expect(d.recording.saveAudio == .everyTransmission)
    }

    @Test func addProblemsReportValidateIssuesAndDuplicates() {
        let empty = StationCLI.makeStation(StationAddOptions(name: "", host: ""))
        #expect(StationCLI.addProblems(empty, existing: []) == [
            StationCLI.issueText(.emptyName), StationCLI.issueText(.missingHost),
        ])
        #expect(StationCLI.issueText(.emptyName) == "the station needs a name (--name)")
        #expect(StationCLI.issueText(.missingHost) == "the station needs a host (--host)")
        #expect(!StationCLI.issueText(.invalidMinimumDuration).isEmpty)
        #expect(!StationCLI.issueText(.invalidMaxTransmission).isEmpty)
        let dup = StationCLI.makeStation(StationAddOptions(name: "test STATION", host: "h"))
        #expect(StationCLI.addProblems(dup, existing: [station("Test Station")])
            == ["a station named \"Test Station\" already exists"])
        #expect(StationCLI.addProblems(dup, existing: [station("Other")]) == [])
    }

    @Test func resolveByNameCaseInsensitive() {
        let a = station("Alpha"), b = station("Bravo")
        #expect(StationCLI.resolve(name: "bravo", stations: [a, b], lastID: a.id) == .success(b))
        #expect(StationCLI.resolve(name: "Charlie", stations: [a, b], lastID: nil)
            == .failure(.notFound(name: "Charlie", names: ["Alpha", "Bravo"])))
        #expect(StationCLI.station(named: " ALPHA ", in: [a, b]) == a)
    }

    @Test func resolveWithoutNameUsesLastThenOnly() {
        let a = station("Alpha"), b = station("Bravo")
        #expect(StationCLI.resolve(name: nil, stations: [a, b], lastID: b.id) == .success(b))
        #expect(StationCLI.resolve(name: nil, stations: [a], lastID: nil) == .success(a))
        #expect(StationCLI.resolve(name: nil, stations: [a], lastID: UUID()) == .success(a))
        #expect(StationCLI.resolve(name: nil, stations: [a, b], lastID: nil) == .failure(.ambiguous(names: ["Alpha", "Bravo"])))
        #expect(StationCLI.resolve(name: nil, stations: [], lastID: nil) == .failure(.noStations))
        #expect(StationCLI.resolve(name: "Alpha", stations: [], lastID: nil) == .failure(.noStations))
    }

    @Test func lookupErrorText() {
        #expect(StationLookupError.noStations.description
            == "no stations; add one with 'noctule station add --name N --host H'")
        #expect(StationLookupError.notFound(name: "Charlie", names: ["Alpha", "Bravo"]).description
            == "no station named \"Charlie\"; stations: Alpha, Bravo")
        #expect(StationLookupError.ambiguous(names: ["Alpha", "Bravo"]).description
            == "more than one station; pick one with --station: Alpha, Bravo")
    }

    @Test func listLines() {
        var a = station("Alpha", host: "192.0.2.10")
        a.connection.udpPort = 50000
        a.connection.rtspPort = 8554
        var b = station("Bravo", host: "192.0.2.11")
        b.recording.saveAudio = .onlyNew
        #expect(StationCLI.listLines([a, b], lastID: b.id) == [
            "  Alpha  192.0.2.10  udp 50000  rtsp 8554  save audio: every",
            "* Bravo  192.0.2.11  udp 50536  rtsp 554  save audio: new",
        ])
        // The reconnect wait shows only when it isn't the default 120 s.
        a.connection.reconnectCooldownSeconds = 0
        b.connection.reconnectCooldownSeconds = 30
        #expect(StationCLI.listLines([a, b], lastID: nil) == [
            "  Alpha  192.0.2.10  udp 50000  rtsp 8554  save audio: every  reconnect wait 0 s",
            "  Bravo  192.0.2.11  udp 50536  rtsp 554  save audio: new  reconnect wait 30 s",
        ])
        #expect(StationCLI.listLines([], lastID: nil) == ["no stations"])
    }

    @Test func stationListUSB() throws {
        let options = try addOptions(["station", "add", "--name", "Truck", "--usb", "--serial-port", "/tmp/p"])
        let usb = StationCLI.makeStation(options)
        let line = StationCLI.listLines([usb], lastID: nil, usbPorts: [usb.id: "/tmp/p"])
        #expect(line == ["  Truck  USB /tmp/p  save audio: every"])
        #expect(!line[0].contains("udp") && !line[0].contains("rtsp") && !line[0].contains("50536") && !line[0].contains("554"))
        // No port set: just USB. The port comes from the map, not another station's entry.
        #expect(StationCLI.listLines([usb], lastID: usb.id, usbPorts: [:]) == ["* Truck  USB  save audio: every"])
        #expect(StationCLI.listLines([usb], lastID: nil, usbPorts: [UUID(): "/tmp/other"]) == ["  Truck  USB  save audio: every"])
        // A network station is listed as before, whatever the map holds.
        let net = station("Alpha", host: "192.0.2.10")
        #expect(StationCLI.listLines([net], lastID: nil, usbPorts: [net.id: "/tmp/p"])
            == ["  Alpha  192.0.2.10  udp 50536  rtsp 554  save audio: every"])
    }
}

@Suite(.timeLimit(.minutes(3))) struct StationCLIFormatTests {
    @Test func sourceLabels() {
        #expect(StationCLI.sourceLabel(key: HitKey(system: "S", talkgroupID: "9", frequencyMHz: 851.0), channel: "Lakeview Fire")
            == "TG9 Lakeview Fire")
        #expect(StationCLI.sourceLabel(key: HitKey(system: "S", talkgroupID: "9", frequencyMHz: nil), channel: nil) == "TG9")
        #expect(StationCLI.sourceLabel(key: HitKey(system: "S", talkgroupID: "9", frequencyMHz: nil), channel: "  ") == "TG9")
        #expect(StationCLI.sourceLabel(key: HitKey(system: "S", talkgroupID: nil, frequencyMHz: 155.1234), channel: "Testville Marina")
            == "155.1234MHz Testville Marina")
        #expect(StationCLI.sourceLabel(key: HitKey(system: "S", talkgroupID: nil, frequencyMHz: nil), channel: "X") == "X")
        #expect(StationCLI.sourceLabel(key: HitKey(system: "S", talkgroupID: nil, frequencyMHz: nil), channel: nil) == "?")
    }

    @Test func clockTimeIsLocal() {
        #expect(StationCLI.clockTime(date(2026, 11, 8, 14, 3, 7), timeZone: utc) == "14:03:07")
        let pst = TimeZone(identifier: "America/Los_Angeles")!
        #expect(StationCLI.clockTime(date(2026, 11, 8, 14, 3, 7), timeZone: pst) == "06:03:07")
    }

    @Test func startLines() {
        let start = date(2026, 11, 8, 14, 3, 7)
        let hit = trunkHit(start: start)
        #expect(StationCLI.startLine(LoggedHit(hit: hit, audioPath: nil, audioError: nil, isNew: true), timeZone: utc)
            == "14:03:07  + TG9 Lakeview Fire  (new)")
        #expect(StationCLI.startLine(LoggedHit(hit: hit, audioPath: nil, audioError: nil, isNew: false), timeZone: utc)
            == "14:03:07  + TG9 Lakeview Fire")
    }

    /// A hit with no audio file and no audio error (every USB hit) has no `→` part.
    @Test func hitLineWithoutFile() {
        let start = date(2026, 11, 8, 14, 3, 7)
        let hit = trunkHit(start: start, end: start.addingTimeInterval(2.34))
        let line = StationCLI.endLine(LoggedHit(hit: hit, audioPath: nil, audioError: nil, isNew: false), timeZone: utc)
        #expect(line == "14:03:09  - TG9 Lakeview Fire  2.3 s")
        #expect(!line.contains("→"))
    }

    @Test func endLines() {
        let start = date(2026, 11, 8, 14, 3, 7)
        let end = start.addingTimeInterval(2.34)
        let hit = trunkHit(start: start, end: end)
        #expect(StationCLI.endLine(LoggedHit(hit: hit, audioPath: "/r/2026-11-08 14-03-07 · TG9 · Lakeview Fire.wav",
                                             audioError: nil, isNew: true), timeZone: utc)
            == "14:03:09  - TG9 Lakeview Fire  2.3 s  → 2026-11-08 14-03-07 · TG9 · Lakeview Fire.wav")
        #expect(StationCLI.endLine(LoggedHit(hit: hit, audioPath: nil, audioError: "disk full", isNew: false), timeZone: utc)
            == "14:03:09  - TG9 Lakeview Fire  2.3 s  → (no audio: disk full)")
        #expect(StationCLI.endLine(LoggedHit(hit: hit, audioPath: nil, audioError: nil, isNew: false), timeZone: utc)
            == "14:03:09  - TG9 Lakeview Fire  2.3 s")
        let conv = conventionalHit(start: start, end: start.addingTimeInterval(0.96))
        #expect(StationCLI.endLine(LoggedHit(hit: conv, audioPath: nil, audioError: nil, isNew: true), timeZone: utc)
            == "14:03:07  - 155.1234MHz Testville Marina  1.0 s")
    }

    @Test func warningAndEvents() {
        #expect(StationCLI.warningLine("scanner stopped sending updates") == "warning: scanner stopped sending updates")
        let start = date(2026, 11, 8, 14, 3, 7)
        let logged = LoggedHit(hit: trunkHit(start: start), audioPath: nil, audioError: nil, isNew: true)
        #expect(StationCLI.eventOutput(.hitStarted(logged), timeZone: utc) == .stdout("14:03:07  + TG9 Lakeview Fire  (new)"))
        #expect(StationCLI.eventOutput(.warning("x"), timeZone: utc) == .stderr("warning: x"))
        #expect(StationCLI.eventOutput(.connected(model: "SDS200", firmware: "1.26.01"), timeZone: utc)
            == .stderr("log: connected to SDS200 (firmware 1.26.01)"))
        #expect(StationCLI.eventOutput(.audio(.streaming), timeZone: utc) == .stderr("audio: streaming"))
        #expect(StationCLI.eventOutput(.audio(.idle), timeZone: utc) == nil)
        #expect(StationCLI.eventOutput(.stopped, timeZone: utc) == nil)
        #expect(StationCLI.stillClosingLine == "log: still closing the scanner session…")
    }

    /// A USB station's line-in on `log` (Plan 19): the one-time `audio:` line, the clip warning that
    /// names the channel, and the denied warning in the terminal's words; the runner's other
    /// line-in states print nothing, and its other warnings print as they are.
    @Test func lineInLinesAndEvents() {
        for channel in LineInChannel.allCases {
            let config = LineInConfig(deviceUID: "fictional-input-1", deviceName: "Fictional Interface", channel: channel)
            #expect(StationCLI.lineInLine(config) == "audio: line-in Fictional Interface (\(channel.rawValue))")
        }
        let start = date(2026, 11, 8, 14, 3, 7)
        let named = LoggedHit(hit: trunkHit(start: start, channel: "Fictional Channel"), audioPath: nil, audioError: nil, isNew: false)
        let expected = "warning: the audio input clipped during \"Fictional Channel\"; turn the scanner's volume down"
        #expect(StationCLI.clippedLine(named) == expected)
        #expect(StationCLI.eventOutput(.clipped(named), timeZone: utc) == .stderr(expected))
        // No channel name: the source label stands in (`TG9`), never an empty pair of quotes.
        let unnamed = LoggedHit(hit: trunkHit(start: start, channel: nil), audioPath: nil, audioError: nil, isNew: false)
        #expect(StationCLI.clippedLine(unnamed)
            == "warning: the audio input clipped during \"TG9\"; turn the scanner's volume down")

        #expect(StationCLI.terminalDeniedLine
            == "warning: this terminal isn't allowed to use audio input. Allow it in System Settings › Privacy & Security › Microphone.")
        #expect(StationCLI.eventOutput(.warning(StationRunner.lineInDeniedMessage), timeZone: utc)
            == .stderr(StationCLI.terminalDeniedLine))
        #expect(StationCLI.eventOutput(.warning("audio input disabled by NOCTULE_NO_USB_DETECTION"), timeZone: utc)
            == .stderr("warning: audio input disabled by NOCTULE_NO_USB_DETECTION"))

        #expect(StationCLI.eventOutput(.lineIn(.starting), timeZone: utc) == nil)
        #expect(StationCLI.eventOutput(.lineIn(.streaming(deviceName: "Fictional Interface")), timeZone: utc) == nil)
        #expect(StationCLI.eventOutput(.lineIn(.denied), timeZone: utc) == nil)
    }

    /// The one line `log` prints after a USB station's first connect: its line-in, or no audio over
    /// USB; nothing under the kill-switch, where the runner's `audio input disabled …` warning
    /// alone says the station has no audio this run (the input is never opened).
    @Test func usbAudioLine() {
        let config = LineInConfig(deviceUID: "fictional-input-1", deviceName: "Fictional Interface", channel: .both)
        #expect(StationCLI.usbAudioLine(lineIn: config, lineInDisabled: false) == "audio: line-in Fictional Interface (both)")
        #expect(StationCLI.usbAudioLine(lineIn: config, lineInDisabled: true) == nil)
        #expect(StationCLI.usbAudioLine(lineIn: nil, lineInDisabled: false) == "log: no audio over USB")
        #expect(StationCLI.usbAudioLine(lineIn: nil, lineInDisabled: true) == "log: no audio over USB")
    }

    @Test func transmissionsTable() {
        let start = date(2026, 11, 8, 14, 3, 7)
        let a = LoggedHit(hit: trunkHit(start: start, end: start.addingTimeInterval(2.34)),
                          audioPath: "/r/a.wav", audioError: nil, isNew: true)
        let b = LoggedHit(hit: conventionalHit(start: start.addingTimeInterval(60)), audioPath: nil, audioError: nil, isNew: false)
        let c = LoggedHit(hit: trunkHit(start: start.addingTimeInterval(120), end: start.addingTimeInterval(121)),
                          audioPath: nil, audioError: "disk full", isNew: false)
        #expect(StationCLI.transmissionsTable([a, b, c], timeZone: utc) == [
            "   STARTED              DURATION  SOURCE                            SYSTEM                    AUDIO",
            "*  2026-11-08 14:03:07     2.3 s  TG9 Lakeview Fire                 Testville P25             a.wav",
            "   2026-11-08 14:04:07      open  155.1234MHz Testville Marina      Testville Marine          -",
            "   2026-11-08 14:05:07     1.0 s  TG9 Lakeview Fire                 Testville P25             (no audio: disk full)",
        ])
        #expect(StationCLI.transmissionsTable([], timeZone: utc) == ["no hits"])
    }

    @Test func groupsTable() {
        let start = date(2026, 11, 8, 14, 3, 7)
        let tg = HitGroup(key: HitKey(system: "Testville P25", talkgroupID: "9", frequencyMHz: nil), label: "Lakeview Fire",
                          hits: 3, talkTime: 12.34, firstSeen: start, lastSeen: start.addingTimeInterval(60),
                          rssiMax: -62, programmed: true, isNew: false, modes: ["NFM"], toneOrCode: nil)
        let conv = HitGroup(key: HitKey(system: "Testville Marine", talkgroupID: nil, frequencyMHz: 155.1234),
                            label: "155.1234 MHz", hits: 1, talkTime: 1, firstSeen: start, lastSeen: start,
                            rssiMax: nil, programmed: false, isNew: true, modes: [], toneOrCode: nil)
        let fallbackTG = HitGroup(key: HitKey(system: "Testville P25", talkgroupID: "77", frequencyMHz: nil), label: "TG 77",
                                  hits: 1, talkTime: 0.5, firstSeen: start, lastSeen: start,
                                  rssiMax: -90, programmed: false, isNew: true, modes: [], toneOrCode: nil)
        #expect(StationCLI.groupsTable([tg, conv, fallbackTG], timeZone: utc) == [
            "   SOURCE                            SYSTEM                     HITS   TALK TIME  LAST SEEN            RSSI",
            "   TG9 Lakeview Fire                 Testville P25                 3      12.3 s  2026-11-08 14:04:07  -62",
            "*  155.1234MHz                       Testville Marine              1       1.0 s  2026-11-08 14:03:07  -",
            "*  TG77                              Testville P25                 1       0.5 s  2026-11-08 14:03:07  -90",
        ])
        #expect(StationCLI.groupsTable([], timeZone: utc) == ["no hits"])
    }
}


// MARK: Line-in (Plan 19, Task 2)

private func fictionalInput(_ uid: String, _ name: String = "Fictional Interface") -> AudioInputDevice {
    AudioInputDevice(uid: uid, name: name, channelCount: 2)
}

@Suite(.timeLimit(.minutes(3))) struct StationCLILineInTests {
    // MARK: Resolution

    @Test func resolveAudioInputByUID() {
        let inputs = [fictionalInput("UID-1"), fictionalInput("UID-2", "Other Interface")]
        #expect(StationCLI.resolveAudioInput("UID-2", inputs: inputs, listingAvailable: true)
            == .input(uid: "UID-2", name: "Other Interface"))
        // A UID wins over a name that happens to be the same text.
        let tricky = [fictionalInput("UID-1", "UID-2"), fictionalInput("UID-2", "Other Interface")]
        #expect(StationCLI.resolveAudioInput("UID-2", inputs: tricky, listingAvailable: true)
            == .input(uid: "UID-2", name: "Other Interface"))
    }

    @Test func resolveAudioInputByName() {
        let inputs = [fictionalInput("UID-1"), fictionalInput("UID-2", "Other Interface")]
        #expect(StationCLI.resolveAudioInput("Fictional Interface", inputs: inputs, listingAvailable: true)
            == .input(uid: "UID-1", name: "Fictional Interface"))
        #expect(StationCLI.resolveAudioInput("  fictional interface ", inputs: inputs, listingAvailable: true)
            == .input(uid: "UID-1", name: "Fictional Interface"))
    }

    @Test func resolveAudioInputAmbiguous() {
        let inputs = [fictionalInput("UID-1"), fictionalInput("UID-2"), fictionalInput("UID-3", "Other Interface")]
        #expect(StationCLI.resolveAudioInput("Fictional Interface", inputs: inputs, listingAvailable: true)
            == .ambiguous("Fictional Interface", uids: ["UID-1", "UID-2"]))
        // Giving one of the IDs settles it.
        #expect(StationCLI.resolveAudioInput("UID-2", inputs: inputs, listingAvailable: true)
            == .input(uid: "UID-2", name: "Fictional Interface"))
    }

    @Test func resolveAudioInputNotFound() {
        let inputs = [fictionalInput("UID-1")]
        #expect(StationCLI.resolveAudioInput("Missing", inputs: inputs, listingAvailable: true) == .notFound("Missing"))
        #expect(StationCLI.resolveAudioInput("Missing", inputs: [], listingAvailable: true) == .notFound("Missing"))
    }

    @Test func resolveAudioInputUnderTheKillSwitchSavesTheID() {
        #expect(StationCLI.resolveAudioInput("UID-9", inputs: [], listingAvailable: false) == .savedAsID("UID-9"))
        // A listing that is there still matches first.
        #expect(StationCLI.resolveAudioInput("UID-1", inputs: [fictionalInput("UID-1")], listingAvailable: false)
            == .input(uid: "UID-1", name: "Fictional Interface"))
    }

    @Test func audioInputRefusalCopy() {
        #expect(StationCLI.audioInputProblem(.notFound("Missing"))
            == "no audio input named \"Missing\"; run noctule audio-inputs")
        #expect(StationCLI.audioInputProblem(.ambiguous("Fictional Interface", uids: ["UID-1", "UID-2"]))
            == "\"Fictional Interface\" names more than one audio input (UID-1, UID-2); give its ID")
        #expect(StationCLI.audioInputProblem(.input(uid: "UID-1", name: "N")) == nil)
        #expect(StationCLI.audioInputProblem(.savedAsID("UID-9")) == nil)
        #expect(StationCLI.audioInputNote(.savedAsID("UID-9"))
            == "station: saved \"UID-9\" as an audio input ID (no inputs are listed)")
        #expect(StationCLI.audioInputNote(.input(uid: "UID-1", name: "N")) == nil)
    }

    // MARK: Parsing

    @Test func stationAddParsesTheLineIn() throws {
        let options = try addOptions(["station", "add", "--name", "Truck", "--usb", "--serial-port", "/tmp/p",
                                      "--audio-input", "Fictional Interface", "--audio-channel", "left"])
        #expect(options.audioInput == "Fictional Interface" && options.audioChannel == .left)
        let right = try addOptions(["station", "add", "--name", "T", "--usb", "--audio-input", "UID-1", "--audio-channel", "right"])
        #expect(right.audioChannel == .right)
        let both = try addOptions(["station", "add", "--name", "T", "--usb", "--audio-input", "UID-1", "--audio-channel", "both"])
        #expect(both.audioChannel == .both)
        let bare = try addOptions(["station", "add", "--name", "T", "--usb", "--audio-input", "UID-1"])
        #expect(bare.audioInput == "UID-1" && bare.audioChannel == nil)
        let none = try addOptions(["station", "add", "--name", "T", "--usb"])
        #expect(none.audioInput == nil && none.audioChannel == nil)
    }

    @Test func stationAddAudioInputRefusals() {
        #expect(throws: CLIUsageError(message: "--audio-input needs --usb")) {
            try CLIArguments.parse(["station", "add", "--name", "A", "--host", "h", "--audio-input", "UID-1"])
        }
        #expect(throws: CLIUsageError(message: "--audio-input needs --usb")) {
            try CLIArguments.parse(["station", "add", "--name", "A", "--audio-input", "UID-1"])
        }
        #expect(throws: CLIUsageError(message: "--audio-channel needs --audio-input")) {
            try CLIArguments.parse(["station", "add", "--name", "A", "--usb", "--audio-channel", "left"])
        }
        #expect(throws: CLIUsageError(message: "--audio-channel must be left, right, or both")) {
            try CLIArguments.parse(["station", "add", "--name", "A", "--usb", "--audio-input", "UID-1", "--audio-channel", "middle"])
        }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["station", "add", "--name", "A", "--usb", "--audio-input"]) }
        #expect(throws: CLIUsageError.self) {
            try CLIArguments.parse(["station", "add", "--name", "A", "--usb", "--audio-input", "  "])
        }
        // Only `station add` takes them.
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["station", "list", "--audio-input", "UID-1"]) }
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["log", "--audio-channel", "left"]) }
    }

    // MARK: What is saved and printed

    @Test func deviceSettingsCarryTheInput() throws {
        let options = try addOptions(["station", "add", "--name", "Truck", "--usb", "--serial-port", "/tmp/p",
                                      "--audio-input", "Fictional Interface", "--audio-channel", "left"])
        let truck = StationCLI.makeStation(options)
        let device = try #require(StationCLI.deviceSettings(
            for: truck, options: options, audioInput: .input(uid: "UID-1", name: "Fictional Interface")))
        #expect(device.usbPort == "/tmp/p")
        #expect(device.audioInputDevice == "UID-1" && device.audioInputName == "Fictional Interface"
            && device.audioInputChannel == .left)
        // No port, still an input: device settings exist. No channel given: none saved (reads as both).
        let noPort = try addOptions(["station", "add", "--name", "T", "--usb", "--audio-input", "UID-9"])
        let saved = try #require(StationCLI.deviceSettings(
            for: StationCLI.makeStation(noPort), options: noPort, audioInput: .savedAsID("UID-9")))
        #expect(saved.usbPort == nil && saved.audioInputDevice == "UID-9" && saved.audioInputName == "UID-9"
            && saved.audioInputChannel == nil)
        #expect(saved.lineIn == LineInConfig(deviceUID: "UID-9", deviceName: "UID-9", channel: .both))
    }

    @Test func addedLineShowsTheLineIn() {
        var usb = Station(); usb.name = "Truck"; usb.connection.transport = .usbSerial
        let line = LineInConfig(deviceUID: "UID-1", deviceName: "Fictional Interface", channel: .left)
        #expect(StationCLI.addedLine(usb, usbPort: "/tmp/p", lineIn: line)
            == "added station \"Truck\" (USB /tmp/p, save audio: every, line-in Fictional Interface (left))")
        #expect(StationCLI.addedLine(usb, usbPort: nil, lineIn: nil) == "added station \"Truck\" (USB, save audio: every)")
    }

    @Test func stationListShowsTheLineIn() {
        var usb = Station(); usb.name = "Truck"; usb.connection.transport = .usbSerial
        let line = LineInConfig(deviceUID: "UID-1", deviceName: "Fictional Interface", channel: .left)
        #expect(StationCLI.listLines([usb], lastID: nil, usbPorts: [usb.id: "/tmp/p"], lineIns: [usb.id: line])
            == ["  Truck  USB /tmp/p  line-in Fictional Interface (left)  save audio: every"])
        #expect(StationCLI.listLines([usb], lastID: nil, usbPorts: [:], lineIns: [usb.id: line])
            == ["  Truck  USB  line-in Fictional Interface (left)  save audio: every"])
        #expect(StationCLI.listLines([usb], lastID: nil, usbPorts: [usb.id: "/tmp/p"])
            == ["  Truck  USB /tmp/p  save audio: every"])
        // A network station never shows a line-in.
        let net = station("Alpha", host: "192.0.2.10")
        #expect(StationCLI.listLines([net], lastID: nil, lineIns: [net.id: line])
            == ["  Alpha  192.0.2.10  udp 50536  rtsp 554  save audio: every"])
    }

    // MARK: Adding

    @Test func stationAddSavesTheInputBeforeTheStation() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "noctule-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OrderRecordingStore(LocalSettingsStore(directory: dir))
        let options = try addOptions(["station", "add", "--name", "Truck", "--usb", "--serial-port", "/tmp/p",
                                      "--audio-input", "Fictional Interface", "--audio-channel", "left"])
        let inputs = [fictionalInput("UID-1")]
        let result = try await StationCLI.add(options, existing: [], store: store, inputs: inputs, listingAvailable: true)
        guard case .added(let line, let notes) = result else { Issue.record("not added: \(result)"); return }
        #expect(line == "added station \"Truck\" (USB /tmp/p, save audio: every, line-in Fictional Interface (left))")
        #expect(notes.isEmpty)
        #expect(await store.events == ["device", "station"])
        let stations = try await store.stations()
        let device = try await store.deviceSettings(for: stations[0].id)
        #expect(device.usbPort == "/tmp/p" && device.audioInputDevice == "UID-1"
            && device.audioInputName == "Fictional Interface" && device.audioInputChannel == .left)
    }

    @Test func stationAddRefusesAnInputThatIsNotThereAndSavesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "noctule-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OrderRecordingStore(LocalSettingsStore(directory: dir))
        let options = try addOptions(["station", "add", "--name", "Truck", "--usb", "--audio-input", "Missing"])
        let missing = try await StationCLI.add(options, existing: [], store: store, inputs: [fictionalInput("UID-1")],
                                               listingAvailable: true)
        #expect(missing == .refused(["no audio input named \"Missing\"; run noctule audio-inputs"]))
        let twice = try addOptions(["station", "add", "--name", "Truck", "--usb", "--audio-input", "Fictional Interface"])
        let ambiguous = try await StationCLI.add(twice, existing: [], store: store,
                                                 inputs: [fictionalInput("UID-1"), fictionalInput("UID-2")], listingAvailable: true)
        #expect(ambiguous == .refused(["\"Fictional Interface\" names more than one audio input (UID-1, UID-2); give its ID"]))
        #expect(await store.events.isEmpty)
        #expect(try await store.stations().isEmpty)
    }

    @Test func stationAddUnderTheKillSwitchSavesTheIDWithANote() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "noctule-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OrderRecordingStore(LocalSettingsStore(directory: dir))
        let options = try addOptions(["station", "add", "--name", "Truck", "--usb", "--audio-input", "UID-9",
                                      "--audio-channel", "right"])
        let result = try await StationCLI.add(options, existing: [], store: store, inputs: [], listingAvailable: false)
        #expect(result == .added(line: "added station \"Truck\" (USB, save audio: every, line-in UID-9 (right))",
                                 notes: ["station: saved \"UID-9\" as an audio input ID (no inputs are listed)"]))
        #expect(await store.events == ["device", "station"])
    }

    @Test func stationAddWithoutAnInputBehavesAsBefore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "noctule-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OrderRecordingStore(LocalSettingsStore(directory: dir))
        let plain = try addOptions(["station", "add", "--name", "Truck", "--usb"])
        #expect(try await StationCLI.add(plain, existing: [], store: store, inputs: [], listingAvailable: false)
            == .added(line: "added station \"Truck\" (USB, save audio: every)", notes: []))
        #expect(await store.events == ["station"])
        // A problem with the station (a duplicate name) is the usual refusal, and nothing more is saved.
        let again = try await StationCLI.add(plain, existing: try await store.stations(), store: store, inputs: [],
                                             listingAvailable: false)
        guard case .invalid(let problems) = again else { Issue.record("not invalid: \(again)"); return }
        #expect(problems.count == 1)
        #expect(await store.events == ["station"])
    }
}

/// A settings store that notes the order of the writes `station add` makes.
private actor OrderRecordingStore: SettingsStore {
    private let base: LocalSettingsStore
    private(set) var events: [String] = []
    init(_ base: LocalSettingsStore) { self.base = base }
    func stations() async throws -> [Station] { try await base.stations() }
    func save(_ station: Station) async throws { events.append("station"); try await base.save(station) }
    func update(id: UUID, _ mutate: @Sendable (inout Station) -> Void) async throws -> Station? {
        try await base.update(id: id, mutate)
    }
    func deleteStation(id: UUID) async throws { try await base.deleteStation(id: id) }
    func deviceSettings(for id: UUID) async throws -> StationDeviceSettings { try await base.deviceSettings(for: id) }
    func saveDeviceSettings(_ s: StationDeviceSettings) async throws {
        events.append("device"); try await base.saveDeviceSettings(s)
    }
    func lastStationID() async -> UUID? { await base.lastStationID() }
    func setLastStationID(_ id: UUID?) async { await base.setLastStationID(id) }
}
