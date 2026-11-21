// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

// Sync-ready station model. Every stored property is defaulted or optional, ids are UUIDs and
// there are no uniqueness constraints, so the types map onto CloudKit records.


// CloudKit-style tolerance: any missing key falls back to the property default, and unknown keys
// are ignored. Synthesized Codable throws on missing keys, so each type decodes by hand.
private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

public struct Station: Codable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var name: String = "New Station"
    public var connection: StationConnection = .init()
    public var recording: RecordingRules = .init()
    public var keyMap: KeyMap = .init()
    public var appearance: Appearance = .init()
    public var preferredView: PreferredView = .scanner
    public var savedFilters: [HitFilter] = []
    public var countsResetAt: Date? = nil
    public init() {}

    private enum CodingKeys: String, CodingKey { case id, name, connection, recording, keyMap, appearance, preferredView, savedFilters, countsResetAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Station()
        id = try c.value(.id, d.id)
        name = try c.value(.name, d.name)
        connection = try c.value(.connection, d.connection)
        recording = try c.value(.recording, d.recording)
        keyMap = try c.value(.keyMap, d.keyMap)
        appearance = try c.value(.appearance, d.appearance)
        preferredView = try c.value(.preferredView, d.preferredView)
        savedFilters = try c.value(.savedFilters, d.savedFilters)
        countsResetAt = try c.value(.countsResetAt, d.countsResetAt)
    }

    /// Problems that stop the station from being saved or connected. Empty means valid.
    public func validate() -> [StationIssue] {
        var issues: [StationIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.emptyName) }
        if connection.transport == .network,
           (connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingHost)
        }
        if !(0...60).contains(recording.minimumDuration) { issues.append(.invalidMinimumDuration) }
        if !(10...3600).contains(recording.maxTransmission) { issues.append(.invalidMaxTransmission) }
        if !StationConnection.reconnectCooldownRange.contains(connection.reconnectCooldownSeconds) {
            issues.append(.invalidReconnectCooldown)
        }
        return issues
    }
}

public enum StationIssue: Equatable, Sendable {
    case emptyName, missingHost, invalidMinimumDuration, invalidMaxTransmission, invalidReconnectCooldown
}

public struct StationConnection: Codable, Sendable, Equatable {
    public var transport: TransportKind = .network
    public var host: String? = nil
    public var udpPort: UInt16 = 50536
    public var rtspPort: UInt16 = 554
    public var modelOverride: ScannerModel? = nil
    /// How long to wait before reconnecting audio after a *clean* close (Plan 5; the owner's
    /// setting, 0…120 s). Every other close waits the full 120 s (`RTSPCooldownPolicy`).
    /// Stations saved before this field, and a stored value outside 0…120, read as 120.
    public var reconnectCooldownSeconds: Int = 120
    public init() {}

    /// The valid range of `reconnectCooldownSeconds`.
    public static let reconnectCooldownRange = 0...120

    private enum CodingKeys: String, CodingKey { case transport, host, udpPort, rtspPort, modelOverride, reconnectCooldownSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StationConnection()
        transport = try c.value(.transport, d.transport)
        host = try c.value(.host, d.host)
        udpPort = try c.value(.udpPort, d.udpPort)
        rtspPort = try c.value(.rtspPort, d.rtspPort)
        modelOverride = try c.value(.modelOverride, d.modelOverride)
        // A hand-edited or imported value outside 0...120 reads as the conservative default.
        let wait = try c.value(.reconnectCooldownSeconds, d.reconnectCooldownSeconds)
        reconnectCooldownSeconds = Self.reconnectCooldownRange.contains(wait) ? wait : d.reconnectCooldownSeconds
    }

    /// The reconnect policy for this station: `full` after an unclean close (120 s; only the
    /// mock-only test overrides shorten it) and `reconnectCooldownSeconds` after a clean one,
    /// clamped to `0…full` (so a hand-edited value outside 0…120 is never trusted).
    public func reconnectCooldownPolicy(full: Duration = .seconds(120)) -> RTSPCooldownPolicy {
        RTSPCooldownPolicy(full: full, afterCleanClose: .seconds(reconnectCooldownSeconds))
    }
}

public enum SaveAudio: String, Codable, Sendable { case everyTransmission, onlyNew, never }

public struct RecordingRules: Codable, Sendable, Equatable {
    public var saveAudio: SaveAudio = .everyTransmission
    public var minimumDuration: Double = 0.5
    public var retentionDays: Int? = nil
    public var maxTransmission: Double = 300
    public init() {}

    private enum CodingKeys: String, CodingKey { case saveAudio, minimumDuration, retentionDays, maxTransmission }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingRules()
        saveAudio = try c.value(.saveAudio, d.saveAudio)
        minimumDuration = try c.value(.minimumDuration, d.minimumDuration)
        retentionDays = try c.value(.retentionDays, d.retentionDays)
        maxTransmission = try c.value(.maxTransmission, d.maxTransmission)
    }
}

