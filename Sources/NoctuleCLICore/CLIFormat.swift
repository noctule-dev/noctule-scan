// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleDevConfig
import NoctuleStore

public enum CLIFormat {
    /// The four lines, then `battery: 100% (full)` when the scanner reported a charge status (`GCS`);
    /// a `CST` code outside Uniden's 0...6 shows as `battery: 100% (unknown, CST=9)`.
    public static func info(model: String, firmware: String, volume: Int, squelch: Int, battery: ChargeStatus? = nil) -> [String] {
        var lines = ["model: \(model)", "firmware: \(firmware)", "volume: \(volume)", "squelch: \(squelch)"]
        if let battery { lines.append("battery: \(battery.percent)% (\(chargeWord(battery)))") }
        return lines
    }

    private static func chargeWord(_ battery: ChargeStatus) -> String {
        switch battery.state {
        case .full: "full"
        case .charging: "charging"
        case .notCharging: "not charging"
        case .recharge: "recharging"
        case .initializing: "initializing"
        case .temperatureFault: "temperature fault"
        case .powerFault: "power fault"
        case nil: "unknown, CST=\(battery.stateCode)"
        }
    }

    /// One line per Uniden serial port: `<path>  <product name or "Uniden device">  <model or "unknown model">`.
    /// With none, the serial-mode hint.
    public static func ports(_ ports: [SerialPortInfo]) -> [String] {
        guard !ports.isEmpty else { return ["No Uniden scanner found. " + SerialPort.noneFoundHint] }
        return ports.map { "\($0.path)  \($0.productName ?? "Uniden device")  \($0.knownModel?.rawValue ?? "unknown model")" }
    }

    /// One audio input, as `audio-inputs` lists it: `<UID>  <name>  <n> ch`.
    public static func audioInputLine(_ device: AudioInputDevice) -> String {
        "\(device.uid)  \(device.name)  \(device.channelCount) ch"
    }

    /// What `audio-inputs` prints when no input is listed (none at all, or the kill-switch is set).
    public static let noAudioInputsLine = "No audio inputs found."

    /// What `--serial` prints when it found no port to open (exit 2): the none-found hint, or the
    /// ports found and how to choose one. Nil when a port was found.
    public static func serialResolutionFailure(_ resolution: SerialPortResolution) -> [String]? {
        switch resolution {
        case .found: nil
        case .noneFound: ports([])
        case .severalFound(let found): ports(found) + ["Pass --serial PATH to choose one."]
        }
    }

