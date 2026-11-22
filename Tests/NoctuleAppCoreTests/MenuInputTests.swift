// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
@testable import NoctuleAppCore

// MenuInput: what an entry screen's value may hold before it is sent with `MSV,,<text>` (design
// §4.3, §5.3). The rules are the shapes of the hardware's `MenuInput` elements; values are fictional.

private let nameKeys = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890[\\]^_`{|}~!\"#$%&'()*+,-./:;<=>?@ "
private let nameRules = MenuScreen.InputRules(maxLength: 64, allowedCharacters: nameKeys)
private let rangeRules = MenuScreen.InputRules(maxLength: 5, allowedCharacters: "0123456789.",
                                               addedInformation: "          (mile)")

@Suite(.timeLimit(.minutes(3))) struct MenuInputTests {
    @Test func sanitizeKeepsOnlyAllowedCharacters() {
        // The comma is in EnableKeys but is never sent; é isn't; the newline never is.
        #expect(MenuInput.sanitize("Fire, é North\n", rules: nameRules) == "Fire  North")
        #expect(MenuInput.sanitize("A\r\nB\rC", rules: nameRules) == "ABC")
        #expect(!MenuInput.isValid("Fire, North", rules: nameRules))
        #expect(MenuInput.isValid("Fire North", rules: nameRules))
    }

    @Test func sanitizeTruncates() {
        let long = String(repeating: "abcdefghij", count: 7)
        #expect(long.count == 70)
        let sanitized = MenuInput.sanitize(long, rules: nameRules)
        #expect(sanitized.count == 64)
        #expect(sanitized == String(long.prefix(64)))
        #expect(!MenuInput.isValid(long, rules: nameRules))
        #expect(MenuInput.isValid(String(long.prefix(64)), rules: nameRules))
    }

    @Test func numbersOnly() {
        #expect(MenuInput.sanitize("3x1.0", rules: rangeRules) == "31.0")
        #expect(MenuInput.isValid("31.0", rules: rangeRules))
        #expect(!MenuInput.isValid("3x1.0", rules: rangeRules))
        #expect(!MenuInput.isValid("123456", rules: rangeRules))
        #expect(!MenuInput.isValid("1,2", rules: rangeRules))
    }

    @Test func emptyIsInvalid() {
        #expect(!MenuInput.isValid("", rules: nameRules))
        #expect(!MenuInput.isValid("", rules: MenuScreen.InputRules()))
        // Nothing left after sanitizing is empty too.
        #expect(MenuInput.sanitize("xyz", rules: rangeRules) == "")
        #expect(!MenuInput.isValid(",", rules: MenuScreen.InputRules()))
    }

    @Test func nilRulesAllowAnythingButCommaAndNewlines() {
        let open = MenuScreen.InputRules()
        let text = "é ü ~ \u{7F} 🚒 " + String(repeating: "x", count: 200)
        #expect(MenuInput.sanitize(text, rules: open) == text)
        #expect(MenuInput.isValid(text, rules: open))
        #expect(MenuInput.sanitize("a,b\nc\rd\r\ne", rules: open) == "abcde")
        #expect(!MenuInput.isValid("a\nb", rules: open))
        #expect(!MenuInput.isValid("a\r\nb", rules: open))
    }
}
