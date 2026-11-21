// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleCLICore

@Suite struct CLIArgumentsTests {
    @Test func subcommands() throws {
        #expect(try CLIArguments.parse(["info"]) == CLIInvocation(command: .info))
        #expect(try CLIArguments.parse(["status"]).command == .status)
        #expect(try CLIArguments.parse(["display"]).command == .display)
        #expect(try CLIArguments.parse(["menu"]).command == .menu)
        #expect(try CLIArguments.parse(["menu", "--host", "h.lan", "--port", "5000"]) == CLIInvocation(command: .menu, host: "h.lan", port: 5000))
        #expect(try CLIArguments.parse(["menu", "--serial", "/tmp/p"]).serial == .path("/tmp/p"))
        #expect(throws: CLIUsageError.self) { try CLIArguments.parse(["menu", "--count", "2"]) }
    }
    @Test func hostAndPortAnyPosition() throws {
        let a = try CLIArguments.parse(["--host", "h.lan", "--port", "5000", "status"])
        #expect(a == CLIInvocation(command: .status, host: "h.lan", port: 5000))
        let b = try CLIArguments.parse(["info", "--port", "1"])
        #expect(b.port == 1 && b.host == nil)
    }
    @Test func watchDefaults() throws {
        #expect(try CLIArguments.parse(["watch"]).command == .watch(interval: .milliseconds(500), count: nil))
    }
    @Test func watchFlags() throws {
        let a = try CLIArguments.parse(["watch", "--interval", "250", "--count", "5"])
        #expect(a.command == .watch(interval: .milliseconds(250), count: 5))
    }
    @Test func rejectsBadInput() {
        for bad in [[], ["bogus"], ["info", "--nope"], ["info", "--host"], ["info", "--port", "x"],
                    ["info", "--port", "70000"], ["info", "--count", "3"], ["watch", "--count", "0"],
                    ["watch", "--interval", "0"], ["watch", "--count", "x"], ["info", "extra"]] {
            #expect(throws: CLIUsageError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
    }
    /// `--cooldown-seconds` (mock-only) needs a private `--cooldown-store`: never the shared record,
    /// however its path is spelled.
    @Test func cooldownSecondsNeedsAPrivateStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noctule-cli-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("Caches/rtsp-cooldown.json")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: root) }
        func problem(_ args: [String]) throws -> String? {
            CLIArguments.cooldownOverrideProblem(try CLIArguments.parse(args), sharedStore: shared)
        }
        let message = "--cooldown-seconds is for tests against the mock only: it needs a private --cooldown-store, not the shared record"
        for command in [["listen", "--host", "h"], ["log"]] {
            #expect(try problem(command + ["--cooldown-seconds", "1"]) == message)
            #expect(try problem(command + ["--cooldown-seconds", "1", "--cooldown-store", shared.path]) == message)
            #expect(try problem(command + ["--cooldown-seconds", "1", "--cooldown-store",
                                           link.appendingPathComponent("rtsp-cooldown.json").path]) == message)
            #expect(try problem(command + ["--cooldown-seconds", "1", "--cooldown-store",
                                           shared.deletingLastPathComponent().path + "/../Caches/rtsp-cooldown.json"]) == message)
            #expect(try problem(command + ["--cooldown-seconds", "1", "--cooldown-store",
                                           root.appendingPathComponent("private.json").path]) == nil)
            #expect(try problem(command) == nil)
            #expect(try problem(command + ["--cooldown-store", root.appendingPathComponent("private.json").path]) == nil)
        }
    }

    @Test func usageErrorMentionsUsage() {
        #expect(CLIUsageError(message: "m").description.contains("usage: noctule"))
    }
}