public struct KeyMap: Codable, Sendable, Equatable {
    /// `FrontPanelKey.rawValue` to key equivalent (for example "⌘4").
    public var overrides: [String: String] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case overrides }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyMap()
        overrides = try c.value(.overrides, d.overrides)
    }

    /// Default key equivalents. Every model shares today's `FrontPanelKey` set, so all models get the
    /// SDS200 table restricted to the keys in `FrontPanelKey.allCases`; per-model tables can diverge
    /// here later (for example a model without soft keys). The brief fixes digits, avoid, function,
    /// menu, enter, dot, scroll and soft keys; the rest (volume, squelch, replay, zip, service type,
    /// range) are chosen to be distinct from those.
    public static func defaults(for model: ScannerModel) -> [FrontPanelKey: String] {
        let sds200: [FrontPanelKey: String] = [
            .digit0: "0", .digit1: "1", .digit2: "2", .digit3: "3", .digit4: "4",
            .digit5: "5", .digit6: "6", .digit7: "7", .digit8: "8", .digit9: "9",
            .avoid: "a", .function: "f", .menu: "m", .enterYes: "↩", .dotNo: ".",
            .scrollLeft: "←", .scrollRight: "→", .scrollPush: "space",
            .soft1: "F1", .soft2: "F2", .soft3: "F3",
            .volumePush: "v", .squelchPush: "q", .replay: "y", .zip: "z", .serviceType: "t", .range: "r",
        ]
        let keys = Set(FrontPanelKey.allCases)
        return sds200.filter { keys.contains($0.key) }
    }

    /// Defaults with `overrides` applied. Override keys that are not a `FrontPanelKey` raw value are ignored.
    public func resolved(for model: ScannerModel) -> [FrontPanelKey: String] {
        var map = KeyMap.defaults(for: model)
        for (raw, value) in overrides {
            if let key = FrontPanelKey(rawValue: raw) { map[key] = value }
        }
        return map
    }
}

public enum ColorMode: String, Codable, Sendable { case color, blackOnWhite, whiteOnBlack }

public struct Appearance: Codable, Sendable, Equatable {
    public var colorMode: ColorMode = .color
    public var profileImportedAt: Date? = nil
    public init() {}

    private enum CodingKeys: String, CodingKey { case colorMode, profileImportedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance()
        colorMode = try c.value(.colorMode, d.colorMode)
        profileImportedAt = try c.value(.profileImportedAt, d.profileImportedAt)
    }
}

public enum PreferredView: String, Codable, Sendable { case scanner, macStyle }

public struct HitFilter: Codable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var name: String = ""
    public var onlyNew: Bool = false
    public var modes: [String] = []
    public var toneOrCode: String? = nil
    public var system: String? = nil
    public var since: Date? = nil
    /// Exclusive upper bound on `startedAt` (the hit log window uses it to select one day).
    public var until: Date? = nil
    public var text: String? = nil
    public init() {}

    private enum CodingKeys: String, CodingKey { case id, name, onlyNew, modes, toneOrCode, system, since, until, text }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HitFilter()
        id = try c.value(.id, d.id)
        name = try c.value(.name, d.name)
        onlyNew = try c.value(.onlyNew, d.onlyNew)
        modes = try c.value(.modes, d.modes)
        toneOrCode = try c.value(.toneOrCode, d.toneOrCode)
        system = try c.value(.system, d.system)
        since = try c.value(.since, d.since)
        until = try c.value(.until, d.until)
        text = try c.value(.text, d.text)
    }
}

/// Device-only settings (never synced): they describe this machine, not the station.
public struct StationDeviceSettings: Codable, Sendable, Equatable {
    public var stationID: UUID
    public var recordingsFolder: String? = nil
    public var usbPort: String? = nil
    public var bluetoothID: String? = nil
    public var audioOutputDevice: String? = nil
    /// The line-in a USB station listens to: the audio input's UID, the name it had when chosen, and
    /// the channel (absent reads as `.both`). `lineIn` is nil unless a device is set.
    public var audioInputDevice: String? = nil
    public var audioInputName: String? = nil
    public var audioInputChannel: LineInChannel? = nil
    public init(stationID: UUID) { self.stationID = stationID }

    public var lineIn: LineInConfig? {
        guard let uid = audioInputDevice else { return nil }
        return LineInConfig(deviceUID: uid, deviceName: audioInputName ?? uid, channel: audioInputChannel ?? .both)
    }

    private enum CodingKeys: String, CodingKey {
        case stationID, recordingsFolder, usbPort, bluetoothID, audioOutputDevice
        case audioInputDevice, audioInputName, audioInputChannel
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try c.decode(UUID.self, forKey: .stationID)
        recordingsFolder = try c.decodeIfPresent(String.self, forKey: .recordingsFolder)
        usbPort = try c.decodeIfPresent(String.self, forKey: .usbPort)
        bluetoothID = try c.decodeIfPresent(String.self, forKey: .bluetoothID)
        audioOutputDevice = try c.decodeIfPresent(String.self, forKey: .audioOutputDevice)
        audioInputDevice = try c.decodeIfPresent(String.self, forKey: .audioInputDevice)
        audioInputName = try c.decodeIfPresent(String.self, forKey: .audioInputName)
        // A word this build doesn't know (a hand edit, a later build's channel) reads as absent, so
        // Both: failing here would fail `device.json`, and every station's port with it.
        audioInputChannel = (try? c.decodeIfPresent(LineInChannel.self, forKey: .audioInputChannel)) ?? nil
    }
}
