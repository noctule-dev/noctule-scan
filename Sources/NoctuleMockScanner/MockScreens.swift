// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Renders what the mock scanner reports for a moment of its scenario: `ScannerInfo` XML (GSI and
/// PSI) and the `STS` display. Shapes follow the real SDS200 captures in
/// `Sources/NoctuleKitTestSupport/Fixtures` (protocol notes §4 and §5), with fictional content;
/// a conventional channel follows the form both models used on hardware, and an idle moment
/// follows the SDS150's capture under that personality (`MockPersonality.IdleForm`).
enum MockScreens {
    static let unprogrammed = "4294967295"

    /// The channels an idle SDS150 steps through (`MockPersonality.IdleForm.conventionalScan`),
    /// one per scenario second, all in `County Roads` › `Road Crews`. Fictional.
    static let idleScanChannels: [(name: String, frequencyMHz: Double)] = [
        ("Plow Dispatch", 155.0125), ("Salt Shed", 155.7525), ("Road Crew 2", 156.0150),
    ]

    /// The `ScannerInfo` document, with an XML declaration, as the scanner sends it: its lines
    /// separated by `lineBreak` (`\n` over UDP, `\r` on serial), an idle moment of a trunk-mode
    /// scenario in `idleForm` at scenario time `seconds` (which picks the idle scan's channel).
    /// A conventional transmission (no talkgroup) takes the form both models used on hardware
    /// (the SDS150 fw 1.01.02, `sds150-gsi-serial.txt`; the SDS200, 2026-11-13): `Freq`, `Mod`
    /// and `SAD` on `ConvFrequency`, no `Site` or `SiteFrequency`, under
    /// `Mode="Scan Mode" V_Screen="conventional_scan"`.
    static func scannerInfoXML(_ moment: MockMoment, scenario: MockScenario, volume: Int, squelch: Int,
                               lineBreak: String = "\n",
                               idleForm: MockPersonality.IdleForm = .trunkSite, seconds: Double = 0,
                               decimalRssi: Bool = false, functionOn: Bool = false) -> String {
        let func_ = functionOn ? "On" : "Off"
        var lines = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>"]
        let idleScan: Bool
        if scenario.mode == .trunk, idleForm == .conventionalScan, case .idle = moment { idleScan = true } else { idleScan = false }
        switch scenario.mode {
        case .trunk:
            if idleScan {
                lines.append("<ScannerInfo Mode=\"Scan Mode\" V_Screen=\"conventional_scan\">")
            } else if case .transmission(_, let t) = moment, t.tgid == nil {
                lines.append("<ScannerInfo Mode=\"Scan Mode\" V_Screen=\"conventional_scan\">")
            } else {
                lines.append("<ScannerInfo Mode=\"Trunk Scan\" V_Screen=\"trunk_scan\">")
            }
            lines.append("<MonitorList Name=\"Mock Favorites\" Index=\"1\" ListType=\"FL\" Q_Key=\"0\" N_Tag=\"None\" DB_Counter=\"0\"/>")
            switch moment {
            case .idle where idleScan:
                // The SDS150's idle (fw 1.01.02, `sds150-gsi-serial.txt`): a conventional channel
                // named with its frequency, nothing on the air.
                let step = Int(max(0, seconds)) % idleScanChannels.count
                let channel = idleScanChannels[step]
                lines.append(system("County Roads", type: "Conventional"))
                lines.append("<Department Name=\"Road Crews\" Index=\"118\" Avoid=\"Off\" Q_Key=\"0\" Hold=\"Off\"/>")
                lines.append(convFrequency(channel.name, index: String(120 + step), mhz: channel.frequencyMHz,
                                           modulation: "NFM", code: nil))
            case .idle(let idle):
                lines.append(system(idle.system))
                lines.append(site(idle.site, modulation: idle.modulation))
                lines.append(siteFrequency(idle.frequencyMHz, code: nil))
            case .transmission(let index, let t):
                let department = t.programmed ? String(200 + index) : unprogrammed
                let channel = t.programmed ? String(1000 + index) : unprogrammed
                lines.append(system(t.system, type: t.tgid == nil ? "Conventional" : "P25 Trunk"))
                lines.append("<Department Name=\"\(escape(t.department))\" Index=\"\(department)\" Avoid=\"Off\" Q_Key=\"0\" Hold=\"Off\"/>")
                if let tgid = t.tgid {
                    lines.append("<TGID Name=\"\(escape(t.channel))\" Index=\"\(channel)\" Avoid=\"Off\" TGID=\"TGID:\(escape(tgid))\" "
                        + "SetSlot=\"Slot Any\" RecSlot=\"Slot None\" N_Tag=\"None\" Hold=\"Off\" P_Ch=\"Off\" LVL=\"0\"/>")
                } else {
                    // Frequency, modulation and tone on ConvFrequency, no Site or SiteFrequency.
                    lines.append(convFrequency(t.channel, index: channel, mhz: t.frequencyMHz, modulation: t.modulation,
                                               code: t.toneOrCode))
                }
                if let unit = t.unitID {
                    lines.append("<UnitID Name=\"UID:\(escape(unit))\" U_Id=\"UID:\(escape(unit))\"/>")
                }
                if t.tgid != nil {
                    lines.append(site(scenario.idle.site, modulation: t.modulation))
                    lines.append(siteFrequency(t.frequencyMHz, code: t.toneOrCode))
                }
            }
        case .weather:
            // fw 1.26.01 in WX Scan: `<WxChannel ... Freq=" 162.425000MHz" Mod="FM" .../>`. Only Freq
            // and Mod are confirmed on hardware; Name, Index, and V_Screen are assumptions.
            lines.append("<ScannerInfo Mode=\"WX Scan\" V_Screen=\"wx_scan\">")
            switch moment {
            case .idle(let idle):
                lines.append("<WxChannel Name=\"\" Index=\"\(unprogrammed)\" Freq=\"\(frequency(idle.frequencyMHz))\" Mod=\"\(escape(idle.modulation))\" Avoid=\"Off\"/>")
            case .transmission(let index, let t):
                let channel = t.programmed ? String(1000 + index) : unprogrammed
                lines.append("<WxChannel Name=\"\(escape(t.channel))\" Index=\"\(channel)\" Freq=\"\(frequency(t.frequencyMHz))\" Mod=\"\(escape(t.modulation))\" Avoid=\"Off\"/>")
            }
        }
        lines.append("<DualWatch PRI=\"Off\" CC=\"Off\" WX=\"Off\"/>")
        let rssi: Int, bars: Int
        switch moment {
        case .idle(let idle): rssi = idle.rssi; bars = 0
        case .transmission(_, let t): rssi = t.rssi; bars = signalBars(rssi: t.rssi)
        }
        // The BCD436HP's `Rssi` is a decimal, a fictional 0.1624 a signal bar (design §3.4, §5.7).
        let rssiText = decimalRssi ? String(format: "%.3f", Double(bars) * 0.1624) : String(rssi)
        if idleScan {
            lines.append("<Property F=\"\(func_)\" VOL=\"\(volume)\" SQL=\"\(squelch)\" Sig=\"0\" Att=\"Off\" Rec=\"Off\" KeyLock=\"Off\" "
                + "P25Status=\"None\" Mute=\"Mute\" Backlight=\"100\" A_Led=\"Off\" Dir=\"Up\" Rssi=\"-999\"/>")
            lines += ["<ViewDescription>", "<OverWrite Text=\"Scanning...\" />", "</ViewDescription>"]
        } else {
            lines.append("<Property F=\"\(func_)\" VOL=\"\(volume)\" SQL=\"\(squelch)\" Sig=\"\(bars)\" Att=\"Off\" Rec=\"Off\" KeyLock=\"Off\" "
                + "P25Status=\"\(scenario.mode == .trunk ? "PT1" : "None")\" Mute=\"Unmute\" Backlight=\"100\" A_Led=\"Off\" Dir=\"Up\" Rssi=\"\(rssiText)\"/>")
            lines.append("<ViewDescription></ViewDescription>")
        }
        lines.append("</ScannerInfo>")
        return lines.joined(separator: lineBreak)
    }

