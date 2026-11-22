// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

/// False in an export without `.git` (a tarball): the checks below read `git ls-files`.
private let hasGitCheckout: Bool = {
    var components = URL(fileURLWithPath: #filePath).standardizedFileURL.pathComponents
    while components.count > 1 {
        components.removeLast()
        let dir = URL(fileURLWithPath: NSString.path(withComponents: components))
        if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
            return FileManager.default.fileExists(atPath: dir.appending(path: ".git").path)
        }
    }
    return false
}()

/// Checks on what the repository tracks, read from `git ls-files` at the repository root.
@Suite(.timeLimit(.minutes(1)), .enabled(if: hasGitCheckout, "no .git directory: the checks read git ls-files")) struct RepositoryHygieneTests {
    static let root: URL? = {
        var components = URL(fileURLWithPath: #filePath).standardizedFileURL.pathComponents
        while components.count > 1 {
            components.removeLast()
            let dir = URL(fileURLWithPath: NSString.path(withComponents: components))
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) { return dir }
        }
        return nil
    }()

    static func trackedPaths(in root: URL) async throws -> [String] {
        let git = try await run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path, "ls-files", "-z"])
        guard git.status == 0 else { throw CocoaError(.fileReadUnknown) }
        return git.stdout.split(separator: "\0").map(String.init)
    }

    @Test func everySourceFileCarriesTheNotice() async throws {
        let root = try #require(Self.root)
        let paths = try await Self.trackedPaths(in: root)
        var offenders: [String] = []
        var checked = 0
        for path in paths where !path.hasPrefix("images/screenshots/") {
            let ext = (path as NSString).pathExtension
            guard ["swift", "sh", "py", "yml", "yaml"].contains(ext) else { continue }
            guard let data = try? Data(contentsOf: root.appending(path: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            checked += 1
            let marker = ext == "swift" ? "// " : "# "
            var lines = text.components(separatedBy: "\n")
            if let first = lines.first, first.hasPrefix("#!") || first.hasPrefix("// swift-tools-version") {
                lines.removeFirst()
            }
            let notice = [marker + "SPDX-License-Identifier: Apache-2.0",
                          marker + "Copyright 2026 Sean Foley and the Noctule Scan contributors"]
            if Array(lines.prefix(2)) != notice { offenders.append(path) }
        }
        #expect(checked > 100, "found only \(checked) source files")
        #expect(offenders.isEmpty, "missing the notice: \(offenders.joined(separator: ", "))")
    }

    @Test func noBrandArtIsTracked() async throws {
        let root = try #require(Self.root)
        let paths = try await Self.trackedPaths(in: root)
        let forbidden = paths.filter { $0.hasPrefix("Resources/AppIcon.icon/") || $0.hasPrefix("packaging/dmg/background/") }
        #expect(forbidden.isEmpty, "brand art is tracked: \(forbidden.joined(separator: ", "))")
        var mentions: [String] = []
        for path in paths where !path.hasPrefix("docs/") {
            guard let data = try? Data(contentsOf: root.appending(path: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            if path == "Tests/NoctuleCLIIntegrationTests/RepositoryHygieneTests.swift" { continue }
            if text.contains("noctule-mark") { mentions.append(path) }
        }
        #expect(mentions.isEmpty, "mentions the brand mark: \(mentions.joined(separator: ", "))")
    }

    /// Session links (and artifact links) are private to their owner; none belongs in a public repository.
    @Test func noClaudeLinksAreTracked() async throws {
        let root = try #require(Self.root)
        let needle = "claude" + ".ai/"
        var offenders: [String] = []
        for path in try await Self.trackedPaths(in: root) {
            guard let data = try? Data(contentsOf: root.appending(path: path)),
                  let text = String(data: data, encoding: .utf8) else { continue }
            if text.contains(needle) { offenders.append(path) }
        }
        #expect(offenders.isEmpty, "links to the assistant's site: \(offenders.joined(separator: ", "))")
    }
}
