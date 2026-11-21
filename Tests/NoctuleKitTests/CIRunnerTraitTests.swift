// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
import NoctuleKitTestSupport

@Suite struct CIRunnerTraitTests {
    @Test func unsetIsNotARunner() {
        #expect(isCIRunner([:]) == false)
    }

    @Test func emptyIsNotARunner() {
        #expect(isCIRunner(["NOCTULE_CI_RUNNER": ""]) == false)
    }

    @Test func setIsARunner() {
        #expect(isCIRunner(["NOCTULE_CI_RUNNER": "1"]) == true)
    }
}
