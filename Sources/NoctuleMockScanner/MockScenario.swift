// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// What a scenario's scanner is doing: trunk scanning (P25 talkgroups) or weather scan.
public enum MockMode: String, Codable, Sendable, Equatable {
    case trunk
    /// WX Scan: GSI carries `<WxChannel ... Freq=" 162.425000MHz" Mod="FM" .../>` (fw 1.26.01).
    case weather
}

/// One transmission on the mock's timeline. Times are seconds from scenario start.
/// `programmed == false` emits `Index="4294967295"` (the scanner's "not programmed" sentinel).
public struct MockTransmission: Codable, Sendable, Equatable {
    public var at: Double
    public var duration: Double
    public var system: String
    public var department: String
    public var channel: String
    public var tgid: String?
    public var unitID: String?
    public var frequencyMHz: Double
    public var modulation: String
    public var toneOrCode: String?
    public var rssi: Int
    public var programmed: Bool
    /// The synthetic sine tone the mock streams while this transmission is active.
    public var toneHz: Double

    public var end: Double { at + duration }

    public init(at: Double, duration: Double, system: String, department: String, channel: String,
                tgid: String? = nil, unitID: String? = nil, frequencyMHz: Double, modulation: String = "NFM",
                toneOrCode: String? = nil, rssi: Int = -70, programmed: Bool = true, toneHz: Double = 440) {
        self.at = at; self.duration = duration; self.system = system; self.department = department
        self.channel = channel; self.tgid = tgid; self.unitID = unitID; self.frequencyMHz = frequencyMHz
        self.modulation = modulation; self.toneOrCode = toneOrCode; self.rssi = rssi
        self.programmed = programmed; self.toneHz = toneHz
    }
}

/// The between-transmission state: `Sig="0"`, no channel, scanning.
public struct MockIdle: Codable, Sendable, Equatable {
    public var system: String
    public var site: String
    public var frequencyMHz: Double
    public var modulation: String
    public var rssi: Int

    public init(system: String, site: String, frequencyMHz: Double, modulation: String = "NFM", rssi: Int = -999) {
        self.system = system; self.site = site; self.frequencyMHz = frequencyMHz
        self.modulation = modulation; self.rssi = rssi
    }
}

/// What the mock shows at one moment of its timeline.
public enum MockMoment: Sendable, Equatable {
    case idle(MockIdle)
    /// `index` is the transmission's position in `MockScenario.transmissions`.
    case transmission(index: Int, MockTransmission)
}

public enum MockScenarioError: Error, Equatable {
    /// Transmissions `first` and `second` (indices, in start order) overlap.
    case overlapping(first: Int, second: Int)
    /// Transmission `index` has a negative start or a non-positive duration.
    case invalidTiming(index: Int)
    case missingBundledScenario(String)
}

/// A scripted timeline for the mock scanner: an idle state and a list of transmissions.
public struct MockScenario: Codable, Sendable, Equatable {
    public var model: String = "SDS200"
    public var firmware: String = "1.26.01"
    public var loop: Bool = true
    public var mode: MockMode = .trunk
    public var idle: MockIdle
    public var transmissions: [MockTransmission]

    public init(model: String = "SDS200", firmware: String = "1.26.01", loop: Bool = true, mode: MockMode = .trunk,
                idle: MockIdle, transmissions: [MockTransmission]) {
        self.model = model; self.firmware = firmware; self.loop = loop; self.mode = mode
        self.idle = idle; self.transmissions = transmissions
    }

    /// The length of one pass when looping: the last transmission's end plus the leading idle
    /// gap before the first one, so every pass looks the same. 0 when there are no transmissions.
    public var period: Double {
        guard let last = transmissions.map(\.end).max() else { return 0 }
        return last + (transmissions.map(\.at).min() ?? 0)
    }

    /// The state at `t` seconds from scenario start. Intervals are half-open (`at ..< end`).
    /// With `loop`, `t` wraps by `period`; without it, everything after the last end is idle.
    public func moment(at t: Double) -> MockMoment {
        var time = max(0, t)
        let period = self.period
        if loop, period > 0 { time = time.truncatingRemainder(dividingBy: period) }
        for (index, transmission) in transmissions.enumerated() where time >= transmission.at && time < transmission.end {
            return .transmission(index: index, transmission)
        }
        return .idle(idle)
    }

    /// Throws if a transmission has a negative start or a non-positive duration, or two overlap
    /// (touching end to start is fine).
    public func validate() throws {
        for (index, transmission) in transmissions.enumerated()
        where transmission.at < 0 || !(transmission.duration > 0) || !transmission.at.isFinite {
            throw MockScenarioError.invalidTiming(index: index)
        }
        let order = transmissions.indices.sorted { transmissions[$0].at < transmissions[$1].at }
        for (a, b) in zip(order, order.dropFirst()) where transmissions[b].at < transmissions[a].end {
            throw MockScenarioError.overlapping(first: min(a, b), second: max(a, b))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, firmware, loop, mode, idle, transmissions
    }

    /// Missing `model`, `firmware`, `loop`, and `mode` take their defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "SDS200"
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware) ?? "1.26.01"
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? true
        mode = try c.decodeIfPresent(MockMode.self, forKey: .mode) ?? .trunk
        idle = try c.decode(MockIdle.self, forKey: .idle)
        transmissions = try c.decode([MockTransmission].self, forKey: .transmissions)
    }

    /// Decodes JSON and validates it.
    public static func decode(_ data: Data) throws -> MockScenario {
        let scenario = try JSONDecoder().decode(MockScenario.self, from: data)
        try scenario.validate()
        return scenario
    }

    public static func load(_ url: URL) throws -> MockScenario {
        try decode(Data(contentsOf: url))
    }

    /// The URL of a scenario bundled with the mock (`default`, `weather`).
    public static func bundledURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Scenarios")
    }

    static func bundled(_ name: String) -> MockScenario {
        guard let url = bundledURL(name) else { preconditionFailure("missing bundled scenario \(name).json") }
        do { return try load(url) } catch { preconditionFailure("bundled scenario \(name).json: \(error)") }
    }

    /// `Scenarios/default.json`: fictional trunk traffic ("Riverbend County P25"), four
    /// transmissions, one of them unprogrammed.
    public static let `default` = bundled("default")
    /// `Scenarios/weather.json`: WX Scan on one fictional weather channel, active throughout.
    public static let weather = bundled("weather")
}
