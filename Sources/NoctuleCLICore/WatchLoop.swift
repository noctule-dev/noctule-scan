// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization

/// How a `watch` run ended.
public enum WatchOutcome: Equatable, Sendable {
    /// `--count` updates arrived.
    case countReached
    /// The update stream finished first, after this many updates.
    case streamEnded(updates: Int)
    /// No update arrived within the deadline, after this many updates.
    case stalled(updates: Int)
}

/// The deadline logic behind `noctule watch`, kept out of `main.swift` so it is unit-testable.
public enum WatchLoop {
    /// How long `watch` waits for the next push before giving up: max(5 s, 3 × interval).
    public static func deadline(forInterval interval: Duration) -> Duration {
        max(.seconds(5), interval * 3)
    }

    /// `no PSI updates from <host>:<port> for <N> s`.
    /// Whole seconds print bare ("5"); fractions print to one decimal ("5.1").
    public static func stallMessage(host: String, port: UInt16, deadline: Duration) -> String {
        stallMessage(target: "\(host):\(port)", deadline: deadline)
    }

    /// `no PSI updates from <target> for <N> s`, for a target that isn't a host and port (a serial
    /// port's path).
    public static func stallMessage(target: String, deadline: Duration) -> String {
        let (seconds, attoseconds) = deadline.components
        let text = attoseconds == 0
            ? String(seconds)
            : String(format: "%.1f", Double(seconds) + Double(attoseconds) / 1e18)
        return "no PSI updates from \(target) for \(text) s"
    }

    /// Consumes `updates`, calling `onUpdate` for each, until `count` updates have arrived,
    /// the stream finishes, or no update arrives within `deadline` of the previous one (or of
    /// the start). On a stall the consuming task is cancelled, which drops the stream.
    public static func run<Element: Sendable>(
        _ updates: AsyncStream<Element>,
        count: Int?,
        deadline: Duration,
        onUpdate: @escaping @Sendable (Element) -> Void
    ) async -> WatchOutcome {
        let progress = Progress()
        return await withTaskGroup(of: WatchOutcome?.self) { group in
            // Consumer: a nil result means it was cancelled because the watchdog won.
            group.addTask {
                var seen = 0
                for await element in updates {
                    if Task.isCancelled { return nil }
                    onUpdate(element)
                    seen += 1
                    progress.record(seen)
                    if let count, seen >= count { return .countReached }
                }
                return Task.isCancelled ? nil : .streamEnded(updates: seen)
            }
            // Watchdog: sleeps until the last update plus the deadline, re-arming whenever an
            // update arrived meanwhile. A nil result means the consumer finished first.
            group.addTask {
                while true {
                    let (last, seen) = progress.snapshot
                    let due = last + deadline
                    if ContinuousClock.now >= due { return .stalled(updates: seen) }
                    do { try await Task.sleep(until: due, clock: .continuous) } catch { return nil }
                }
            }
            // Leaving the group cancels the loser; a cancelled consumer drops the stream.
            defer { group.cancelAll() }
            while let result = await group.next() {
                if let result { return result }
            }
            return .stalled(updates: progress.snapshot.seen)
        }
    }

    /// The time of the latest update and how many have arrived, shared by consumer and watchdog.
    private final class Progress: Sendable {
        private let state = Mutex((last: ContinuousClock.now, seen: 0))
        func record(_ seen: Int) { state.withLock { $0 = (ContinuousClock.now, seen) } }
        var snapshot: (last: ContinuousClock.Instant, seen: Int) { state.withLock { $0 } }
    }
}
