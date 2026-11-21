// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import NoctuleKit

/// Reads the scanner's whole Favorites tree and its quick-key states, with reads only (`GLT`, `FQK`,
/// `SQK`, `DQK`; never a set). Design `docs/specs/2026-11-18-quick-keys-design.md` §5.3.
public enum QuickKeyTreeReader {
    public static func read(using client: ScannerClient) async throws -> QuickKeyTree {
        let lists = try await client.favoritesLists()
        let listStates = try await client.listKeyStates()
        var systemStates: [Int: QuickKeyStates] = [:]
        var childStates: [QuickKeyPair: QuickKeyStates] = [:]
        var nodes: [QuickKeyTree.ListNode] = []
        for list in lists {
            // `SQK` is addressed by the list's key: a list without one can't be read.
            guard let listKey = list.quickKey else {
                nodes.append(.init(list: list, systems: []))
                continue
            }
            if systemStates[listKey] == nil {
                systemStates[listKey] = try await client.systemKeyStates(listKey: listKey)
            }
            var systemNodes: [QuickKeyTree.SystemNode] = []
            for system in try await client.favoritesSystems(inList: list.index) {
                var children = try await client.favoritesDepartments(inSystem: system.index)
                if !system.isConventional {
                    children += try await client.favoritesSites(inSystem: system.index)
                }
                if let systemKey = system.quickKey {
                    let pair = QuickKeyPair(list: listKey, system: systemKey)
                    if childStates[pair] == nil {
                        childStates[pair] = try await client.departmentKeyStates(listKey: listKey, systemKey: systemKey)
                    }
                }
                systemNodes.append(.init(system: system, children: children))
            }
            nodes.append(.init(list: list, systems: systemNodes))
        }
        return QuickKeyTree(nodes: nodes, lists: listStates, systems: systemStates, children: childStates)
    }
}