    /// The full `STS` reply line (without the trailing `\r`): 17 display lines with masks, then
    /// the trailing scalars, in the real capture's shape. `glyphBytes` (the personality's
    /// `displayGlyphBytes`) replace the first characters of the first line while the scanner is idle,
    /// as raw bytes: they aren't text, so the reply is bytes, not a `String`.
    static func display(_ moment: MockMoment, scenario: MockScenario, volume: Int, squelch: Int, seconds: Double,
                        glyphBytes: [UInt8] = []) -> Data {
        let flags = "00001010100000000"
        let total = Int(max(0, seconds))
        let clock = String(format: "Mock  t+%02d:%02d", total / 60 % 60, total % 60)
        var text = Array(repeating: "", count: 17)
        text[0] = "              " + clock
        text[2] = String(format: "S0:-12345*---   VOL:%2d SQL:%2d", volume, squelch)
        text[3] = "D0:----4-----   Tag:--.--.---"
        switch (scenario.mode, moment) {
        case (.trunk, .idle(let idle)):
            text[1] = "F0:************ P25"
            text[4] = idle.system
            text[8] = "ID Searching..."
            text[7] = idle.site
            text[11] = "Sys ID: 2A1h  " + frequency(idle.frequencyMHz)
            text[14] = "UID: ---        RSSI: ---"
        case (.trunk, .transmission(_, let t)):
            text[1] = "F0:***3******** P25"
            text[4] = t.system
            text[5] = t.department
            text[6] = t.channel
            text[7] = scenario.idle.site
            text[8] = t.tgid.map { "TGID:\($0)" } ?? ""
            text[11] = "Sys ID: 2A1h  " + frequency(t.frequencyMHz)
            text[12] = "RFSS ID: 1      Site ID: 3"
            text[13] = "WACN: ---       NOISE: ---"
            text[14] = "UID: \((t.unitID ?? "---").padding(toLength: 11, withPad: " ", startingAt: 0))RSSI:\(t.rssi)dBm"
        case (.weather, .idle(let idle)):
            text[4] = "WX Scan"
            text[6] = "Searching..."
            text[11] = frequency(idle.frequencyMHz) + " " + idle.modulation
        case (.weather, .transmission(_, let t)):
            text[4] = "WX Scan"
            text[6] = t.channel
            text[11] = frequency(t.frequencyMHz) + " " + t.modulation
            text[14] = "RSSI:\(t.rssi)dBm"
        }
        text[16] = " SYSTEM      DEPT     CHANNEL "
        var fields = [flags]
        for (index, line) in text.enumerated() {
            let padded = pad(line)
            fields.append(padded)
            fields.append(index == 16 ? "********* ********** *********" : String(repeating: " ", count: 30))
        }
        fields += ["1", "1", "0", "0", "", "", "1", "OFF", "3"]
        var reply = Data("STS,".utf8)
        for (index, field) in fields.enumerated() {
            if index > 0 { reply.append(UInt8(ascii: ",")) }
            if index == 1, case .idle = moment {
                // Columns 0..<glyphBytes.count of the first line: one byte per column, as padded (ASCII) text.
                reply.append(contentsOf: glyphBytes)
                reply.append(contentsOf: Array(field.utf8.dropFirst(glyphBytes.count)))
            } else {
                reply.append(contentsOf: field.utf8)
            }
        }
        return reply
    }

