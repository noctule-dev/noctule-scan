// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleStore

@Suite(.timeLimit(.minutes(3))) struct StationTests {
    @Test func decodesFromEmptyJSON() throws {
        let s = try JSONDecoder().decode(Station.self, from: Data("{}".utf8))
        #expect(s.name == "New Station")
        #expect(s.connection.udpPort == 50536)
        #expect(s.connection.rtspPort == 554)
        #expect(s.connection.transport == .network)
        #expect(s.recording == RecordingRules())
        #expect(s.keyMap == KeyMap())
        #expect(s.appearance == Appearance())
        #expect(s.preferredView == .scanner)
        #expect(s.savedFilters.isEmpty)
        #expect(s.countsResetAt == nil)
        // nested objects tolerate missing keys too
        let c = try JSONDecoder().decode(StationConnection.self, from: Data("{}".utf8))
        #expect(c == StationConnection())
        let f = try JSONDecoder().decode(HitFilter.self, from: Data("{}".utf8))
        #expect(f.name == "" && !f.onlyNew && f.modes.isEmpty)
    }

    @Test func roundTrips() throws {
        var s = Station()
        s.name = "Base"
        s.connection.host = "scanner.example.test"
        s.connection.modelOverride = .sds200
        s.recording.saveAudio = .onlyNew
        s.recording.retentionDays = 30
        s.keyMap.overrides["4"] = "⌘4"
        s.appearance.colorMode = .whiteOnBlack
        s.appearance.profileImportedAt = Date(timeIntervalSince1970: 1_700_000_000)
        s.preferredView = .macStyle
        var f = HitFilter(); f.name = "New"; f.onlyNew = true; f.modes = ["P25"]; f.since = Date(timeIntervalSince1970: 1_700_000_100)
        s.savedFilters = [f]
        s.countsResetAt = Date(timeIntervalSince1970: 1_700_000_200)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Station.self, from: try enc.encode(s))
        #expect(back == s)
        let d = StationDeviceSettings(stationID: s.id)
        #expect(try JSONDecoder().decode(StationDeviceSettings.self, from: try JSONEncoder().encode(d)) == d)
    }

    @Test func ignoresUnknownKeys() throws {
        let json = #"{"name":"X","futureField":{"a":1},"connection":{"host":"h.test","newThing":true}}"#
        let s = try JSONDecoder().decode(Station.self, from: Data(json.utf8))
        #expect(s.name == "X")
        #expect(s.connection.host == "h.test")
        #expect(s.connection.udpPort == 50536)
    }

    @Test func keyMapDefaultsCoverEveryKey() {
        for model in ScannerModel.allCases {
            let d = KeyMap.defaults(for: model)
            #expect(FrontPanelKey.allCases.count == 27)
            for k in FrontPanelKey.allCases {
                #expect(!(d[k] ?? "").isEmpty, "\(model) missing \(k)")
            }
            #expect(Set(d.values).count == d.count, "\(model) has duplicate key equivalents")
        }
        let d = KeyMap.defaults(for: .sds200)
        #expect(d[.digit4] == "4")
        #expect(d[.avoid] == "a" && d[.function] == "f" && d[.menu] == "m")
        #expect(d[.enterYes] == "↩" && d[.dotNo] == ".")
        #expect(d[.scrollLeft] == "←" && d[.scrollRight] == "→" && d[.scrollPush] == "space")
        #expect(d[.soft1] == "F1" && d[.soft2] == "F2" && d[.soft3] == "F3")
    }

    @Test func overridesApply() {
        var km = KeyMap()
        km.overrides[FrontPanelKey.digit4.rawValue] = "⌘4"
        km.overrides[FrontPanelKey.menu.rawValue] = "x"
        let r = km.resolved(for: .sds200)
        #expect(r[.digit4] == "⌘4")
        #expect(r[.menu] == "x")
        #expect(r[.digit5] == "5")
        #expect(r.count == 27)
        // unknown override keys are ignored
        km.overrides["nope"] = "z"
        #expect(km.resolved(for: .sds200).count == 27)
    }

    @Test func validationFindsIssues() {
        var s = Station()
        #expect(s.validate() == [.missingHost])
        s.connection.host = "  "
        #expect(s.validate() == [.missingHost])
        s.connection.host = "h.test"
        #expect(s.validate().isEmpty)
        s.name = "   "
        #expect(s.validate() == [.emptyName])
        s.name = "Ok"
        s.recording.minimumDuration = 61
        #expect(s.validate() == [.invalidMinimumDuration])
        s.recording.minimumDuration = -1
        #expect(s.validate() == [.invalidMinimumDuration])
        s.recording.minimumDuration = 60
        s.recording.maxTransmission = 9
        #expect(s.validate() == [.invalidMaxTransmission])
        s.recording.maxTransmission = 3601
        #expect(s.validate() == [.invalidMaxTransmission])
        s.recording.maxTransmission = 3600
        #expect(s.validate().isEmpty)
        // a USB station needs no host
        var u = Station(); u.connection.transport = .usbSerial
        #expect(u.validate().isEmpty)
    }

    // MARK: The reconnect cooldown (Plan 5 Task 2)

    @Test func reconnectCooldownValidationEdges() {
        var s = Station()
        s.connection.host = "h.test"
        #expect(s.connection.reconnectCooldownSeconds == 120)
        for (seconds, valid) in [(-1, false), (0, true), (120, true), (121, false)] {
            s.connection.reconnectCooldownSeconds = seconds
            #expect(s.validate() == (valid ? [] : [.invalidReconnectCooldown]), "\(seconds)")
        }
        #expect(StationIssue.invalidReconnectCooldown.message == "the reconnect wait must be 0-120 s")
    }

    /// Stations saved before Plan 5 have no key and read as 120; a stored value round-trips.
    @Test func reconnectCooldownDecodesTolerantly() throws {
        let old = #"{"name":"X","connection":{"host":"h.test","udpPort":50000}}"#
        #expect(try JSONDecoder().decode(Station.self, from: Data(old.utf8)).connection.reconnectCooldownSeconds == 120)
        let set = #"{"connection":{"host":"h.test","reconnectCooldownSeconds":30}}"#
        #expect(try JSONDecoder().decode(Station.self, from: Data(set.utf8)).connection.reconnectCooldownSeconds == 30)
        // A hand-edited or imported value outside 0...120 reads as the conservative default.
        for bad in [500, -5, 121, -1] {
            let json = #"{"connection":{"host":"h.test","reconnectCooldownSeconds":"# + "\(bad)}}"
            #expect(try JSONDecoder().decode(Station.self, from: Data(json.utf8)).connection.reconnectCooldownSeconds == 120,
                    "\(bad)")
        }
        for edge in [0, 120] {
            let json = #"{"connection":{"reconnectCooldownSeconds":"# + "\(edge)}}"
            #expect(try JSONDecoder().decode(Station.self, from: Data(json.utf8)).connection.reconnectCooldownSeconds == edge)
        }
        var s = Station()
        s.connection.reconnectCooldownSeconds = 0
        let back = try JSONDecoder().decode(Station.self, from: try JSONEncoder().encode(s))
        #expect(back.connection.reconnectCooldownSeconds == 0)
        #expect(back == s)
    }

    /// The station's value is the clean-close wait, clamped to the full one (which stays 120 s
    /// unless a mock-only test override shortens it).
    @Test func reconnectCooldownPolicy() {
        var c = StationConnection()
        #expect(c.reconnectCooldownPolicy() == .standard)
        c.reconnectCooldownSeconds = 0
        #expect(c.reconnectCooldownPolicy() == RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .zero))
        c.reconnectCooldownSeconds = 30
        #expect(c.reconnectCooldownPolicy().afterCleanClose == .seconds(30))
        #expect(c.reconnectCooldownPolicy(full: .seconds(5)) == .symmetric(.seconds(5)))
        c.reconnectCooldownSeconds = 0
        #expect(c.reconnectCooldownPolicy(full: .seconds(5)) == RTSPCooldownPolicy(full: .seconds(5), afterCleanClose: .zero))
        // A value outside 0...120 (a hand-edited file) is clamped, never trusted.
        c.reconnectCooldownSeconds = -5
        #expect(c.reconnectCooldownPolicy().afterCleanClose == .zero)
        c.reconnectCooldownSeconds = 500
        #expect(c.reconnectCooldownPolicy() == .standard)
    }
}
