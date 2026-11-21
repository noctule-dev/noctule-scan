// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

/// The mock's scenario time, in seconds from scenario start.
///
/// `.real()` follows wall time from its creation (plus any `advance`); `.stepped(at:)` stands
/// still until a test moves it with `advance(by:)` or `set(_:)`, so tests are deterministic.
/// Only scenario content (what GSI, STS, PSI, and the RTP tone show) and a personality's push
/// lifetime (`MockPersonality.pushLifetime`) follow this clock; network timing (PSI intervals, RTP
/// pacing, reply delays, the reconnect cooldown, reboots, the timed faults) is real time.
public final class MockClock: Sendable {
    private let origin: ContinuousClock.Instant?
    private let offset: Mutex<Double>

    private init(origin: ContinuousClock.Instant?, offset: Double) {
        self.origin = origin
        self.offset = Mutex(offset)
    }

    /// Scenario time that runs in real time, starting at `seconds`.
    public static func real(startingAt seconds: Double = 0) -> MockClock {
        MockClock(origin: .now, offset: seconds)
    }

    /// Scenario time that moves only when told to.
    public static func stepped(at seconds: Double = 0) -> MockClock {
        MockClock(origin: nil, offset: seconds)
    }

    public var isStepped: Bool { origin == nil }

    /// Seconds from scenario start.
    public var now: Double {
        let base = offset.withLock { $0 }
        guard let origin else { return base }
        let elapsed = origin.duration(to: .now)
        return base + Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func advance(by seconds: Double) {
        offset.withLock { $0 += seconds }
    }

    /// Jumps to `seconds` from scenario start.
    public func set(_ seconds: Double) {
        let current = now
        offset.withLock { $0 += seconds - current }
    }
}
