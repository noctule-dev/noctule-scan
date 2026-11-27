// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// The mock scanner's menu: a small fictional tree, the keys that walk it, and the `STS`, `GSI`/`PSI`
/// and `MSI` renderings of whatever screen is showing. It copies what the owner's SDS200 did on
/// fw 1.26.01 (remote menus design §4.1-§4.4): `M` enters, goes up a level, and cancels an entry;
/// `>`/`<` move the highlight and wrap, the nine-row window scrolling a row at a time; `E` opens,
/// toggles, chooses or runs; `L` leaves from any depth; `MSV,,<index>` on a list acts like `E` on
/// that item without moving the radio's highlight (`Selected` follows, the `STS` highlight stays);
/// `MSV,,<text>` on an entry saves it at once and returns to the parent, except that Set Range
/// leaves the menu altogether; `MSI` omits the main menu's Analyze, whose screens answer a
/// `TypeError` with the "can't remote control" message. The test-only `MockFaults.rejectNext`
/// answers a command `NG` without carrying it out (an assumed shape for a hardware rejection).
///
/// **Assumptions, not hardware:** every `MSV,NG` (a bad or omitted index, an input that is empty,
/// longer than `MaxLength` or outside `EnableKeys`, `MSV` outside a menu or on Analyze's screens;
/// hardware rejection is untried); `MSV` on an action item runs it with no confirm prompt and stays
/// on the screen; digit and `.` keys on the number entry replace the value on the first key and
/// append after, `E` saves (digits on the name entry do nothing); an action's effect beyond the
/// action log (only Set All Lists Off/On change anything); the `Index` and `MenuSummary` indexes
/// (fixed fictional numbers per screen); the entry titles' `MenuSummary` name on list screens
/// (the screen title); a pick-one screen listing plain option names; Select Service Types as a
/// plain on/off list placed after Set Your Location (its names, the generic categories, and their
/// states are fictional, and the radio's own screen is unverified); and, outside this type, that
/// `Property F` reads On after a `KEY,F,P` until the next `KEY` of any code is handled (a second
/// `KEY,F,P` sets it On again), without changing what that next key does.
struct MockMenu: Sendable {
    static let mainTitle = "       --- M E N U ---"
    static let rowsOnScreen = 9
    static let analyzeError = "The scanner is in state that you can't remote control.\rPlease goto scan mode to remote control."

