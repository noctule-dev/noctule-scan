// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum MenuScreenError: Error, Equatable {
    case unexpectedRoot(String)
}

/// Typed view of the `<MSI>` document the `MSI` command answers: the whole current menu screen
/// (every item, not only the nine on the radio's display), or a `TypeError` when there is no
/// menu the protocol can describe.
public struct MenuScreen: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case select, input, location, error, other(String) }

    public struct Item: Sendable, Equatable, Identifiable {
        public var index: Int
        public var name: String
        public var value: String?
        public var id: Int { index }

        public init(index: Int, name: String, value: String? = nil) {
            self.index = index
            self.name = name
            self.value = value
        }
    }

    public struct InputRules: Sendable, Equatable {
        public var maxLength: Int?
        public var allowedCharacters: String?
        public var addedInformation: String?

        public init(maxLength: Int? = nil, allowedCharacters: String? = nil, addedInformation: String? = nil) {
            self.maxLength = maxLength
            self.allowedCharacters = allowedCharacters
            self.addedInformation = addedInformation
        }
    }

    public var title: String?
    public var menuIndex: String?
    public var kind: Kind
    /// The root `Value`. Stale on lists after `MSV` (the scanner keeps the first row's text), so never used for lists.
    public var value: String?
    public var selectedIndex: Int?
    /// `MenuItem` children in order. The scanner omits items it can't remote-control, so indexes can skip.
    public var items: [Item]
    public var input: InputRules?
    public var errorText: String?

    public init(xml root: XMLNode) throws {
        guard root.name == "MSI" else { throw MenuScreenError.unexpectedRoot(root.name) }
        let a = root.attributes
        title = a["Name"]
        menuIndex = a["Index"]
        kind = switch a["MenuType"] {
        case "TypeSelect": .select
        case "TypeInput": .input
        case "TypeLocation": .location
        case "TypeError": .error
        case let other: .other(other ?? "")
        }
        value = a["Value"]
        selectedIndex = a["Selected"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        items = root.children.filter { $0.name == "MenuItem" }.compactMap { node in
            guard let index = node.attributes["Index"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
                return nil
            }
            return Item(index: index, name: node.attributes["Name"] ?? "", value: node.attributes["Value"])
        }
        input = root.child("MenuInput").map { node in
            InputRules(
                maxLength: node.attributes["MaxLength"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                allowedCharacters: node.attributes["EnableKeys"],
                addedInformation: node.attributes["AddedInformation"])
        }
        errorText = root.child("MenuErrorMsg")?.attributes["Text"]
    }
}
