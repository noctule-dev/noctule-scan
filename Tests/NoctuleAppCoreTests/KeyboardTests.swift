// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
import NoctuleKit
import NoctuleStore
@testable import NoctuleAppCore

@Suite(.timeLimit(.minutes(3))) struct KeyboardTests {
    @Test func parsesAndFormatsEveryDefault() throws {
        let defaults = KeyMap.defaults(for: .sds200)
        #expect(!defaults.isEmpty)
        for (key, text) in defaults {
            let chord = try #require(KeyChord(text), "\(key) \(text)")
            #expect(chord.display == text)
        }
        let c = try #require(KeyChord("⌘4"))
        #expect(c.key == "4" && c.modifiers == [.command])
        #expect(try #require(KeyChord("⇧⌘a")).display == "⇧⌘a")
        #expect(KeyChord("⌘⇧a") == KeyChord("⇧⌘a"))
    }

    @Test func rejectsGarbage() {
        #expect(KeyChord("") == nil)
        #expect(KeyChord("⌘") == nil)
        #expect(KeyChord("⌘⌥") == nil)
        #expect(KeyChord("ab") == nil)
        #expect(KeyChord("F13") == nil)
    }

    @Test func routerFindsOverride() throws {
        var km = KeyMap()
        km.overrides[FrontPanelKey.menu.rawValue] = "⌘4"
        let router = KeyboardRouter(map: km.resolved(for: .sds200))
        #expect(router.key(for: try #require(KeyChord("⌘4"))) == .menu)
        #expect(router.key(for: try #require(KeyChord("a"))) == .avoid)
        #expect(router.key(for: try #require(KeyChord("m"))) == nil)
        #expect(router.conflicts.isEmpty)
    }

    @Test func conflictsReported() throws {
        var km = KeyMap()
        km.overrides[FrontPanelKey.menu.rawValue] = "a"
        let router = KeyboardRouter(map: km.resolved(for: .sds200))
        let a = try #require(KeyChord("a"))
        #expect(Set(try #require(router.conflicts[a])) == [.menu, .avoid])
        #expect(router.conflicts.count == 1)
    }
}
