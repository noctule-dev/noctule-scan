// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleCLICore
import NoctuleStore

// `noctule hits`: reads a station's hit log; never talks to the scanner.

enum HitsCommand {
    /// The most transmissions the table shows (newest first).
    static let transmissionLimit = 200

    static func run(_ options: HitsOptions, settingsDirectory: URL) async -> Int32 {
        let store = LocalSettingsStore(directory: settingsDirectory)
        let station: Station
        do {
            let stations = try await store.stations()
            switch StationCLI.resolve(name: options.station, stations: stations, lastID: await store.lastStationID()) {
            case .success(let s): station = s
            case .failure(let error):
                fputs("hits: \(error)\n", stderr)
                return 1
            }
        } catch {
            fputs("hits: can't read the stations: \(error)\n", stderr)
            return 1
        }

        var filter = HitFilter()
        filter.onlyNew = options.onlyNew
        filter.since = options.since
        let url = StationCLI.hitLogURL(settingsDirectory: settingsDirectory, stationID: station.id)
        do {
            // A station that has never logged has no file yet; opening creates an empty log.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let log = try HitLog(url: url)  // closes when released, on the error path too
            if options.csv {
                print(try await log.exportCSV(filter), terminator: "")
            } else if options.groups {
                let groups = try await log.groups(filter, countsSince: station.countsResetAt)
                StationCLI.groupsTable(groups).forEach { print($0) }
            } else {
                let hits = try await log.transmissions(filter, limit: transmissionLimit)
                StationCLI.transmissionsTable(hits).forEach { print($0) }
            }
            await log.close()
        } catch {
            fputs("hits: can't read the hit log at \(url.path): \(error)\n", stderr)
            return 1
        }
        return 0
    }
}
