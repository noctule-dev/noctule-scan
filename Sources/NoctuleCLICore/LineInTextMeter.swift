// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// The one-line text meter `listen --station --meter` draws for a line-in (Plan 19; line-in design
/// §5.3): 20 cells over -60...0 dBFS (cell k, 0...19, is filled when the held peak reaches
/// -60 + 3(k+1) dBFS), a `|` after the 18th cell at -6 dBFS (the top of the target band), the held
/// peak (`PeakHold`, 1.5 s) rounded to a whole decibel, and ` CLIP` for `clipLatch` after a clipped
/// level. Pure: it draws what `update(_:)` was given, at the instant the caller names.
public struct LineInTextMeter: Sendable, Equatable {
    /// The cells across the bar.
    public static let cells = 20
    /// How long CLIP stays lit after a clipped level.
    public static let clipLatch: Duration = .seconds(3)

    private static let floorDBFS = -60.0
    private static let dBPerCell = 3.0
    /// The bar goes after this many cells: -6 dBFS.
    private static let cellsBeforeTargetMark = 18

    private var hold = PeakHold()
    private var lastClip: ContinuousClock.Instant?

    public init() {}

    /// Takes a level: the peak goes through the peak hold, and a clipped level starts the latch.
    public mutating func update(_ level: LineInLevel) {
        _ = hold.update(peak: level.peakDBFS, at: level.at)
        if level.clipped { lastClip = level.at }
    }

    /// The line to draw at `now`, with no newline or carriage return.
    public func line(at now: ContinuousClock.Instant) -> String {
        let peak = hold.held ?? -.infinity
        var bar = ""
        for k in 0..<Self.cells {
            if k == Self.cellsBeforeTargetMark { bar += "|" }
            bar += peak >= Self.floorDBFS + Self.dBPerCell * Double(k + 1) ? "▇" : "·"
        }
        var line = "line-in \(bar) peak \(Self.peakText(peak)) dBFS"
        if let lastClip, lastClip.duration(to: now) < Self.clipLatch { line += " CLIP" }
        return line
    }

    /// How often to redraw: about every 100 ms on a terminal (in place, with `\r`), once a second
    /// when stderr is a file or a pipe (a line each).
    public static func redrawInterval(isTerminal: Bool) -> Duration {
        isTerminal ? .milliseconds(100) : .seconds(1)
    }

    private static func peakText(_ peak: Double) -> String {
        if peak == -.infinity { return "\u{2212}\u{221E}" }
        let whole = Int(peak.rounded())
        return whole < 0 ? "\u{2212}\(-whole)" : "\(whole)"
    }
}
