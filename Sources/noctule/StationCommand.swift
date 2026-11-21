// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleCLICore
import NoctuleKit
import NoctuleStore

// `noctule station add|list|remove`: local settings only (`LocalSettingsStore`); never talks to
// the scanner.

enum StationCommand {
    static func run(_ action: StationAction, settingsDirectory: URL) async -> Int32 {
        let store = LocalSettingsStore(directory: settingsDirectory)
        do {
            let stations = try await store.stations()
            switch action {
            case .add(let options):
                // The listing only decides whether `--audio-input` matches a name or UID. With none
                // available (the kill-switch, the test stream) a value is saved as the UID it is.
                let selection = LineInSupport.selection(environment: ProcessInfo.processInfo.environment)
                var listingAvailable = false
                if case .system = selection { listingAvailable = true }
                let inputs = options.audioInput == nil ? [] : LineInSupport.listing(for: selection).inputs()
                switch try await StationCLI.add(options, existing: stations, store: store,
                                                inputs: inputs, listingAvailable: listingAvailable) {
                case .added(let line, let notes):
                    notes.forEach { fputs("\($0)\n", stderr) }
                    print(line)
                case .invalid(let problems):
                    problems.forEach { fputs("station: \($0)\n", stderr) }
                    return 1
                case .refused(let problems):
                    problems.forEach { fputs("station: \($0)\n", stderr) }
                    return 64
                }
            case .list:
                var usbPorts: [UUID: String] = [:]
                var lineIns: [UUID: LineInConfig] = [:]
                for station in stations where station.connection.transport == .usbSerial {
                    let device = try await store.deviceSettings(for: station.id)
                    usbPorts[station.id] = device.usbPort
                    lineIns[station.id] = device.lineIn
                }
                StationCLI.listLines(stations, lastID: await store.lastStationID(), usbPorts: usbPorts, lineIns: lineIns)
                    .forEach { print($0) }
            case .remove(let name):
                guard let station = StationCLI.station(named: name, in: stations) else {
                    let error: StationLookupError = stations.isEmpty
                        ? .noStations : .notFound(name: name, names: stations.map(\.name))
                    fputs("station: \(error)\n", stderr)
                    return 1
                }
                try await store.deleteStation(id: station.id)
                if await store.lastStationID() == station.id { await store.setLastStationID(nil) }
                let log = StationCLI.hitLogURL(settingsDirectory: settingsDirectory, stationID: station.id)
                print("removed station \"\(station.name)\"; its hit log and recordings are kept (\(log.deletingLastPathComponent().path))")
            }
        } catch {
            fputs("station: \(error)\n", stderr)
            return 1
        }
        return 0
    }
}
