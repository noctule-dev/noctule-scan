// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleStore
@testable import NoctuleAppCore

@Suite(.timeLimit(.minutes(3))) struct AppSettingsModelTests {
    @MainActor @Test func iCloudListedDisabled() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-appsettings-\(UUID().uuidString)")
        let model = AppSettingsModel(settings: LocalSettingsStore(directory: dir))
        #expect(model.locations.map(\.location) == [.local, .iCloud])
        #expect(model.locations[0].available)
        #expect(!model.locations[1].available)
        #expect(model.locations[1].reason == "requires an Apple Developer Program membership")
    }

    @MainActor @Test func exportImportRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-appsettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LocalSettingsStore(directory: root.appendingPathComponent("a"))
        var s = Station(); s.name = "Hilltop"; s.connection.host = "192.0.2.10"
        try await source.save(s)
        let data = try await AppSettingsModel(settings: source).exportSettings()

        let target = LocalSettingsStore(directory: root.appendingPathComponent("b"))
        let model = AppSettingsModel(settings: target)
        #expect(try await model.importSettings(data, replaceExisting: false) == 1)
        #expect(try await target.stations() == [s])
        // Importing again without replace keeps both; with replace overwrites by id.
        #expect(try await model.importSettings(data, replaceExisting: false) == 1)
        #expect(try await target.stations().count == 2)
        #expect(try await model.importSettings(data, replaceExisting: true) == 1)
        #expect(try await target.stations().count == 2)
        await #expect(throws: (any Error).self) { _ = try await model.importSettings(Data("nope".utf8), replaceExisting: false) }
    }
}
