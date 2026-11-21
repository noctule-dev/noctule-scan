// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Tracks RTP sequence numbers (modulo 2^16) to count loss, duplicates and reordering.
///
/// Relative to the highest sequence seen, a packet is:
/// - `inOrder` (+1), or a `gap` (+2 … +3000, counting the skipped numbers in `lost`);
/// - `duplicate` if it was among the last 64 seen;
/// - `reordered` if it is up to 64 behind (it un-counts its slot from `lost` if that slot was missing);
/// - `stale` if it is 65 … 3000 behind: too late to place, counted in `stale`, state unchanged;
/// - `first` (a restart: the stream reset) for the very first packet, a jump of more than 3000
///   either way, or the 8th `stale` packet in a row (a same-SSRC reset a little way back must
///   not silence the stream until it catches up).
public struct RTPSequenceTracker: Sendable {
    public enum Observation: Equatable, Sendable {
        case first, inOrder, gap(missing: Int), duplicate, reordered, stale
    }

    public private(set) var received = 0
    public private(set) var lost = 0
    public private(set) var duplicates = 0
    public private(set) var reordered = 0
    /// Packets 65 … 3000 behind the highest (too late to place).
    public private(set) var stale = 0

    private static let windowSize = 64
    private static let maxForwardGap = 3000
    private static let staleRunLimit = 8

    private var highest: UInt16?
    private var window: [UInt16] = []      // most recently seen, oldest first
    private var missing: Set<UInt16> = []  // counted lost, not yet seen
    private var staleRun = 0                // consecutive stale observations

    public init() {}

    public mutating func observe(_ seq: UInt16) -> Observation {
        guard let last = highest else { return restart(at: seq) }
        let d = Int(Int16(bitPattern: seq &- last))
        if d == 0 || window.contains(seq) {
            duplicates += 1
            return .duplicate
        }
        if d > 0 {
            guard d <= Self.maxForwardGap else { return restart(at: seq) }
            staleRun = 0
            received += 1
            highest = seq
            remember(seq)
            if d == 1 { return .inOrder }
            for k in 1..<d { missing.insert(last &+ UInt16(k)) }
            missing = missing.filter { Int(Int16(bitPattern: seq &- $0)) <= Self.windowSize }
            lost += d - 1
            return .gap(missing: d - 1)
        }
        guard d >= -Self.maxForwardGap else { return restart(at: seq) }
        if d < -Self.windowSize {
            staleRun += 1
            if staleRun >= Self.staleRunLimit { return restart(at: seq) }
            stale += 1
            return .stale
        }
        staleRun = 0
        received += 1
        reordered += 1
        if missing.remove(seq) != nil { lost -= 1 }
        remember(seq)
        return .reordered
    }

    public mutating func reset() {
        received = 0; lost = 0; duplicates = 0; reordered = 0; stale = 0
        highest = nil; window = []; missing = []; staleRun = 0
    }

    private mutating func restart(at seq: UInt16) -> Observation {
        received += 1
        highest = seq
        window = [seq]
        missing = []
        staleRun = 0
        return .first
    }

    private mutating func remember(_ seq: UInt16) {
        window.append(seq)
        if window.count > Self.windowSize { window.removeFirst() }
    }
}
