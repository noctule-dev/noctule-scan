// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import NoctuleKit
import NoctuleStore

/// One station's page in Settings › Stations: recording rules, the recordings folder, the display
/// color mode and the key map. Each setter changes only its own field, at once, in one atomic
/// `SettingsStore.update` (so edits made meanwhile in another window are kept), then hands the
/// saved station to `stationChanged` (the app passes `StationDirectory.changed`, which calls
/// `SessionRegistry.stationChanged`). The saved value comes from `update` itself, so there is no
/// second read that could fail after the write and leave an open session on the old rules.
///
/// What a change does to an open session (`SessionRegistry.restartRelevant`):
/// - recording rules (save audio, minimum length, retention) restart it, because the runner reads
///   them at start; the restart goes through the cooldown gate;
/// - the color mode and the key map are applied to the running session, no restart;
/// - the recordings folder is device-only (`StationDeviceSettings`) and is read when the session
///   starts, so it applies from the next connection.
@MainActor @Observable
public final class StationSettingsModel {
    public private(set) var station: Station
    public private(set) var device: StationDeviceSettings
    /// The last failed load or save, in words; cleared by the next success.
    public private(set) var problem: String?
    private let settings: any SettingsStore
    private let stationChanged: @MainActor (Station) -> Void

    public init(station: Station, settings: any SettingsStore,
                stationChanged: @escaping @MainActor (Station) -> Void) {
        self.station = station
        self.device = StationDeviceSettings(stationID: station.id)
        self.settings = settings
        self.stationChanged = stationChanged
    }

    /// Reads the device settings (the recordings folder).
    public func load() async {
        do {
            device = try await settings.deviceSettings(for: station.id)
            problem = nil
        } catch {
            problem = Self.describe(error)
        }
    }

    /// Takes a newer copy of the same station read elsewhere (a rename in the editor), so the page
    /// shows it. Ignores another station's value.
    public func adopt(_ fresh: Station) {
        guard fresh.id == station.id, fresh != station else { return }
        station = fresh
    }

    // MARK: Recording (restarts an open session)

    public func setSaveAudio(_ value: SaveAudio) async {
        await apply { $0.recording.saveAudio = value }
    }

    /// Ignores a value outside `RecordingInput.minimumLengthRange` (the view validates first).
    public func setMinimumDuration(_ seconds: Double) async {
        guard RecordingInput.minimumLengthRange.contains(seconds) else { return }
        await apply { $0.recording.minimumDuration = seconds }
    }

    /// nil keeps recordings forever. Ignores a day count outside `RecordingInput.retentionRange`.
    public func setRetentionDays(_ days: Int?) async {
        if let days, !RecordingInput.retentionRange.contains(days) { return }
        await apply { $0.recording.retentionDays = days }
    }

    // MARK: Live (no restart)

    public func setColorMode(_ mode: ColorMode) async {
        await apply { $0.appearance.colorMode = mode }
    }

    /// Binds `key` to `chord` for `model`; nil (or the model's default) clears the override.
    public func setChord(_ chord: KeyChord?, for key: FrontPanelKey, model: ScannerModel) async {
        let raw = key.rawValue
        let value = KeyMapEditing.overrideValue(chord, for: key, model: model)
        await apply { station in
            if let value { station.keyMap.overrides[raw] = value } else { station.keyMap.overrides[raw] = nil }
        }
    }

    /// "Reset to model defaults": drops every override.
    public func resetKeyMap() async {
        await apply { $0.keyMap.overrides = [:] }
    }

    // MARK: Device (next connection)

    /// A folder path, or nil for the default (`<recordings root>/<station name>/`).
    public func setRecordingsFolder(_ path: String?) async {
        do {
            var fresh = try await settings.deviceSettings(for: station.id)
            fresh.recordingsFolder = path
            try await settings.saveDeviceSettings(fresh)
            device = fresh
            problem = nil
        } catch {
            problem = Self.describe(error)
        }
    }

    // MARK: Internals

    private func apply(_ mutate: @escaping @Sendable (inout Station) -> Void) async {
        do {
            guard let saved = try await settings.update(id: station.id, mutate) else {
                throw StationNoLongerExists(id: station.id)
            }
            station = saved
            problem = nil
            stationChanged(saved)
        } catch {
            problem = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? SettingsStoreError { return error.description }
        if let error = error as? StationNoLongerExists { return error.description }
        return error.localizedDescription
    }
}

/// Key map edits, independent of any view.
public enum KeyMapEditing {
    /// The text to store in `KeyMap.overrides` for binding `key` to `chord`, or nil to remove the
    /// override: no chord (cleared), or the model's own default.
    public static func overrideValue(_ chord: KeyChord?, for key: FrontPanelKey, model: ScannerModel) -> String? {
        guard let chord else { return nil }
        if let text = KeyMap.defaults(for: model)[key], KeyChord(text) == chord { return nil }
        return chord.display
    }

