// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

extension SessionEnvironment.OverrideKey {
    /// `NOCTULE_TEST_UPDATE_FEED`, a file, http or https URL in place of GitHub's latest release.
    public static let testUpdateFeed = "NOCTULE_TEST_UPDATE_FEED"
    /// `NOCTULE_TEST_APP_VERSION`, a version in place of the app's own.
    public static let testAppVersion = "NOCTULE_TEST_APP_VERSION"
}

/// What the update check runs against: the running version and the feed to ask (update-check
/// design §5.0, §5.1, §7).
///
/// An app launched by a test or an agent always has a private `NOCTULE_SETTINGS_DIR` (set, and not
/// the standard directory, compared after resolving symlinks). With one, the app never asks
/// GitHub: the feed is nil unless `NOCTULE_TEST_UPDATE_FEED` names one. Both overrides are
/// ignored, and say so, without a private settings directory. Empty values count as unset.
public struct UpdateCheckConfiguration: Equatable, Sendable {
    /// The version as found, for messages (`"0.0.0"`); empty when the bundle has none.
    public var runningVersionText: String
    /// Nil, or a development version (0.0.0), means a development build.
    public var runningVersion: AppVersion?
    /// Nil means checks are disabled for testing.
    public var feed: URL?

    public var isDevelopmentBuild: Bool { runningVersion?.isDevelopment ?? true }

    public init(runningVersionText: String, runningVersion: AppVersion?, feed: URL?) {
        self.runningVersionText = runningVersionText
        self.runningVersion = runningVersion
        self.feed = feed
    }

    public static func resolve(variables: [String: String], infoDictionary: [String: Any],
                               standardSettingsDirectory: URL = SessionEnvironment.standardSettingsDirectory)
        -> (configuration: UpdateCheckConfiguration, notes: [String]) {
        func value(_ key: String) -> String? {
            guard let text = variables[key], !text.isEmpty else { return nil }
            return text
        }
        func plist(_ key: String) -> String? {
            guard let text = infoDictionary[key] as? String, !text.isEmpty else { return nil }
            return text
        }
        let key = SessionEnvironment.OverrideKey.self
        var notes: [String] = []
        let found = plist("NoctuleFullVersion") ?? plist("CFBundleShortVersionString") ?? ""
        var config = UpdateCheckConfiguration(runningVersionText: found, runningVersion: AppVersion(found),
                                              feed: ReleaseFeed.gitHubLatest)
        var privateSettings = false
        if let path = value(key.settingsDirectory) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            privateSettings = !FileRTSPCooldownStore.samePath(url, standardSettingsDirectory)
        }
        let needsPrivate = "it needs a private \(key.settingsDirectory)"
        if privateSettings { config.feed = nil }
        if let text = value(key.testUpdateFeed) {
            if !privateSettings {
                notes.append("ignoring \(key.testUpdateFeed): \(needsPrivate)")
            } else if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                      ["file", "http", "https"].contains(scheme),
                      scheme == "file" || url.host?.isEmpty == false {
                config.feed = url
                notes.append("\(key.testUpdateFeed)=\(text) (in place of GitHub's latest release)")
            } else {
                notes.append("ignoring \(key.testUpdateFeed)=\(text): not a file, http or https URL")
            }
        } else if privateSettings {
            notes.append("no update checks with a private \(key.settingsDirectory)")
        }
        if let text = value(key.testAppVersion) {
            if !privateSettings {
                notes.append("ignoring \(key.testAppVersion): \(needsPrivate)")
            } else if let version = AppVersion(text) {
                config.runningVersion = version
                config.runningVersionText = text
                notes.append("\(key.testAppVersion)=\(text) (in place of the app's version)")
            } else {
                notes.append("ignoring \(key.testAppVersion)=\(text): not a version")
            }
        }
        return (config, notes)
    }
}
