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
        for line in ["    runs-on: xcode-27", "    timeout-minutes: 120", "      NOCTULE_NO_USB_DETECTION: \"1\"",
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
