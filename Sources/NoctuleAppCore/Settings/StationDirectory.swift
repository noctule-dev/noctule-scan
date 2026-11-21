// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import NoctuleStore

/// The stored stations as the app's windows show them (the picker, Settings › Stations), and the
/// one place that tells the `SessionRegistry` about a change. After any add, edit, delete or
/// import, `reloadAndApply()` (or `changed(_:)` for one saved station) takes the fresh value, so every view updates and
/// open sessions follow (`SessionRegistry.stationsChanged`: restart, live update, or stop).
///
/// A failed read never reaches the registry: an empty or partial list would stop sessions whose
/// stations still exist.
@MainActor @Observable
public final class StationDirectory {
    public private(set) var stations: [Station] = []
    public private(set) var lastStationID: UUID?
    /// The last failed read, in words; cleared by the next success.
    public private(set) var problem: String?
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let registry: SessionRegistry

    public init(settings: any SettingsStore, registry: SessionRegistry) {
        self.settings = settings
        self.registry = registry
    }

    /// Re-reads the stations (and the last used one) without touching sessions.
    @discardableResult
    public func reload() async -> Bool {
        lastStationID = await settings.lastStationID()
        do {
            stations = try await settings.stations()
            problem = nil
            return true
        } catch {
            problem = (error as? SettingsStoreError)?.description ?? error.localizedDescription
            return false
        }
    }

    /// Re-reads the stations and, if that worked, hands them to the registry.
    public func reloadAndApply() async {
        guard await reload() else { return }
        registry.stationsChanged(stations)
    }

    /// One station just saved by someone else (`StationSettingsModel`, from the store's `update`):
    /// patches the list and tells the registry about that station only.
    public func changed(_ station: Station) {
        if let i = stations.firstIndex(where: { $0.id == station.id }) { stations[i] = station }
        registry.stationChanged(station)
    }

    /// Deletes the station's settings and stops its open session. Its hit log
    /// (`Stations/<uuid>/hits.sqlite`) and recordings are kept.
    ///
    /// The store may have removed the station even if it then throws (it writes `stations.json`
    /// before `device.json`), so the list is re-read and applied either way. If that re-read
    /// fails, the station's session is stopped anyway: a session left running for a station
    /// that may be gone is worse than one stopped for a station that survived.
    public func delete(id: UUID) async throws {
        var failure: (any Error)?
        do { try await settings.deleteStation(id: id) } catch { failure = error }
        if await reload() {
            registry.stationsChanged(stations)
        } else {
            registry.stationDeleted(id)
        }
        if let failure { throw failure }
    }
}
