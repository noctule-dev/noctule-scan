// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
@testable import NoctuleKit

@Suite(.timeLimit(.minutes(3))) struct ModelProfileTests {
    @Test func profiles() {
        let sds200 = ModelProfile.profile(for: .sds200)
        #expect(sds200.hasNetworkAudio); #expect(sds200.supportsRemoteRestart)
        #expect(!sds200.supportsChargeStatus); #expect(sds200.usbProductIDs == [])

        let sds150 = ModelProfile.profile(for: .sds150)
        #expect(!sds150.hasNetworkAudio); #expect(!sds150.supportsRemoteRestart)
        #expect(sds150.supportsChargeStatus); #expect(sds150.usbProductIDs == [0x001A])

        // The SDS100 shows the SDS150's product ID in serial mode; neither has audio, restart or a battery reading here.
        let sds100 = ModelProfile.profile(for: .sds100)
        #expect(!sds100.hasNetworkAudio); #expect(!sds100.supportsRemoteRestart)
        #expect(!sds100.supportsChargeStatus); #expect(sds100.usbProductIDs == [0x001A])

    }

    /// The BCD436HP (design §5.1): on the SDS handhelds' stack, with its own menu commands and no soft keys.
    @Test func bcd436hpProfile() {
        let p = ModelProfile.profile(for: .bcd436hp)
        #expect(p.volumeRange == 0...15 && p.squelchRange == 0...15)
        #expect(p.pushKeepAlive == PushKeepAlive(action: .renewSubscription, interval: .seconds(60)))
        #expect(p.pushInterval == .milliseconds(100) && p.displayRefreshInterval == .milliseconds(100))
        #expect(p.supportsQuickKeys && !p.supportsChargeStatus && !p.supportsRemoteRestart && !p.hasNetworkAudio)
        #expect(p.usbProductIDs == [0x001A] && !p.protocolVerifiedOnHardware)
        #expect(p.display == .bcd436hp && p.menuNavigation == .menuCommands && p.holdMethod == .holdCommand)
        #expect(p.frontPanelKeys == Set(FrontPanelKey.allCases).subtracting([.serviceType, .squelchPush]))
        #expect(p.destructiveMenuItems == .bcd436hp)
        #expect(p.encoderPushCaption == "Vol")
    }

    @Test(arguments: [ScannerModel.sds200, .sds150, .sds100])
    func sdsModelsKeepTheirData(model: ScannerModel) {
        let p = ModelProfile.profile(for: model)
        #expect(p.display == .sds && p.display.columns == 30 && p.display.hasSoftKeyLine)
        #expect(p.menuNavigation == .keys && p.holdMethod == .softKeyLabel)
    }

    /// The handhelds' panels (design §5.11): keys a model lacks are not offered, and the encoder push is captioned.
    @Test func handheldPanels() {
        let all = Set(FrontPanelKey.allCases)
        let sds200 = ModelProfile.profile(for: .sds200)
        #expect(sds200.frontPanelKeys == all && sds200.encoderPushCaption == "Func")
        let sds100 = ModelProfile.profile(for: .sds100)
        #expect(sds100.frontPanelKeys == all.subtracting([.serviceType, .squelchPush]) && sds100.encoderPushCaption == "Vol")
        let sds150 = ModelProfile.profile(for: .sds150)
        #expect(sds150.frontPanelKeys == all.subtracting([.serviceType, .squelchPush, .range])
                && sds150.encoderPushCaption == "Vol")
    }

    @Test func bcd436hpDestructiveItems() {
        let d = DestructiveMenuItems.bcd436hp
        for name in ["Clear User Data", "Reset User Settings", "Stop All Avoiding", "Set All Lists Off", "Set All Lists On",
                     "Clear All ID Avoids", "Reset to Factory", "Delete Site", "Initialize Value"] {
            #expect(d.contains(name), "\(name)")
        }
        #expect(!d.contains("Set Clock"))
    }

    /// The keep-alive a subscription passes: the model's, over a serial link only, with an
    /// interval override applied only to a keep-alive the model has.
    @Test func keepAliveForASubscription() {
        let kal = PushKeepAlive(command: "KAL", interval: .seconds(60))
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150", overSerial: true) == kal)
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150GBT", overSerial: true) == kal)
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150", overSerial: true, interval: .milliseconds(400))
                == PushKeepAlive(command: "KAL", interval: .milliseconds(400)))
        // The SDS100 renews its own `PSI` instead of sending a command.
        let renewal = PushKeepAlive(action: .renewSubscription, interval: .seconds(60))
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS100", overSerial: true) == renewal)
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS100", overSerial: true, interval: .milliseconds(400))
                == PushKeepAlive(action: .renewSubscription, interval: .milliseconds(400)))
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS100", overSerial: false) == nil)
        #expect(PushKeepAlive.forSubscription(reportedModel: "BCD436HP", overSerial: true) == renewal)
        #expect(PushKeepAlive.forSubscription(reportedModel: "BCD436HP", overSerial: false) == nil)
        // Never over the network, and never to a model without one, whatever the override.
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150", overSerial: false) == nil)
        #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150", overSerial: false, interval: .seconds(1)) == nil)
        for reported in ["SDS200", "UBC9999", ""] {
            #expect(PushKeepAlive.forSubscription(reportedModel: reported, overSerial: true) == nil, "\(reported)")
            #expect(PushKeepAlive.forSubscription(reportedModel: reported, overSerial: true, interval: .seconds(1)) == nil,
                    "\(reported)")
            #expect(PushKeepAlive.forSubscription(reportedModel: reported, overSerial: false) == nil, "\(reported)")
        }
    }

    /// The two kinds of keep-alive: a named command (`KAL`), the form every existing call site
    /// builds, and the renewal of the subscription's own `PSI`.
    @Test func keepAliveKinds() {
        #expect(PushKeepAlive(command: "KAL", interval: .seconds(60)).action == .command("KAL"))
        #expect(PushKeepAlive(command: "KAL", interval: .seconds(60))
                == PushKeepAlive(action: .command("KAL"), interval: .seconds(60)))
        #expect(PushKeepAlive(action: .renewSubscription, interval: .seconds(60)).action == .renewSubscription)
        #expect(PushKeepAlive(action: .renewSubscription, interval: .seconds(60))
                != PushKeepAlive(command: "PSI", interval: .seconds(60)))
        #expect("\(PushRenewalRefused())" == "the scanner refused PSI")
        #expect(PushRenewalRefused() == PushRenewalRefused())
    }

    /// An override outside 0.05–60 s is ignored: the model's own interval stays.
    @Test func overrideOutsideTheRangeIsIgnored() {
        let kal = PushKeepAlive(command: "KAL", interval: .seconds(60))
        #expect(PushKeepAlive.overrideRange == .milliseconds(50) ... .seconds(60))
        for ignored in [Duration.milliseconds(1), .milliseconds(49), .zero, .seconds(-1), .seconds(61), .seconds(184)] {
            #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150", overSerial: true, interval: ignored)?.interval
                    == .seconds(60), "\(ignored)")
            #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150", overSerial: true, interval: ignored) == kal)
        }
        for taken in [Duration.milliseconds(50), .seconds(60)] {
            #expect(PushKeepAlive.forSubscription(reportedModel: "SDS150", overSerial: true, interval: taken)?.interval
                    == taken, "\(taken)")
        }
    }

    /// How often a subscription asks for pushes (`PSI,<ms>`): 100 ms on the SDS150 (sustained on
    /// hardware, 2026-11-13), the SDS200, the SDS100 and the BCD436HP.
    @Test func pushIntervals() {
        for model in ScannerModel.allCases {
            #expect(ModelProfile.profile(for: model).pushInterval == .milliseconds(100), "\(model)")
        }
    }

    /// The shortest gap between two `STS` reads while the screen changes: 100 ms on the SDS150 and
    /// the SDS200 and the SDS100 and the BCD436HP (their push interval, so a scan's every step is read).
    @Test func displayRefreshIntervals() {
        for model in ScannerModel.allCases {
            #expect(ModelProfile.profile(for: model).displayRefreshInterval == .milliseconds(100), "\(model)")
        }
    }

    @Test func reportedNames() {
        #expect(ScannerModel(reported: "SDS150") == .sds150)
        #expect(ScannerModel(reported: "SDS150GBT") == .sds150)
    }
}
