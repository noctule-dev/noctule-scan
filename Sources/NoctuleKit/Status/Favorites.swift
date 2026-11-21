// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// A Favorites List from `GLT,FL`.
public struct FavoritesList: Sendable, Equatable {
    public var index: UInt32
    public var name: String
    public var quickKey: Int?
    public var monitored: Bool

    public init(index: UInt32, name: String, quickKey: Int?, monitored: Bool) {
        self.index = index
        self.name = name
        self.quickKey = quickKey
        self.monitored = monitored
    }
}

/// A system from `GLT,SYS,<list index>`.
public struct FavoritesSystem: Sendable, Equatable {
    public var index: UInt32
    public var name: String
    public var type: String
    public var quickKey: Int?
    public var avoided: Bool

    public var isConventional: Bool { type == "Conventional" }

    public init(index: UInt32, name: String, type: String, quickKey: Int?, avoided: Bool) {
        self.index = index
        self.name = name
        self.type = type
        self.quickKey = quickKey
        self.avoided = avoided
    }
}

/// A department (`GLT,DEPT`) or site (`GLT,SITE`) of a system. Both share one key numbering (`DQK`).
public struct FavoritesChild: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case department, site }

    public var index: UInt32
    public var name: String
    public var quickKey: Int?
    public var avoided: Bool
    public var kind: Kind

    public init(index: UInt32, name: String, quickKey: Int?, avoided: Bool, kind: Kind) {
        self.index = index
        self.name = name
        self.quickKey = quickKey
        self.avoided = avoided
        self.kind = kind
    }
}

public enum QuickKeyState: Int, Sendable {
    case none = 0, off = 1, on = 2
}

/// The 100 values `FQK`, `SQK` and `DQK` answer: 0 no such key, 1 off, 2 on.
public struct QuickKeyStates: Sendable, Equatable {
    private let values: [QuickKeyState]

    /// Nil unless there are exactly 100 fields, each "0", "1" or "2".
    public init?(fields: [String]) {
        guard fields.count == 100 else { return nil }
        var parsed: [QuickKeyState] = []
        parsed.reserveCapacity(100)
        for field in fields {
            guard let raw = Int(field.trimmingCharacters(in: .whitespaces)),
                  let state = QuickKeyState(rawValue: raw) else { return nil }
            parsed.append(state)
        }
        values = parsed
    }

    /// The state of a key; `.none` outside 0–99.
    public subscript(key: Int) -> QuickKeyState {
        values.indices.contains(key) ? values[key] : .none
    }

    public var existingKeys: Set<Int> {
        Set(values.indices.filter { values[$0] != .none })
    }

    /// The 100 values of a set that changes one key: "0" (leave alone) everywhere but `key`,
    /// "2" for on and "1" for off. A `key` outside 0–99 gives all zeros; callers refuse it first.
    public static func setting(_ key: Int, on: Bool) -> [String] {
        (0..<100).map { $0 == key ? (on ? "2" : "1") : "0" }
    }
}

public enum FavoritesXMLError: Error, Equatable {
    case unexpectedRoot(String)
    /// A `<FL>`, `<SYS>`, `<DEPT>` or `<SITE>` in a document read as another kind.
    case unexpectedElement(String)
}

/// Reads the `<GLT>` documents. The built-in entries (the lists `Full Database` and
/// `Search with Scan`, the department `Unknown`) are dropped; other elements are skipped. A document
/// holding another of the four kinds is refused (`unexpectedElement`), never read as an empty one: replies
/// are matched to requests by command name, so a late reply to an earlier `GLT` can answer a later one
/// (a `DEPT` document answering `GLT,SYS` would otherwise be a list with no systems).
public enum FavoritesXML {
    private static let fullDatabase: UInt32 = 4_294_967_295
    private static let searchWithScan: UInt32 = 4_261_412_864

