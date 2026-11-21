// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// The mocks' fictional Favorites tree and the quick-key commands over it (Plan 20; design
/// `docs/specs/2026-11-18-quick-keys-design.md` §3, §5.2): `GLT,FL|SYS,<i>|DEPT,<i>|SITE,<i>` read the
/// tree, `FQK`, `SQK,<fq>` and `DQK,<fq>,<sq>` read the 100 key states of a level, and the same with
/// 100 more values set them. Pure: `ControlCore` routes the four command names here and keeps one
/// value per mock, which tests read and replace (`MockSDS200.favorites`, `setFavorites(_:)`).
///
/// **Seen on hardware (design §3):** the shapes of the `GLT` documents and their attributes; `FQK`,
/// `SQK` and `DQK` replies that carry only the 100 values (0 no such key, 1 off, 2 on); a set
/// answered `<CMD>,OK` after about 0.8 s for `FQK` and `SQK` and at once for `DQK`; a 0 in a set
/// leaving that key alone (confirmed for `SQK`); the built-in lists and the `Unknown` department;
/// department and site keys sharing one numbering; and a system whose departments have `GLT` keys
/// that `DQK` reports as 0. **`GLT` replies come in pages** (the SDS150 and the SDS100 over USB serial,
/// 2026-11-19): every `GLT` document ends with `<Footer No="n" EOT="0|1"/>`, and a long reply is several
/// documents, each with its own `GLT,<XML>,` line, numbered from 1 with `EOT="1"` on the last only, sent
/// back to back; the SDS200's replies over the network came whole through the UDP reassembly, so they
/// carry footers too. The mocks page every `GLT` reply (`gltPageSize`, `defaultGLTPageSize` elements a
/// page unless a test or `--glt-page-size` says otherwise), on every model.
///
/// **Assumed, not hardware:** the tree itself and its names (fictional); `GLT` for an unknown index
/// answering an empty `<GLT>` document; a wrong or missing argument to `GLT` answering `ERR`; a set
/// that is not exactly 100 values each `0`-`2`, or that names a list, system or department level
/// with nothing behind that key, answered `<CMD>,NG` with nothing changed; a `1` or `2` for a key
/// that doesn't exist ignored; a set to a key several rows hold changing every one of them (and a
/// read of it answering the first holder in `GLT` order, departments before sites); the same key in
/// two systems or lists answered from the first in `GLT` order; the mismatch system's `DQK` set
/// accepted and ignored; `FQK` and `DQK` sets taking a 0 as "leave alone" as `SQK` does; the quick
/// keys and states being kept across a power cycle; paging by element count (the hardware pages by
/// size: 6-13 elements a page were seen); and that each of the SDS200's pages is a datagram of its own
/// with its own `GLT,<XML>,` line (its pages were never looked at one by one).
public struct MockFavorites: Sendable, Equatable {
    public struct ListRow: Sendable, Equatable {
        public var index: UInt32
        public var name: String
        public var quickKey: Int?
        /// Whether the list is selected in Select Lists to Monitor (`GLT,FL`'s `Monitor`). Read-only: no
        /// command here changes it.
        public var monitored: Bool
        /// The list's quick-key on/off state, what `FQK` reports and sets. Not the same thing as `monitored`.
        public var isOn: Bool

        public init(index: UInt32, name: String, quickKey: Int?, monitored: Bool = true, isOn: Bool = true) {
            self.index = index; self.name = name; self.quickKey = quickKey
            self.monitored = monitored; self.isOn = isOn
        }
    }

    public struct SystemRow: Sendable, Equatable {
        public var index: UInt32
        public var listIndex: UInt32
        public var name: String
        /// `P25 Trunk`, `Motorola` or `Conventional`.
        public var type: String
        public var quickKey: Int?
        public var avoided: Bool
        /// The system's key state: true is on (2), false off (1).
        public var isOn: Bool

        public init(index: UInt32, listIndex: UInt32, name: String, type: String, quickKey: Int?,
                    avoided: Bool = false, isOn: Bool = true) {
            self.index = index; self.listIndex = listIndex; self.name = name; self.type = type
            self.quickKey = quickKey; self.avoided = avoided; self.isOn = isOn
        }

        public var isTrunked: Bool { type != "Conventional" }
    }

