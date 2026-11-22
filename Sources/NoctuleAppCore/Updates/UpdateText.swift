// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// A title and a sentence for a check that has no update to offer.
public struct UpdateMessage: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Every word the update check shows (update-check design §6), and the release notes made safe
/// to show: the owner writes them on GitHub, but they arrive over the network.
public enum UpdateText {
    public static let windowTitle = "Software Update"
    public static let headline = "A new version of Noctule Scan is available"
    public static let automaticToggle = "Check for updates automatically"
    public static let settingsFooter =
        "At launch and once a day, Noctule Scan asks GitHub for its latest release (betas aren't included). Nothing is downloaded or installed."
    public static let menuItem = "Check for Updates…"

    public static func available(_ offer: UpdateOffer) -> String {
        "Noctule Scan \(offer.release.version) is available — you have \(offer.running)."
    }

    /// The message for a result that offers no update; nil for `.updateAvailable`.
    public static func message(for result: UpdateCheckResult) -> UpdateMessage? {
        switch result {
        case .updateAvailable:
            return nil
        case .upToDate(let running, let latest):
            if running > latest {
                return UpdateMessage(
                    title: "You're up to date",
                    body: "Noctule Scan \(running) is newer than the latest release, \(latest).")
            }
            return UpdateMessage(
                title: "You're up to date", body: "Noctule Scan \(running) is the newest version.")
        case .developmentBuild(let versionText):
            return UpdateMessage(
                title: "This is a development build",
                body:
                    "Version \(versionText) can't be compared with releases. Builds from a release tag check for updates."
            )
        case .failed(let failure):
            let body: String
            switch failure {
            case .network(let text): body = text
            case .noRelease: body = "No release has been published yet."
            case .rateLimited: body = "GitHub is limiting requests. Try again later."
            case .unreadable: body = "GitHub sent an answer Noctule Scan couldn't read."
            case .disabledForTesting:
                body = "Update checks are off with a private settings folder (NOCTULE_SETTINGS_DIR)."
            }
            return UpdateMessage(title: "Couldn't check for updates", body: body)
        }
    }

    /// Release notes as inline Markdown, with nothing clickable and HTML shown as the characters
    /// it is. Plain text when the Markdown can't be read.
    public static func notes(_ body: String) -> AttributedString {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AttributedString("No release notes.")
        }
        var text: AttributedString
        do {
            text = try AttributedString(
                markdown: body,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(body)
        }
        for run in text.runs where run.link != nil {
            text[run.range].link = nil
        }
        return text
    }

    public static func lastChecked(
        _ date: Date?, now: Date, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        guard let date else { return "Last checked: never" }
        // DateFormatter's relative dates compare with the real clock, so "today" and "yesterday"
        // are decided here, against `now`.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        var text: String
        if calendar.isDate(date, inSameDayAs: now) {
            text = "today at " + time.string(from: date)
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            text = "yesterday at " + time.string(from: date)
        } else {
            let both = DateFormatter()
            both.locale = locale
            both.timeZone = timeZone
            both.dateStyle = .medium
            both.timeStyle = .short
            text = both.string(from: date)
            if let first = text.first { text = first.lowercased() + text.dropFirst() }
        }
        return "Last checked: " + text
    }
}