    public static func lists(_ root: XMLNode) throws -> [FavoritesList] {
        try elements(root, "FL").compactMap { node in
            guard let index = index(node), index != fullDatabase, index != searchWithScan else { return nil }
            return FavoritesList(
                index: index, name: node.attributes["Name"] ?? "", quickKey: quickKey(node),
                monitored: node.attributes["Monitor"] == "On")
        }
    }

    public static func systems(_ root: XMLNode) throws -> [FavoritesSystem] {
        try elements(root, "SYS").compactMap { node in
            guard let index = index(node) else { return nil }
            return FavoritesSystem(
                index: index, name: node.attributes["Name"] ?? "", type: node.attributes["Type"] ?? "",
                quickKey: quickKey(node), avoided: avoided(node))
        }
    }

    public static func departments(_ root: XMLNode) throws -> [FavoritesChild] {
        try elements(root, "DEPT").compactMap { node in
            guard let index = index(node), index != fullDatabase else { return nil }
            return child(node, index: index, kind: .department)
        }
    }

    public static func sites(_ root: XMLNode) throws -> [FavoritesChild] {
        try elements(root, "SITE").compactMap { node in
            guard let index = index(node) else { return nil }
            return child(node, index: index, kind: .site)
        }
    }

    private static let kinds: Set<String> = ["FL", "SYS", "DEPT", "SITE"]

    private static func elements(_ root: XMLNode, _ name: String) throws -> [XMLNode] {
        guard root.name == "GLT" else { throw FavoritesXMLError.unexpectedRoot(root.name) }
        if let other = root.children.first(where: { $0.name != name && kinds.contains($0.name) }) {
            throw FavoritesXMLError.unexpectedElement(other.name)
        }
        return root.children.filter { $0.name == name }
    }

    private static func child(_ node: XMLNode, index: UInt32, kind: FavoritesChild.Kind) -> FavoritesChild {
        FavoritesChild(
            index: index, name: node.attributes["Name"] ?? "", quickKey: quickKey(node),
            avoided: avoided(node), kind: kind)
    }

    private static func index(_ node: XMLNode) -> UInt32? {
        node.attributes["Index"].flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func quickKey(_ node: XMLNode) -> Int? {
        node.attributes["Q_Key"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func avoided(_ node: XMLNode) -> Bool {
        node.attributes["Avoid"].map { $0.trimmingCharacters(in: .whitespaces) != "Off" } ?? false
    }
}

/// A list's key and a system's key: the address of one `DQK` read.
public struct QuickKeyPair: Hashable, Sendable {
    public var list: Int
    public var system: Int

    public init(list: Int, system: Int) {
        self.list = list
        self.system = system
    }
}

/// The Favorites tree with the quick-key states read from the scanner (`noctule quick-keys`, and the
/// app's quick-keys model). Only a list with a quick key has its systems read (`SQK` is addressed by
/// the list's key), so a list without one has no `systems` here.
public struct QuickKeyTree: Sendable, Equatable {
    public struct SystemNode: Sendable, Equatable {
        public var system: FavoritesSystem
        /// Departments, then sites, in `GLT` order.
        public var children: [FavoritesChild]

        public init(system: FavoritesSystem, children: [FavoritesChild]) {
            self.system = system
            self.children = children
        }
    }

    public struct ListNode: Sendable, Equatable {
        public var list: FavoritesList
        public var systems: [SystemNode]

        public init(list: FavoritesList, systems: [SystemNode]) {
            self.list = list
            self.systems = systems
        }
    }

    /// The lists in `GLT` order.
    public var nodes: [ListNode]
    /// `FQK`.
    public var lists: QuickKeyStates
    /// `SQK` by list key.
    public var systems: [Int: QuickKeyStates]
    /// `DQK` by list and system key.
    public var children: [QuickKeyPair: QuickKeyStates]

    public init(nodes: [ListNode], lists: QuickKeyStates, systems: [Int: QuickKeyStates],
                children: [QuickKeyPair: QuickKeyStates]) {
        self.nodes = nodes
        self.lists = lists
        self.systems = systems
        self.children = children
    }
}