    /// One row of the key map editor.
    public struct Row: Equatable, Sendable, Identifiable {
        public var key: FrontPanelKey
        /// The chord in force, as displayed ("⌘4", "F1"); nil if the key has none.
        public var chord: String?
        /// The station overrides the model's default for this key.
        public var isOverridden: Bool
        /// Other keys bound to the same chord, in `FrontPanelKey.allCases` order.
        public var conflicts: [FrontPanelKey]
        public var id: String { key.rawValue }
    }

    /// A row per `FrontPanelKey`, in `allCases` order.
    public static func rows(for keyMap: KeyMap, model: ScannerModel) -> [Row] {
        let resolved = keyMap.resolved(for: model)
        let conflicts = KeyboardRouter(map: resolved).conflicts
        let order = FrontPanelKey.allCases
        return order.map { key in
            let chord = resolved[key].flatMap(KeyChord.init)
            let others = chord.flatMap { conflicts[$0] }?.filter { $0 != key } ?? []
            return Row(key: key, chord: chord?.display ?? resolved[key],
                       isOverridden: keyMap.overrides[key.rawValue] != nil,
                       conflicts: order.filter { others.contains($0) })
        }
    }
}

/// Parsing and limits for the recording settings typed in by hand.
public enum RecordingInput {
    /// `Station.validate()`'s range for the minimum recording length, in seconds.
    public static let minimumLengthRange: ClosedRange<Double> = 0...60
    /// Days to keep recordings when not forever.
    public static let retentionRange: ClosedRange<Int> = 1...3650

    /// Seconds from text like "0.5" or "2" (a comma decimal separator works too), within
    /// `minimumLengthRange`; nil otherwise.
    public static func minimumLength(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value.isFinite, minimumLengthRange.contains(value) else { return nil }
        return value
    }

    /// Whole days from text like "30", within `retentionRange`; nil otherwise.
    public static func retentionDays(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), retentionRange.contains(value) else { return nil }
        return value
    }

    /// "0.5", "2", "12.25": no trailing zeros.
    public static func format(seconds: Double) -> String {
        var text = String(format: "%.2f", seconds)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    public static let minimumLengthProblem = "Enter 0 to 60 seconds."
    public static let retentionProblem = "Enter 1 to 3650 days."
}

/// Text for the station picker and editor.
public enum StationText {
    /// "host:port", or "no address"; a USB station "USB", or "USB <port>" with a saved port
    /// (`StationDeviceSettings.usbPort`, which a network station ignores).
    public static func address(_ station: Station, usbPort: String? = nil) -> String {
        if station.connection.transport == .usbSerial {
            let port = (usbPort ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return port.isEmpty ? "USB" : "USB \(port)"
        }
        let host = (station.connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "no address" : "\(host):\(station.connection.udpPort)"
    }

    /// The editor's Scanner row for a USB station: the port it would open ("SDS150 Serial Port on
    /// /dev/cu.…", "Uniden device on …" when the listing has no product name or the saved path
    /// isn't listed), or what to do.
    public static func usbStatusText(_ status: StationEditorModel.USBStatus) -> String {
        switch status {
        case .found(let port): "\(port.productName ?? "Uniden device") on \(port.path)"
        case .savedPortMissing(let path): "\(path) isn't connected. " + SerialPort.noneFoundHint
        case .noneFound: SerialPort.noneFoundHint
        case .choose: SerialPort.severalFoundHint
        }
    }

    /// The model to show: the open session's, else the override, else "model detected on connect".
    public static func model(_ station: Station, connected: ScannerModel? = nil) -> String {
        if let connected { return connected.rawValue }
        if let override = station.connection.modelOverride { return override.rawValue }
        return "model detected on connect"
    }

    /// A port typed by hand: 1...65535, else nil.
    public static func port(_ text: String) -> UInt16? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return UInt16(value)
    }

    /// "Imported 1 station." / "Imported 3 stations."
    public static func importSummary(_ count: Int) -> String {
        "Imported \(count) station\(count == 1 ? "" : "s")."
    }
}