    public struct ChildRow: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case department, site }

        public var index: UInt32
        public var systemIndex: UInt32
        public var kind: Kind
        public var name: String
        public var quickKey: Int?
        public var avoided: Bool
        public var isOn: Bool

        public init(index: UInt32, systemIndex: UInt32, kind: Kind, name: String, quickKey: Int?,
                    avoided: Bool = false, isOn: Bool = true) {
            self.index = index; self.systemIndex = systemIndex; self.kind = kind; self.name = name
            self.quickKey = quickKey; self.avoided = avoided; self.isOn = isOn
        }
    }

    /// In `GLT` order.
    public var lists: [ListRow]
    public var systems: [SystemRow]
    /// Departments and sites of every system, in `GLT` order within each system and kind.
    public var children: [ChildRow]
    /// Systems whose `DQK` reports all 0 although their departments have keys (design §3.2).
    public var dqkReportsZeros: Set<UInt32>

    public init(lists: [ListRow], systems: [SystemRow], children: [ChildRow], dqkReportsZeros: Set<UInt32> = []) {
        self.lists = lists; self.systems = systems; self.children = children
        self.dqkReportsZeros = dqkReportsZeros
    }

    static let unknownIndex: UInt32 = 4_294_967_295
    static let searchWithScanIndex: UInt32 = 4_261_412_864

    /// The default tree. `GSI` names list 1 (`Q_Key="0"`, the wrong key, as the real one does), system
    /// 101 and departments 200, 201 and 203 (`MockScreens`).
    public static let `default`: MockFavorites = {
        var lists: [ListRow] = []
        var systems: [SystemRow] = []
        var children: [ChildRow] = []
        func list(_ index: UInt32, _ name: String, _ key: Int?, on: Bool = true, monitored: Bool = true) {
            lists.append(ListRow(index: index, name: name, quickKey: key, monitored: monitored, isOn: on))
        }
        func system(_ index: UInt32, in listIndex: UInt32, _ name: String, _ type: String, _ key: Int?,
                    on: Bool = true, avoided: Bool = false) {
            systems.append(SystemRow(index: index, listIndex: listIndex, name: name, type: type, quickKey: key,
                                     avoided: avoided, isOn: on))
            // Departments of a trunked system start with Unknown.
            if type != "Conventional" {
                children.append(ChildRow(index: MockFavorites.unknownIndex, systemIndex: index, kind: .department,
                                         name: "Unknown", quickKey: nil))
            }
        }
        func department(_ index: UInt32, of systemIndex: UInt32, _ name: String, _ key: Int?, on: Bool = true) {
            children.append(ChildRow(index: index, systemIndex: systemIndex, kind: .department, name: name,
                                     quickKey: key, isOn: on))
        }
        func site(_ index: UInt32, of systemIndex: UInt32, _ name: String, _ key: Int?, on: Bool = true) {
            children.append(ChildRow(index: index, systemIndex: systemIndex, kind: .site, name: name,
                                     quickKey: key, isOn: on))
        }
        list(0, "Mock Police", 0)
        system(110, in: 0, "Metro P25", "P25 Trunk", 0)
        department(500, of: 110, "Patrol", 0)
        department(501, of: 110, "Detectives", 1, on: false)
        site(610, of: 110, "Metro Simulcast", nil)
        system(111, in: 0, "Metro Backup", "P25 Trunk", 0)
        department(510, of: 111, "Backup Patrol", 0)
        system(112, in: 0, "Metro Conventional", "Conventional", nil)
        department(520, of: 112, "Records", 0)

        list(1, "Mock Favorites", 7)
        system(101, in: 1, "Riverbend County P25", "P25 Trunk", 0)
        department(118, of: 101, "Road Crews", nil)
        department(200, of: 101, "Lakeview Fire", 0)
        department(201, of: 101, "Riverbend Sheriff", 1)
        department(203, of: 101, "Lakeview Fire Tac", 0)
        site(301, of: 101, "Riverbend Simulcast", 0)
        system(102, in: 1, "Mock Simplex", "Conventional", 1)
        department(400, of: 102, "Simplex A", 0)
        department(401, of: 102, "Simplex B", 1, on: false)
        department(402, of: 102, "Simplex C", 2, on: false)

        list(4, "Mock Fire & EMS", 1, on: false)
        system(120, in: 4, "Lakeview City P25", "P25 Trunk", 0)
        department(530, of: 120, "Fire Dispatch", nil)
        site(620, of: 120, "North Site", 0)
        site(621, of: 120, "South Site", 1, on: false)
        system(121, in: 4, "County 800 Trunk", "Motorola", 1, on: false, avoided: true)
        site(630, of: 121, "County Simulcast", nil)
        system(122, in: 4, "State Forestry", "Conventional", 2)
        department(540, of: 122, "Air Attack", 2)

        list(6, "Mock Utilities", 3)
        system(130, in: 6, "Water District", "Conventional", 0)
        department(550, of: 130, "Field Ops", 0)

        list(8, "Mock Marine", 12, on: false, monitored: false)
        system(140, in: 8, "Harbor", "Conventional", 0)
        department(560, of: 140, "Harbor Ops", 0)

        list(10, "Mock Events", nil)
        system(150, in: 10, "Fairgrounds", "Conventional", 0)
        department(570, of: 150, "Gates", 0)

        list(12, "Mock Air", 23)
        system(160, in: 12, "Airport", "Conventional", 4)
        department(580, of: 160, "Tower", 0)

        list(14, "Mock Interop", 41, on: false)
        system(170, in: 14, "Interop", "Conventional", nil)
        department(590, of: 170, "Calling", nil)
        return MockFavorites(lists: lists, systems: systems, children: children, dqkReportsZeros: [122])
    }()

    // MARK: Commands

    /// How many elements a `GLT` page holds unless a mock is given another size (`gltPageSize`).
    public static let defaultGLTPageSize = 4

    /// The reply to `name` with `args` (`GLT`, `FQK`, `SQK` or `DQK`), changing the tree for a set; nil
    /// for any other command or a form it doesn't answer (the caller answers `ERR`). `delayed` is true
    /// for the sets that take about 0.8 s on hardware (`FQK`, `SQK`). `replies` is one line for every
    /// command but `GLT`, whose reply is one document per page of at most `pageSize` elements, in the
    /// model's line form (`lineBreak`), each to be sent on its own (a datagram, or a write).
    mutating func reply(to name: String, args: [String], lineBreak: String, pageSize: Int = defaultGLTPageSize)
        -> (replies: [String], delayed: Bool)? {
        let answer: (text: String, delayed: Bool)?
        switch name {
        case "GLT": return glt(args, lineBreak: lineBreak, pageSize: pageSize).map { ($0, false) }
        case "FQK": answer = args.isEmpty ? (readReply("FQK", listStates()), false) : setFQK(args)
        case "SQK":
            guard !args.isEmpty else { return nil }
            answer = args.count == 1 ? sqkRead(args[0]) : setSQK(args)
        case "DQK":
            guard args.count >= 2 else { return nil }
            answer = args.count == 2 ? dqkRead(args) : setDQK(args)
        default: return nil
        }
        return answer.map { ([$0.text], $0.delayed) }
    }

    // MARK: GLT

    /// The pages of a `GLT` reply, as the hardware sends them (design §3.1): each a whole document with
    /// its own `GLT,<XML>,` line and a `<Footer No="n" EOT="0|1"/>`, `No` from 1 and `EOT="1"` on the
    /// last only. An empty reply is one page.
    private func glt(_ args: [String], lineBreak: String, pageSize: Int) -> [String]? {
        var rows: [String] = []
        switch (args.first ?? "", args.count) {
        case ("FL", 1):
            rows.append(Self.listRow(ListRow(index: Self.unknownIndex, name: "Full Database", quickKey: nil, monitored: false)))
            rows.append(Self.listRow(ListRow(index: Self.searchWithScanIndex, name: "Search with Scan", quickKey: nil,
                                             monitored: false)))
            rows += lists.map(Self.listRow)
        case ("SYS", 2):
            if let parent = UInt32(args[1]) {
                rows = systems.filter { $0.listIndex == parent }.map(Self.systemRow)
            }
        case ("DEPT", 2), ("SITE", 2):
            if let parent = UInt32(args[1]) {
                let kind: ChildRow.Kind = args[0] == "DEPT" ? .department : .site
                let conventional = systems.first { $0.index == parent }?.isTrunked == false
                rows = children.filter { $0.systemIndex == parent && $0.kind == kind }
                    .map { Self.childRow($0, conventional: conventional) }
            }
        default:
            return nil
        }
        let size = max(1, pageSize)
        let pages = rows.isEmpty ? [[]] : stride(from: 0, to: rows.count, by: size).map {
            Array(rows[$0..<min($0 + size, rows.count)])
        }
        return pages.enumerated().map { offset, page in
            let footer = "<Footer No=\"\(offset + 1)\" EOT=\"\(offset == pages.count - 1 ? 1 : 0)\"/>"
            let lines = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<GLT>"] + page + [footer, "</GLT>"]
            return "GLT,<XML>,\r" + lines.joined(separator: lineBreak)
        }
    }

    private static func key(_ key: Int?) -> String { key.map(String.init) ?? "None" }
    private static func text(_ value: String) -> String { MockScreens.escape(value) }

    private static func listRow(_ row: ListRow) -> String {
        "<FL Index=\"\(row.index)\" Name=\"\(text(row.name))\" Monitor=\"\(row.monitored ? "On" : "Off")\" "
            + "Q_Key=\"\(key(row.quickKey))\" N_Tag=\"None\"/>"
    }

    private static func systemRow(_ row: SystemRow) -> String {
        "<SYS Index=\"\(row.index)\" Name=\"\(text(row.name))\" Type=\"\(text(row.type))\" "
            + "Q_Key=\"\(key(row.quickKey))\" Avoid=\"\(row.avoided ? "On" : "Off")\" CountyId=\"0\" N_Tag=\"None\"/>"
    }

    private static func childRow(_ row: ChildRow, conventional: Bool) -> String {
        let avoid = row.avoided ? "On" : "Off"
        switch row.kind {
        case .department:
            let group = conventional ? "CGroupId" : "TGroupId"
            return "<DEPT Index=\"\(row.index)\" Name=\"\(text(row.name))\" Q_Key=\"\(key(row.quickKey))\" "
                + "Avoid=\"\(avoid)\" \(group)=\"\(row.index)\"/>"
        case .site:
            return "<SITE Index=\"\(row.index)\" Name=\"\(text(row.name))\" Q_Key=\"\(key(row.quickKey))\" "
                + "Avoid=\"\(avoid)\" SiteId=\"\(row.index)\"/>"
        }
    }

    // MARK: Reading states

    private func readReply(_ name: String, _ states: [Int]) -> String {
        name + "," + states.map(String.init).joined(separator: ",")
    }

    /// 100 values from `(key, on)` pairs in order: the first holder of a key gives its value.
    private func states(of pairs: [(key: Int?, on: Bool)]) -> [Int] {
        var values = [Int](repeating: 0, count: 100)
        for (key, on) in pairs {
            guard let key, (0..<100).contains(key), values[key] == 0 else { continue }
            values[key] = on ? 2 : 1
        }
        return values
    }

    private func listStates() -> [Int] { states(of: lists.map { ($0.quickKey, $0.isOn) }) }

    private func list(key text: String) -> ListRow? {
        guard let key = Int(text) else { return nil }
        return lists.first { $0.quickKey == key }
    }

    private func systemsOf(_ list: ListRow) -> [SystemRow] { systems.filter { $0.listIndex == list.index } }

    private func system(key text: String, in list: ListRow) -> SystemRow? {
        guard let key = Int(text) else { return nil }
        return systemsOf(list).first { $0.quickKey == key }
    }

    /// Departments before sites, each in order.
    private func childrenOf(_ system: SystemRow) -> [ChildRow] {
        let held = children.filter { $0.systemIndex == system.index }
        return held.filter { $0.kind == .department } + held.filter { $0.kind == .site }
    }

    private func sqkRead(_ listKey: String) -> (text: String, delayed: Bool) {
        guard let list = list(key: listKey) else { return (readReply("SQK", states(of: [])), false) }
        return (readReply("SQK", states(of: systemsOf(list).map { ($0.quickKey, $0.isOn) })), false)
    }

    private func dqkRead(_ args: [String]) -> (text: String, delayed: Bool) {
        guard let list = list(key: args[0]), let system = system(key: args[1], in: list),
              !dqkReportsZeros.contains(system.index) else { return (readReply("DQK", states(of: [])), false) }
        return (readReply("DQK", states(of: childrenOf(system).map { ($0.quickKey, $0.isOn) })), false)
    }

    // MARK: Sets

    /// The 100 values of a set, or nil unless exactly 100 each "0", "1" or "2".
    private func values(_ fields: [String]) -> [Int]? {
        guard fields.count == 100 else { return nil }
        var parsed: [Int] = []
        for field in fields {
            guard let value = Int(field), (0...2).contains(value) else { return nil }
            parsed.append(value)
        }
        return parsed
    }

    private mutating func setFQK(_ args: [String]) -> (text: String, delayed: Bool) {
        guard let values = values(args) else { return ("FQK,NG", false) }
        for position in lists.indices {
            guard let key = lists[position].quickKey, (0..<100).contains(key), values[key] != 0 else { continue }
            lists[position].isOn = values[key] == 2
        }
        return ("FQK,OK", true)
    }

    private mutating func setSQK(_ args: [String]) -> (text: String, delayed: Bool) {
        guard let values = values(Array(args.dropFirst())), let list = list(key: args[0]) else { return ("SQK,NG", false) }
        for position in systems.indices where systems[position].listIndex == list.index {
            guard let key = systems[position].quickKey, (0..<100).contains(key), values[key] != 0 else { continue }
            systems[position].isOn = values[key] == 2
        }
        return ("SQK,OK", true)
    }

    private mutating func setDQK(_ args: [String]) -> (text: String, delayed: Bool) {
        guard let values = values(Array(args.dropFirst(2))), let list = list(key: args[0]),
              let system = system(key: args[1], in: list) else { return ("DQK,NG", false) }
        if !dqkReportsZeros.contains(system.index) {
            for position in children.indices where children[position].systemIndex == system.index {
                guard let key = children[position].quickKey, (0..<100).contains(key), values[key] != 0 else { continue }
                children[position].isOn = values[key] == 2
            }
        }
        return ("DQK,OK", false)
    }
}
