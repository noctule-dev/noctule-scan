// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors
import CryptoKit
import Foundation
import Testing

// The license, notices and community files a public repository carries (Plan 21, task 7).

private func repositoryText(_ path: String) throws -> String {
    try String(contentsOf: repositoryFile(path), encoding: .utf8)
}

@Suite(.timeLimit(.minutes(1))) struct RepositoryFilesTests {
    @Test func licenseIsApache20() throws {
        let data = try Data(contentsOf: repositoryFile("LICENSE"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // SHA-256 of https://www.apache.org/licenses/LICENSE-2.0.txt, downloaded 2026-11-20.
        #expect(hash == "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30")
    }

    @Test func noticeNamesTheHolderAndTheExceptions() throws {
        let notice = try repositoryText("NOTICE")
        for needle in ["Copyright 2026 Sean Foley", "TRADEMARKS.md", "images/screenshots", "ACKNOWLEDGMENTS.md"] {
            #expect(notice.contains(needle), "NOTICE lacks \(needle)")
        }
    }

    @Test func screenshotsAreExcluded() throws {
        let text = try repositoryText("images/screenshots/LICENSE.md")
        for needle in ["not licensed under the Apache License", "Sean Foley", "TRADEMARKS.md"] {
            #expect(text.contains(needle), "images/screenshots/LICENSE.md lacks \(needle)")
        }
    }

    @Test func communityFilesExist() throws {
        for path in ["NOTICE", "TRADEMARKS.md", "CODE_OF_CONDUCT.md", "SECURITY.md",
                     "images/screenshots/LICENSE.md",
                     ".github/ISSUE_TEMPLATE/bug_report.yml", ".github/ISSUE_TEMPLATE/feature_request.yml",
                     ".github/ISSUE_TEMPLATE/config.yml", ".github/pull_request_template.md"] {
            let data = try Data(contentsOf: repositoryFile(path))
            #expect(!data.isEmpty, "\(path) is empty")
        }
        let conduct = try repositoryText("CODE_OF_CONDUCT.md")
        for needle in ["Contributor Covenant", "version 2.1", "info@noctule.app"] {
            #expect(conduct.contains(needle), "CODE_OF_CONDUCT.md lacks \(needle)")
        }
        let security = try repositoryText("SECURITY.md")
        for needle in ["private vulnerability reporting", "no authentication"] {
            #expect(security.contains(needle), "SECURITY.md lacks \(needle)")
        }
    }

    @Test func issueTemplatesAreConfigured() throws {
        let config = try repositoryText(".github/ISSUE_TEMPLATE/config.yml")
        #expect(config.contains("blank_issues_enabled: false"))
        #expect(config.contains("SECURITY.md"))
        // Questions and ideas go to Discussions, not issues.
        for category in ["discussions/categories/q-a", "discussions/categories/ideas"] {
            #expect(config.contains("https://github.com/noctule-dev/noctule-scan/\(category)"), "config.yml lacks \(category)")
        }
        let contributing = try repositoryText("CONTRIBUTING.md")
        #expect(contributing.contains("https://github.com/noctule-dev/noctule-scan/discussions"), "CONTRIBUTING.md doesn't point at Discussions")
    }

    @Test func readmeHasTheBadgesAndPointers() throws {
        let readme = try repositoryText("README.md")
        // The badges come first, in this order.
        let badges = [
            "https://github.com/noctule-dev/noctule-scan/actions/workflows/ci.yml/badge.svg?branch=main",
            "img.shields.io/github/license/noctule-dev/noctule-scan",
            "img.shields.io/github/v/release/noctule-dev/noctule-scan?include_prereleases",
            "img.shields.io/badge/Swift-6.4-",
            "img.shields.io/badge/Xcode-27.2-",
            "img.shields.io/badge/platform-macOS-",
        ]
        var from = readme.startIndex
        for badge in badges {
            let found = readme.range(of: badge, range: from..<readme.endIndex)
            #expect(found != nil, "README lacks the badge \(badge), or has it out of order")
            if let found { from = found.upperBound }
        }
        for link in ["CONTRIBUTING.md", "TRADEMARKS.md", "LICENSE", "docs/specs/README.md"] {
            #expect(readme.contains("](\(link))"), "README doesn't link \(link)")
        }
        let shots = readme.components(separatedBy: "images/screenshots/").dropFirst()
            .map { String($0.prefix { !")\" ".contains($0) }) }
        #expect(!shots.isEmpty)
        for shot in shots {
            #expect(FileManager.default.fileExists(atPath: try repositoryFile("images/screenshots/" + shot).path),
                    "README references the missing images/screenshots/\(shot)")
        }
        #expect(readme.contains("not affiliated with or endorsed by Uniden"))
    }
}
