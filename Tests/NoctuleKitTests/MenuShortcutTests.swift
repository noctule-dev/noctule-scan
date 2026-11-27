// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleKit

@Suite(.timeLimit(.minutes(1))) struct MenuShortcutTests {
    @Test(arguments: ScannerModel.allCases)
    func pathsAreTheDesignsOnEveryModel(model: ScannerModel) {
        let profile = ModelProfile.profile(for: model)
        #expect(profile.menuShortcuts == [.serviceTypes: .serviceTypes, .range: .range])
        for path in profile.menuShortcuts.values { #expect(path.steps.count <= MenuPath.maxSteps) }
        #expect(MenuPath.serviceTypes.steps == [MenuStep(screen: "Menu", item: "Select Service Types")])
        #expect(MenuPath.serviceTypes.destination == "Select Service Types")
        #expect(MenuPath.range.steps == [MenuStep(screen: "Menu", item: "Set Your Location"),
                                         MenuStep(screen: "Set Your Location", item: "Set Range")])
        #expect(MenuPath.range.destination == "Set Range")
    }

    @Test func keysMapToShortcuts() {
        #expect(MenuShortcut(key: .serviceType) == .serviceTypes)
        #expect(MenuShortcut(key: .range) == .range)
        #expect(MenuShortcut(key: .zip) == nil)
        #expect(MenuShortcut.serviceTypes.key == .serviceType && MenuShortcut.range.key == .range)
    }
}
