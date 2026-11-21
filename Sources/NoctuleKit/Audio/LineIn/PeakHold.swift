// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

/// The line-in meter's peak-hold tick (line-in design §5.3): the highest peak shown, held for
/// `holdTime`, then falling to the current peak, which is held from then on in turn. A higher peak
/// replaces it at once. Pure, on the readings' own instants.
public struct PeakHold: Sendable, Equatable {
    /// How long a peak is held (about 1.5 s).
    public static let holdTime: Duration = .milliseconds(1500)

    /// The peak held now, in dBFS; nil before the first reading and after `reset()`.
    public private(set) var held: Double?
    private var heldAt: ContinuousClock.Instant?

    public init() {}

    /// Takes a reading's peak at `at`, returning the peak to show: the reading when it is at least
    /// the one held, or the one held is `holdTime` old (or older); the one held otherwise.
    public mutating func update(peak: Double, at: ContinuousClock.Instant) -> Double {
        if let held, let heldAt, peak < held, heldAt.duration(to: at) < Self.holdTime { return held }
        held = peak
        heldAt = at
        return peak
    }

    /// Forgets the peak held (the input stopped or went away).
    public mutating func reset() {
        held = nil
        heldAt = nil
    }
}
