// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// A portable export of the synced part of the settings. Device-only settings are never included.
public struct SettingsArchive: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var exportedAt: Date
    public var stations: [Station]
    public init(exportedAt: Date = Date(), stations: [Station] = []) {
        self.exportedAt = exportedAt; self.stations = stations
    }

    public static func export(from store: any SettingsStore) async throws -> Data {
        let archive = SettingsArchive(exportedAt: Date(), stations: try await store.stations())
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(archive)
    }

    /// Saves the archive's stations into `store` and returns how many. Without `replaceExisting`, a
    /// station whose id already exists gets a fresh id (and an " (imported)" suffix if its name is
    /// also taken), so nothing existing is overwritten. With it, same-id stations are replaced.
    /// Throws if `data` is not an archive; nothing is saved in that case.
    public static func importing(_ data: Data, into store: any SettingsStore, replaceExisting: Bool) async throws -> Int {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let archive = try d.decode(SettingsArchive.self, from: data)
        let existing = try await store.stations()
        var ids = Set(existing.map(\.id))
        var names = Set(existing.map(\.name))
        for var station in archive.stations {
            if !replaceExisting, ids.contains(station.id) {
                station.id = UUID()
                if names.contains(station.name) { station.name += " (imported)" }
            }
            try await store.save(station)
            ids.insert(station.id)
            names.insert(station.name)
        }
        return archive.stations.count
    }
}
