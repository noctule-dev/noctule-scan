// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import Foundation
import NoctuleAppCore
import NoctuleKit
import NoctuleKitTestSupport
import NoctuleStore
import Testing
@testable import NoctuleScan

/// The Mac-style view's text, "Active now", and the view-choice save, without any views.
@MainActor @Suite(.timeLimit(.minutes(3))) struct MacStyleTests {
    private func info(_ inner: String, attrs: String = #"Mode="Trunk Scan" V_Screen="trunk_scan""#) throws -> ScannerInfo {
        try ScannerInfo(xml: NoctuleKit.XMLNode.parse(Data("<ScannerInfo \(attrs)>\(inner)</ScannerInfo>".utf8)))
    }

    private let connected = SessionPhase.connected(model: "SDS200", firmware: "1.26.01")

    private var transmission: String {
        #"<MonitorList Name="Test Favorites" Index="1"/>"#
            + #"<System Name="Testville P25" Index="101" SystemType="P25 Trunk" Hold="Off" Avoid="Off"/>"#
            + #"<Department Name="Testville Fire" Index="201" Hold="Off" Avoid="Off"/>"#
            + #"<TGID Name="Fire Dispatch" Index="1001" TGID="TGID:1201" Hold="Off" Avoid="Off"/>"#
            + #"<UnitID Name="UID:7702" U_Id="UID:7702"/>"#
            + #"<Site Name="Testville Simulcast" Index="301" Mod="P25"/>"#
            + #"<SiteFrequency Freq=" 852.512500MHz" SAD="2A1"/>"#
            + #"<Property VOL="2" SQL="1" Sig="3" Rssi="-71"/>"#
    }

    /// The SDS150 fixture (`sds150-gsi-serial.txt`, its `GSI,<XML>,` line dropped), with `Sig` set.
    private func sds150(sig: Int) throws -> ScannerInfo {
        let text = String(decoding: fixture("sds150-gsi-serial.txt"), as: UTF8.self)
        let document = try #require(text.split(separator: "\n", maxSplits: 1).last)
        let edited = document.replacingOccurrences(of: #"Sig="0""#, with: "Sig=\"\(sig)\"")
        return try ScannerInfo(xml: NoctuleKit.XMLNode.parse(Data(edited.utf8)))
    }

    /// An SDS150 stepping through its conventional channels names each one, but nothing is on
    /// the air until `Sig` rises.
    @Test func headlineWhileAnSDS150Scans() throws {
        #expect(MacStyleText.headline(try sds150(sig: 0), phase: connected, stationName: "S") == "Scanning…")
        #expect(MacStyleText.headline(try sds150(sig: 3), phase: connected, stationName: "S") == "Plow Dispatch")
    }

    @Test func chipsDuringATransmission() throws {
        let chips = MacStyleText.chips(try info(transmission))
        #expect(chips == [
            InfoChip(label: "Mode", value: "P25"), InfoChip(label: "TGID", value: "1201"),
            InfoChip(label: "UID", value: "7702"), InfoChip(label: "NAC / Tone", value: "2A1"),
            InfoChip(label: "Freq", value: "852.5125 MHz"), InfoChip(label: "RSSI", value: "-71 dBm"),
        ])
    }

    @Test func codeChipTakesTheScannersPrefixAsItsLabel() {
        #expect(MacStyleText.codeChip("NAC 2A1h") == ("NAC", "2A1h"))
        #expect(MacStyleText.codeChip("CTCSS 100.0Hz") == ("CTCSS", "100.0Hz"))
        #expect(MacStyleText.codeChip("2A1") == ("NAC / Tone", "2A1"))
        #expect(MacStyleText.codeChip("  ") == ("NAC / Tone", nil))
        #expect(MacStyleText.codeChip(nil) == ("NAC / Tone", nil))
    }

    @Test func idleChipsHideWhatIsMissing() throws {
        let idle = try info(#"<System Name="Testville P25" Index="101" SystemType="P25 Trunk"/>"#
                            + #"<Site Name="Testville Simulcast" Index="301" Mod="P25"/>"#
                            + #"<SiteFrequency Freq=" 851.012500MHz" SAD=""/><Property Rssi="-999"/>"#)
        #expect(MacStyleText.chips(idle) == [InfoChip(label: "Mode", value: "P25"),
                                             InfoChip(label: "Freq", value: "851.0125 MHz")])
        #expect(MacStyleText.chips(nil) == [])
        #expect(MacStyleText.headline(idle, phase: connected, stationName: "S") == "Scanning…")
        #expect(MacStyleText.breadcrumb(idle) == "Testville P25")
    }

    @Test func headlineBreadcrumbAndScanning() throws {
        let live = try info(transmission)
        #expect(MacStyleText.headline(live, phase: connected, stationName: "S") == "Fire Dispatch")
        #expect(MacStyleText.breadcrumb(live) == "Testville P25 › Testville Fire")
        #expect(MacStyleText.scanning(live) == "Trunk Scan · Test Favorites")
        #expect(MacStyleText.headline(nil, phase: .connecting, stationName: "S") == "Connecting…")
        #expect(MacStyleText.breadcrumb(nil) == nil)
        #expect(MacStyleText.scanning(nil) == nil)
    }

    @Test func headlineWhileWaiting() {
        #expect(MacStyleText.headline(nil, phase: .waitingForScanner(hint: "x"), stationName: "S")
                == "Waiting for the scanner")
    }

    @Test func activeNowIsTheNewestOpenHit() {
        func logged(_ name: String, ended: Bool) -> LoggedHit {
            LoggedHit(hit: Hit(id: UUID(), key: HitKey(system: "Testville", talkgroupID: name, frequencyMHz: nil),
                               startedAt: Date(), endedAt: ended ? Date() : nil, startInstant: .now, channel: name),
                      audioPath: nil, audioError: nil, isNew: false)
        }
        let open = logged("B", ended: false)
        #expect(RecentHitText.activeHit([logged("A", ended: true), open, logged("C", ended: false)]) == open)
        #expect(RecentHitText.activeHit([logged("A", ended: true)]) == nil)
        #expect(RecentHitText.activeHit([]) == nil)
    }

    /// Design §5.3: Hold and Avoid aren't offered in a menu (Avoid would leave it), in either view.
    @Test func holdAndAvoidDisabledInMenu() {
        let inMenu = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: true, hasAudio: true)
        #expect(!inMenu.hold)
        #expect(!inMenu.avoid)
        #expect(inMenu.listen && inMenu.logging, "Listen and Logging stay")
        let scanning = MacControlsBar.Enablement(connected: true, canHoldAny: true, inMenu: false, hasAudio: true)
        #expect(scanning.hold && scanning.avoid)
        let nothingToHold = MacControlsBar.Enablement(connected: true, canHoldAny: false, inMenu: false, hasAudio: true)
        #expect(!nothingToHold.hold && nothingToHold.avoid)
        let offline = MacControlsBar.Enablement(connected: false, canHoldAny: false, inMenu: false, hasAudio: true)
        #expect(!offline.hold && !offline.avoid && !offline.listen && !offline.logging)
    }

    // MARK: View choice

    /// QA (Task 13, M3): the save-failure alert is a sentence, not a raw enum dump.
    @Test func saveFailureIsReadable() {
        let message = StationViewPreference.failureMessage(
            SettingsStoreError.unreadable(path: "/tmp/x/stations.json", reason: "Permission denied"))
        #expect(message == "This window keeps the view you chose, but it won't be remembered next time. "
                + "can't read /tmp/x/stations.json: Permission denied; nothing was changed")
        #expect(!message.contains("unreadable(path:"))
    }

    @Test func savingTheViewChangesOnlyPreferredView() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = LocalSettingsStore(directory: dir)
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        try await settings.save(station)
        // Edited elsewhere after the window loaded its copy: the save keeps the edit.
        station.name = "Renamed"
        try await settings.save(station)

        try await StationViewPreference.save(.macStyle, stationID: station.id, in: settings)
        let saved = try #require(try await settings.stations().first)
        #expect(saved.preferredView == .macStyle)
        #expect(saved.name == "Renamed")
        try await StationViewPreference.save(.scanner, stationID: station.id, in: settings)
        #expect(try await settings.stations().first?.preferredView == .scanner)
        try await StationViewPreference.save(.macStyle, stationID: UUID(), in: settings)  // gone: nothing
        #expect(try await settings.stations().count == 1)
    }

    /// A store whose `stations()` lets another window rename the station right after the read:
    /// it returns what it read, then renames in the wrapped store. A read-then-save caller writes
    /// that stale copy back over the rename; `update` never calls `stations()`.
    actor RenameAfterReadStore: SettingsStore {
        let inner: LocalSettingsStore
        let newName: String
        private(set) var renamed = false
        init(inner: LocalSettingsStore, newName: String) { self.inner = inner; self.newName = newName }
        func stations() async throws -> [Station] {
            let read = try await inner.stations()
            let name = newName
            for s in read { try await inner.update(id: s.id) { $0.name = name } }
            renamed = true
            return read
        }
        func save(_ station: Station) async throws { try await inner.save(station) }
        func update(id: UUID, _ mutate: @Sendable (inout Station) -> Void) async throws -> Station? {
            try await inner.update(id: id, mutate)
        }
        func deleteStation(id: UUID) async throws { try await inner.deleteStation(id: id) }
        func deviceSettings(for id: UUID) async throws -> StationDeviceSettings { try await inner.deviceSettings(for: id) }
        func saveDeviceSettings(_ s: StationDeviceSettings) async throws { try await inner.saveDeviceSettings(s) }
        func lastStationID() async -> UUID? { await inner.lastStationID() }
        func setLastStationID(_ id: UUID?) async { await inner.setLastStationID(id) }
    }

    /// R18, deterministic: a rename that lands between a read and a write survives the view save.
    @Test func viewSaveKeepsARenameThatLandsAfterARead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = LocalSettingsStore(directory: dir)
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        try await inner.save(station)
        let store = RenameAfterReadStore(inner: inner, newName: "Renamed Elsewhere")
        try await StationViewPreference.save(.macStyle, stationID: station.id, in: store)
        let saved = try #require(try await inner.stations().first)
        // Whatever the store holds after any rename must survive: "Renamed Elsewhere" if the save
        // read (and so triggered the rename), else the original name. A read-then-save writes
        // "Test Station" back after the rename and fails here.
        let expected = await store.renamed ? "Renamed Elsewhere" : "Test Station"
        #expect(saved.name == expected)
        #expect(saved.preferredView == .macStyle)
    }

    /// R18: view saves racing a rename made in another window never undo the rename.
    @Test func viewSaveDoesNotUndoAConcurrentRename() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = LocalSettingsStore(directory: dir)
        var station = Station()
        station.name = "Test Station"
        station.connection.host = "127.0.0.1"
        try await settings.save(station)
        let id = station.id
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    if i == 20 {
                        try await settings.update(id: id) { $0.name = "Renamed" }
                    } else {
                        try await StationViewPreference.save(i.isMultiple(of: 2) ? .macStyle : .scanner,
                                                             stationID: id, in: settings)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await settings.stations().first?.name == "Renamed")
    }

}
#endif
