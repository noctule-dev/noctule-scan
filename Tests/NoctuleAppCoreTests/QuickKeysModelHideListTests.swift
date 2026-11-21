// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleAppCore

// `QuickKeysModel.hideList()` (design `docs/specs/2026-11-18-quick-keys-design.md` §5.5: the tree belongs to the
// focused tile): the open list's tree closes, and nothing else changes.

@MainActor
@Suite(.timeLimit(.minutes(1))) struct QuickKeysModelHideListTests {
    @Test func hidingTheListClosesItsTree() {
        let model = QuickKeysModel(cacheURL: nil)
        model.showList(4)
        #expect(model.shownList == 4)
        model.hideList()
        #expect(model.shownList == nil)
        model.hideList()
        #expect(model.shownList == nil, "hiding with nothing shown does nothing")
        model.showList(6)
        #expect(model.shownList == 6, "a list can be shown again")
    }
}
