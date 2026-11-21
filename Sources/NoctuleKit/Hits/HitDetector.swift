// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Turns timestamped `PSI` pushes into transmission hits.
///
/// A pure value type with no clock of its own: all time comes from `PushUpdate.receivedAt` and the
/// `now` arguments, and wall-clock dates are `anchor.date + (instant - anchor.instant)`.
///
/// Rules:
/// - An update is *active* when `info.isReceiving` (`hasActiveChannel` and `Sig` above 0), so an
///   SDS150 stepping through its conventional channels with `Sig="0"` never starts a hit.
///   On a trunked system (`info.isTrunk`) that requires a talkgroup, so a scanner parked on a
///   control channel (`SiteFrequency`, signal, TGID placeholder) never starts a hit.
/// - Key: trunk (`isTrunk`, not weather) is system + talkgroup; conventional and weather is
///   system + frequency rounded to 4 decimal places, so float noise can't split a hit.
/// - An active update with no open hit starts one (`.started`). The descriptive fields
///   (department, channel, site, modulation, tone/code) come from that first update; `programmed`
///   is `channel?.isProgrammed ?? true`.
/// - An active update with the open hit's key extends it: `endInstant` moves to the update, new
///   unit IDs are appended in arrival order, and `rssiMax` rises (nil RSSI is ignored). `.updated`
///   is emitted when any of those visibly change, which in practice is every active update, since
///   each one extends the end. At most one `.updated` per `ingest`.
/// - An active update with a different key ends the open hit (`channelChanged`) and starts another.
/// - Silence alone (no push at all since the last active one) ends a hit only through `stallEnd`
///   (`stalled`). `signalLost` needs a later *inactive* push. So a lost `PSI` datagram can't split
///   a transmission: a same-key active push after any silent gap under `stallEnd` continues the
///   hit, and a different key after one is `channelChanged`.
/// - Hangover: once an inactive push has arrived after the last active one, the hit ends
///   `signalLost` on the first `ingest` or `tick` whose time is at least
///   `lastActive + endHangover`. An active update with the same key before then continues the hit.
/// - Stall: `tick(now:)` (or an `ingest` that follows a gap) with
///   `now - lastUpdateReceived >= stallEnd` ends the hit `stalled`. Every update, active or not,
///   counts as received; `lastUpdateReceived` is the newest `receivedAt` seen, so an out-of-order
///   push can't move the stall clock backwards. Frequent ticks can't pre-empt the stall.
/// - Max length: an active update with `receivedAt - startInstant >= maxTransmission` ends the hit
///   `maxLength` at the previous active update, then starts a new hit with the same key and
///   `continued = true` at this update.
/// - `finish(now:)` ends any open hit `stopped`; `finish(now:reason:)` with the given reason.
/// - An ended hit's `endedAt` and `endInstant` are always the last *active* update's time.
public struct HitDetector: Sendable {
    private let anchor: (instant: ContinuousClock.Instant, date: Date)
    private let endHangover: Duration
    private let stallEnd: Duration
    private let maxTransmission: Duration
    private let makeID: @Sendable () -> UUID

    private var open: Hit?
    private var lastUpdateReceived: ContinuousClock.Instant?

    public init(
        anchor: (instant: ContinuousClock.Instant, date: Date),
        endHangover: Duration = .seconds(1), stallEnd: Duration = .seconds(3),
        maxTransmission: Duration = .seconds(300),
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.anchor = anchor
        self.endHangover = endHangover
        self.stallEnd = stallEnd
        self.maxTransmission = maxTransmission
        self.makeID = makeID
    }

