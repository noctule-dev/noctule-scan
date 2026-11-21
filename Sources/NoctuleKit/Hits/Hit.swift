// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// What identifies one transmission source: trunk hits key on system plus talkgroup, conventional
/// and weather hits on system plus frequency (rounded to 4 decimal places).
public struct HitKey: Hashable, Sendable, Codable {
    public var system: String?
    public var talkgroupID: String?
    public var frequencyMHz: Double?

    public init(system: String?, talkgroupID: String?, frequencyMHz: Double?) {
        self.system = system; self.talkgroupID = talkgroupID; self.frequencyMHz = frequencyMHz
    }
}

/// One transmission: from the first active push to the last active push with the same key.
///
/// While the hit is open, `endInstant` is the last active update's instant (it extends with every
/// active update), and `endedAt` and `endReason` are nil. When it ends, `endedAt` is set from
/// `endInstant` and `endReason` says why.
///
/// `startInstant` and `endInstant` are runtime-only (`ContinuousClock` has no meaning across
/// processes), so `Codable` omits them. A decoded hit gets `decodedInstantPlaceholder` for
/// `startInstant`, and for `endInstant` when `endedAt` is set (nil otherwise). Those decoded
/// instants are meaningless; use `startedAt` and `endedAt`.
public struct Hit: Sendable, Equatable, Codable {
    public enum EndReason: String, Sendable, Codable {
        case signalLost, channelChanged, stalled, maxLength, stopped, interrupted
    }

    public var id: UUID
    public var key: HitKey
    public var startedAt: Date
    public var endedAt: Date?
    public var startInstant: ContinuousClock.Instant
    public var endInstant: ContinuousClock.Instant?
    public var system: String?
    public var department: String?
    public var channel: String?
    public var site: String?
    public var unitIDs: [String]
    public var modulation: String?
    public var toneOrCode: String?
    public var rssiMax: Int?
    public var programmed: Bool
    public var continued: Bool
    public var endReason: EndReason?

    /// The instant a decoded `Hit` carries in place of its runtime-only instants. It is a fixed
    /// value for the life of the process and means nothing; never do arithmetic with it.
    public static let decodedInstantPlaceholder: ContinuousClock.Instant = .now

    public init(
        id: UUID, key: HitKey, startedAt: Date, endedAt: Date? = nil,
        startInstant: ContinuousClock.Instant, endInstant: ContinuousClock.Instant? = nil,
        system: String? = nil, department: String? = nil, channel: String? = nil, site: String? = nil,
        unitIDs: [String] = [], modulation: String? = nil, toneOrCode: String? = nil, rssiMax: Int? = nil,
        programmed: Bool = true, continued: Bool = false, endReason: EndReason? = nil
    ) {
        self.id = id; self.key = key; self.startedAt = startedAt; self.endedAt = endedAt
        self.startInstant = startInstant; self.endInstant = endInstant
        self.system = system; self.department = department; self.channel = channel; self.site = site
        self.unitIDs = unitIDs; self.modulation = modulation; self.toneOrCode = toneOrCode
        self.rssiMax = rssiMax; self.programmed = programmed; self.continued = continued
        self.endReason = endReason
    }
}

extension Hit {
    private enum CodingKeys: String, CodingKey {
        case id, key, startedAt, endedAt, system, department, channel, site, unitIDs, modulation
        case toneOrCode, rssiMax, programmed, continued, endReason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            key: try c.decode(HitKey.self, forKey: .key),
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            endedAt: endedAt,
            startInstant: Self.decodedInstantPlaceholder,
            endInstant: endedAt == nil ? nil : Self.decodedInstantPlaceholder,
            system: try c.decodeIfPresent(String.self, forKey: .system),
            department: try c.decodeIfPresent(String.self, forKey: .department),
            channel: try c.decodeIfPresent(String.self, forKey: .channel),
            site: try c.decodeIfPresent(String.self, forKey: .site),
            unitIDs: try c.decodeIfPresent([String].self, forKey: .unitIDs) ?? [],
            modulation: try c.decodeIfPresent(String.self, forKey: .modulation),
            toneOrCode: try c.decodeIfPresent(String.self, forKey: .toneOrCode),
            rssiMax: try c.decodeIfPresent(Int.self, forKey: .rssiMax),
            programmed: try c.decodeIfPresent(Bool.self, forKey: .programmed) ?? true,
            continued: try c.decodeIfPresent(Bool.self, forKey: .continued) ?? false,
            endReason: try c.decodeIfPresent(EndReason.self, forKey: .endReason))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(system, forKey: .system)
        try c.encodeIfPresent(department, forKey: .department)
        try c.encodeIfPresent(channel, forKey: .channel)
        try c.encodeIfPresent(site, forKey: .site)
        try c.encode(unitIDs, forKey: .unitIDs)
        try c.encodeIfPresent(modulation, forKey: .modulation)
        try c.encodeIfPresent(toneOrCode, forKey: .toneOrCode)
        try c.encodeIfPresent(rssiMax, forKey: .rssiMax)
        try c.encode(programmed, forKey: .programmed)
        try c.encode(continued, forKey: .continued)
        try c.encodeIfPresent(endReason, forKey: .endReason)
    }
}

public enum HitEvent: Sendable {
    case started(Hit), updated(Hit), ended(Hit)
}