    /// The BCD436HP's scan screen (design §3.6, §5.7): 14 lines of 24 columns and no soft-key line,
    /// form `00110110110000`, `_` masks on lines 2, 5, 8 and 12, fictional text from the scenario.
    /// During a transmission the personality's glyph bytes (cycled) fill the first two columns of
    /// line 1 and the first four of line 5, as raw bytes; idle, none. The trailing fields read
    /// `1,1,0,0,,,0,OFF,0` idle and `1,0,0,0,,,<signal bars>,OFF,0` on a call.
    static func bcdDisplay(_ moment: MockMoment, scenario: MockScenario, seconds: Double, glyphBytes: [UInt8]) -> Data {
        var text = Array(repeating: "", count: 14)
        let bars: Int
        switch moment {
        case .idle(let idle):
            text[0] = idle.system
            text[2] = idle.site
            text[3] = "ID Searching..."
            text[7] = frequency(idle.frequencyMHz) + " " + idle.modulation
            bars = 0
        case .transmission(_, let t):
            text[0] = t.system
            text[1] = t.department
            text[2] = t.channel
            text[3] = t.tgid.map { "TGID:\($0)" } ?? ""
            text[4] = "Sig:\(signalBars(rssi: t.rssi))"
            text[7] = frequency(t.frequencyMHz) + " " + t.modulation
            text[9] = "UID: \(t.unitID ?? "---")"
            bars = signalBars(rssi: t.rssi)
        }
        let total = Int(max(0, seconds))
        text[13] = String(format: "Mock  t+%02d:%02d", total / 60 % 60, total % 60)
        var onCall = false
        if case .transmission = moment { onCall = true }
        let glyphCounts = [0: 2, 4: 4]
        let masks = [1, 4, 7, 11]
        var reply = Data("STS,00110110110000".utf8)
        for (index, line) in text.enumerated() {
            reply.append(UInt8(ascii: ","))
            let columns = pad(line, columns: 24)
            var count = 0
            if onCall, !glyphBytes.isEmpty, let wanted = glyphCounts[index] { count = wanted }
            for column in 0..<count { reply.append(glyphBytes[column % glyphBytes.count]) }
            reply.append(contentsOf: columns.utf8.dropFirst(count))
            reply.append(UInt8(ascii: ","))
            if masks.contains(index) { reply.append(contentsOf: String(repeating: "_", count: 24).utf8) }
        }
        reply.append(contentsOf: (onCall ? ",1,0,0,0,,,\(bars),OFF,0" : ",1,1,0,0,,,0,OFF,0").utf8)
        return reply
    }

