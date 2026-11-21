// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// When to fetch the next `STS` screen. Polling is slow by default so the scanner isn't hammered.
public struct DisplayRefreshPolicy: Sendable {
    public var minInterval: Duration = .seconds(1)
    public var maxInterval: Duration = .seconds(5)
    public var afterKey: Duration = .milliseconds(150)
    /// In a menu: the shortest gap between fetches, and the gap when nothing has changed.
    public var menuMinInterval: Duration = .milliseconds(200)
    public var menuIdleInterval: Duration = .seconds(2)
    /// In a menu: key replies push the next fetch to `afterKey` after the latest, but never later
    /// than this after the last fetch, so a held key (replies closer together than `afterKey`)
    /// still shows the screen moving.
    public var menuMaxKeyDeferral: Duration = .milliseconds(400)

    public init() {}

    /// The default policy, with the model's `ModelProfile.displayRefreshInterval` as `minInterval`.
    public init(model: ScannerModel) {
        minInterval = ModelProfile.profile(for: model).displayRefreshInterval
    }

    /// The instant of the next fetch. Never earlier than `lastFetch + minInterval`. A change, or a key
    /// reply since the last fetch, brings it forward (a key reply waits `afterKey` first); otherwise it
    /// is `lastFetch + maxInterval`. With no earlier fetch, `now`.
    public func nextFetch(lastFetch: ContinuousClock.Instant?, lastKeyReply: ContinuousClock.Instant?,
                          changed: Bool, now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        nextFetch(lastFetch: lastFetch, lastKeyReply: lastKeyReply, changed: changed, now: now, inMenu: false)
    }

    /// Like the four-argument form; with `inMenu` the scanner is in a menu and the screen is re-read
    /// promptly: never before `lastFetch + menuMinInterval`, `afterKey` after a key (or menu command)
    /// reply since the last fetch but no later than `lastFetch + menuMaxKeyDeferral`, and otherwise
    /// every `menuIdleInterval` so the radio's own panel shows.
    public func nextFetch(lastFetch: ContinuousClock.Instant?, lastKeyReply: ContinuousClock.Instant?,
                          changed: Bool, now: ContinuousClock.Instant, inMenu: Bool) -> ContinuousClock.Instant {
        guard let lastFetch else { return now }
        if inMenu {
            let earliest = lastFetch + menuMinInterval
            if let reply = lastKeyReply, reply > lastFetch {
                return max(min(reply + afterKey, lastFetch + menuMaxKeyDeferral), earliest)
            }
            return changed ? earliest : lastFetch + menuIdleInterval
        }
        let earliest = lastFetch + minInterval
        if changed { return earliest }
        if let reply = lastKeyReply, reply > lastFetch { return min(max(reply + afterKey, earliest), lastFetch + maxInterval) }
        return lastFetch + maxInterval
    }

    /// True when something the screen shows changed: mode, screen, system/department/channel name,
    /// talkgroup, or a hold/avoid flag. Signal strength and similar are ignored.
    public static func significantChange(_ a: ScannerInfo?, _ b: ScannerInfo) -> Bool {
        guard let a else { return true }
        func flags(_ i: ScannerInfo) -> [Bool?] {
            [i.system, i.department, i.channel].flatMap { [$0?.hold, $0?.avoid] }
        }
        return a.mode != b.mode || a.screen != b.screen
            || a.system?.name != b.system?.name || a.department?.name != b.department?.name
            || a.channel?.name != b.channel?.name || a.talkgroupID != b.talkgroupID
            || flags(a) != flags(b)
            || a.menuTitle != b.menuTitle || a.menuIndex != b.menuIndex || a.menuScreenKind != b.menuScreenKind
    }
}
