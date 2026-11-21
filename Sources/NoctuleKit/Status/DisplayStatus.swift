// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

public enum DisplayStatusError: Error, Equatable {
    case tooFewFields(expected: Int, got: Int)
}

/// The scanner display as returned by `STS`.
public struct DisplayStatus: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var text: String
        public var highlightMask: String
        public var sizeFlag: Character

        public init(text: String, highlightMask: String, sizeFlag: Character) {
            self.text = text
            self.highlightMask = highlightMask
            self.sizeFlag = sizeFlag
        }
    }

    public var lines: [Line]
    public var trailing: [String]

    public init(fields: [String]) throws {
        let flags = Array(fields.first ?? "")
        let expected = 1 + 2 * flags.count
        guard fields.count >= expected else {
            throw DisplayStatusError.tooFewFields(expected: expected, got: fields.count)
        }
        lines = flags.enumerated().map { i, flag in
            Line(text: fields[1 + 2 * i], highlightMask: fields[2 + 2 * i], sizeFlag: flag)
        }
        trailing = Array(fields[expected...])
    }

    /// The last line's text split on runs of spaces, with empty pieces dropped.
    public var softKeyLabels: [String] {
        guard let last = lines.last else { return [] }
        return last.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}
