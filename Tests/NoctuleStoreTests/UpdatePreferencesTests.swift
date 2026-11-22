// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleStore

@Suite("Update preferences in app.json", .timeLimit(.minutes(1)))
struct UpdatePreferencesTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("noctule-up-\(UUID().uuidString)")
    }

    @Test func defaultsWithNoFile() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = await LocalSettingsStore(directory: dir).updatePreferences()
        #expect(p == UpdatePreferences())
        #expect(p.checkAutomatically == true)
        #expect(p.lastChecked == nil)
        #expect(p.skippedVersion == nil)
    }

    @Test func roundTrip() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var p = UpdatePreferences()
        p.checkAutomatically = false
        p.lastChecked = Date(timeIntervalSince1970: 1_800_000_000)
        p.skippedVersion = "1.0.1"
        await LocalSettingsStore(directory: dir).saveUpdatePreferences(p)
        #expect(await LocalSettingsStore(directory: dir).updatePreferences() == p)
        let text = try String(contentsOf: dir.appendingPathComponent("app.json"), encoding: .utf8)
        #expect(text.contains("\"checkForUpdates\" : false"))
        #expect(text.contains("\"lastUpdateCheck\""))
        #expect(text.contains("\"skippedUpdateVersion\" : \"1.0.1\""))
    }

    @Test func updateKeysAndLastStationSurviveEachOther() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID(), b = UUID()
        var p = UpdatePreferences()
        p.checkAutomatically = false
        p.skippedVersion = "2.0.0"
        p.lastChecked = Date(timeIntervalSince1970: 1_800_000_000)
        let first = LocalSettingsStore(directory: dir)
        await first.setLastStationID(a)
        await first.saveUpdatePreferences(p)
        let second = LocalSettingsStore(directory: dir)
        await second.setLastStationID(b)
        #expect(await second.updatePreferences() == p)
        #expect(await second.lastStationID() == b)

        var s = AppSettings()
        s.storageLocation = .iCloud
        try? await second.saveAppSettings(s)
        p.skippedVersion = nil
        await second.saveUpdatePreferences(p)
        #expect(await LocalSettingsStore(directory: dir).appSettings().storageLocation == .iCloud)
        #expect(await LocalSettingsStore(directory: dir).lastStationID() == b)
    }

    @Test func oldFileReadsDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        try Data("{\"version\":1,\"lastStationID\":\"\(id.uuidString)\"}".utf8)
            .write(to: dir.appendingPathComponent("app.json"))
        let store = LocalSettingsStore(directory: dir)
        #expect(await store.updatePreferences() == UpdatePreferences())
        #expect(await store.lastStationID() == id)
    }

    @Test func garbageFileReadsDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("app.json"))
        #expect(await LocalSettingsStore(directory: dir).updatePreferences() == UpdatePreferences())
    }

    @Test func inMemoryStoreKeepsWhatItIsGiven() async {
        var p = UpdatePreferences(); p.skippedVersion = "3.0.0"
        let store = InMemoryUpdatePreferences()
        #expect(await store.updatePreferences() == UpdatePreferences())
        await store.saveUpdatePreferences(p)
        #expect(await store.updatePreferences() == p)
    }
}
