// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleAppCore

/// How the update check is configured, and the test overrides that keep an app launched by a
/// test or agent from ever asking GitHub (update-check design §5.0, §5.1, §7).
@Suite(.timeLimit(.minutes(1))) struct UpdateCheckConfigurationTests {
    private let standard = URL(fileURLWithPath: "/standard/NoctuleScan", isDirectory: true)
    private let info: [String: Any] = ["NoctuleFullVersion": "1.0.0", "CFBundleShortVersionString": "1.0.0"]

    private func resolve(_ variables: [String: String] = [:], info: [String: Any]? = nil)
        -> (configuration: UpdateCheckConfiguration, notes: [String]) {
        UpdateCheckConfiguration.resolve(variables: variables, infoDictionary: info ?? self.info,
                                         standardSettingsDirectory: standard)
    }

    private func version(_ text: String) -> AppVersion? { AppVersion(text) }

    @Test func standardSettingsUseGitHub() {
        let (config, notes) = resolve()
        #expect(config.feed == ReleaseFeed.gitHubLatest)
        #expect(config.runningVersion == version("1.0.0"))
        #expect(config.runningVersionText == "1.0.0")
        #expect(!config.isDevelopmentBuild)
        #expect(notes.isEmpty)
    }

    @Test func standardSettingsSpelledOutStillUseGitHub() {
        let (config, notes) = resolve(["NOCTULE_SETTINGS_DIR": standard.path])
        #expect(config.feed == ReleaseFeed.gitHubLatest)
        #expect(!notes.contains { $0.hasPrefix("no update checks") })
    }

    @Test func fullVersionWins() {
        let pre: [String: Any] = ["NoctuleFullVersion": "1.0.1-beta.2", "CFBundleShortVersionString": "1.0.1"]
        #expect(resolve(info: pre).configuration.runningVersion == version("1.0.1-beta.2"))
        let missing: [String: Any] = ["CFBundleShortVersionString": "1.0.1"]
        #expect(resolve(info: missing).configuration.runningVersion == version("1.0.1"))
        let empty: [String: Any] = ["NoctuleFullVersion": "", "CFBundleShortVersionString": "1.0.1"]
        let config = resolve(info: empty).configuration
        #expect(config.runningVersion == version("1.0.1"))
        #expect(config.runningVersionText == "1.0.1")
    }

    @Test func developmentBuilds() {
        #expect(resolve(info: ["NoctuleFullVersion": "0.0.0", "CFBundleShortVersionString": "0.0.0"])
            .configuration.isDevelopmentBuild)
        #expect(resolve(info: [:]).configuration.isDevelopmentBuild)
        let garbage = resolve(info: ["NoctuleFullVersion": "garbage"]).configuration
        #expect(garbage.isDevelopmentBuild)
        #expect(garbage.runningVersion == nil)
        #expect(garbage.runningVersionText == "garbage")
    }

    @Test func privateSettingsNeverUseGitHub() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (config, notes) = resolve(["NOCTULE_SETTINGS_DIR": dir.path])
        #expect(config.feed == nil)
        #expect(notes == ["no update checks with a private NOCTULE_SETTINGS_DIR"])
    }

    @Test func privateSettingsWithATestFeed() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vars = ["NOCTULE_SETTINGS_DIR": dir.path, "NOCTULE_TEST_UPDATE_FEED": "file:///tmp/x.json"]
        let (config, notes) = resolve(vars)
        #expect(config.feed == URL(string: "file:///tmp/x.json"))
        #expect(notes == ["NOCTULE_TEST_UPDATE_FEED=file:///tmp/x.json (in place of GitHub's latest release)"])
        // The real GitHub URL, given on purpose, is honoured the same way.
        var github = vars
        github["NOCTULE_TEST_UPDATE_FEED"] = ReleaseFeed.gitHubLatest.absoluteString
        #expect(resolve(github).configuration.feed == ReleaseFeed.gitHubLatest)
        var http = vars
        http["NOCTULE_TEST_UPDATE_FEED"] = "http://127.0.0.1:8080/latest"
        #expect(resolve(http).configuration.feed == URL(string: "http://127.0.0.1:8080/latest"))
    }

    @Test func testAppVersion() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vars = ["NOCTULE_SETTINGS_DIR": dir.path, "NOCTULE_TEST_APP_VERSION": "0.9.0"]
        let (config, notes) = resolve(vars)
        #expect(config.runningVersion == version("0.9.0"))
        #expect(config.runningVersionText == "0.9.0")
        #expect(notes.contains("NOCTULE_TEST_APP_VERSION=0.9.0 (in place of the app's version)"), "\(notes)")
        var bad = vars
        bad["NOCTULE_TEST_APP_VERSION"] = "nope"
        let (kept, badNotes) = resolve(bad)
        #expect(kept.runningVersion == version("1.0.0"))
        #expect(badNotes.contains("ignoring NOCTULE_TEST_APP_VERSION=nope: not a version"), "\(badNotes)")
    }

    @Test func overridesNeedPrivateSettings() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link")
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let overrides = ["NOCTULE_TEST_UPDATE_FEED": "file:///tmp/x.json", "NOCTULE_TEST_APP_VERSION": "0.9.0"]
        let spellings: [[String: String]] = [[:], ["NOCTULE_SETTINGS_DIR": real.path], ["NOCTULE_SETTINGS_DIR": link.path]]
        for (index, extra) in spellings.enumerated() {
            let (config, notes) = UpdateCheckConfiguration.resolve(
                variables: overrides.merging(extra) { $1 }, infoDictionary: info,
                standardSettingsDirectory: index == 0 ? standard : real)
            #expect(config.feed == ReleaseFeed.gitHubLatest, "case \(index)")
            #expect(config.runningVersion == version("1.0.0"), "case \(index)")
            #expect(notes.contains("ignoring NOCTULE_TEST_UPDATE_FEED: it needs a private NOCTULE_SETTINGS_DIR"), "\(notes)")
            #expect(notes.contains("ignoring NOCTULE_TEST_APP_VERSION: it needs a private NOCTULE_SETTINGS_DIR"), "\(notes)")
        }
    }

    @Test func badFeed() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for bad in ["ftp://x", "not a url", "https://"] {
            let (config, notes) = resolve(["NOCTULE_SETTINGS_DIR": dir.path, "NOCTULE_TEST_UPDATE_FEED": bad])
            #expect(config.feed == nil, "\(bad)")
            #expect(notes.contains("ignoring NOCTULE_TEST_UPDATE_FEED=\(bad): not a file, http or https URL"), "\(notes)")
        }
    }

    @Test func emptyValuesCountAsUnset() throws {
        let (config, notes) = resolve(["NOCTULE_SETTINGS_DIR": "", "NOCTULE_TEST_UPDATE_FEED": "",
                                       "NOCTULE_TEST_APP_VERSION": ""])
        #expect(config.feed == ReleaseFeed.gitHubLatest)
        #expect(notes.isEmpty)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
