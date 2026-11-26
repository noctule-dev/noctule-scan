// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum ScannerModel: String, Sendable, CaseIterable, Codable {
    case sds100 = "SDS100", sds150 = "SDS150", sds200 = "SDS200", bcd436hp = "BCD436HP"

    /// Maps a model string reported by `MDL` (trimmed, case-insensitive; "SDS150GBT" is an SDS150).
    public init?(reported: String) {
        let name = reported.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let exact = ScannerModel(rawValue: name) { self = exact }
        else if name.hasPrefix("SDS150") { self = .sds150 }
        else { return nil }
    }
}

public enum TransportKind: String, Sendable, Codable { case network, usbSerial, bluetooth }

/// Menu items whose action destroys data or settings, so the UI confirms before sending them.
public struct DestructiveMenuItems: Sendable, Equatable {
    public var names: Set<String>
    public var prefixes: [String]

    public init(names: Set<String>, prefixes: [String]) {
        self.names = names
        self.prefixes = prefixes
    }

    /// Trimmed, case-insensitive; an exact name or a name starting with a prefix.
    public func contains(_ itemName: String) -> Bool {
        let name = itemName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return names.contains { $0.lowercased() == name } || prefixes.contains { name.hasPrefix($0.lowercased()) }
    }

    /// The firmware's own item names; the SDS models share them for now.
    static let sds = DestructiveMenuItems(
        names: ["Clear User Data", "Reset User Settings", "Stop All Avoiding", "Set All Lists Off", "Set All Lists On"],
        prefixes: ["Delete"])
}

extension DestructiveMenuItems {
    /// The BCD436HP's menus (design §5.5): the SDS names, and the two it adds to them.
    static let bcd436hp = DestructiveMenuItems(
        names: DestructiveMenuItems.sds.names.union(["Clear All ID Avoids", "Reset to Factory"]),
        prefixes: ["Delete", "Initialize"])
}

/// How a model's screen is laid out (`STS`): the width of a text line, and whether the last line
/// holds soft-key labels.
public struct DisplayLayout: Sendable, Equatable {
    public var columns: Int
    public var hasSoftKeyLine: Bool

    public init(columns: Int, hasSoftKeyLine: Bool) {
        self.columns = columns
        self.hasSoftKeyLine = hasSoftKeyLine
    }

    /// The SDS models: 30 columns and a soft-key line.
    public static let sds = DisplayLayout(columns: 30, hasSoftKeyLine: true)
    /// The BCD436HP: 24 columns, no soft-key line (design §3.3, §5.3).
    public static let bcd436hp = DisplayLayout(columns: 24, hasSoftKeyLine: false)
}

/// How `MenuModel` enters, goes back and leaves a menu.
public enum MenuNavigation: Sendable, Equatable {
    /// Front-panel keys (`KEY,M,P` and the like): the SDS models.
    case keys
    /// The menu commands (`MNU`, `MSB`): the BCD436HP (design §5.2).
    case menuCommands
}

/// How a Hold is sent.
public enum HoldMethod: Sendable, Equatable {
    /// The soft key whose label reads Hold, pressed with `KEY`: the SDS models.
    case softKeyLabel
    /// The `HLD` command, naming what to hold: the BCD436HP (design §5.5).
    case holdCommand
}

/// What keeps a `PSI` subscription alive, and how often the client writes it while one runs
/// (`ScannerClient.startPush(interval:keepAlive:)`).
public struct PushKeepAlive: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// A command written with no arguments and no reply awaited (`KAL`).
        case command(String)
        /// The subscription's own `PSI,<ms>`, written again on the open port, its reply not
        /// awaited (a renewal; a rejected one is reported as `PushRenewalRefused`).
        case renewSubscription
    }

    /// What is written each interval.
    public var action: Action
    /// The time between keep-alives, the first one interval after the `PSI`.
    public var interval: Duration

    public init(action: Action, interval: Duration) {
        self.action = action
        self.interval = interval
    }

    /// `.command(command)`.
    public init(command: String, interval: Duration) {
        self.init(action: .command(command), interval: interval)
    }

    /// What an interval override may be: 0.05 s to 60 s. `forSubscription` ignores one outside it.
    /// Enough for every test, and no setting that floods the port with keep-alives or (past the
    /// SDS150's 183 s) turns the keep-alive off in effect. `NOCTULE_TEST_KEEPALIVE_SECONDS`
    /// (`KeepAliveOverride`) takes the same range.
    public static let overrideRange: ClosedRange<Duration> = .milliseconds(50) ... .seconds(60)

    /// The keep-alive a subscription passes (`startPush(interval:keepAlive:)`): the keep-alive of
    /// the model `MDL` reported (`ModelProfile.pushKeepAlive`), and only over a serial link, with
    /// `interval` in place of its own when given and inside `overrideRange` (one outside it is
    /// ignored, and the model's own interval stays). Nil for a network link (nothing on the network
    /// path sends one), a name that is no known model, and a model without one: an override can
    /// only change the interval of a keep-alive the model already has.
    public static func forSubscription(reportedModel: String, overSerial: Bool, interval: Duration? = nil) -> PushKeepAlive? {
        guard overSerial, let model = ScannerModel(reported: reportedModel),
              var keepAlive = ModelProfile.profile(for: model).pushKeepAlive else { return nil }
        if let interval, overrideRange.contains(interval) { keepAlive.interval = interval }
        return keepAlive
    }
}

