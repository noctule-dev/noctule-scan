// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Why `LocalSettingsStore` couldn't load a settings file. Either way nothing was written, so
/// the file on disk is left as it was.
public enum SettingsStoreError: Error, Equatable, CustomStringConvertible {
    /// The file exists (or may exist) but couldn't be read, e.g. no permission or an I/O error.
    case unreadable(path: String, reason: String)
    /// The file couldn't be decoded, and moving it aside to `<name>.corrupt-<stamp>` failed.
    case quarantineFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            "can't read \(path): \(reason); nothing was changed"
        case .quarantineFailed(let path, let reason):
            "\(path) is unreadable as settings and couldn't be moved aside: \(reason); nothing was changed"
        }
    }
}

/// Settings in three small JSON files under `directory`:
/// `stations.json` (synced part), `device.json` (device-only, never synced or exported) and
/// `app.json` (last station, storage location). Writes are atomic. Use one instance per
/// directory per process.
///
/// Only a missing file reads as empty. Any other read failure (no permission, an I/O error, an
/// evicted file) throws `SettingsStoreError.unreadable`, so a save can never replace a file it
/// couldn't read. A file that fails to decode is renamed to `<name>.corrupt-<yyyyMMdd-HHmmss>`
/// and treated as empty; if that rename fails, it throws `.quarantineFailed` instead. `app.json`
/// (a convenience) stays best-effort: any failure there reads as defaults.
public actor LocalSettingsStore: SettingsStore {
    public let directory: URL

    private struct StationsFile: Codable { var version: Int = 1; var stations: [Station] = [] }
    private struct DeviceFile: Codable { var version: Int = 1; var devices: [StationDeviceSettings] = [] }
    private struct AppFile: Codable {
        var version: Int = 1
        var lastStationID: UUID? = nil
        var storageLocation: StorageLocation = .local
        init() {}
        private enum CodingKeys: String, CodingKey { case version, lastStationID, storageLocation }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            lastStationID = try c.decodeIfPresent(UUID.self, forKey: .lastStationID)
            storageLocation = try c.decodeIfPresent(StorageLocation.self, forKey: .storageLocation) ?? .local
        }
    }

    public init(directory: URL) { self.directory = directory }

    // MARK: SettingsStore

    public func stations() async throws -> [Station] { try loadStations().stations }

    public func save(_ station: Station) async throws {
        var file = try loadStations()
        if let i = file.stations.firstIndex(where: { $0.id == station.id }) {
            file.stations[i] = station
        } else {
            file.stations.append(station)
        }
        try write(file, to: "stations.json")
    }

    /// One actor-isolated read-modify-write of `stations.json` (no `await` between the read and
    /// the write). Same rules as `save`: an unreadable file throws and nothing is written.
    @discardableResult
    public func update(id: UUID, _ mutate: @Sendable (inout Station) -> Void) async throws -> Station? {
        var file = try loadStations()
        guard let i = file.stations.firstIndex(where: { $0.id == id }) else { return nil }
        var station = file.stations[i]
        mutate(&station)
        station.id = id
        guard station != file.stations[i] else { return station }
        file.stations[i] = station
        try write(file, to: "stations.json")
        return station
    }

    public func deleteStation(id: UUID) async throws {
        var file = try loadStations()
        file.stations.removeAll { $0.id == id }
        try write(file, to: "stations.json")
        var dev = try loadDevices()
        if dev.devices.contains(where: { $0.stationID == id }) {
            dev.devices.removeAll { $0.stationID == id }
            try write(dev, to: "device.json")
        }
    }

    public func deviceSettings(for id: UUID) async throws -> StationDeviceSettings {
        try loadDevices().devices.first { $0.stationID == id } ?? StationDeviceSettings(stationID: id)
    }

    public func saveDeviceSettings(_ s: StationDeviceSettings) async throws {
        var file = try loadDevices()
        if let i = file.devices.firstIndex(where: { $0.stationID == s.stationID }) {
            file.devices[i] = s
        } else {
            file.devices.append(s)
        }
        try write(file, to: "device.json")
    }

    public func lastStationID() async -> UUID? { loadApp().lastStationID }

    public func setLastStationID(_ id: UUID?) async {
        var file = loadApp()
        file.lastStationID = id
        try? write(file, to: "app.json")  // best effort: the id is only a convenience
    }

    // MARK: App settings (local-store only; the app layer reads the storage location here)

    public func appSettings() async -> AppSettings {
        var s = AppSettings()
        s.storageLocation = loadApp().storageLocation
        return s
    }

    public func saveAppSettings(_ s: AppSettings) async throws {
        var file = loadApp()
        file.storageLocation = s.storageLocation
        try write(file, to: "app.json")
    }

    // MARK: Files

    private func loadStations() throws -> StationsFile { try load("stations.json") ?? StationsFile() }
    private func loadDevices() throws -> DeviceFile { try load("device.json") ?? DeviceFile() }
    /// Best effort: the last station and storage location are conveniences.
    private func loadApp() -> AppFile { ((try? load("app.json")) ?? nil) ?? AppFile() }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    /// nil when the file is missing, or present but undecodable (in which case it is moved
    /// aside). Throws for any other read failure, or if the undecodable file can't be moved.
    private func load<T: Decodable>(_ name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if Self.isMissingFile(error) { return nil }
            throw SettingsStoreError.unreadable(path: url.path, reason: Self.reason(error))
        }
        do {
            return try Self.decoder().decode(T.self, from: data)
        } catch {
            try quarantine(url)
            return nil
        }
    }

    private static func isMissingFile(_ error: any Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile {
            return true
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }

    /// The POSIX reason if there is one ("Permission denied"), else the localized description.
    private static func reason(_ error: any Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            return String(cString: strerror(code.rawValue))
        }
        return error.localizedDescription
    }

    private func quarantine(_ url: URL) throws {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let fm = FileManager.default
        var target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(n)")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            throw SettingsStoreError.quarantineFailed(path: url.path, reason: Self.reason(error))
        }
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(value)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
