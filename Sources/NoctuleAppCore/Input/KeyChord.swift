// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum KeyModifier: String, CaseIterable, Sendable {
    case command = "⌘", option = "⌥", control = "⌃", shift = "⇧"
}

/// A keyboard shortcut as stored in `KeyMap` strings: leading modifier symbols, then one key.
public struct KeyChord: Hashable, Sendable {
    public var key: String
    public var modifiers: Set<KeyModifier>

    public init(key: String, modifiers: Set<KeyModifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Named keys other than a single character.
    static let namedKeys: Set<String> = Set(["space"] + (1...12).map { "F\($0)" })

    /// Parses "a", "F1", "space", "←", "↩", "⌘4". Returns nil for "", a bare modifier, or an unknown multi-character key.
    public init?(_ text: String) {
        var mods: Set<KeyModifier> = []
        var rest = Substring(text)
        while let first = rest.first, let m = KeyModifier(rawValue: String(first)) {
            mods.insert(m)
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        guard rest.count == 1 || KeyChord.namedKeys.contains(String(rest)) else { return nil }
        self.init(key: String(rest), modifiers: mods)
    }

    /// Modifiers in the macOS order (⌃⌥⇧⌘) followed by the key.
    public var display: String {
        let order: [KeyModifier] = [.control, .option, .shift, .command]
        return order.filter { modifiers.contains($0) }.map(\.rawValue).joined() + key
    }
}
