// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors
import Foundation
import Testing

// The pull-request build (`.github/workflows/ci.yml`), the DCO check (`scripts/check-dco.sh`) and the
// rules that keep every workflow safe in a public repository (Plan 21, task 6).

private func isPinned(_ line: String) -> Bool {
    line.firstMatch(of: #/@[0-9a-f]{40}( |$)/#) != nil
}

private func workflowText(_ name: String) throws -> String {
    try String(contentsOf: repositoryFile(".github/workflows/\(name)"), encoding: .utf8)
}

/// The non-comment, non-blank lines of a workflow.
private func codeLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter {
        let t = $0.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.hasPrefix("#")
    }
}

/// The `run:` commands of the steps whose `name:` starts with `prefix` (single-line `run:` only).
private func runCommand(in text: String, stepNamed prefix: String) -> String? {
    let lines = text.components(separatedBy: "\n")
    guard let at = lines.firstIndex(where: { $0.hasPrefix("      - name: \(prefix)") }) else { return nil }
    for line in lines[(at + 1)...] {
        if line.hasPrefix("      - ") { return nil }
        if line.hasPrefix("        run: ") { return String(line.dropFirst("        run: ".count)) }
    }
    return nil
}

// One test at a time: each runs tools (IntegrationSupport.swift, "Waiting in these tests").
@Suite(.serialized, .timeLimit(.minutes(2))) struct CIWorkflowTests {
    // MARK: check-dco.sh

    private struct Repo {
        let dir: URL
        init() async throws {
            dir = try temporaryDirectory()
            try await git("init", "-q", "-b", "main")
            try await git("config", "user.name", "Ada Tester")
            try await git("config", "user.email", "ada@example.test")
            try await git("config", "commit.gpgsign", "false")
            try await commit("base", signOff: true)
        }
        @discardableResult
        func git(_ args: String...) async throws -> String {
            let r = try await run(tool("git"), args, environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"], currentDirectory: dir)
            try #require(r.status == 0, "git \(args) failed: \(r.stderr)")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func commit(_ subject: String, signOff: Bool, trailer: String? = nil, body: String? = nil, file: String = "f.txt") async throws {
            try "\(subject) \(UUID())".write(to: dir.appending(path: file), atomically: true, encoding: .utf8)
            try await git("add", file)
            var message = subject
            if let body { message += "\n\n" + body }
            if signOff { message += "\n\nSigned-off-by: Ada Tester <ada@example.test>" }
            if let trailer { message += "\n\n" + trailer }
            try await git("commit", "-q", "-m", message)
        }
        func dco(_ base: String, _ head: String = "HEAD") async throws -> (status: Int32, stdout: String, stderr: String) {
            try await run(repositoryFile("scripts/check-dco.sh"), [base, head], currentDirectory: dir)
        }
        /// Commits a file at each path (making its directories), and returns the new commit.
        @discardableResult
        func commitFiles(_ paths: [String], _ subject: String = "files") throws -> String {
            for path in paths {
                let url = dir.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "\(path) \(UUID())".write(to: url, atomically: true, encoding: .utf8)
                try git("add", path)
            }
            try git("commit", "-q", "-m", subject)
            return try git("rev-parse", "HEAD")
        }
        func ciChanges(_ args: String...) throws -> (status: Int32, stdout: String, stderr: String) {
            try run(repositoryFile("scripts/ci-changes.sh"), args, currentDirectory: dir)
        }
        /// What `ci-changes.sh` says for a commit that adds a file at each of `paths`.
        func scope(adding paths: [String]) throws -> String {
            let base = try git("rev-parse", "HEAD")
            try commitFiles(paths)
            let r = try ciChanges(base, "HEAD")
            try #require(r.status == 0, "\(r)")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func dcoAcceptsSignedCommits() async throws {
        let repo = try await Repo()
        let base = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("one", signOff: true)
        try await repo.commit("two", signOff: true)
        let r = try await repo.dco(base)
        #expect(r.status == 0, "\(r)")
        #expect(r.stdout.contains("dco: 2 commits signed off"), "\(r.stdout)")
    }

    @Test func dcoRejectsAMissingSignOff() async throws {
        let repo = try await Repo()
        let base = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("signed", signOff: true)
        try await repo.commit("unsigned change", signOff: false)
        let r = try await repo.dco(base)
        #expect(r.status == 1, "\(r)")
        #expect(r.stdout.contains("unsigned change: no Signed-off-by for Ada Tester <ada@example.test>"), "\(r.stdout)")
        #expect(!r.stdout.contains("signed off"), "\(r.stdout)")
    }

    @Test func dcoRejectsAMismatchedSignOff() async throws {
        let repo = try await Repo()
        let base = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("other email", signOff: false, trailer: "Signed-off-by: Ada Tester <someone-else@example.test>")
        let r = try await repo.dco(base)
        #expect(r.status == 1, "\(r)")
        #expect(r.stdout.contains("other email: no Signed-off-by for Ada Tester <ada@example.test>"), "\(r.stdout)")
    }

    @Test func dcoRejectsTheRightEmailUnderAnotherName() async throws {
        let repo = try await Repo()
        let base = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("wrong name", signOff: false, trailer: "Signed-off-by: Someone Else <ada@example.test>")
        let r = try await repo.dco(base)
        #expect(r.status == 1, "\(r)")
        #expect(r.stdout.contains("wrong name: no Signed-off-by for Ada Tester <ada@example.test>"), "\(r.stdout)")
    }

    @Test func dcoAcceptsANameWithSpacesAndAPlusInTheEmail() async throws {
        let repo = try await Repo()
        try await repo.git("config", "user.name", "Ada Q. Lovelace")
        try await repo.git("config", "user.email", "ada+dev@example.test")
        let base = try await repo.git("rev-parse", "HEAD")
        try await repo.commit("plus address", signOff: false, trailer: "Signed-off-by: Ada Q. Lovelace <ada+dev@example.test>")
        let r = try await repo.dco(base)
        #expect(r.status == 0, "\(r)")
        #expect(r.stdout.contains("dco: 1 commits signed off"), "\(r.stdout)")
    }

    @Test func dcoIgnoresASignOffInTheBodyText() async throws {
        let repo = try await Repo()
        let base = try await repo.git("rev-parse", "HEAD")
        // A sign-off line that is not in the trailer block (prose around it) doesn't count.
        try await repo.commit("body only", signOff: false, body: "Some prose.\nMore prose.\nSigned-off-by: Ada Tester <ada@example.test>\nand then more prose.\nAnd more.\nAnd more still.")
        let r = try await repo.dco(base)
        #expect(r.status == 1, "\(r)")
    }

    @Test func dcoSkipsMergeCommits() async throws {
        let repo = try await Repo()
        let base = try await repo.git("rev-parse", "HEAD")
        try await repo.git("checkout", "-q", "-b", "side")
        try await repo.commit("side work", signOff: true, file: "side.txt")
        try await repo.git("checkout", "-q", "main")
        try await repo.commit("main work", signOff: true)
        // An unsigned merge commit.
        try await repo.git("merge", "-q", "--no-ff", "-m", "Merge side into main", "side")
        let r = try await repo.dco(base)
        #expect(r.status == 0, "\(r)")
        #expect(r.stdout.contains("dco: 2 commits signed off"), "\(r.stdout)")
    }

    @Test func dcoUsageErrors() async throws {
        let repo = try await Repo()
        let none = try await run(repositoryFile("scripts/check-dco.sh"), [], currentDirectory: repo.dir)
        #expect(none.status == 2, "\(none)")
        let one = try await run(repositoryFile("scripts/check-dco.sh"), ["HEAD"], currentDirectory: repo.dir)
        #expect(one.status == 2, "\(one)")
        let three = try await run(repositoryFile("scripts/check-dco.sh"), ["a", "b", "c"], currentDirectory: repo.dir)
        #expect(three.status == 2, "\(three)")
    }

    // MARK: ci-changes.sh

    @Test(arguments: [
        ["README.md"], ["docs/specs/x.md"], ["docs/uniden/README.txt"], ["images/screenshots/a.png"], ["LICENSE"], ["NOTICE"],
        ["README.md", "docs/a.md", "CONTRIBUTING.md"],
    ]) func ciChangesCallsDocumentationDocs(paths: [String]) throws {
        #expect(try Repo().scope(adding: paths) == "docs")
    }

    @Test(arguments: [
        ["Sources/X/a.swift"], ["README.md", "Sources/X/a.swift"], ["Sources/X/notes.md"], ["Tests/X/fixture.md"], ["Resources/x.md"],
        [".github/workflows/ci.yml"], ["scripts/x.sh"], ["packaging/x.sh"], ["Package.swift"], ["docs/a.md", "Package.swift"],
        ["config/x.env.example"], ["README.txt"],
        ["sources/X/notes.md"], ["TESTS/x.md"], ["tests/X/fixture.md"], ["Resources/x.md"], ["resources/x.md"], ["SOURCES/X/n.md"],
        ["Package.swift", "README.md"], [".github/workflows/ci.yml", "CONTRIBUTING.md"],
    ]) func ciChangesCallsEverythingElseCode(paths: [String]) throws {
        #expect(try Repo().scope(adding: paths) == "code")
    }

    @Test func ciChangesCountsAFileMovedIntoDocsAsCode() throws {
        let repo = try Repo()
        try repo.commitFiles(["Sources/X/a.md"])
        let base = try repo.git("rev-parse", "HEAD")
        try FileManager.default.createDirectory(at: repo.dir.appending(path: "docs"), withIntermediateDirectories: true)
        try repo.git("mv", "Sources/X/a.md", "docs/a.md")
        try repo.git("commit", "-q", "-m", "move")
        let r = try repo.ciChanges(base, "HEAD")
        #expect(r.status == 0, "\(r)")
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "code", "\(r.stdout)")
    }

    @Test func ciChangesCallsAnEmptyDiffCode() throws {
        let repo = try Repo()
        let r = try repo.ciChanges("HEAD", "HEAD")
        #expect(r.status == 0, "\(r)")
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "code", "\(r.stdout)")
    }

    @Test func ciChangesComparesFromTheMergeBase() throws {
        // As a pull request shows it: what the branch changed, not what main did meanwhile.
        let repo = try Repo()
        try repo.git("checkout", "-q", "-b", "side")
        try repo.commitFiles(["README.md"])
        try repo.git("checkout", "-q", "main")
        try repo.commitFiles(["Sources/X/a.swift"])
        let r = try repo.ciChanges("main", "side")
        #expect(r.status == 0, "\(r)")
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "docs", "\(r.stdout)")
    }

    @Test func ciChangesUsageAndUnknownRevisions() throws {
        let repo = try Repo()
        let none = try repo.ciChanges()
        #expect(none.status == 2 && none.stderr.contains("usage:"), "\(none)")
        let one = try repo.ciChanges("HEAD")
        #expect(one.status == 2 && one.stderr.contains("usage:"), "\(one)")
        let three = try repo.ciChanges("a", "b", "c")
        #expect(three.status == 2 && three.stderr.contains("usage:"), "\(three)")
        let unknown = try repo.ciChanges("no-such-revision", "HEAD")
        #expect(unknown.status == 2, "\(unknown)")
        #expect(unknown.stderr.contains("ci-changes: can't compare no-such-revision and HEAD"), "\(unknown.stderr)")
        #expect(unknown.stdout.isEmpty, "\(unknown.stdout)")
    }

    // MARK: ci.yml

    @Test func ciRunsOnPushesToMainAndPullRequests() throws {
        let text = try workflowText("ci.yml")
        let on = text.components(separatedBy: "\n").drop { $0 != "on:" }.dropFirst().prefix { $0.isEmpty || $0.hasPrefix(" ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(on == ["push:", "branches: [main]", "pull_request:"], "\(on)")
    }

    @Test func ciIsReadOnlyAndSecretless() throws {
        let text = try workflowText("ci.yml")
        let code = codeLines(text)
        let at = try #require(code.firstIndex(of: "permissions:"), "no top-level permissions")
        #expect(code[at + 1] == "  contents: read")
        #expect(code[at + 2].hasPrefix(" ") == false, "permissions must hold contents: read only: \(code[at + 2])")
        for word in ["secrets.", "environment:", "pull_request_target", "workflow_run", "BRANDING_DEPLOY_KEY"] {
            #expect(!code.contains { $0.contains(word) }, "ci.yml mentions \(word)")
        }
        #expect(!code.contains { $0.contains("repository:") }, "ci.yml checks out another repository")
        let concurrency = code.drop { $0 != "concurrency:" }.prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(concurrency == ["concurrency:", "group: ci-${{ github.ref }}", "cancel-in-progress: ${{ github.event_name == 'pull_request' }}"], "\(concurrency)")
    }

    @Test func ciRunsOnTheReleaseRunner() throws {
        let code = codeLines(try workflowText("ci.yml"))
        for line in ["    runs-on: xcode-27-xlarge", "    timeout-minutes: 120", "      NOCTULE_NO_USB_DETECTION: \"1\"",
                     "      NOCTULE_CI_RUNNER: \"1\"", "      NOCTULE_PYTHON: /opt/homebrew/bin/python3"] {
            #expect(code.contains(line), "missing \(line)")
        }
        #expect(code.contains { $0.contains("sudo xcode-select -s /Applications/Xcode_27.2.app") })
        #expect(code.contains { $0.contains("run: swift build --build-tests") })
        #expect(code.contains { $0.contains("xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build") })
        let build = try #require(runCommand(in: try workflowText("ci.yml"), stepNamed: "Build the app"))
        #expect(build == "scripts/build-app.sh")
        #expect(code.contains("          NOCTULE_BRANDING_DIR: \"\""), "the app build must name the placeholder art")
    }

    @Test func ciAndReleaseUseTheSameRunner() throws {
        func runner(_ name: String) throws -> String {
            let line = try #require(codeLines(try workflowText(name)).first { $0.hasPrefix("    runs-on:") }, "\(name) has no runs-on")
            return line.trimmingCharacters(in: .whitespaces)
        }
        let ci = try runner("ci.yml"), release = try runner("release.yml")
        #expect(ci == "runs-on: xcode-27-xlarge", "\(ci)")
        #expect(release == ci, "ci.yml and release.yml must use the same runner")
    }

    @Test func ciTestsAsTheReleaseJobDoes() throws {
        let ci = try workflowText("ci.yml"), release = try workflowText("release.yml")
        for name in ["Test (parallel)", "Test (timing-sensitive suites, one at a time)"] {
            let a = try #require(runCommand(in: ci, stepNamed: name), "ci.yml has no step \(name)")
            let b = try #require(runCommand(in: release, stepNamed: name), "release.yml has no step \(name)")
            #expect(a == b)
        }
    }

    @Test func ciChecksTheDCOOnlyOnPullRequests() throws {
        let text = try workflowText("ci.yml")
        let lines = text.components(separatedBy: "\n")
        let at = try #require(lines.firstIndex { $0.contains("scripts/check-dco.sh") })
        #expect(lines[at].contains("\"${{ github.event.pull_request.base.sha }}\" \"${{ github.event.pull_request.head.sha }}\""), "\(lines[at])")
        let stepStart = try #require(lines[...at].lastIndex { $0.hasPrefix("      - ") })
        let step = lines[stepStart...at]
        #expect(step.contains("        if: github.event_name == 'pull_request'"), "\(step)")
    }

    @Test func ciChecksOutWithFullHistoryAndNoCredentials() throws {
        let code = codeLines(try workflowText("ci.yml"))
        #expect(code.contains("          fetch-depth: 0"))
        #expect(code.contains("          persist-credentials: false"))
    }

    @Test func ciActionsArePinned() throws {
        try expectPinned("ci.yml")
    }

    // MARK: the documentation fast path

    /// The step starting at the line `      - name: <prefix>…`, through the line before the next step.
    private func step(_ prefix: String) throws -> [String] {
        let lines = try workflowText("ci.yml").components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("      - name: \(prefix)") }, "no step \(prefix)")
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("      - ") } ?? lines.endIndex
        return Array(lines[start..<end])
    }

    private func stepIndex(_ prefix: String) throws -> Int {
        try #require(try workflowText("ci.yml").components(separatedBy: "\n").filter { $0.hasPrefix("      - name: ") }
            .firstIndex { $0.hasPrefix("      - name: \(prefix)") }, "no step \(prefix)")
    }

    @Test func ciClassifiesPullRequestsAfterTheDCOStep() throws {
        let s = try step("Classify the change")
        #expect(s.contains("        id: changes"), "\(s)")
        #expect(s.contains("        if: github.event_name == 'pull_request'"), "\(s)")
        // Assign first, then write: under the runner's `bash -e` a failing script stops the step.
        #expect(s.contains("        run: |"), "\(s)")
        #expect(s.contains(#"          scope=$(scripts/ci-changes.sh "${{ github.event.pull_request.base.sha }}" "${{ github.event.pull_request.head.sha }}")"#), "\(s)")
        #expect(s.contains(#"          echo "scope=$scope" >> "$GITHUB_OUTPUT""#), "\(s)")
        #expect(s.filter { $0.hasPrefix("          ") }.count == 2, "the run block must be exactly the two lines: \(s)")
        let dco = try stepIndex("Check the sign-offs"), classify = try stepIndex("Classify the change"), build = try stepIndex("Build the tests")
        #expect(dco < classify && classify < build, "\(dco) \(classify) \(build)")
    }

    @Test func ciRunsOnlyTheRepositorySuitesForDocumentation() throws {
        let s = try step("Test (documentation checks)")
        #expect(s.contains("        if: steps.changes.outputs.scope == 'docs'"), "\(s)")
        #expect(s.contains("        timeout-minutes: 10"), "\(s)")
        #expect(s.contains(#"        run: swift test --skip-build --filter "RepositoryFilesTests|RepositoryHygieneTests|CIWorkflowTests|PrivateWordsTests|RealNamesTests|InfoPlistTests|PlaceholderBackgroundTests""#), "\(s)")
        let docs = try stepIndex("Test (documentation checks)"), build = try stepIndex("Build the tests")
        #expect(build < docs)
    }

    @Test func ciSkipsTheFullStepsForDocumentation() throws {
        for name in ["Test (parallel)", "Test (timing-sensitive suites, one at a time)", "Build the app", "Check the shared code builds for iOS"] {
            #expect(try step(name).contains("        if: steps.changes.outputs.scope != 'docs'"), "\(name)")
        }
        for name in ["Check out the code", "Check the sign-offs", "Select Xcode", "Build the tests"] {
            #expect(!(try step(name).contains { $0.contains("steps.changes") }), "\(name) must not depend on the scope")
        }
    }

    @Test func ciStaysOneJobNamedBuildWithNoPathFilter() throws {
        let text = try workflowText("ci.yml")
        let code = codeLines(text)
        let at = try #require(code.firstIndex(of: "jobs:"))
        let jobs = code[(at + 1)...].filter { $0.hasPrefix("  ") && !$0.hasPrefix("   ") }
        #expect(jobs == ["  build:"], "\(jobs)")
        for key in ["paths:", "paths-ignore:"] {
            #expect(!code.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key) }, "ci.yml has \(key)")
        }
    }

    // MARK: every workflow

    private func expectPinned(_ name: String) throws {
        let uses = codeLines(try workflowText(name)).filter { $0.contains("uses:") }
        #expect(!uses.isEmpty || name != "ci.yml", "no uses: in \(name)")
        for line in uses {
            #expect(isPinned(line), "\(name): action not pinned to a 40-hex SHA: \(line)")
        }
    }

    @Test func noWorkflowGivesForkCodeSecrets() throws {
        let dir = try repositoryFile(".github/workflows")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.sorted()
        #expect(names.contains("ci.yml") && names.contains("release.yml"), "\(names)")
        for name in names {
            let code = codeLines(try workflowText(name))
            #expect(!code.contains { $0.contains("pull_request_target") }, "\(name) uses pull_request_target")
            #expect(!code.contains { $0.contains("workflow_run") }, "\(name) uses workflow_run")
            try expectPinned(name)
        }
    }

    @Test func codeOwnersCoverTheBuildPath() throws {
        let text = try String(contentsOf: repositoryFile(".github/CODEOWNERS"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for path in ["/.github/", "/packaging/", "/scripts/"] {
            #expect(lines.contains("\(path) @sean-foley"), "no CODEOWNERS line for \(path)")
        }
    }
}
