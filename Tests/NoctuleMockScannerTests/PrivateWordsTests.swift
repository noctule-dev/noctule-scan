// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

/// Words that must never appear in tracked files (internal names, private hosts, personal paths).
/// They live in the git-ignored `config/private-words.txt` (template: `config/private-words.txt.example`),
/// one per line; blank lines and `#` comments are ignored. Absent file: the check is skipped.
/// Matching and file coverage are `RealNames`'s.
enum PrivateWords {
    static let list: [String]? = {
        guard let root = RealNames.repositoryRoot,
              let text = try? String(contentsOf: root.appending(path: "config/private-words.txt"), encoding: .utf8)
        else { return nil }
        let entries = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return entries.isEmpty ? nil : entries
    }()
}

@Suite(.timeLimit(.minutes(1))) struct PrivateWordsTests {
    @Test(.enabled(if: PrivateWords.list != nil, "config/private-words.txt is absent"))
    func noPrivateWordsInTrackedFiles() throws {
        let list = try #require(PrivateWords.list)
        let root = try #require(RealNames.repositoryRoot)
        let files = RealNames.trackedTextFiles(root: root)
        #expect(files.count > 50, "found only \(files.count) files under \(root.path)")
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let count = RealNames.hits(in: String(decoding: data, as: UTF8.self), list: list).count
            // Report the count, never the words: the failure output must not repeat them (so the
            // expectation is on a number, not on the hits array, which Swift Testing would print).
            #expect(count == 0, "\(file.path.dropFirst(root.path.count + 1)) contains \(count) private word(s)")
        }
    }
}