    /// The hold levels of the BCD436HP's `HLD` command and the `GSI` element each one marks.
    static let holdLevels: [(level: String, tag: String)] = [
        ("SYS", "System"), ("DEPT", "Department"), ("TGID", "TGID"), ("CFREQ", "ConvFrequency"),
    ]

    /// The `Index` of the first `tag` element of a `ScannerInfo` document, if the moment shows one.
    static func shownIndex(_ xml: String, tag: String, lineBreak: String) -> String? {
        for line in xml.components(separatedBy: lineBreak) where line.hasPrefix("<\(tag) ") {
            guard let start = line.range(of: " Index=\"") else { continue }
            let rest = line[start.upperBound...]
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        return nil
    }

    /// Whether the document shows a `tag` element whose `Index` is `index`.
    static func shows(_ xml: String, tag: String, index: String, lineBreak: String) -> Bool {
        xml.components(separatedBy: lineBreak).contains {
            $0.hasPrefix("<\(tag) ") && $0.contains(" Index=\"\(index)\"")
        }
    }

    /// Marks the held elements `Hold="On"` (`holds` holds `"<LEVEL>:<index>"`), and ends `Mode` in
    /// ` Hold` while a channel (a `TGID` or `ConvFrequency`) is held; a System or Department hold
    /// leaves `Mode` alone (design §3.5a).
    static func applyHolds(_ xml: String, holds: Set<String>, lineBreak: String) -> String {
        guard !holds.isEmpty else { return xml }
        var channelHeld = false
        var lines = xml.components(separatedBy: lineBreak)
        for (n, line) in lines.enumerated() {
            for (level, tag) in holdLevels where line.hasPrefix("<\(tag) ") {
                guard let start = line.range(of: " Index=\""),
                      let end = line[start.upperBound...].firstIndex(of: "\"") else { continue }
                let index = String(line[start.upperBound..<end])
                if holds.contains("\(level):\(index)") {
                    lines[n] = line.replacingOccurrences(of: "Hold=\"Off\"", with: "Hold=\"On\"")
                    if level == "TGID" || level == "CFREQ" { channelHeld = true }
                }
            }
        }
        if channelHeld, let n = lines.firstIndex(where: { $0.hasPrefix("<ScannerInfo ") }),
           let mode = lines[n].range(of: "Mode=\""), let end = lines[n][mode.upperBound...].firstIndex(of: "\"") {
            lines[n].insert(contentsOf: " Hold", at: end)
        }
        return lines.joined(separator: lineBreak)
    }

    /// Signal bars (0-5) from RSSI, roughly as the scanner shows them.
    static func signalBars(rssi: Int) -> Int {
        if rssi >= -65 { return 5 }
        if rssi >= -75 { return 4 }
        if rssi >= -85 { return 3 }
        if rssi >= -95 { return 2 }
        return 1
    }

    /// `" 851.237500MHz"`: the scanner's frequency format, right-aligned in 11 characters.
    static func frequency(_ mhz: Double) -> String { String(format: "%11.6fMHz", mhz) }

    /// `type` is "P25 Trunk" except for a transmission with no talkgroup, which is a conventional
    /// channel ("Conventional"; the attribute value on hardware is not yet captured).
    private static func system(_ name: String, type: String = "P25 Trunk") -> String {
        "<System Name=\"\(escape(name))\" Index=\"101\" Avoid=\"Off\" SystemType=\"\(type)\" Q_Key=\"0\" N_Tag=\"None\" Hold=\"Off\"/>"
    }

    private static func site(_ name: String, modulation: String) -> String {
        "<Site Name=\"\(escape(name))\" Index=\"301\" Avoid=\"Off\" Q_Key=\"None\" Hold=\"Off\" Mod=\"\(escape(modulation))\"/>"
    }

    /// A conventional channel as both models send it (`sds150-gsi-serial.txt`): frequency (`%12.6fMHz`),
    /// modulation and tone (`None` without one) on `ConvFrequency`, with its ID placeholders.
    private static func convFrequency(_ name: String, index: String, mhz: Double, modulation: String, code: String?) -> String {
        "<ConvFrequency Name=\"\(escape(name))\" Index=\"\(index)\" Avoid=\"Off\" "
            + "Freq=\"\(String(format: "%12.6fMHz", mhz))\" Mod=\"\(escape(modulation))\" N_Tag=\"None\" "
            + "Hold=\"Off\" P_Ch=\"Off\" SAS=\"All\" SAD=\"\(escape(code ?? "None"))\" RecSlot=\"Slot None\" "
            + "LVL=\"0\" IFX=\"Off\" TGID=\"TGID None\" U_Id=\"UID None\"/>"
    }

    private static func siteFrequency(_ mhz: Double, code: String?) -> String {
        "<SiteFrequency Freq=\"\(frequency(mhz))\" IFX=\"Off\" SAS=\"NAC Search\" SAD=\"\(escape(code ?? ""))\"/>"
    }

    /// 30 columns, no commas (the STS field separator).
    private static func pad(_ text: String, columns: Int = 30) -> String {
        let clean = text.replacingOccurrences(of: ",", with: " ")
        return String(clean.prefix(columns)).padding(toLength: columns, withPad: " ", startingAt: 0)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