    /// The line and exit status for a serial port that couldn't be opened: busy (another program
    /// has it) exits 1, a missing port 2. Nil for any other error, which is reported as usual.
    public static func serialOpenFailure(_ error: any Error) -> (line: String, exitCode: Int32)? {
        #if os(macOS)
        switch error {
        case SerialTransportError.busy(let path): return ("\(path) is in use by another program.", 1)
        case SerialTransportError.noSuchPort(let path): return ("\(path): no such port", 2)
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// `info`'s warning when `GCS` got no usable answer (the other lines still print).
    public static func noBatteryLine(_ error: any Error) -> String {
        let reason: String
        switch error {
        case ScannerClientError.timeout(let command): reason = "no answer to \(command)"
        case ScannerClientError.unexpectedResponse(let command): reason = "unreadable answer to \(command)"
        case ScannerClientError.rejected(_, let response): reason = "the scanner answered \(response)"
        default: reason = "\(error)"
        }
        return "warning: no battery status (\(reason))"
    }

    /// The status fields, one `label: value` line each, ending with `signal:` (`Property/@Sig`,
    /// which hit detection reads) and `muted:` (`Property/@Mute`, shown for comparison; nothing
    /// else reads it).
    public static func status(_ info: ScannerInfo) -> [String] {
        [
            "system: \(show(info.system?.name))",
            "department: \(show(info.department?.name))",
            "channel: \(show(info.channel?.name))",
            "tgid: \(show(info.talkgroupID))",
            "uid: \(show(info.unitID))",
            "site: \(show(info.site?.name))",
            "frequency: \(info.frequencyMHz.map { "\(frequency($0)) MHz" } ?? "-")",
            "modulation: \(show(info.modulation))",
            "tone/code: \(show(info.toneOrCode))",
            "rssi: \(info.rssi.map(String.init) ?? "-")",
            "signal: \(info.signalBars.map(String.init) ?? "-")",
            "muted: \(info.muted.map { $0 ? "yes" : "no" } ?? "-")",
        ]
    }

    /// Trimmed text, or "-" when missing or blank.
    private static func show(_ text: String?) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "-" : trimmed
    }

    /// Non-blank display lines (trailing spaces trimmed), then the soft-key labels.
    public static func display(_ status: DisplayStatus) -> [String] {
        var out = status.lines.dropLast()
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        out.append("soft keys: " + status.softKeyLabels.joined(separator: " | "))
        return out
    }

    /// The Favorites tree, one line per list, system, department and site, indented 0, 2 and 4 spaces:
    /// `<tag padded to 4>  <state padded to 3>  <name><suffixes>`. The tag is `F<k>`, `S<k>` or `D<k>`
    /// for a quick key, else `-`; the state `on`, `off`, `?` (a key the scanner reports as 0) or `-`
    /// (no key, or a parent without one). Lists by quick key, those without one last in `GLT` order.
    public static func quickKeys(_ tree: QuickKeyTree) -> [String] {
        func line(_ level: Int, _ prefix: String, _ key: Int?, _ state: QuickKeyState?, _ name: String,
                  _ suffixes: [String]) -> String {
            let tag = key.map { "\(prefix)\($0)" } ?? "-"
            let word: String
            switch (key, state) {
            case (.some, .some(.on)): word = "on"
            case (.some, .some(.off)): word = "off"
            case (.some, .some(.none)): word = "?"
            default: word = "-"
            }
            let text = String(repeating: " ", count: 2 * level) + pad(tag, 4) + "  " + pad(word, 3) + "  " + name
                + suffixes.map { " (\($0))" }.joined()
            return String(text.reversed().drop { $0 == " " }.reversed())
        }
        let keyed = tree.nodes.filter { $0.list.quickKey != nil }.sorted { $0.list.quickKey! < $1.list.quickKey! }
        var out: [String] = []
        for node in keyed + tree.nodes.filter({ $0.list.quickKey == nil }) {
            let listKey = node.list.quickKey
            out.append(line(0, "F", listKey, listKey.map { tree.lists[$0] }, node.list.name,
                            node.list.monitored ? [] : ["not monitored"]))
            for entry in node.systems {
                let system = entry.system
                let systemKey = system.quickKey
                let systemState = listKey.flatMap { key in systemKey.flatMap { tree.systems[key]?[$0] } }
                out.append(line(1, "S", systemKey, systemState, system.name,
                                (system.isConventional ? [] : [system.type]) + (system.avoided ? ["avoided"] : [])))
                let childStates = listKey.flatMap { list in
                    systemKey.flatMap { tree.children[QuickKeyPair(list: list, system: $0)] }
                }
                for child in entry.children {
                    out.append(line(2, "D", child.quickKey, child.quickKey.flatMap { childStates?[$0] }, child.name,
                                    (child.kind == .site ? ["site"] : []) + (child.avoided ? ["avoided"] : [])))
                }
            }
        }
        return out
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    /// The `MSI` screen as the scanner sent it: title, menu index and type, then for a list the
    /// highlighted index and every item with its own index (one the scanner left out shows as a
    /// gap) and its value; for an entry its value and rules; for an error its message.
    public static func menu(_ screen: MenuScreen) -> [String] {
        var out = ["title: \(show(screen.title))", "menu index: \(show(screen.menuIndex))"]
        switch screen.kind {
        case .select: out.append("type: select")
        case .input: out.append("type: input")
        case .location: out.append("type: location")
        case .error: out.append("type: error (no menu screen the protocol describes)")
        case .other(let name): out.append("type: \(name.isEmpty ? "-" : name)")
        }
        switch screen.kind {
        case .select:
            out.append("selected: \(screen.selectedIndex.map(String.init) ?? "-")")
            out.append("items: \(screen.items.count)")
            out += screen.items.map { item in
                "item \(item.index): \(item.name)" + (item.value.map { " = \($0)" } ?? "")
            }
        case .input:
            out.append("value: \(show(screen.value))")
            if let rules = screen.input {
                out.append("max length: \(rules.maxLength.map(String.init) ?? "-")")
                out.append("keys: \(show(rules.allowedCharacters))")
                if let info = rules.addedInformation { out.append("added information: \(show(info))") }
            }
        default:
            out += screen.items.map { "item \($0.index): \($0.name)" + ($0.value.map { " = \($0)" } ?? "") }
        }
        if let error = screen.errorText { out.append("error: \(error)") }
        return out
    }

    public static func watchLine(_ info: ScannerInfo, at date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(time)  \(show(info.system?.name)) / \(show(info.channel?.name))"
            + "  TG \(show(info.talkgroupID))  UID \(show(info.unitID))"
            + "  \(info.frequencyMHz.map(frequency) ?? "-") MHz  RSSI \(info.rssi.map(String.init) ?? "-")"
    }

    /// Up to four decimals, trailing zeros dropped (935.4375, 851.0).
    private static func frequency(_ mhz: Double) -> String {
        var s = String(format: "%.4f", mhz)
        while s.hasSuffix("0"), !s.hasSuffix(".0") { s.removeLast() }
        return s
    }
}

public func resolveHost(invocation: CLIInvocation, searchingFrom start: URL) -> (host: String, port: UInt16)? {
    if let host = invocation.host { return (host, invocation.port ?? 50536) }
    guard let url = DevScannerConfig.defaultURL(searchingUpFrom: start),
          let config = try? DevScannerConfig.load(from: url) else { return nil }
    return (config.host, invocation.port ?? config.port)
}

/// The port a `--serial` invocation opens: the flag's path, else `SCANNER_SERIAL` from the config file,
/// else automatic (the one Uniden port in `ports`, via `SerialPort.resolve`). A path from the flag or
/// the file is used exactly as given and never falls back to a detected port: a missing one fails at
/// open (so `exists` is not consulted for it). Without `--serial` nothing is resolved, and the config
/// file's `SCANNER_SERIAL` is never read.
///
/// With USB detection off in `environment` (`USBDetection.isEnabled`), a bare `--serial` is
/// `.noneFound` at once: neither `SCANNER_SERIAL` nor `ports` is consulted. `environment` has no
/// default, so no caller gets detection on without saying so: the shell passes its process
/// environment, and a test `[:]` when it means detection on.
public func resolveSerial(invocation: CLIInvocation, searchingFrom start: URL,
                          ports: [SerialPortInfo], exists: (String) -> Bool,
                          environment: [String: String]) -> SerialPortResolution {
    switch invocation.serial {
    case nil:
        return .noneFound
    case .path(let path)?:
        return .found(path: path, info: nil)
    case .auto?:
        guard USBDetection.isEnabled(environment) else { return .noneFound }
        if let url = DevScannerConfig.defaultURL(searchingUpFrom: start),
           let path = try? DevScannerConfig.serialPath(from: url) {
            return .found(path: path, info: nil)
        }
        return SerialPort.resolve(configured: nil, ports: ports, exists: exists)
    }
}
