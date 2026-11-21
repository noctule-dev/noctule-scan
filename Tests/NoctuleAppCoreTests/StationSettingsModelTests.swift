// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleStore
@testable import NoctuleAppCore

// StationSettingsModel, KeyMapEditing, RecordingInput and StationText against LocalSettingsStore in
// a temporary directory. All names are fictional.

@MainActor
private final class ChangeLog {
    var saved: [Station] = []
}

@MainActor
private func withSettings(_ stations: [Station],
                          _ body: (LocalSettingsStore, StationSettingsModel, ChangeLog) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noctule-station-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LocalSettingsStore(directory: dir)
    for s in stations { try await store.save(s) }
    let log = ChangeLog()
    let model = StationSettingsModel(station: stations[0], settings: store) { log.saved.append($0) }
    await model.load()
    try await body(store, model, log)
}

private func station(_ name: String) -> Station {
    var s = Station()
    s.name = name
    s.connection.host = "127.0.0.1"
    return s
}

@Suite struct StationSettingsModelTests {
    @MainActor @Test func eachSetterChangesOnlyItsFieldAndReportsTheStations() async throws {
        let first = station("Test Station")
        let other = station("Other Station")
        try await withSettings([first, other]) { store, model, log in
            // Changed elsewhere after the page opened: must survive every setter below.
            try await store.update(id: first.id) { $0.name = "Renamed Elsewhere"; $0.preferredView = .macStyle }

            await model.setSaveAudio(.onlyNew)
            await model.setMinimumDuration(2.5)
            await model.setRetentionDays(30)
            await model.setColorMode(.whiteOnBlack)
            #expect(model.problem == nil)

            let stored = try #require(try await store.stations().first { $0.id == first.id })
            #expect(stored.name == "Renamed Elsewhere" && stored.preferredView == .macStyle)
            #expect(stored.recording.saveAudio == .onlyNew)
            #expect(stored.recording.minimumDuration == 2.5)
            #expect(stored.recording.retentionDays == 30)
            #expect(stored.appearance.colorMode == .whiteOnBlack)
            #expect(model.station == stored)
            #expect(log.saved.count == 4)
            #expect(log.saved.last == stored, "the saved station goes to stationChanged")

            await model.setRetentionDays(nil)
            do { let value = try await store.stations().first { $0.id == first.id }?.recording.retentionDays; #expect(value == nil) }
        }
    }

    @MainActor @Test func outOfRangeValuesAreIgnored() async throws {
        let first = station("Test Station")
        try await withSettings([first]) { store, model, log in
            await model.setMinimumDuration(61)
            await model.setMinimumDuration(-1)
            await model.setRetentionDays(0)
            #expect(log.saved.isEmpty)
            do { let value = try await store.stations().first?.recording; #expect(value == RecordingRules()) }
        }
    }

    @MainActor @Test func keyMapOverridesStoreTheChordDisplayAndDefaultsClearThem() async throws {
        let first = station("Test Station")
        try await withSettings([first]) { store, model, _ in
            await model.setChord(KeyChord(key: "l", modifiers: [.command]), for: .avoid, model: .sds200)
            do { let value = try await store.stations().first?.keyMap.overrides; #expect(value == ["L": "⌘l"]) }
            // The resolved map is what the window's router uses.
            let router = KeyboardRouter(map: model.station.keyMap.resolved(for: .sds200))
            #expect(router.key(for: KeyChord(key: "l", modifiers: [.command])) == .avoid)
            #expect(router.key(for: KeyChord(key: "a")) == nil)

            // Binding the default chord again removes the override.
            await model.setChord(KeyChord(key: "a"), for: .avoid, model: .sds200)
            do { let value = try await store.stations().first?.keyMap.overrides; #expect(value == [:]) }

            await model.setChord(KeyChord(key: "x"), for: .zip, model: .sds200)
            await model.setChord(nil, for: .zip, model: .sds200)
            do { let value = try await store.stations().first?.keyMap.overrides; #expect(value == [:]) }

            await model.setChord(KeyChord(key: "x"), for: .zip, model: .sds200)
            await model.setChord(KeyChord(key: "w"), for: .range, model: .sds200)
            await model.resetKeyMap()
            do { let value = try await store.stations().first?.keyMap.overrides; #expect(value == [:]) }
        }
    }

    @MainActor @Test func recordingsFolderIsDeviceOnly() async throws {
        let first = station("Test Station")
        try await withSettings([first]) { store, model, log in
            await model.setRecordingsFolder("/tmp/noctule-test-folder")
            do { let value = try await store.deviceSettings(for: first.id).recordingsFolder; #expect(value == "/tmp/noctule-test-folder") }
            #expect(model.device.recordingsFolder == "/tmp/noctule-test-folder")
            do { let value = try await store.stations().first; #expect(value == first, "the synced station is untouched") }
            #expect(log.saved.isEmpty)
            await model.setRecordingsFolder(nil)
            do { let value = try await store.deviceSettings(for: first.id).recordingsFolder; #expect(value == nil) }
        }
    }

    @MainActor @Test func aDeletedStationIsNotRecreated() async throws {
        let first = station("Test Station")
        try await withSettings([first]) { store, model, log in
            try await store.deleteStation(id: first.id)
            await model.setColorMode(.blackOnWhite)
            #expect(model.problem == "This station no longer exists.")
            #expect(try await store.stations().isEmpty)
            #expect(log.saved.isEmpty)
        }
    }

    @MainActor @Test func adoptTakesOnlyTheSameStation() async throws {
        let first = station("Test Station")
        try await withSettings([first]) { _, model, _ in
            var renamed = first; renamed.name = "Renamed Station"
            model.adopt(renamed)
            #expect(model.station.name == "Renamed Station")
            model.adopt(station("Other Station"))
            #expect(model.station.name == "Renamed Station")
        }
    }

    @Test func keyMapRowsShowConflictsBothWays() throws {
        var map = KeyMap()
        map.overrides[FrontPanelKey.zip.rawValue] = "a"  // Avoid's default
        let rows = KeyMapEditing.rows(for: map, model: .sds200)
        #expect(rows.count == FrontPanelKey.allCases.count)
        let zip = try #require(rows.first { $0.key == .zip })
        let avoid = try #require(rows.first { $0.key == .avoid })
        #expect(zip.chord == "a" && zip.isOverridden && zip.conflicts == [.avoid])
        #expect(avoid.chord == "a" && !avoid.isOverridden && avoid.conflicts == [.zip])
        #expect(rows.filter { !$0.conflicts.isEmpty }.count == 2)
        #expect(KeyMapEditing.rows(for: KeyMap(), model: .sds200).allSatisfy { $0.conflicts.isEmpty && $0.chord != nil })
    }

    @Test func overrideValueUsesTheDisplayOrder() {
        let chord = KeyChord(key: "4", modifiers: [.command, .shift])
        #expect(KeyMapEditing.overrideValue(chord, for: .digit4, model: .sds200) == "⇧⌘4")
        #expect(KeyMapEditing.overrideValue(KeyChord(key: "F1"), for: .soft1, model: .sds200) == nil)
        #expect(KeyMapEditing.overrideValue(nil, for: .soft1, model: .sds200) == nil)
    }

    @Test func recordingInputParsing() {
        #expect(RecordingInput.minimumLength("0.5") == 0.5)
        #expect(RecordingInput.minimumLength(" 2 ") == 2)
        #expect(RecordingInput.minimumLength("1,5") == 1.5)
        #expect(RecordingInput.minimumLength("0") == 0)
        #expect(RecordingInput.minimumLength("60") == 60)
        #expect(RecordingInput.minimumLength("60.1") == nil)
        #expect(RecordingInput.minimumLength("-1") == nil)
        #expect(RecordingInput.minimumLength("abc") == nil)
        #expect(RecordingInput.minimumLength("nan") == nil)
        #expect(RecordingInput.retentionDays("30") == 30)
        #expect(RecordingInput.retentionDays("0") == nil)
        #expect(RecordingInput.retentionDays("3651") == nil)
        #expect(RecordingInput.retentionDays("1.5") == nil)
        #expect(RecordingInput.format(seconds: 0.5) == "0.5")
        #expect(RecordingInput.format(seconds: 2) == "2")
        #expect(RecordingInput.format(seconds: 12.25) == "12.25")
        #expect(RecordingInput.format(seconds: 0) == "0")
    }

    @Test func stationText() {
        var s = station("Test Station")
        s.connection.udpPort = 50999
        #expect(StationText.address(s) == "127.0.0.1:50999")
        #expect(StationText.model(s) == "model detected on connect")
        #expect(StationText.model(s, connected: .sds200) == "SDS200")
        s.connection.modelOverride = .sds150
        #expect(StationText.model(s) == "SDS150")
        s.connection.host = "  "
        #expect(StationText.address(s) == "no address")
        #expect(StationText.port("554") == 554)
        #expect(StationText.port("0") == nil)
        #expect(StationText.port("65536") == nil)
        #expect(StationText.port("x") == nil)
        #expect(StationText.importSummary(1) == "Imported 1 station.")
        #expect(StationText.importSummary(3) == "Imported 3 stations.")
        #expect(StationText.importSummary(0) == "Imported 0 stations.")
    }

    /// A USB station shows "USB" and its saved port, if any, where a network station shows its
    /// address; a host left over from before a switch to USB isn't shown.
    @Test func addressOfAUSBStation() {
        var s = station("Handheld")
        s.connection.transport = .usbSerial
        #expect(StationText.address(s) == "USB")
        #expect(StationText.address(s, usbPort: "/dev/ttys012") == "USB /dev/ttys012")
        #expect(StationText.address(s, usbPort: "  ") == "USB")
        // A network station ignores a saved port.
        s.connection.transport = .network
        #expect(StationText.address(s, usbPort: "/dev/ttys012") == "127.0.0.1:50536")
    }
}
