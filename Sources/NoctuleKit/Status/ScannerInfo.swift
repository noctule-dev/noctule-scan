// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum ScannerInfoError: Error, Equatable {
    case unexpectedRoot(String)
}

/// A named element from `ScannerInfo` (system, department, channel, site, ...).
public struct NamedItem: Sendable, Equatable {
    public var name: String
    public var index: UInt32?
    public var avoid: Bool?
    public var hold: Bool?
    public var attributes: [String: String]

    /// False when the scanner reports the unprogrammed sentinel index; a missing index counts as programmed.
    public var isProgrammed: Bool { index != ScannerInfo.unprogrammedIndex }

    public init(
        name: String, index: UInt32? = nil, avoid: Bool? = nil, hold: Bool? = nil,
        attributes: [String: String] = [:]
    ) {
        self.name = name
        self.index = index
        self.avoid = avoid
        self.hold = hold
        self.attributes = attributes
    }

    init?(_ node: XMLNode?) {
        guard let node else { return nil }
        let a = node.attributes
        self.init(
            name: a["Name"] ?? "",
            index: a["Index"].flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) },
            avoid: onOff(a["Avoid"]), hold: onOff(a["Hold"]), attributes: a)
    }
}

private func onOff(_ value: String?) -> Bool? {
    switch value?.trimmingCharacters(in: .whitespaces) {
    case "On": true
    case "Off": false
    default: nil
    }
}

private func int(_ value: String?) -> Int? {
    value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
}

/// What the scanner reports in place of an ID, once the `TGID:`/`UID:` prefix is stripped and the
/// value trimmed: the SDS200's idle `---` (`" ---"`, `"TGID: ---"`, `"UID: ---"`) and the SDS150's
/// `None` forms (`TGID="TGID None"`, `U_Id="UID None"`, seen on hardware as `ConvFrequency`
/// attributes of a conventional channel, fw 1.01.02). That the SDS150 writes the same `None`
/// spellings in a trunk document's `TGID` and `UnitID` elements is an assumption until a trunk
/// capture from it.
private let identifierPlaceholders: Set<String> = ["", "---", "None", "TGID None", "UID None"]

/// Placeholders the scanner reports in place of IDs (`identifierPlaceholders`) become nil.
private func identifier(_ prefix: String, from value: String?) -> String? {
    guard let stripped = stripping(prefix, from: value) else { return nil }
    return identifierPlaceholders.contains(stripped.trimmingCharacters(in: .whitespaces)) ? nil : stripped
}

/// A tone or code; `None` (any case, trimmed), the SDS150's `SAD` for a channel with no tone
/// (`sds150-gsi-serial.txt`), is nil.
private func toneOrCodeValue(_ value: String?) -> String? {
    guard let value else { return nil }
    return value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("None") == .orderedSame ? nil : value
}

private func megahertz(_ value: String?) -> Double? {
    value.flatMap {
        var t = $0.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("MHz") { t.removeLast(3) }
        return Double(t.trimmingCharacters(in: .whitespaces))
    }
}

private func stripping(_ prefix: String, from value: String?) -> String? {
    guard let value else { return nil }
    return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
}

public enum MenuScreenKind: Sendable, Equatable { case selection, input }

/// Typed view of the `ScannerInfo` XML returned by `GSI` and pushed by `PSI`.
public struct ScannerInfo: Sendable, Equatable {
    public static let unprogrammedIndex: UInt32 = 4_294_967_295

    public var mode: String?
    public var screen: String?
    public var monitorList: NamedItem?
    public var system: NamedItem?
    public var systemType: String?
    public var department: NamedItem?
    public var channel: NamedItem?
    public var talkgroupID: String?
    public var unitID: String?
    public var site: NamedItem?
    public var modulation: String?
    public var frequencyMHz: Double?
    public var toneOrCode: String?
    public var rssi: Int?
    public var signalBars: Int?
    public var volume: Int?
    public var squelch: Int?
    public var attenuatorOn: Bool?
    public var recordingOn: Bool?
    public var p25Status: String?
    public var muted: Bool?
    /// `MenuSummary/@name`, untrimmed. Present only in a menu.
    public var menuTitle: String?
    /// `MenuSummary/@index`, opaque.
    public var menuIndex: String?
    /// From `V_Screen`: `menu_selection` is a list, `menu_input` an entry screen.
    public var menuScreenKind: MenuScreenKind?
    public var raw: XMLNode

