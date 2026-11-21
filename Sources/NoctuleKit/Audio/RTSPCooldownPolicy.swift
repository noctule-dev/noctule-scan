// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// How long `RTSPClient` (and anything that waits ahead of it) must leave between one TCP
/// connection to the scanner's RTSP server closing and the next opening, by how the last one closed.
///
/// A quick reconnect after a crash, a network drop or an unanswered request hung the SDS200's
/// audio server until a power cycle (protocol notes §6; LESSONS.md, 2026-11-08), so `full`
/// (120 s by default) applies after every close that isn't clean. The owner's call (Plan 5) is
/// that a controlled close is safe to follow sooner, so `afterCleanClose` (which they set per
/// station, 0…120 s) applies only after a *clean* close: one where this process opened the
/// connection, a session was set up on it, every session it held got a 2xx TEARDOWN reply on that
/// still-open connection, no request on it went unanswered, and `RTSPClient.close()` closed it
/// gracefully. Everything else (a dead lease, a failed or refused connect, a server-closed
/// connection, an unanswered or non-2xx TEARDOWN, any other unanswered request, a teardown that
/// needed a reconnect, a connection that never had a session, and records written by older code)
/// is unclean.
///
/// **A clean close never hides an unclean one.** The wait (`remaining(after:)`) lasts until both
/// `full` has passed since the latest unclean close and the latest close's own wait (by its
/// flag) has passed. A close stamped in the future (the clock stepped back) counts as an unclean
/// close now. Across several cooldown keys, or local and stored records, the latest close and the
/// latest unclean close are each the maximum over all of them (`RTSPCloseHistory.merged`).
public struct RTSPCooldownPolicy: Sendable, Equatable {
    /// The wait after any close that isn't clean. Never negative.
    public let full: Duration
    /// The wait after a clean close, clamped to `0…full`.
    public let afterCleanClose: Duration

    /// 120 s after every close: the behavior before Plan 5.
    public static let standard = RTSPCooldownPolicy(full: .seconds(120), afterCleanClose: .seconds(120))

    /// `full` below zero counts as zero, and `afterCleanClose` is clamped to `0…full`.
    public init(full: Duration = .seconds(120), afterCleanClose: Duration) {
        let full = max(.zero, full)
        self.full = full
        self.afterCleanClose = min(max(.zero, afterCleanClose), full)
    }

    /// The same wait after every close, clean or not (what a single `reconnectCooldown` meant).
    public static func symmetric(_ cooldown: Duration) -> RTSPCooldownPolicy {
        RTSPCooldownPolicy(full: cooldown, afterCleanClose: cooldown)
    }

    /// The wait after a close that was (or wasn't) clean.
    public func required(afterCleanClose clean: Bool) -> Duration {
        clean ? afterCleanClose : full
    }

    /// How much of the wait after `history` is left at `now`, or nil if none: the longer of
    /// `full` after `history.lastUnclean` and the latest close's own wait. A close stamped in the
    /// future (the clock stepped back) counts as an unclean close now.
    func remaining(after history: RTSPCloseHistory, now: Date = Date()) -> Duration? {
        let fullSeconds = Self.seconds(full)
        var left: TimeInterval = 0
        if let unclean = history.lastUnclean {
            left = max(left, fullSeconds - max(0, now.timeIntervalSince(unclean)))
        }
        if let latest = history.latest {
            if latest.at > now {
                left = max(left, fullSeconds)
            } else {
                left = max(left, Self.seconds(required(afterCleanClose: latest.clean)) - now.timeIntervalSince(latest.at))
            }
        }
        return left > 0 ? .seconds(left) : nil
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

extension RTSPCloseHistory {
    /// One close.
    init(_ close: RTSPCloseRecord) {
        self.init(latest: close, lastUnclean: close.clean ? nil : close.at)
    }

    /// Both records combined: the later latest close (unclean winning a tie) and the later
    /// latest unclean close, each taken separately.
    func merged(with other: RTSPCloseHistory?) -> RTSPCloseHistory {
        guard let other else { return self }
        let unclean: Date? = switch (lastUnclean, other.lastUnclean) {
        case let (a?, b?): max(a, b)
        case let (a, b): a ?? b
        }
        return RTSPCloseHistory(latest: RTSPCloseRecord.latest(latest, other.latest), lastUnclean: unclean)
    }

    /// `merged(with:)` over optional histories, nil if both are.
    static func merged(_ a: RTSPCloseHistory?, _ b: RTSPCloseHistory?) -> RTSPCloseHistory? {
        guard let a else { return b }
        return a.merged(with: b)
    }
}

extension RTSPCloseRecord {
    /// The later of two closes; at an equal time, the unclean one (the safe side).
    static func latest(_ a: RTSPCloseRecord?, _ b: RTSPCloseRecord?) -> RTSPCloseRecord? {
        guard let a else { return b }
        guard let b else { return a }
        if a.at != b.at { return a.at > b.at ? a : b }
        return RTSPCloseRecord(at: a.at, clean: a.clean && b.clean)
    }
}
