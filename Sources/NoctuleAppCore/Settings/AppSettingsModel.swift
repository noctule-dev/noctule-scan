// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import NoctuleStore

/// App-wide settings: where settings live, and export/import of the synced part (`SettingsArchive`).
@MainActor @Observable
public final class AppSettingsModel {
    /// Local, and iCloud listed as unavailable with its reason.
    public let locations: [StorageLocationAvailability] = AppSettings.availableLocations()
    private let settings: any SettingsStore

    public init(settings: any SettingsStore) { self.settings = settings }

    public func exportSettings() async throws -> Data {
        try await SettingsArchive.export(from: settings)
    }

    /// Returns how many stations the archive held. Throws if `data` isn't an archive.
    public func importSettings(_ data: Data, replaceExisting: Bool) async throws -> Int {
        try await SettingsArchive.importing(data, into: settings, replaceExisting: replaceExisting)
    }
}
