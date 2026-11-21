// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// Puts together XML documents the scanner sends in numbered pieces, for both assemblers: over the
/// network a document split across datagrams, over serial a `GLT` reply split into pages (quick-keys
/// design §3.1). A piece ends with `<Footer No="n" EOT="0|1"/>` (or `Foot`): `No="1"` starts a
/// sequence for its command, each next number continues it, and `EOT="1"` completes it as one
/// document with every piece's children and no footer. Sequences are per command, so a push or
/// another reply between two pieces leaves them alone. A document with no footer is whole as it is.
struct XMLFragmentSequences {
    enum Outcome: Equatable {
        /// A whole document: one with no footer, or a sequence's last piece with the rest before it.
        case document(XMLNode)
        /// A piece kept until the rest arrives.
        case pending
        /// The piece, and the command's open sequence, were dropped; why.
        case dropped(String)
    }

    private struct Sequence {
        var root: XMLNode
        var nextNumber: Int
        var fragments: Int
        var bytes: Int
        var started: ContinuousClock.Instant
    }

    private let maxAge: Duration
    private let maxBytes: Int
    private let maxFragments: Int
    private var sequences: [String: Sequence] = [:]

    init(maxAge: Duration, maxBytes: Int, maxFragments: Int) {
        self.maxAge = maxAge
        self.maxBytes = maxBytes
        self.maxFragments = maxFragments
    }

    /// Drops every sequence started more than `maxAge` before `now`, and returns their commands.
    mutating func dropExpired(at now: ContinuousClock.Instant) -> [String] {
        let expired = sequences.filter { now - $0.value.started > maxAge }.keys.sorted()
        for command in expired { sequences[command] = nil }
        return expired
    }

    /// Drops `command`'s open sequence, if any (a piece of it that couldn't be read); true if there was one.
    @discardableResult
    mutating func drop(_ command: String) -> Bool {
        sequences.removeValue(forKey: command) != nil
    }

    /// Takes one parsed document for `command`, `bytes` long.
    mutating func add(_ fragment: XMLNode, bytes: Int, for command: String,
                      at now: ContinuousClock.Instant) -> Outcome {
        let footerIndex = fragment.children.firstIndex { $0.name == "Footer" || $0.name == "Foot" }
        guard let footerIndex else { return .document(fragment) }

        let footer = fragment.children[footerIndex]
        guard let number = footer.attributes["No"].flatMap({ Int($0) }), number > 0 else {
            sequences[command] = nil
            return .dropped("a footer with no page number")
        }
        var body = fragment
        body.children.remove(at: footerIndex)
        let isLast = footer.attributes["EOT"] == "1"

        var sequence: Sequence
        if number == 1 {
            sequence = Sequence(root: body, nextNumber: 2, fragments: 1, bytes: bytes, started: now)
        } else {
            guard var existing = sequences[command], existing.nextNumber == number else {
                let expected = sequences[command].map { "page \($0.nextNumber)" } ?? "page 1"
                sequences[command] = nil
                return .dropped("page \(number) where \(expected) was due")
            }
            existing.root.children.append(contentsOf: body.children)
            existing.nextNumber += 1
            existing.fragments += 1
            existing.bytes += bytes
            sequence = existing
        }

        guard sequence.fragments <= maxFragments else {
            sequences[command] = nil
            return .dropped("too many (over \(maxFragments) pages)")
        }
        guard sequence.bytes <= maxBytes else {
            sequences[command] = nil
            return .dropped("too big (over \(maxBytes) bytes)")
        }
        if isLast {
            sequences[command] = nil
            return .document(sequence.root)
        }
        sequences[command] = sequence
        return .pending
    }
}
