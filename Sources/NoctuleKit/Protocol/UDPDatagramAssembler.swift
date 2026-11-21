// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Turns raw UDP datagrams from the scanner into `ScannerResponse` values, reassembling
/// XML documents the scanner splits across several datagrams (`XMLFragmentSequences`). Never throws: anything
/// malformed, out of order, or oversized is dropped.
public struct UDPDatagramAssembler {
    private static let xmlMarker = ",<XML>,"
    private static let bareRoots = ["<?xml", "<ScannerInfo", "<GLT", "<MSI", "<AST"]

    private let now: @Sendable () -> ContinuousClock.Instant
    private let maxDocumentBytes: Int
    private var expectedCommand: String?
    private var sequences: XMLFragmentSequences

    public init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        maxSequenceAge: Duration = .seconds(10),
        maxDocumentBytes: Int = 4_194_304,
        maxFragments: Int = 256
    ) {
        self.now = now
        self.maxDocumentBytes = maxDocumentBytes
        sequences = XMLFragmentSequences(maxAge: maxSequenceAge, maxBytes: maxDocumentBytes, maxFragments: maxFragments)
    }

    public mutating func expectXML(for command: String) {
        expectedCommand = command.uppercased()
    }

    public mutating func feed(_ datagram: Data) -> [ScannerResponse] {
        let current = now()
        _ = sequences.dropExpired(at: current)

        let text = String(scannerBytes: datagram)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let marker = trimmed.range(of: Self.xmlMarker) {
            let command = trimmed[..<marker.lowerBound].uppercased()
            let payload = trimmed[marker.upperBound...]
            if !command.isEmpty, !command.contains(where: \.isNewline), !command.contains("<") {
                return handleXML(String(payload), command: command, at: current)
            }
        }
        if Self.bareRoots.contains(where: { trimmed.hasPrefix($0) }) {
            guard let command = expectedCommand else { return [] }
            return handleXML(trimmed, command: command, at: current)
        }
        return text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .compactMap { ResponseLineParser.parse(String($0)) }
    }

    private mutating func handleXML(
        _ payload: String, command: String, at current: ContinuousClock.Instant
    ) -> [ScannerResponse] {
        let xml = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = xml.utf8.count
        guard size <= maxDocumentBytes, let fragment = try? XMLNode.parse(Data(xml.utf8)) else {
            sequences.drop(command)
            return []
        }
        guard case .document(let root) = sequences.add(fragment, bytes: size, for: command, at: current) else {
            return []
        }
        return [.xml(command: command, root: root)]
    }
}
