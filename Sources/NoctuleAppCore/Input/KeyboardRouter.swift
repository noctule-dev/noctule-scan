// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// Maps keyboard chords to front-panel keys from a resolved `KeyMap`.
public struct KeyboardRouter: Sendable {
    private let byChord: [KeyChord: [FrontPanelKey]]

    /// Entries whose text doesn't parse are skipped.
    public init(map: [FrontPanelKey: String]) {
        var byChord: [KeyChord: [FrontPanelKey]] = [:]
        for (key, text) in map {
            guard let chord = KeyChord(text) else { continue }
            byChord[chord, default: []].append(key)
        }
        for chord in byChord.keys { byChord[chord]?.sort { $0.rawValue < $1.rawValue } }
        self.byChord = byChord
    }

    /// The key for a chord. With a conflict, the first by raw value wins (stable).
    public func key(for chord: KeyChord) -> FrontPanelKey? { byChord[chord]?.first }

    /// Chords assigned to more than one key.
    public var conflicts: [KeyChord: [FrontPanelKey]] { byChord.filter { $0.value.count > 1 } }
}