/// What `onKeepAliveFailure` gets when the scanner rejects a renewal (`PushKeepAlive.Action.renewSubscription`).
public struct PushRenewalRefused: Error, Equatable, CustomStringConvertible {
    public init() {}
    public var description: String { "the scanner refused PSI" }
}

public struct ModelProfile: Sendable, Equatable {
    public let model: ScannerModel
    public let volumeRange: ClosedRange<Int>?
    public let squelchRange: ClosedRange<Int>?
    public let transports: Set<TransportKind>
    public let protocolVerifiedOnHardware: Bool
    public let destructiveMenuItems: DestructiveMenuItems
    /// RTSP audio over the network (SDS200 only).
    public let hasNetworkAudio: Bool
    /// `MSM,1` restarts the scanner (SDS200 only; never sent to any other model).
    public let supportsRemoteRestart: Bool
    /// `GCS` reports the battery and charger (SDS150 only).
    public let supportsChargeStatus: Bool
    /// The Favorites quick keys (`GLT`, `FQK`, `SQK`, `DQK`) read and set on the scanner: the three SDS
    /// models (hardware spike, 2026-11-18) and the BCD436HP (reads on hardware, design §3.4; sets from Uniden's spec).
    public let supportsQuickKeys: Bool
    /// USB product IDs (under Uniden's vendor ID) the model shows in serial mode.
    public let usbProductIDs: Set<Int>
    /// What keeps a `PSI` subscription pushing; nil: nothing is needed, and nothing is sent. The
    /// SDS150 stops pushing 183 s after the `PSI` (fw 1.01.02, seen on hardware): `KAL` ("Keep
    /// Alive", no reply, in Uniden's spec) every 60 s, three chances inside the 183 s. On hardware
    /// (2026-11-12) it kept the pushes going for 240 s (`SDS150HardwareTests/KeepAlive`, which saw
    /// nothing sent back for a `KAL`), 300 s (`watch`) and an hour (`log`); no other interval was
    /// tried. The SDS100 (fw 1.26.01) stops pushing about 182 to 186 s after the `PSI` too, but
    /// answers `KAL` `ERR` and does nothing for it: its keep-alive is the same `PSI,<ms>` written
    /// again every 60 s on the open port, which kept the pushes going for a 240 s hold (spec
    /// `2026-11-16-sds100-usb-design.md` §3.3; the owner's run of the app, §3.4, ran about five
    /// minutes). The BCD436HP's pushes stop 183 s after the `PSI` too, and the same renewal keeps
    /// them going (BCD436HP design §3.3).
    public let pushKeepAlive: PushKeepAlive?
    /// How often a subscription asks for pushes (`PSI,<ms>`). 100 ms on the SDS150: at 500 ms a
    /// scan that steps several channels a second showed only one in three or four. On hardware
    /// (fw 1.01.02, 2026-11-13) `PSI,100` gave a push every 116 ms (median; longest gap 138 ms)
    /// for 35 s. 100 ms on the SDS200 too (the owner's call, 2026-11-13, spec
    /// `2026-11-13-sds200-100ms-design.md`): an ad-hoc app run kept up with the radio; the long
    /// run is pending. 100 ms on the SDS100 (fw 1.26.01, 2026-11-16): `PSI,100` gave a push about every
    /// 137 ms (median; longest gap 161 ms) over a 186 s `watch`, and the owner's run of the app at
    /// 100 ms was good. 100 ms on the BCD436HP (a push about every 160 ms, design §3.3).
    public let pushInterval: Duration
    /// The shortest gap between two `STS` reads of the screen while a push shows it changing
    /// (outside a menu; `DisplayRefreshPolicy(model:)`). 100 ms on the SDS150, the SDS200 and the
    /// SDS100, their push interval, so the Scanner view reads each step of a fast scan (on the
    /// SDS100 the owner's five-minute run of the app at 100 ms showed no stall). 100 ms on the BCD436HP
    /// too (the designer's call, design §5.1; `STS` beside `PSI,100` is not yet run on it).
    /// On the SDS200 `STS` beside `PSI` and audio has run only in the ad-hoc app run above; the
    /// long run is pending (protocol notes §8 item 9).
    public let displayRefreshInterval: Duration
    /// Where a line-in's audio lies against the pushes (line-in design §5.2): the recorder places a
    /// line-in chunk at its capture time plus this. Zero for every model: on the owner's SDS150 rig
    /// (2026-11-17) each hit's audio lay inside the hit as the pushes timed it; the SDS100 is
    /// unmeasured until its hardware session.
    public let lineInAudioOffset: Duration
    /// The screen's layout (columns, and whether the last line holds soft-key labels).
    public let display: DisplayLayout
    /// How `MenuModel` enters, goes back and leaves a menu.
    public let menuNavigation: MenuNavigation
    /// How a Hold is sent.
    public let holdMethod: HoldMethod
    /// The front-panel keys the model has and the product may send (design §5.11); a key it lacks sends nothing.
    public let frontPanelKeys: Set<FrontPanelKey>
    /// The caption of the encoder's push on the Scanner view: Func on the SDS200, Vol on the handhelds.
    public let encoderPushCaption: String

