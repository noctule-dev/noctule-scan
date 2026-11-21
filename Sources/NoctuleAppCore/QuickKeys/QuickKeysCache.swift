// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// The last Favorites structure read for a station (`Stations/<uuid>/quick-keys.json`, beside the hit
/// log; design `docs/specs/2026-11-18-quick-keys-design.md` §5.4): names, indexes, types, quick-key
/// numbers and avoids of each list's systems, departments and sites. **Never a state**: on/off comes
/// only from reads made since the pop-over opened, so the file has no field for one.
///
/// Versioned JSON (`{"version": 1, "lists": [...]}`), written atomically. As with the settings store, a
/// missing file is no cache; unlike it, so is any other failure (unreadable, undecodable, a version
/// this build doesn't know): the cache is a convenience, and the next full read replaces it.
public enum QuickKeysCache {
    static let version = 1

    private struct File: Codable {
        var version: Int
        var lists: [List]
    }

    private struct List: Codable {
        var index: UInt32
        var systems: [System]
    }

    private struct System: Codable {
        var index: UInt32
        var name: String
        var type: String
        var quickKey: Int?
        var avoided: Bool
        var children: [Child]
    }

    private struct Child: Codable {
        enum Kind: String, Codable { case department, site }
        var index: UInt32
        var name: String
        var kind: Kind
        var quickKey: Int?
        var avoided: Bool
    }

    /// The cached trees by list index, each `.checking` with every state nil; nil when there is no
    /// usable file.
    public static func load(from url: URL) -> [UInt32: QuickKeyListTree]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == version else { return nil }
        var trees: [UInt32: QuickKeyListTree] = [:]
        for list in file.lists {
            let systems = list.systems.map { system in
                QuickKeyListTree.SystemRow(
                    index: system.index, name: system.name, type: system.type, key: system.quickKey,
                    avoided: system.avoided, state: nil,
                    children: system.children.map { child in
                        QuickKeyListTree.ChildRow(
                            index: child.index, name: child.name, kind: child.kind == .site ? .site : .department,
                            key: child.quickKey, avoided: child.avoided, state: nil)
                    })
            }
            trees[list.index] = QuickKeyListTree(systems: systems, freshness: .checking)
        }
        return trees
    }

    /// Writes the structure of `trees` (their states and freshness are left out), creating the
    /// directory if needed.
    public static func save(_ trees: [UInt32: QuickKeyListTree], to url: URL) throws {
        let lists = trees.keys.sorted().map { index in
            List(index: index, systems: (trees[index]?.systems ?? []).map { system in
                System(index: system.index, name: system.name, type: system.type, quickKey: system.key,
                       avoided: system.avoided, children: system.children.map { child in
                           Child(index: child.index, name: child.name, kind: child.kind == .site ? .site : .department,
                                 quickKey: child.key, avoided: child.avoided)
                       })
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: version, lists: lists))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
