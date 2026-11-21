// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Waiting out the scanner's RTSP reconnect cooldown before connecting, shared by `listen`, `log`
/// and the app. The store is checked first, so a wait never costs a refused start (and its probe).
public enum RTSPCooldownGate {
    /// How much of the cooldown is left for `host` according to the store, or nil. The store is
    /// keyed the way `RTSPClient` keys it (`RTSPClient.cooldownKeys(for:)`: the IP literal, or a
    /// name's resolved addresses plus the name). The keys' histories are merged and the wait is
    /// `policy.remaining(after:)`: the full value since the latest unclean close, and the latest
    /// close's own wait (the clean-close value only if it was clean). A clean close never hides
    /// an unclean one.
    public static func remaining(store: any RTSPCooldownStore, host: String, policy: RTSPCooldownPolicy) async -> Duration? {
        guard policy.full > .zero else { return nil }
        var merged: RTSPCloseHistory?
        for key in await RTSPClient.cooldownKeys(for: host) {
            merged = RTSPCloseHistory.merged(merged, await store.closeHistory(host: key))
        }
        guard let merged else { return nil }
        return policy.remaining(after: merged)
    }

    /// `remaining(store:host:policy:)` with the same `cooldown` after every close, clean or not.
    public static func remaining(store: any RTSPCooldownStore, host: String, cooldown: Duration) async -> Duration? {
        await remaining(store: store, host: host, policy: .symmetric(cooldown))
    }

    /// Sleeps `duration` plus a small margin, in 100 ms steps. False if `isInterrupted` became true.
    public static func waitOut(_ duration: Duration, isInterrupted: @Sendable () -> Bool) async -> Bool {
        let until = ContinuousClock.now + duration + .milliseconds(50)
        while ContinuousClock.now < until {
            if isInterrupted() { return false }
            try? await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: until)))
        }
        return !isInterrupted()
    }
}
