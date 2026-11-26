// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleKit

@Suite(.timeLimit(.minutes(3))) struct ScannerModelTests {
    @Test func normalizesReportedModels() {
        #expect(ScannerModel(reported: "SDS200") == .sds200)
        #expect(ScannerModel(reported: " sds150gbt ") == .sds150)
        #expect(ScannerModel(reported: "UBC125XLT") == nil)
    }

    @Test func sds200Profile() {
        let p = ModelProfile.profile(for: .sds200)
        #expect(p.volumeRange == 0...29); #expect(p.squelchRange == 0...19)
        #expect(p.transports == [.network, .usbSerial])
        #expect(p.protocolVerifiedOnHardware)
    }

    @Test func otherProfiles() {
        let a = ModelProfile.profile(for: .sds100)
        #expect(a.volumeRange == 0...15); #expect(a.squelchRange == 0...15)
        #expect(a.transports == [.usbSerial]); #expect(!a.protocolVerifiedOnHardware)
        let b = ModelProfile.profile(for: .sds150)
        #expect(b.volumeRange == 0...15); #expect(b.squelchRange == 0...15)
        #expect(b.transports == [.usbSerial, .bluetooth]); #expect(b.protocolVerifiedOnHardware)
        let c = ModelProfile.profile(for: .bcd436hp)
        #expect(c.volumeRange == 0...15); #expect(c.squelchRange == 0...15)
        #expect(c.transports == [.usbSerial]); #expect(!c.protocolVerifiedOnHardware)
        for m in ScannerModel.allCases { #expect(ModelProfile.profile(for: m).model == m) }
    }

    @Test func keyCodes() {
        #expect(FrontPanelKey.avoid.rawValue == "L"); #expect(FrontPanelKey.scrollPush.rawValue == "^")
        #expect(FrontPanelKey.allCases.count == 27)
        #expect(Set(FrontPanelKey.allCases.map(\.rawValue)).count == 27)
    }

    @Test func destructiveNamesMatchLoosely() {
        let d = ModelProfile.profile(for: .sds200).destructiveMenuItems
        for name in [" clear user data ", "Delete System", "delete", "Reset User Settings", "Stop All Avoiding",
                     "Set All Lists Off", "Set All Lists On"] {
            #expect(d.contains(name), "\(name)")
        }
        for name in ["Set All Lists", "Review Avoids", "Undelete"] { #expect(!d.contains(name), "\(name)") }
        for m in [ScannerModel.sds100, .sds150] { #expect(ModelProfile.profile(for: m).destructiveMenuItems == d) }
    }
}