    /// True when the scanner is in a menu: `Mode` or `V_Screen` contains "menu" (any case).
    public var isMenu: Bool {
        [mode, screen].contains { $0?.localizedCaseInsensitiveContains("menu") == true }
    }
    /// True when the scanner is in a weather mode (`Mode` contains "WX").
    public var isWeather: Bool { mode?.contains("WX") ?? false }
    /// True for a trunked system: `SystemType` contains "Trunk" (any case), or the document has a `TGID` element.
    public var isTrunk: Bool {
        (systemType?.range(of: "trunk", options: .caseInsensitive) != nil) || raw.child("TGID") != nil
    }
    /// True when a channel is present and carries what identifies it: a talkgroup on a trunked
    /// system (`isTrunk`), otherwise a talkgroup or a frequency. False for idle placeholders,
    /// including a trunk scanner parked on a control channel, which reports a `SiteFrequency`
    /// and a signal but no talkgroup. **Not the same as receiving:** an SDS150 stepping through
    /// its conventional channels names each one with its frequency while `Sig` is 0, so this is
    /// true while it only scans (`sds150-gsi-serial.txt`). Whether a transmission is on air is
    /// `isReceiving`.
    public var hasActiveChannel: Bool {
        channel != nil && (isTrunk ? talkgroupID != nil : (talkgroupID != nil || frequencyMHz != nil))
    }

    /// A transmission is on air: `hasActiveChannel` and `Sig` above 0. What hit detection and the
    /// headline go by.
    public var isReceiving: Bool { hasActiveChannel && (signalBars ?? 0) > 0 }

    public init(xml root: XMLNode) throws {
        guard root.name == "ScannerInfo" else { throw ScannerInfoError.unexpectedRoot(root.name) }
        raw = root
        mode = root.attributes["Mode"]
        screen = root.attributes["V_Screen"]
        monitorList = NamedItem(root.child("MonitorList"))
        let systemNode = root.child("System")
        system = NamedItem(systemNode)
        systemType = systemNode?.attributes["SystemType"]
        // An empty Name is the idle placeholder, not a department.
        department = NamedItem(root.child("Department")).flatMap { $0.name.isEmpty ? nil : $0 }
        let tgid = root.child("TGID")
        let wx = root.child("WxChannel")
        let conv = root.child("ConvFrequency")
        channel = NamedItem(tgid ?? conv)
        if channel == nil, let wx {
            // fw 1.26.01 weather: no Name, only `CH_No`; synthesize "WX <n>".
            var item = NamedItem(wx) ?? NamedItem(name: "")
            item.name = "WX " + (wx.attributes["CH_No"] ?? "").trimmingCharacters(in: .whitespaces)
            channel = item
        }
        talkgroupID = identifier("TGID:", from: tgid?.attributes["TGID"])
        unitID = identifier("UID:", from: root.child("UnitID")?.attributes["U_Id"])
        let siteNode = root.child("Site")
        site = NamedItem(siteNode)
        // The SDS150 puts a conventional channel's `Freq`, `Mod` and `SAD` on `ConvFrequency` itself,
        // with no `Site` or `SiteFrequency` (fw 1.01.02); each is used only when the SDS200's
        // element doesn't carry that attribute.
        modulation = siteNode?.attributes["Mod"] ?? wx?.attributes["Mod"] ?? conv?.attributes["Mod"]
        let freq = root.child("SiteFrequency")
        frequencyMHz = megahertz(freq?.attributes["Freq"] ?? wx?.attributes["Freq"] ?? conv?.attributes["Freq"])
        toneOrCode = toneOrCodeValue(freq?.attributes["SAD"] ?? conv?.attributes["SAD"])
        let p = root.child("Property")?.attributes
        rssi = int(p?["Rssi"]).flatMap { $0 == -999 ? nil : $0 }  // -999 is the idle placeholder
        signalBars = int(p?["Sig"])
        volume = int(p?["VOL"])
        squelch = int(p?["SQL"])
        attenuatorOn = onOff(p?["Att"])
        recordingOn = onOff(p?["Rec"])
        p25Status = p?["P25Status"]
        muted = p?["Mute"].map { $0 == "Mute" }
        let summary = root.child("MenuSummary")?.attributes
        menuTitle = summary?["name"]
        menuIndex = summary?["index"]
        menuScreenKind = switch screen {
        case "menu_selection": .selection
        case "menu_input": .input
        default: nil
        }
    }
}
