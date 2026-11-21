// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum XMLNodeError: Error, Equatable {
    case parseFailed
}

/// A minimal element tree: name, attributes, child elements. Character data is ignored
/// because scanner XML carries everything in attributes.
public struct XMLNode: Sendable, Equatable {
    public var name: String
    public var attributes: [String: String]
    public var children: [XMLNode]

    public init(name: String, attributes: [String: String] = [:], children: [XMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    public static func parse(_ data: Data) throws -> XMLNode {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !builder.failed, let root = builder.root else {
            throw XMLNodeError.parseFailed
        }
        return root
    }

    public func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var stack: [XMLNode] = []
    var root: XMLNode?
    var failed = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        if stack.isEmpty, root != nil {
            failed = true
            parser.abortParsing()
            return
        }
        stack.append(XMLNode(name: elementName, attributes: attributeDict))
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let node = stack.popLast() else { return }
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failed = true
    }
}