    /// The name entry's `EnableKeys` (design §4.3).
    static let nameKeys = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890[\\]^_`{|}~!\"#$%&'()*+,-./:;<=>?@ "

    /// The name entry's soft-key row (design §4.2): icon glyph bytes, not valid UTF-8.
    static let nameEntrySoftKeys: [UInt8] = [
        0xC8, 0xC8, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0x20, 0xD8, 0xD0, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE,
        0xDF, 0xD0, 0x20, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD6, 0xD6,
    ]

    enum Kind: Sendable {
        case menu, toggleList, toggle, action, number, text, pickOne
        /// Analyze: on the screen, but the menu protocol doesn't describe it.
        case unsupportedMenu
        /// A row that does nothing (Analyze's items).
        case inert
    }

    enum Effect: Sendable { case allListsOff, allListsOn }

    struct Node: Sendable {
        var name: String
        var screenTitle: String?
        var kind: Kind
        var children: [Int] = []
        /// False for rows the screen shows but `MSI` omits.
        var inMSI = true
        var isOn = false
        var value = ""
        var maxLength = 0
        var enableKeys = ""
        var addedInformation: String?
        /// Set Range: saving leaves the menu instead of returning to the parent.
        var leavesMenuOnSave = false
        var options: [String] = []
        var choice = 0
        var effect: Effect?

        var title: String { screenTitle ?? name }
    }

    struct Frame: Sendable {
        var node: Int
        var highlight = 0
        var top = 0
        /// `MSI`'s `Selected`. Follows the highlight, but `MSV` moves only this.
        var selected = 0
        /// Digits typed on a number entry; nil until the first key (which replaces the value).
        var typed: String?
    }

    private(set) var nodes: [Node] = []
    private var frames: [Frame] = []
    /// Every state change the menu carried out, oldest first.
    private(set) var actions: [String] = []

    var isActive: Bool { !frames.isEmpty }
    var path: [String] { frames.map { nodes[$0.node].title } }

    init() {
        let root = add(Node(name: "Menu", screenTitle: Self.mainTitle, kind: .menu), under: nil)
        let scan = add(Node(name: "Set Scan Selection", kind: .menu), under: root)
        let lists = add(Node(name: "Select Lists to Monitor", kind: .toggleList), under: scan)
        let listNames = ["Full Database", "Search with Scan", "Lakeview Fire", "County Roads", "Harbor Patrol",
                         "Transit", "Airport Ops", "Public Works", "Parks", "Marine", "Rail Yard", "Events"]
        for (index, name) in listNames.enumerated() {
            add(Node(name: name, kind: .toggle, isOn: index >= 2), under: lists)
        }
        add(Node(name: "Set All Lists Off", kind: .action, effect: .allListsOff), under: scan)
        add(Node(name: "Set All Lists On", kind: .action, effect: .allListsOn), under: scan)

        let location = add(Node(name: "Set Your Location", kind: .menu), under: root)
        add(Node(name: "Set Range", kind: .number, value: "30.0", maxLength: 5, enableKeys: "0123456789.",
                 addedInformation: "          (mile)", leavesMenuOnSave: true), under: location)

        // Select Service Types (design §5.5): the type-select list the Services key opens.
        let services = add(Node(name: "Select Service Types", kind: .toggleList), under: root)
        for (name, isOn) in [("Multi-Dispatch", true), ("Law Dispatch", true), ("Fire Dispatch", true),
                             ("EMS Dispatch", true), ("Custom 1", true), ("Hospital", false), ("Railroad", false)] {
            add(Node(name: name, kind: .toggle, isOn: isOn), under: services)
        }

        let search = add(Node(name: "Search for...", kind: .menu), under: root)
        let custom = add(Node(name: "Edit Custom", screenTitle: "Select Custom", kind: .menu), under: search)
        for index in 0..<10 {
            let bank = add(Node(name: "Custom \(index)", kind: .menu), under: custom)
            add(Node(name: "Edit Name", kind: .text, value: "Custom \(index)", maxLength: 64,
                     enableKeys: Self.nameKeys), under: bank)
        }

        let analyze = add(Node(name: "Analyze", kind: .unsupportedMenu, inMSI: false), under: root)
        add(Node(name: "System Status", kind: .inert), under: analyze)
        add(Node(name: "LCN Finder", kind: .inert), under: analyze)

        let display = add(Node(name: "Display Options", kind: .menu), under: root)
        add(Node(name: "Set ID Format (P25/Mot)", kind: .pickOne, options: ["Decimal Format", "Hex Format"]),
            under: display)

        let settings = add(Node(name: "Settings", kind: .menu), under: root)
        add(Node(name: "Clear User Data", kind: .action), under: settings)
    }

    @discardableResult
    private mutating func add(_ node: Node, under parent: Int?) -> Int {
        nodes.append(node)
        let id = nodes.count - 1
        if let parent { nodes[parent].children.append(id) }
        return id
    }

    // MARK: Menu commands (the BCD436HP's `MNU` and `MSB`)

    /// `MNU,TOP,`: shows the top menu (from anywhere).
    mutating func enterTop() { frames = [Frame(node: 0)] }

    /// `MSB,,`: back one level; at the top menu it stays (assumed). Returns false outside a menu.
    mutating func back() -> Bool {
        guard isActive else { return false }
        if frames.count > 1 { frames.removeLast() }
        return true
    }

    /// `MSB,,RETURN_PREVOUS_MODE`: leaves the menu entirely. Returns false outside a menu.
    mutating func leave() -> Bool {
        guard isActive else { return false }
        frames = []
        return true
    }

    // MARK: Keys

    /// Handles a front-panel key code (already known to be valid). Returns true when the menu
    /// consumed it (it was entered, or is showing); false means the key is for scan mode.
    mutating func key(_ code: String) -> Bool {
        let key = code.uppercased()
        guard let frame = frames.last else {
            guard key == "M" else { return false }
            frames = [Frame(node: 0)]
            return true
        }
        switch key {
        case "M": if frames.count > 1 { frames.removeLast() }
        case "L": frames = []
        case ">": move(1)
        case "<": move(-1)
        case "E":
            if isSelection(nodes[frame.node].kind) {
                guard rowCount(frame.node) > 0 else { break }
                frames[frames.count - 1].selected = frame.highlight
                choose(frame.highlight)
            } else if nodes[frame.node].kind == .number {
                save(displayValue(frame))
            } else if nodes[frame.node].kind == .text {
                save(nodes[frame.node].value)
            }
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".":
            guard nodes[frame.node].kind == .number else { break }
            let typed = frame.typed.map { $0.count < nodes[frame.node].maxLength ? $0 + key : $0 } ?? key
            frames[frames.count - 1].typed = typed
        default: break
        }
        return true
    }

    /// `MSV,,<value>`. Returns false for what the mock rejects with `MSV,NG`.
    mutating func setValue(_ value: String) -> Bool {
        guard let frame = frames.last else { return false }
        let node = nodes[frame.node]
        switch node.kind {
        case .menu, .toggleList, .pickOne:
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let row = Int(value),
                  row < rowCount(frame.node), rowIsInMSI(frame.node, row) else { return false }
            frames[frames.count - 1].selected = row
            choose(row)
            return true
        case .number, .text:
            guard !value.isEmpty, value.count <= node.maxLength,
                  value.allSatisfy({ node.enableKeys.contains($0) }) else { return false }
            save(value)
            return true
        case .unsupportedMenu, .toggle, .action, .inert:
            return false
        }
    }

    private func isSelection(_ kind: Kind) -> Bool {
        switch kind {
        case .menu, .toggleList, .pickOne, .unsupportedMenu: true
        case .toggle, .action, .number, .text, .inert: false
        }
    }

    private func rowCount(_ node: Int) -> Int {
        nodes[node].kind == .pickOne ? nodes[node].options.count : nodes[node].children.count
    }

    private func rowIsInMSI(_ node: Int, _ row: Int) -> Bool {
        nodes[node].kind == .pickOne || nodes[nodes[node].children[row]].inMSI
    }

    private mutating func move(_ step: Int) {
        guard var frame = frames.last, isSelection(nodes[frame.node].kind) else { return }
        let count = rowCount(frame.node)
        guard count > 0 else { return }
        frame.highlight = (frame.highlight + step + count) % count
        frame.selected = frame.highlight
        if frame.highlight < frame.top {
            frame.top = frame.highlight
        } else if frame.highlight >= frame.top + Self.rowsOnScreen {
            frame.top = frame.highlight - Self.rowsOnScreen + 1
        }
        frames[frames.count - 1] = frame
    }

    /// What `E` on row `row` of the top screen does.
    private mutating func choose(_ row: Int) {
        let frame = frames[frames.count - 1]
        let screen = nodes[frame.node]
        if screen.kind == .pickOne {
            nodes[frame.node].choice = row
            actions.append("set \(screen.name) \(screen.options[row])")
            frames.removeLast()
            return
        }
        let childID = screen.children[row]
        let child = nodes[childID]
        switch child.kind {
        case .menu, .toggleList, .unsupportedMenu, .number, .text:
            frames.append(Frame(node: childID))
        case .pickOne:
            var opened = Frame(node: childID, highlight: child.choice, selected: child.choice)
            opened.top = max(0, min(child.choice, child.options.count - Self.rowsOnScreen))
            frames.append(opened)
        case .toggle:
            nodes[childID].isOn.toggle()
            actions.append("toggle \(child.name) \(nodes[childID].isOn ? "On" : "Off")")
        case .action:
            actions.append("run \(child.name)")
            switch child.effect {
            case .allListsOff: setAllLists(false)
            case .allListsOn: setAllLists(true)
            case nil: break
            }
        case .inert:
            break
        }
    }

    private mutating func setAllLists(_ on: Bool) {
        for index in nodes.indices where nodes[index].kind == .toggle { nodes[index].isOn = on }
    }

    /// Saves an entry screen's value and leaves it, as hardware did (§4.4).
    private mutating func save(_ value: String) {
        let frame = frames[frames.count - 1]
        nodes[frame.node].value = value
        actions.append("set \(nodes[frame.node].title) \(value)")
        if nodes[frame.node].leavesMenuOnSave {
            frames = []
            return
        }
        frames.removeLast()
        // A name entry names the bank it was opened from.
        if nodes[frame.node].kind == .text, let parent = frames.last { nodes[parent.node].name = value }
    }

    private func displayValue(_ frame: Frame) -> String { frame.typed ?? nodes[frame.node].value }

    // MARK: Rendering

    private func screenIndex(_ node: Int) -> String { String(4_293_060_000 + node) }

    private func rowText(_ screen: Int, _ row: Int, columns: Int = 30) -> String {
        let node = nodes[screen]
        if node.kind == .pickOne { return node.options[row] }
        let child = nodes[node.children[row]]
        guard child.kind == .toggle else { return child.name }
        return String(child.name.prefix(columns - 4)).padding(toLength: columns - 4, withPad: " ", startingAt: 0)
            + (child.isOn ? ":On " : ":Off")
    }

    /// The whole `STS` reply line, without the trailing `\r`, as bytes: the name entry's soft-key
    /// row isn't valid UTF-8. `columns` is 30 for the SDS models, whose screens are unchanged, and 24
    /// for the BCD436HP (design §3.6): there a number entry's mask spans the value, a name entry has
    /// `glyphBytes` (four, cycled) on line 6 and no soft-key line, and the trailing field is 0.
    func statusFields(columns: Int = 30, glyphBytes: [UInt8] = []) -> Data {
        guard let frame = frames.last else { return Data() }
        let node = nodes[frame.node]
        let narrow = columns != 30
        let blank = String(repeating: " ", count: columns)
        var lines: [(text: Data, mask: String)] = [(Self.padded(node.title, columns: columns), String(repeating: "_", count: columns))]
        switch node.kind {
        case .number, .text:
            let valueMask = narrow && node.kind == .number ? String(repeating: "*", count: columns)
                : "*" + String(repeating: " ", count: columns - 1)
            lines.append((Self.padded(displayValue(frame), columns: columns), valueMask))
            for row in 2..<10 {
                if node.kind == .number, row == 4, let info = node.addedInformation {
                    lines.append((Self.padded(info, columns: columns), blank))
                } else if node.kind == .text, row == 9, !narrow {
                    lines.append((Data(Self.nameEntrySoftKeys), blank))
                } else if node.kind == .text, row == 5, narrow, !glyphBytes.isEmpty {
                    let glyphs = (0..<4).map { glyphBytes[$0 % glyphBytes.count] }
                    lines.append((Data(glyphs) + Self.padded("", columns: columns - 4), blank))
                } else {
                    lines.append((Self.padded("", columns: columns), blank))
                }
            }
        default:
            for slot in 0..<Self.rowsOnScreen {
                let row = frame.top + slot
                guard row < rowCount(frame.node) else {
                    lines.append((Self.padded("", columns: columns), blank))
                    continue
                }
                lines.append((Self.padded(rowText(frame.node, row, columns: columns), columns: columns),
                              row == frame.highlight ? String(repeating: "*", count: columns) : blank))
            }
        }
        var data = Data("STS,1111111111,".utf8)
        for line in lines {
            data.append(line.text)
            data.append(Data(",\(line.mask),".utf8))
        }
        data.append(Data((narrow ? "1,1,0,0,,,0,OFF,0" : "1,1,0,0,,,0,OFF,3").utf8))
        return data
    }

    /// `columns` (30) wide, no commas (the `STS` field separator).
    private static func padded(_ text: String, columns: Int = 30) -> Data {
        let clean = text.replacingOccurrences(of: ",", with: " ")
        return Data(String(clean.prefix(columns)).padding(toLength: columns, withPad: " ", startingAt: 0).utf8)
    }

    /// The `ScannerInfo` document for `GSI`/`PSI`: no channel elements (design §4.2). Its lines are
    /// separated by `lineBreak` (`\n` over UDP, `\r` on serial).
    func scannerInfoXML(lineBreak: String = "\n") -> String {
        guard let frame = frames.last else { return "" }
        let node = nodes[frame.node]
        let screen = isSelection(node.kind) ? "menu_selection" : "menu_input"
        return ["<?xml version=\"1.0\" encoding=\"utf-8\"?>",
                "<ScannerInfo Mode=\"Menu tree\" V_Screen=\"\(screen)\">",
                "<MenuSummary name=\"\(Self.attribute(node.title))\" index=\"\(screenIndex(frame.node))\" />",
                "<ViewDescription>", "</ViewDescription>", "</ScannerInfo>"].joined(separator: lineBreak)
    }

    /// The `MSI` document (design §4.3), with the `Footer` when `footer` is true (the UDP form; the
    /// serial form has none), its lines separated by `lineBreak`.
    func msiXML(footer hasFooter: Bool = true, lineBreak: String = "\n") -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>"]
        let footer = hasFooter ? ["<Footer No=\"1\" EOT=\"1\"/>"] : []
        guard let frame = frames.last else {
            return (lines + ["<MSI MenuType=\"TypeError\" >"] + footer + ["</MSI>"]).joined(separator: lineBreak)
        }
        let node = nodes[frame.node]
        let head = "<MSI Name=\"\(Self.attribute(node.title))\" Index=\"\(screenIndex(frame.node))\""
        switch node.kind {
        case .unsupportedMenu:
            lines += ["<MSI MenuType=\"TypeError\" >",
                      "<MenuErrorMsg Text=\"\(Self.attribute(Self.analyzeError))\" ScanButton=\"1\"  />"] + footer + ["</MSI>"]
        case .number, .text:
            lines.append("\(head) MenuType=\"TypeInput\" Value=\"\(Self.attribute(displayValue(frame)))\" >")
            var input = "<MenuInput MaxLength=\"\(node.maxLength)\""
            if let info = node.addedInformation { input += " AddedInformation=\"\(Self.attribute(info))\"" }
            lines += [input + " EnableKeys=\"\(Self.attribute(node.enableKeys))\" />"] + footer + ["</MSI>"]
        default:
            // The root `Value` of an on/off list is its first row's text, whatever the highlight.
            let value = node.kind == .toggleList && rowCount(frame.node) > 0
                ? " Value=\"\(Self.attribute(rowText(frame.node, 0)))\"" : ""
            lines.append("\(head) MenuType=\"TypeSelect\"\(value) Selected=\"\(frame.selected)\" >")
            for row in 0..<rowCount(frame.node) where rowIsInMSI(frame.node, row) {
                var item = "<MenuItem Name=\"\(Self.attribute(node.kind == .pickOne ? node.options[row] : nodes[node.children[row]].name))\" Index=\"\(row)\""
                if node.kind == .toggleList { item += " Value=\"\(nodes[node.children[row]].isOn ? "On" : "Off")\"" }
                lines.append(item + " />")
            }
            lines += footer + ["</MSI>"]
        }
        return lines.joined(separator: lineBreak)
    }

    private static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\r", with: "&#xD;")
    }
}
