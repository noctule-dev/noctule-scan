// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Where settings live. iCloud is modelled but disabled until there is a developer membership.
public enum StorageLocation: String, Codable, Sendable { case local, iCloud }

public struct AppSettings: Codable, Sendable, Equatable {
    public var storageLocation: StorageLocation = .local
    public init() {}
}

public struct StorageLocationAvailability: Equatable, Sendable {
    public var location: StorageLocation
    public var available: Bool
    public var reason: String?
    public init(location: StorageLocation, available: Bool, reason: String? = nil) {
        self.location = location; self.available = available; self.reason = reason
    }
}

extension AppSettings {
    /// iCloud is listed but disabled until the project has a paid developer membership.
    public static func availableLocations() -> [StorageLocationAvailability] {
        [StorageLocationAvailability(location: .local, available: true, reason: nil),
         StorageLocationAvailability(location: .iCloud, available: false,
                                     reason: "requires an Apple Developer Program membership")]
    }
}

public protocol SettingsStore: Sendable {
    func stations() async throws -> [Station]
    func save(_ station: Station) async throws
    /// Reads the stored station `id`, applies `mutate`, and saves it, as one atomic step, so a
    /// caller changes only its own fields and never overwrites another window's edits with a
    /// stale copy. Returns the saved station, or nil if no station has that id (a deleted
    /// station is never re-created). The station's `id` can't be changed this way.
    @discardableResult
    func update(id: UUID, _ mutate: @Sendable (inout Station) -> Void) async throws -> Station?
    func deleteStation(id: UUID) async throws
    func deviceSettings(for id: UUID) async throws -> StationDeviceSettings
    func saveDeviceSettings(_ s: StationDeviceSettings) async throws
    func lastStationID() async -> UUID?
    func setLastStationID(_ id: UUID?) async
}
