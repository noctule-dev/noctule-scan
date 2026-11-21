// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

/// The owner's deny-list of real names and values (system, site, and channel names, frequencies,
/// unit IDs, NAC / Sys ID / WACN values) that must never appear in tracked files. It lives in the
/// git-ignored `config/real-names.txt` (template: `config/real-names.txt.example`), one entry per
/// line; blank lines and `#` comments are ignored. Absent file: the checks are skipped.
enum RealNames {
    /// The repository root: the nearest ancestor of this file that holds `Package.swift`. Walks up
    /// by path components (LESSONS.md: `deletingLastPathComponent()` can run away).
    static let repositoryRoot: URL? = {
        var components = URL(fileURLWithPath: #filePath).standardizedFileURL.pathComponents
        while components.count > 1 {
            components.removeLast()
            let dir = URL(fileURLWithPath: NSString.path(withComponents: components))
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) { return dir }
        }
        return nil
    }()

    static let list: [String]? = {
        guard let root = repositoryRoot,
              let text = try? String(contentsOf: root.appending(path: "config/real-names.txt"), encoding: .utf8)
        else { return nil }
        let entries = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return entries.isEmpty ? nil : entries
    }()

    /// The deny-list entries found in `text`, case-insensitive. A letter at either end of an entry
    /// must not touch another letter (so "LCH" doesn't match "squelchPush"); digits match as
    /// substrings (so "123.4567" still matches " 123.456700MHz").
    static func hits(in text: String, list: [String]) -> [String] {
        let haystack = text.lowercased()
        return list.filter { entry in
            let needle = entry.lowercased()
            var searchRange = haystack.startIndex..<haystack.endIndex
            while let found = haystack.range(of: needle, range: searchRange) {
                let before = found.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: found.lowerBound)]
                let after = found.upperBound == haystack.endIndex ? nil : haystack[found.upperBound]
                let joins: (Character?, Character?) -> Bool = { neighbor, edge in
                    (neighbor?.isLetter ?? false) && (edge?.isLetter ?? false)
                }
                if !joins(before, needle.first), !joins(after, needle.last) { return true }
                searchRange = found.upperBound..<haystack.endIndex
            }
            return false
        }
    }

    /// Every file `git ls-files` lists that decodes as UTF-8 (so `.github/`, `packaging/`, the root
    /// files and the screenshots' text too). `config/` holds the deny-lists themselves and only its
    /// tracked templates are listed. Falls back to walking the usual directories if git fails.
    static func trackedTextFiles(root: URL) -> [URL] {
        if let listed = gitTrackedFiles(root: root) {
            return listed.filter { url in
                guard let data = try? Data(contentsOf: url) else { return false }
                return String(data: data, encoding: .utf8) != nil
            }
        }
        return walkedTextFiles(root: root)
    }

    private static func gitTrackedFiles(root: URL) -> [URL]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "-z"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let paths = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        guard !paths.isEmpty else { return nil }
        return paths.map { root.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func walkedTextFiles(root: URL) -> [URL] {
        let extensions: Set<String> = ["swift", "md", "json", "xml", "txt", "example", "sh", "py", "plist", "strings", "svg"]
        var files: [URL] = ["Package.swift", "AGENTS.md", "LESSONS.md", "README.md", "ACKNOWLEDGMENTS.md",
                            "CLAUDE.md", ".gitignore", "docs/uniden/README.md"]
            .map { root.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for directory in ["Sources", "Tests", "docs/specs", "scripts", "Resources"] {
            guard let enumerator = FileManager.default.enumerator(
                at: root.appending(path: directory), includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where extensions.contains(url.pathExtension) {
                files.append(url)
            }
        }
        return files
    }
}

@Suite(.timeLimit(.minutes(1))) struct RealNamesTests {
    @Test(.enabled(if: RealNames.list != nil, "config/real-names.txt is absent"))
    func noRealNamesInTrackedFiles() throws {
        let list = try #require(RealNames.list)
        let root = try #require(RealNames.repositoryRoot)
        let files = RealNames.trackedTextFiles(root: root)
        #expect(files.count > 50, "found only \(files.count) files under \(root.path)")
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let hits = RealNames.hits(in: String(decoding: data, as: UTF8.self), list: list)
            #expect(hits.isEmpty, "\(file.path.dropFirst(root.path.count + 1)) contains \(hits)")
        }
    }

    /// The scan covers the app bundle's files and the build script too (final review M2).
    @Test func scanCoversScriptsAndResources() throws {
        let root = try #require(RealNames.repositoryRoot)
        let files = Set(RealNames.trackedTextFiles(root: root).map { $0.standardizedFileURL.path })
        for path in ["scripts/build-app.sh", "Resources/Info.plist", "ACKNOWLEDGMENTS.md", "docs/uniden/README.md",
                     "Resources/Placeholder/AppIcon.icon/icon.json", "Resources/Placeholder/AppIcon.icon/Assets/01-signal.svg",
                     "scripts/compile-app-icon.sh"] {
            #expect(files.contains(root.appending(path: path).standardizedFileURL.path), "\(path) isn't scanned")
        }
    }

    @Test func hitsIgnoreCaseAndLetterJoins() {
        let list = ["LCH", "Example County", "123.4567", "9876"]
        #expect(RealNames.hits(in: "case squelchPush = \"Q\"", list: list).isEmpty)
        #expect(RealNames.hits(in: "the lch unit", list: list) == ["LCH"])
        #expect(RealNames.hits(in: "EXAMPLE COUNTY P25", list: list) == ["Example County"])
        #expect(RealNames.hits(in: "Example Countywide", list: list).isEmpty)
        #expect(RealNames.hits(in: "Freq=\" 123.456700MHz\"", list: list) == ["123.4567"])
        #expect(RealNames.hits(in: "UID:9876\"", list: list) == ["9876"])
    }
}