    public mutating func ingest(_ u: PushUpdate) -> [HitEvent] {
        let t = u.receivedAt
        var events = expire(now: t)
        // Never move the stall clock backwards on an out-of-order `receivedAt`.
        lastUpdateReceived = max(lastUpdateReceived ?? t, t)

        let info = u.info
        guard info.isReceiving else {
            // An inactive push is the evidence the hangover needs.
            if let hit = open, let last = hit.endInstant, t - last >= endHangover {
                events.append(.ended(close(hit, .signalLost)))
            }
            return events
        }
        let key = Self.key(for: info)

        guard var hit = open else {
            events.append(.started(start(info, key: key, at: t, continued: false)))
            return events
        }
        if hit.key != key {
            events.append(.ended(close(hit, .channelChanged)))
            events.append(.started(start(info, key: key, at: t, continued: false)))
            return events
        }
        if t - hit.startInstant >= maxTransmission {
            events.append(.ended(close(hit, .maxLength)))
            events.append(.started(start(info, key: key, at: t, continued: true)))
            return events
        }

        let before = hit
        if let last = hit.endInstant, t > last { hit.endInstant = t }
        if let uid = info.unitID, !hit.unitIDs.contains(uid) { hit.unitIDs.append(uid) }
        if let rssi = info.rssi, rssi > (hit.rssiMax ?? .min) { hit.rssiMax = rssi }
        open = hit
        if hit != before { events.append(.updated(hit)) }
        return events
    }

    public mutating func tick(now: ContinuousClock.Instant) -> [HitEvent] {
        expire(now: now)
    }

    public mutating func finish(now: ContinuousClock.Instant) -> [HitEvent] {
        finish(now: now, reason: .stopped)
    }

    /// Ends any open hit with `reason` (for example `stalled` when the push stream itself ended).
    public mutating func finish(now: ContinuousClock.Instant, reason: Hit.EndReason) -> [HitEvent] {
        guard let hit = open else { return [] }
        return [.ended(close(hit, reason))]
    }

    // MARK: - Internals

    /// Ends the open hit by hangover (only after some update followed the last active one) or by
    /// stall (no update at all for `stallEnd`), judged at `now` against what was received before.
    private mutating func expire(now: ContinuousClock.Instant) -> [HitEvent] {
        guard let hit = open, let lastActive = hit.endInstant, let received = lastUpdateReceived
        else { return [] }
        if received > lastActive, now - lastActive >= endHangover {
            return [.ended(close(hit, .signalLost))]
        }
        if now - received >= stallEnd {
            return [.ended(close(hit, .stalled))]
        }
        return []
    }

    private mutating func start(
        _ info: ScannerInfo, key: HitKey, at t: ContinuousClock.Instant, continued: Bool
    ) -> Hit {
        let hit = Hit(
            id: makeID(), key: key, startedAt: date(t), startInstant: t, endInstant: t,
            system: info.system?.name, department: info.department?.name, channel: info.channel?.name,
            site: info.site?.name, unitIDs: info.unitID.map { [$0] } ?? [],
            modulation: info.modulation, toneOrCode: info.toneOrCode, rssiMax: info.rssi,
            programmed: info.channel?.isProgrammed ?? true, continued: continued)
        open = hit
        return hit
    }

    private mutating func close(_ hit: Hit, _ reason: Hit.EndReason) -> Hit {
        var hit = hit
        let end = hit.endInstant ?? hit.startInstant
        hit.endInstant = end
        hit.endedAt = date(end)
        hit.endReason = reason
        open = nil
        return hit
    }

    private func date(_ instant: ContinuousClock.Instant) -> Date {
        let d = instant - anchor.instant
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return anchor.date.addingTimeInterval(seconds)
    }

    static func key(for info: ScannerInfo) -> HitKey {
        if info.isTrunk, !info.isWeather, let tg = info.talkgroupID {
            return HitKey(system: info.system?.name, talkgroupID: tg, frequencyMHz: nil)
        }
        let freq = info.frequencyMHz.map { ($0 * 10_000).rounded() / 10_000 }
        return HitKey(system: info.system?.name, talkgroupID: nil, frequencyMHz: freq)
    }
}
