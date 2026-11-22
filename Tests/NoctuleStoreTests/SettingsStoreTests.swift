// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleStore

@Suite(.timeLimit(.minutes(3))) struct SettingsStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noctule-settings-\(UUID().uuidString)", isDirectory: true)
    }
    private func station(_ name: String, id: UUID = UUID()) -> Station {
        var s = Station(); s.id = id; s.name = name; s.connection.host = "scanner.example.test"; return s
    }

    @Test func saveLoadDelete() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        #expect(try await store.stations().isEmpty)
        let a = station("A"), b = station("B")
        try await store.save(a); try await store.save(b)
        #expect(Set(try await store.stations().map(\.id)) == [a.id, b.id])
        var a2 = a; a2.name = "A2"
        try await store.save(a2)
        let all = try await store.stations()
        #expect(all.count == 2 && all.first { $0.id == a.id }?.name == "A2")
        // persists across instances
        #expect(try await LocalSettingsStore(directory: dir).stations().count == 2)
        var dev = StationDeviceSettings(stationID: a.id); dev.usbPort = "/dev/x"
        try await store.saveDeviceSettings(dev)
        try await store.deleteStation(id: a.id)
        #expect(try await store.stations().map(\.id) == [b.id])
        #expect(try await store.deviceSettings(for: a.id) == StationDeviceSettings(stationID: a.id))
    }

    /// `update` changes only what its closure touches: a rename saved elsewhere survives a
    /// view-preference update made from an older copy (controller ruling R18).
    @Test func updateChangesOneFieldAndKeepsOthers() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let a = station("A"), b = station("B")
        try await store.save(a); try await store.save(b)
        var renamed = a; renamed.name = "A renamed"
        try await store.save(renamed)            // another window's edit
        let result = try await store.update(id: a.id) { $0.preferredView = .macStyle }
        #expect(result?.name == "A renamed" && result?.preferredView == .macStyle)
        let stored = try await LocalSettingsStore(directory: dir).stations()
        #expect(stored.first { $0.id == a.id }?.name == "A renamed")
        #expect(stored.first { $0.id == a.id }?.preferredView == .macStyle)
        #expect(stored.first { $0.id == b.id } == b)
        // The closure can't move the station to another id.
        let kept = try await store.update(id: b.id) { $0.id = UUID(); $0.name = "B2" }
        #expect(kept?.id == b.id)
        #expect(try await store.stations().map(\.id) == [a.id, b.id])
    }

    @Test func updateOfDeletedStationReturnsNilAndDoesNotRecreate() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let a = station("A"), b = station("B")
        try await store.save(a); try await store.save(b)
        try await store.deleteStation(id: a.id)
        let result = try await store.update(id: a.id) { $0.name = "Zombie" }
        #expect(result == nil)
        #expect(try await store.stations().map(\.id) == [b.id])
    }

    /// An undecodable stations.json is quarantined and reads as empty, so the station is gone:
    /// update returns nil and writes nothing (no stations.json holding a re-created station).
    @Test func updateOnACorruptFileQuarantinesAndReturnsNil() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json {{".utf8).write(to: dir.appendingPathComponent("stations.json"))
        let store = LocalSettingsStore(directory: dir)
        let result = try await store.update(id: UUID()) { $0.name = "Zombie" }
        #expect(result == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("stations.json.corrupt-") })
        #expect(!names.contains("stations.json"))
        #expect(try await store.stations().isEmpty)
    }

    @Test func updateThrowsOnUnreadableFile() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stations.json")
        let store = LocalSettingsStore(directory: dir)
        let a = station("A")
        try await store.save(a)
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        await #expect(throws: SettingsStoreError.self) { _ = try await store.update(id: a.id) { $0.name = "X" } }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func deviceSettingsStayLocal() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let a = station("A")
        try await store.save(a)
        var dev = StationDeviceSettings(stationID: a.id)
        dev.recordingsFolder = "/Users/someone/Music/A"
        try await store.saveDeviceSettings(dev)
        let stations = try String(contentsOf: dir.appendingPathComponent("stations.json"), encoding: .utf8)
        #expect(!stations.contains("recordingsFolder") && !stations.contains("/Users/someone"))
        let device = try String(contentsOf: dir.appendingPathComponent("device.json"), encoding: .utf8)
        #expect(device.contains("recordingsFolder"))
        #expect(try await store.deviceSettings(for: a.id) == dev)
        #expect(stations.contains("\"version\" : 1") || stations.contains("\"version\":1"))
    }

    @Test func corruptFileIsQuarantined() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json {{".utf8).write(to: dir.appendingPathComponent("stations.json"))
        try Data("\u{0}garbage".utf8).write(to: dir.appendingPathComponent("app.json"))
        let store = LocalSettingsStore(directory: dir)
        #expect(try await store.stations().isEmpty)
        #expect(await store.lastStationID() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("stations.json.corrupt-") })
        #expect(names.contains { $0.hasPrefix("app.json.corrupt-") })
        // still usable afterwards
        try await store.save(station("A"))
        #expect(try await store.stations().count == 1)
    }

    /// Only a missing file means "no stations". Any other read failure throws, so a save can
    /// never replace a `stations.json` it couldn't read (final review I2).
    @Test func unreadableStationsFileThrowsAndIsNeverOverwritten() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stations.json")
        let store = LocalSettingsStore(directory: dir)
        try await store.save(station("A")); try await store.save(station("B"))
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        await #expect { _ = try await store.stations() } throws: { error in
            guard case SettingsStoreError.unreadable(let path, _) = error else { return false }
            return path.hasSuffix("stations.json")
        }
        await #expect(throws: SettingsStoreError.self) { try await store.save(station("C")) }
        await #expect(throws: SettingsStoreError.self) { try await store.deleteStation(id: UUID()) }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
        #expect(try await store.stations().map(\.name).sorted() == ["A", "B"])
    }

    @Test func unreadableDeviceFileThrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("device.json")
        let store = LocalSettingsStore(directory: dir)
        let a = station("A")
        try await store.save(a)
        try await store.saveDeviceSettings(StationDeviceSettings(stationID: a.id))
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        await #expect(throws: SettingsStoreError.self) { _ = try await store.deviceSettings(for: a.id) }
        await #expect(throws: SettingsStoreError.self) {
            try await store.saveDeviceSettings(StationDeviceSettings(stationID: UUID()))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
    }

    /// An undecodable file that can't be moved aside throws rather than reading as empty, so
    /// no save replaces a file that wasn't preserved.
    @Test func failedQuarantineThrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stations.json")
        try Data("not json {{".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let store = LocalSettingsStore(directory: dir)
        await #expect { _ = try await store.stations() } throws: { error in
            guard case SettingsStoreError.quarantineFailed(let path, _) = error else { return false }
            return path.hasSuffix("stations.json")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(try Data(contentsOf: url) == Data("not json {{".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["stations.json"])
    }

    @Test func lastStationAndAppSettingsPersist() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let id = UUID()
        await store.setLastStationID(id)
        #expect(await LocalSettingsStore(directory: dir).lastStationID() == id)
        #expect(await store.appSettings().storageLocation == .local)
        try await store.saveAppSettings(AppSettings())
        // setting the id keeps storageLocation and vice versa
        await store.setLastStationID(nil)
        #expect(await LocalSettingsStore(directory: dir).lastStationID() == nil)
        let text = try String(contentsOf: dir.appendingPathComponent("app.json"), encoding: .utf8)
        #expect(text.contains("storageLocation"))
    }

    @Test func exportImportRoundTrip() async throws {
        let d1 = tempDir(), d2 = tempDir()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let src = LocalSettingsStore(directory: d1)
        var a = station("A"); a.countsResetAt = Date(timeIntervalSince1970: 1_700_000_000)
        a.connection.reconnectCooldownSeconds = 15
        let b = station("B")
        try await src.save(a); try await src.save(b)
        var dev = StationDeviceSettings(stationID: a.id); dev.recordingsFolder = "/secret/path"
        try await src.saveDeviceSettings(dev)
        let data = try await SettingsArchive.export(from: src)
        #expect(!String(decoding: data, as: UTF8.self).contains("/secret/path"))
        let dst = LocalSettingsStore(directory: d2)
        let n = try await SettingsArchive.importing(data, into: dst, replaceExisting: false)
        #expect(n == 2)
        let got = try await dst.stations()
        #expect(Set(got.map(\.id)) == [a.id, b.id])
        #expect(got.first { $0.id == a.id } == a)
        #expect(try await dst.deviceSettings(for: a.id).recordingsFolder == nil)
    }

    /// An imported archive with a reconnect wait outside 0...120 stores 120 (the conservative
    /// default), never the raw value.
    @Test func importClampsAnOutOfRangeReconnectWaitToTheDefault() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let id = UUID()
        let json = #"{"version":1,"exportedAt":"2026-11-09T00:00:00Z","stations":[{"id":""# + id.uuidString
            + #"","name":"Hand Edited","connection":{"host":"192.0.2.10","reconnectCooldownSeconds":-5}}]}"#
        _ = try await SettingsArchive.importing(Data(json.utf8), into: store, replaceExisting: false)
        let stored = try await store.stations()
        #expect(stored.count == 1)
        #expect(stored.first?.connection.reconnectCooldownSeconds == 120)
    }

    @Test func importDoesNotClobberWithoutReplace() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let a = station("A")
        try await store.save(a)
        var changed = a; changed.name = "Changed"
        let other = station("Other")
        let data = try await archive([changed, other])
        let n = try await SettingsArchive.importing(data, into: store, replaceExisting: false)
        #expect(n == 2)
        let all = try await store.stations()
        #expect(all.count == 3)
        #expect(all.first { $0.id == a.id }?.name == "A")
        #expect(all.filter { $0.name == "Changed" }.count == 1)
        #expect(all.first { $0.name == "Changed" }?.id != a.id)
        // name collision gets a suffix, id collision alone does not
        let dup = station("A")  // new id, same name as existing
        let dupData = try await archive([dup])
        _ = try await SettingsArchive.importing(dupData, into: store, replaceExisting: false)
        let after = try await store.stations()
        #expect(after.contains { $0.id == dup.id && $0.name == "A" })
        let again = try await archive([after.first { $0.id == a.id } ?? a])
        _ = try await SettingsArchive.importing(again, into: store, replaceExisting: false)
        #expect(try await store.stations().contains { $0.name == "A (imported)" })
    }

    @Test func importReplaceExistingOverwrites() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        let a = station("A")
        try await store.save(a)
        var changed = a; changed.name = "Changed"
        let n = try await SettingsArchive.importing(try await archive([changed]), into: store, replaceExisting: true)
        #expect(n == 1)
        let all = try await store.stations()
        #expect(all.count == 1 && all.first?.name == "Changed" && all.first?.id == a.id)
    }

    @Test func importRejectsGarbage() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalSettingsStore(directory: dir)
        await #expect(throws: (any Error).self) {
            _ = try await SettingsArchive.importing(Data("nope".utf8), into: store, replaceExisting: false)
        }
    }

    @Test func iCloudUnavailable() {
        let locations = AppSettings.availableLocations()
        #expect(locations.first { $0.location == .local }?.available == true)
        let cloud = locations.first { $0.location == .iCloud }
        #expect(cloud?.available == false)
        #expect(cloud?.reason == "requires an Apple Developer Program membership")
        #expect(AppSettings().storageLocation == .local)
    }

    private func archive(_ stations: [Station]) async throws -> Data {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        return try enc.encode(SettingsArchive(exportedAt: Date(), stations: stations))
    }
}