    public static func profile(for model: ScannerModel) -> ModelProfile {
        switch model {
        case .sds200:
            ModelProfile(model: model, volumeRange: 0...29, squelchRange: 0...19,
                         transports: [.network, .usbSerial], protocolVerifiedOnHardware: true, destructiveMenuItems: .sds,
                         hasNetworkAudio: true, supportsRemoteRestart: true, supportsChargeStatus: false, supportsQuickKeys: true, usbProductIDs: [],
                         pushKeepAlive: nil, pushInterval: .milliseconds(100), displayRefreshInterval: .milliseconds(100),
                         lineInAudioOffset: .zero, display: .sds, menuNavigation: .keys, holdMethod: .softKeyLabel,
                         frontPanelKeys: Set(FrontPanelKey.allCases), encoderPushCaption: "Func")
        case .sds100:
            ModelProfile(model: model, volumeRange: 0...15, squelchRange: 0...15,
                         transports: [.usbSerial], protocolVerifiedOnHardware: false, destructiveMenuItems: .sds,
                         hasNetworkAudio: false, supportsRemoteRestart: false, supportsChargeStatus: false, supportsQuickKeys: true,
                         usbProductIDs: [0x001A],
                         pushKeepAlive: PushKeepAlive(action: .renewSubscription, interval: .seconds(60)),
                         pushInterval: .milliseconds(100), displayRefreshInterval: .milliseconds(100),
                         lineInAudioOffset: .zero, display: .sds, menuNavigation: .keys, holdMethod: .softKeyLabel,
                         frontPanelKeys: Set(FrontPanelKey.allCases).subtracting([.serviceType, .squelchPush]),
                         encoderPushCaption: "Vol")
        case .sds150:
            ModelProfile(model: model, volumeRange: 0...15, squelchRange: 0...15,
                         transports: [.usbSerial, .bluetooth], protocolVerifiedOnHardware: true, destructiveMenuItems: .sds,
                         hasNetworkAudio: false, supportsRemoteRestart: false, supportsChargeStatus: true, supportsQuickKeys: true,
                         usbProductIDs: [0x001A], pushKeepAlive: PushKeepAlive(command: "KAL", interval: .seconds(60)),
                         pushInterval: .milliseconds(100), displayRefreshInterval: .milliseconds(100),
                         lineInAudioOffset: .zero, display: .sds, menuNavigation: .keys, holdMethod: .softKeyLabel,
                         frontPanelKeys: Set(FrontPanelKey.allCases).subtracting([.serviceType, .squelchPush, .range]),
                         encoderPushCaption: "Vol")
        case .bcd436hp:
            ModelProfile(model: model, volumeRange: 0...15, squelchRange: 0...15,
                         transports: [.usbSerial], protocolVerifiedOnHardware: false, destructiveMenuItems: .bcd436hp,
                         hasNetworkAudio: false, supportsRemoteRestart: false, supportsChargeStatus: false, supportsQuickKeys: true,
                         usbProductIDs: [0x001A],
                         pushKeepAlive: PushKeepAlive(action: .renewSubscription, interval: .seconds(60)),
                         pushInterval: .milliseconds(100), displayRefreshInterval: .milliseconds(100),
                         lineInAudioOffset: .zero, display: .bcd436hp, menuNavigation: .menuCommands, holdMethod: .holdCommand,
                         frontPanelKeys: Set(FrontPanelKey.allCases).subtracting([.serviceType, .squelchPush]),
                         encoderPushCaption: "Vol")
        }
    }
}
