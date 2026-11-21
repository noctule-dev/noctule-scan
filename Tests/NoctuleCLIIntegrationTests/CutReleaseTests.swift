// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

// `packaging/cut-release.sh` (Plan 15, `docs/specs/2026-11-14-release-manager-design.md` §1), run only in
// fake repositories (a clone of a bare `origin` in a temporary directory) with stub `swift` and `gh` first on
// PATH. Nothing here touches this repository, its `origin`, GitHub or the real test suite.

@Suite(.timeLimit(.minutes(1))) struct CutReleaseTests {
    typealias Result = (status: Int32, stdout: String, stderr: String)

    struct Rig {
        let stubs: StubTools
        let repo: URL
        let origin: URL

        init(tags: [String]) throws {
            stubs = try StubTools()
            (repo, origin) = try releaseRepository(in: stubs.directory.deletingLastPathComponent(), tags: tags)
        }

        func git(_ arguments: String...) throws -> String {
            let result = try run(tool("git"), ["-C", repo.path] + arguments)
            try #require(result.status == 0, "git \(arguments): \(result.stderr)")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func originGit(_ arguments: String...) throws -> String {
            let result = try run(tool("git"), ["-C", origin.path] + arguments)
            try #require(result.status == 0, "git \(arguments): \(result.stderr)")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var localTags: String { get throws { try git("tag", "--list") } }
        var originTags: String { get throws { try originGit("tag", "--list") } }

        func cut(_ arguments: [String], input: String? = "n\n", _ extra: [String: String] = [:]) throws -> Result {
            try runScript("packaging/cut-release.sh", arguments, environment: stubs.environment.merging(extra) { _, new in new },
                          root: repo, limit: 60, input: input)
        }

        var swiftCalls: [String] { stubs.calls().filter { $0.hasPrefix("swift ") } }
    }

    /// The whole output, for messages that may go to either stream.
    private func text(_ result: Result) -> String { result.stdout + result.stderr }

    struct Case: Sendable, CustomTestStringConvertible {
        let tags: [String]
        let arguments: [String]
        let next: String
        let latest: String
        var testDescription: String { "\(tags) \(arguments.joined(separator: " ")) -> \(next)" }
    }

    @Test(arguments: [
        Case(tags: ["v0.1.1-beta.1"], arguments: ["beta"], next: "v0.1.1-beta.2", latest: "v0.1.1-beta.1"),
        Case(tags: ["v0.1.1-beta.1"], arguments: ["final"], next: "v0.1.1", latest: "v0.1.1-beta.1"),
        Case(tags: ["v0.1.1"], arguments: ["patch"], next: "v0.1.2", latest: "v0.1.1"),
        Case(tags: ["v0.1.1"], arguments: ["patch", "--beta"], next: "v0.1.2-beta.1", latest: "v0.1.1"),
        Case(tags: ["v0.1.1"], arguments: ["minor"], next: "v0.2.0", latest: "v0.1.1"),
        Case(tags: ["v0.1.1"], arguments: ["major", "--beta"], next: "v1.0.0-beta.1", latest: "v0.1.1"),
    ])
    func nextVersionTable(_ c: Case) throws {
        let rig = try Rig(tags: c.tags)
        let result = try rig.cut(c.arguments, input: "n\n")
        #expect(result.status == 1, "\(text(result))")
        #expect(text(result).contains("as \(c.next) (latest \(c.latest)) and push it?"), "\(text(result))")
        #expect(text(result).contains("This starts the release workflow, which uploads the app to Apple for notarization. [y/N]"))
        #expect(text(result).contains("cut-release: nothing tagged"))
        #expect(try rig.originTags == c.tags.sorted().joined(separator: "\n"))
    }

    // A repository with no release tags has no "latest": the first release names its version.
    @Test func noTagsNeedsFirst() throws {
        let rig = try Rig(tags: [])
        for arguments in [["beta"], ["minor"], ["patch", "--beta"]] {
            let result = try rig.cut(arguments)
            #expect(result.status == 1, "\(text(result))")
            #expect(result.stderr.contains("cut-release: no release tags on origin; pass --first X.Y.Z or X.Y.Z-beta.N for the first release"),
                    "\(result.stderr)")
        }
        // Tags that aren't releases don't count.
        let odd = try Rig(tags: ["v0.1.1-rc.1", "foo"])
        let result = try odd.cut(["beta"])
        #expect(result.status == 1, "\(text(result))")
        #expect(result.stderr.contains("no release tags on origin; pass --first"), "\(result.stderr)")
        for r in [rig, odd] {
            #expect(r.swiftCalls.isEmpty)
            #expect(!r.stubs.calls().contains { $0.hasPrefix("gh ") })
        }
        #expect(try rig.originTags == "")
        #expect(try odd.originTags == "foo\nv0.1.1-rc.1")
    }

    @Test(arguments: [
        (["beta", "--first", "0.1.1-beta.4"], "v0.1.1-beta.4"),
        (["--first", "0.1.1-beta.4", "beta"], "v0.1.1-beta.4"),
        (["minor", "--beta", "--first", "0.2.0-beta.1"], "v0.2.0-beta.1"),
        (["patch", "--first", "0.1.0"], "v0.1.0"),
        (["--first", "1.0.0", "final"], "v1.0.0"),
    ] as [([String], String)])
    func firstProposesThatVersion(_ arguments: [String], _ tag: String) throws {
        let rig = try Rig(tags: [])
        let result = try rig.cut(arguments)
        #expect(result.status == 1, "\(text(result))")
        #expect(text(result).contains("as \(tag) (latest none) and push it?"), "\(text(result))")
        #expect(text(result).contains("cut-release: nothing tagged"))
        #expect(rig.swiftCalls.count == 1)
        #expect(try rig.originTags == "")
        // A yes tags and pushes exactly that version.
        let yes = try Rig(tags: [])
        let done = try yes.cut(arguments, input: "y\n", ["STUB_GH_DRAFT": "1"])
        #expect(done.status == 0, "\(text(done))")
        #expect(try yes.originTags == tag)
    }

    @Test func firstIsRefusedWhenTagsExist() throws {
        let rig = try Rig(tags: ["v0.1.1-beta.1", "v0.0.5"])
        let result = try rig.cut(["beta", "--first", "0.1.1-beta.4"])
        #expect(result.status == 2, "\(text(result))")
        #expect(result.stderr.contains("cut-release: --first is only for a repository with no release tags"), "\(result.stderr)")
        #expect(rig.stubs.calls().isEmpty)
        #expect(try rig.originTags == "v0.0.5\nv0.1.1-beta.1")
    }

    @Test(arguments: [
        ["beta", "--first", "v0.1.1-beta.4"], ["beta", "--first", "0.1.1"], ["beta", "--first", "0.1.1-beta"],
        ["minor", "--beta", "--first", "0.2.0"], ["final", "--first", "0.1.1-beta.4"], ["patch", "--first", "0.1"],
        ["patch", "--first", "01.2.3"], ["patch", "--first", ""], ["patch", "--first", "0.1.0", "--first", "0.2.0"],
    ] as [[String]])
    func firstMustBeAVersion(_ arguments: [String]) throws {
        let rig = try Rig(tags: [])
        let result = try rig.cut(arguments)
        #expect(result.status == 2, "\(text(result))")
        #expect(result.stderr.contains("cut-release: --first needs") || result.stderr.contains("usage:"), "\(result.stderr)")
        #expect(rig.stubs.calls().isEmpty)
    }

    @Test(arguments: [
        (["v0.1.1"], ["beta"], "latest is v0.1.1 (final); use patch --beta, minor --beta or major --beta"),
        (["v0.1.1"], ["final"], "latest is v0.1.1, already final"),
        (["v0.1.1-beta.1"], ["patch"], "v0.1.1-beta.1 isn't final yet; release it with final, or another beta with beta"),
        (["v0.1.1-beta.1"], ["minor"], "v0.1.1-beta.1 isn't final yet; release it with final, or another beta with beta"),
        (["v0.1.1-beta.1"], ["major", "--beta"], "v0.1.1-beta.1 isn't final yet; release it with final, or another beta with beta"),
    ] as [([String], [String], String)])
    func refusedKinds(_ tags: [String], _ arguments: [String], _ message: String) throws {
        let rig = try Rig(tags: tags)
        let result = try rig.cut(arguments)
        #expect(result.status == 1)
        #expect(result.stderr.contains("cut-release: \(message)"), "\(result.stderr)")
        #expect(rig.swiftCalls.isEmpty)
    }

    @Test(arguments: [
        (["v0.9.0", "v0.10.0"], ["patch"], "v0.10.1"),
        (["v0.2.0-beta.9", "v0.2.0-beta.10"], ["beta"], "v0.2.0-beta.11"),
        (["v0.2.0-beta.3", "v0.2.0"], ["patch"], "v0.2.1"),
    ] as [([String], [String], String)])
    func latestIsByPrecedence(_ tags: [String], _ arguments: [String], _ next: String) throws {
        let rig = try Rig(tags: tags)
        let result = try rig.cut(arguments)
        #expect(text(result).contains("as \(next) (latest"), "\(text(result))")
    }

    @Test func unreadableTagsAreWarnedAbout() throws {
        let rig = try Rig(tags: ["v0.1.1-rc.1", "vfoo", "v0.1.0"])
        let result = try rig.cut(["patch"])
        #expect(result.stderr.contains("cut-release: ignoring tags it can't read: v0.1.1-rc.1 vfoo"), "\(result.stderr)")
        #expect(text(result).contains("as v0.1.1 (latest v0.1.0)"), "\(text(result))")
    }

    @Test func oddlyNumberedTagsAreIgnored() throws {
        // Leading zeros (read as octal), and numbers too long for the sort key, are not versions.
        let rig = try Rig(tags: ["v0.010.0", "v0.1.08", "v0.1.1-beta.09", "v0.1.12345678901", "v0.1.0"])
        let result = try rig.cut(["patch"])
        #expect(result.stderr.contains("cut-release: ignoring tags it can't read: v0.010.0 v0.1.08 v0.1.1-beta.09 v0.1.12345678901"),
                "\(result.stderr)")
        #expect(text(result).contains("as v0.1.1 (latest v0.1.0)"), "\(text(result))")
    }

    @Test func missingOriginMainIsAMessage() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        _ = try rig.git("config", "--unset-all", "remote.origin.fetch")
        _ = try rig.git("update-ref", "-d", "refs/remotes/origin/main")
        let result = try rig.cut(["patch"])
        #expect(result.status == 1, "\(text(result))")
        #expect(result.stderr.contains("cut-release: can't find origin/main; check the origin remote"), "\(result.stderr)")
        #expect(rig.swiftCalls.isEmpty)
    }

    @Test func localTestRunDropsTheOwnersHardwareVariables() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let names = ["NOCTULE_CI_RUNNER", "NOCTULE_HARDWARE_TESTS", "NOCTULE_AUDIO_HARDWARE_TESTS", "NOCTULE_RESTART_HARDWARE_TEST",
                     "NOCTULE_SDS150_HARDWARE_TESTS", "NOCTULE_SDS150_PUSH_TEST", "NOCTULE_SDS150_KEEPALIVE_TEST"]
        let result = try rig.cut(["patch"], input: "n\n", Dictionary(uniqueKeysWithValues: names.map { ($0, "1") }))
        #expect(result.status == 1, "\(text(result))")
        let calls = rig.stubs.calls()
        #expect(calls.contains("env NOCTULE_NO_USB_DETECTION=1"), "\(calls)")
        for name in names { #expect(calls.contains("env \(name)=unset"), "\(name): \(calls)") }
    }

    @Test func theWatchCannotBeStoppedByTheTerminal() throws {
        // In a background process group a terminal setting or a read stops a child (SIGTTOU, SIGTTIN) and the
        // script's wait would hang: the watch gets /dev/null for input and ignores both signals.
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: "y\n", ["STUB_GH_DRAFT": "1"])
        #expect(result.status == 0, "\(text(result))")
        #expect(rig.stubs.calls().contains("watch stdin=null ignores-TTOU=yes ignores-TTIN=yes"), "\(rig.stubs.calls())")
    }

    @Test(arguments: ["Y\n", "YES\n", "Yes\n"])
    func anyCaseOfYesTags(_ input: String) throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: input, ["STUB_GH_DRAFT": "1"])
        #expect(result.status == 0, "\(text(result))")
        #expect(try rig.originTags == "v0.1.1\nv0.1.2")
    }

    @Test func refusesOffMain() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        _ = try rig.git("checkout", "-q", "-b", "other")
        let result = try rig.cut(["patch"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("cut-release: you are on other; switch to main"), "\(result.stderr)")
        #expect(rig.swiftCalls.isEmpty)
    }

    @Test func refusesADirtyTree() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        try "x".write(to: rig.repo.appending(path: "stray.txt"), atomically: true, encoding: .utf8)
        let result = try rig.cut(["patch"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("cut-release: the working tree isn't clean"), "\(result.stderr)")
        #expect(rig.swiftCalls.isEmpty)
    }

    @Test func refusesBehindOrAhead() throws {
        let behind = try Rig(tags: ["v0.1.1"])
        _ = try behind.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "more")
        _ = try behind.git("push", "-q", "origin", "main")
        _ = try behind.git("reset", "-q", "--hard", "HEAD~1")
        let one = try behind.cut(["patch"])
        #expect(one.status == 1)
        #expect(one.stderr.contains("cut-release: main is behind origin/main; pull first"), "\(one.stderr)")
        #expect(behind.swiftCalls.isEmpty)

        let ahead = try Rig(tags: ["v0.1.1"])
        _ = try ahead.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "unpushed")
        let two = try ahead.cut(["patch"])
        #expect(two.status == 1)
        #expect(two.stderr.contains("cut-release: main has commits origin/main doesn't; push them first"), "\(two.stderr)")
        #expect(ahead.swiftCalls.isEmpty)
    }

    @Test func refusesALocalOnlyTag() throws {
        let rig = try Rig(tags: ["v0.1.1-beta.1"])
        _ = try rig.git("tag", "v0.1.1-beta.2")
        let result = try rig.cut(["beta"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("cut-release: v0.1.1-beta.2 exists locally but not on GitHub; delete it with git tag -d v0.1.1-beta.2"),
                "\(result.stderr)")
        #expect(rig.swiftCalls.isEmpty)
    }

    @Test func localTagsDontCount() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        _ = try rig.git("tag", "v9.0.0")
        let result = try rig.cut(["patch"])
        #expect(text(result).contains("as v0.1.2 (latest v0.1.1)"), "\(text(result))")
    }

    @Test func refusesAnExistingRelease() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], ["STUB_GH_VIEW_STATUS": "0"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("cut-release: a release for v0.1.2 already exists"), "\(result.stderr)")
        #expect(rig.swiftCalls.isEmpty)
        #expect(try rig.localTags == "v0.1.1")
    }

    @Test func stopsOnAnyOtherGhError() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], ["STUB_GH_VIEW_STATUS": "1", "STUB_GH_VIEW_STDERR": "HTTP 401: Bad credentials\nsecond line"])
        #expect(result.status == 1)
        #expect(result.stderr.contains("cut-release: couldn't ask GitHub about releases: HTTP 401: Bad credentials"), "\(result.stderr)")
        #expect(!result.stderr.contains("second line"))
        #expect(rig.swiftCalls.isEmpty)
        #expect(try rig.localTags == "v0.1.1")
    }

    @Test func failingTestsTagNothing() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: "y\n", ["STUB_SWIFT_STATUS": "1"])
        #expect(result.status == 1)
        #expect(text(result).contains("build/cut-release-test.log"), "\(text(result))")
        #expect(text(result).contains("Test run with 1 tests failed"), "the log's last lines are shown")
        #expect(try rig.localTags == "v0.1.1")
        #expect(try rig.originTags == "v0.1.1")
        #expect(rig.swiftCalls == ["swift test"])
        #expect(rig.stubs.calls().contains("env NOCTULE_NO_USB_DETECTION=1"), "\(rig.stubs.calls())")
        #expect(!text(result).contains("and push it?"), "no question after a failure")
    }

    @Test(arguments: [String?.some(""), String?.none])
    func emptyAnswerOrEndOfInputTagsNothing(_ input: String?) throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: input)
        #expect(result.status == 1)
        #expect(result.stderr.contains("cut-release: nothing tagged"), "\(result.stderr)")
        #expect(try rig.localTags == "v0.1.1")
        #expect(try rig.originTags == "v0.1.1")
        #expect(!rig.stubs.calls().contains { $0.hasPrefix("gh run") })
    }

    @Test func interruptDuringTestsTagsNothing() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let pidFile = rig.stubs.directory.appending(path: "grandchild.pid")
        let environment = rig.stubs.environment.merging(["STUB_SWIFT_SLEEP": "5", "STUB_SWIFT_GRANDCHILD": pidFile.path]) { _, new in new }
        let script = rig.repo.appending(path: "packaging/cut-release.sh")
        let process = try Subprocess(script, ["patch"], environment: environment, currentDirectory: rig.stubs.directory, input: "y\n")
        #expect(waitFor(10) { rig.swiftCalls.contains("swift test") }, "swift never started: \(process.stderr)")
        // The stub writes the pid file after its call-log lines; interrupt only once the grandchild is there.
        func recordedPid() -> Int32 {
            Int32((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        let grandchildStarted = waitFor(10) { recordedPid() > 1 }
        #expect(grandchildStarted, "the stub never started its grandchild")
        let started = Date()
        process.interrupt()
        #expect(waitFor(3) { !process.isRunning }, "the script kept waiting for the tests")
        let result = process.finish()
        #expect(result.status == 130, "\(result)")
        #expect(Date().timeIntervalSince(started) < 4)
        // Everything the tests started goes with them, not just swift and its children.
        // A pid of 0 or 1 would mean a process group or init: never signal one.
        let grandchild = recordedPid()
        if grandchild > 1 {
            #expect(waitFor(3) { kill(grandchild, 0) != 0 }, "process \(grandchild) outlived the interrupted script")
            kill(grandchild, SIGKILL)
        }
        #expect(try rig.localTags == "v0.1.1")
        #expect(try rig.originTags == "v0.1.1")
    }

    @Test func yesTagsPushesAndFollowsTheRun() throws {
        let rig = try Rig(tags: ["v0.1.1-beta.1"])
        let result = try rig.cut(["beta"], input: "y\n", ["STUB_GH_DRAFT": "1"])
        #expect(result.status == 0, "\(text(result))")
        #expect(try rig.originGit("cat-file", "-t", "refs/tags/v0.1.1-beta.2") == "tag")
        #expect(try rig.originGit("tag", "-l", "--format=%(contents:subject)", "v0.1.1-beta.2") == "Noctule Scan 0.1.1-beta.2")
        #expect(try rig.originGit("rev-parse", "v0.1.1-beta.2^{commit}") == (try rig.originGit("rev-parse", "main")))
        #expect(result.stdout.contains("https://example.invalid/runs/4242"), "\(result.stdout)")
        #expect(result.stdout.contains("https://example.invalid/releases/v0.1.1-beta.2"))
        #expect(result.stdout.contains("noctule-scan-0.1.1-beta.2.dmg\n"))
        #expect(result.stdout.contains("noctule-scan-0.1.1-beta.2.dmg.sha256"))
        #expect(result.stdout.contains("Check it, write the notes, then publish it."))
        let calls = rig.stubs.calls()
        #expect(inOrder(calls, ["gh release view v0.1.1-beta.2", "swift test", "gh run list --workflow release.yml --event push",
                                "gh run watch 4242 --exit-status", "gh release view v0.1.1-beta.2 --json url,assets"]), "\(calls)")
    }

    @Test func refusedPushRemovesTheLocalTag() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let hook = rig.origin.appending(path: "hooks/pre-receive")
        try "#!/bin/sh\necho 'no pushes today' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let result = try rig.cut(["patch"], input: "y\n")
        #expect(result.status == 1, "\(text(result))")
        #expect(text(result).contains("couldn't push v0.1.2"))
        #expect(try rig.localTags == "v0.1.1")
        #expect(try rig.originTags == "v0.1.1")
        #expect(!rig.stubs.calls().contains { $0.hasPrefix("gh run") })
    }

    private let actions = "https://github.com/noctule-dev/noctule-scan/actions"

    @Test(arguments: [
        "[]",
        #"[{"databaseId":7,"headBranch":"v0.0.9","url":"https://example.invalid/runs/7"}]"#,
        #"[{"databaseId":7,"headBranch":"v0.1.2","url":"https://example.invalid/runs/7"},{"databaseId":8,"headBranch":"v0.1.2","url":"https://example.invalid/runs/8"}]"#,
    ])
    func runNotFoundLeavesTheTagAndPointsAtActions(_ runs: String) throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: "y\n",
                                 ["STUB_GH_RUNS": runs, "CUT_RELEASE_POLL_SECONDS": "0.1", "CUT_RELEASE_POLL_LIMIT": "3"])
        #expect(result.status == 1, "\(text(result))")
        #expect(try rig.originTags == "v0.1.1\nv0.1.2")
        #expect(result.stdout.contains(actions), "\(result.stdout)")
        #expect(!rig.stubs.calls().contains { $0.hasPrefix("gh run watch") })
    }

    @Test func noRunMeansEveryPollIsTried() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        _ = try rig.cut(["patch"], input: "y\n", ["STUB_GH_RUNS": "[]", "CUT_RELEASE_POLL_SECONDS": "0.1", "CUT_RELEASE_POLL_LIMIT": "3"])
        #expect(rig.stubs.calls().filter { $0.hasPrefix("gh run list") }.count == 3)
    }

    @Test func aGitHubOriginNamesItsOwnActionsPage() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        // The push goes through a rewrite, so the fake origin stays local while its URL reads as GitHub's.
        _ = try rig.git("config", "url.\(rig.origin.path).insteadOf", "https://github.com/someone/else.git")
        _ = try rig.git("remote", "set-url", "origin", "https://github.com/someone/else.git")
        let result = try rig.cut(["patch"], input: "y\n",
                                 ["STUB_GH_RUNS": "[]", "CUT_RELEASE_POLL_SECONDS": "0.1", "CUT_RELEASE_POLL_LIMIT": "1"])
        #expect(result.stdout.contains("https://github.com/someone/else/actions"), "\(text(result))")
    }

    @Test func failedRunIsReported() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let view = #"{"jobs":[{"name":"release","steps":[{"name":"Set up","conclusion":"success"},{"name":"Notarize","conclusion":"failure"}]}]}"#
        let result = try rig.cut(["patch"], input: "y\n", ["STUB_GH_WATCH_STATUS": "1", "STUB_GH_RUN_VIEW": view])
        #expect(result.status == 1, "\(text(result))")
        #expect(text(result).contains("packaging/README.md"))
        #expect(text(result).contains("the failing step: Notarize"), "\(text(result))")
        #expect(rig.stubs.calls().filter { $0.hasPrefix("gh run watch") }.count == 1)
        #expect(try rig.originTags == "v0.1.1\nv0.1.2")
    }

    @Test func aLostWatchOfARunThatGoesOnIsNotAFailure() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: "y\n", ["STUB_GH_WATCH_STATUS": "1", "STUB_GH_RUN_STATUS": "in_progress", "STUB_GH_RUN_CONCLUSION": ""])
        #expect(result.status == 1, "\(text(result))")
        #expect(text(result).contains("cut-release: stopped following the run (gh run watch exited 1); it goes on: https://example.invalid/runs/4242"),
                "\(text(result))")
        #expect(!text(result).contains("failed"), "\(text(result))")
        #expect(!text(result).contains("failing step"))
        #expect(try rig.originTags == "v0.1.1\nv0.1.2")
    }

    @Test func aRunThatCannotBeReadAfterALostWatchGoesOn() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: "y\n", ["STUB_GH_WATCH_STATUS": "1", "STUB_GH_RUN_VIEW_FAILS": "1"])
        #expect(result.status == 1, "\(text(result))")
        #expect(text(result).contains("cut-release: stopped following the run (gh run watch exited 1); it goes on:"), "\(text(result))")
        #expect(!text(result).contains("the release run failed"))
    }

    @Test func aLostWatchOfARunThatSucceededGoesToTheDraft() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(["patch"], input: "y\n",
                                 ["STUB_GH_WATCH_STATUS": "1", "STUB_GH_RUN_STATUS": "completed", "STUB_GH_RUN_CONCLUSION": "success", "STUB_GH_DRAFT": "1"])
        #expect(result.status == 0, "\(text(result))")
        #expect(result.stdout.contains("https://example.invalid/releases/v0.1.2"), "\(result.stdout)")
        #expect(result.stdout.contains("Check it, write the notes, then publish it."))
        #expect(!text(result).contains("failed"))
    }

    @Test func interruptDuringTheWatchLeavesTheRun() throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let environment = rig.stubs.environment.merging(["STUB_GH_WATCH_SLEEP": "5"]) { _, new in new }
        let script = rig.repo.appending(path: "packaging/cut-release.sh")
        let process = try Subprocess(script, ["patch"], environment: environment, currentDirectory: rig.stubs.directory, input: "y\n")
        #expect(waitFor(20) { rig.stubs.calls().contains { $0.hasPrefix("gh run watch") } }, "never got to the watch: \(process.stderr)")
        process.interrupt()
        // SIGINT first, so gh can restore the terminal; the SIGTERM fallback only comes after about 2 s.
        #expect(waitFor(1.5) { !process.isRunning }, "the script kept waiting for the watch")
        let result = process.finish()
        #expect(result.status == 130, "\(result)")
        #expect(result.stdout.contains("cut-release: the release run goes on: https://example.invalid/runs/4242"), "\(result.stdout)")
        #expect(try rig.originTags == "v0.1.1\nv0.1.2")
    }

    @Test(arguments: [[], ["beta", "extra"], ["patch", "--rc"], ["--beta"], ["final", "--beta"], ["patch", "--beta", "x"], ["bogus"], ["patch", "--first"], ["beta", "--first", "0.1.1-beta.1", "extra"]] as [[String]])
    func refusesBadArguments(_ arguments: [String]) throws {
        let rig = try Rig(tags: ["v0.1.1"])
        let result = try rig.cut(arguments)
        #expect(result.status == 2, "\(result)")
        #expect(result.stderr.contains("usage:"))
        #expect(rig.stubs.calls().isEmpty)
    }
}
