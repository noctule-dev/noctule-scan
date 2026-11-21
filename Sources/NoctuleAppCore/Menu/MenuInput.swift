// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// What an entry screen's text may hold before it is sent with `MSV,,<text>` (design §4.3, §5.3).
///
/// A comma, CR or LF is never allowed, whatever the rules say: the comma is the protocol's field
/// separator (the spec's comma-as-tab rule is untried on hardware) and CR ends a command. With
/// `allowedCharacters` (the screen's `EnableKeys`) every other character must be one of them; with
/// `maxLength` the text is at most that many characters.
public enum MenuInput {
    /// Drops disallowed characters, commas, CR and LF, then truncates to `maxLength`.
    public static func sanitize(_ text: String, rules: MenuScreen.InputRules) -> String {
        var kept = String(text.filter { isAllowed($0, rules: rules) })
        if let maxLength = rules.maxLength, kept.count > maxLength {
            kept = String(kept.prefix(max(0, maxLength)))
        }
        return kept
    }

    /// Non-empty and unchanged by `sanitize(_:rules:)`.
    public static func isValid(_ text: String, rules: MenuScreen.InputRules) -> Bool {
        !text.isEmpty && sanitize(text, rules: rules) == text
    }

    private static func isAllowed(_ character: Character, rules: MenuScreen.InputRules) -> Bool {
        // By scalar: "\r\n" is one Character, equal to neither "\r" nor "\n" (LESSONS 2026-11-08).
        guard !character.unicodeScalars.contains(where: { $0 == "," || $0 == "\r" || $0 == "\n" }) else {
            return false
        }
        guard let allowed = rules.allowedCharacters else { return true }
        return allowed.contains(character)
    }
}
