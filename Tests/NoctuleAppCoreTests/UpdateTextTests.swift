// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

@testable import NoctuleAppCore

@Suite(.timeLimit(.minutes(1)))
struct UpdateTextTests {
    private func v(_ text: String) -> AppVersion { AppVersion(text)! }

    @Test func availableLine() {
        let offer = UpdateOffer(
            release: LatestRelease(
                version: v("1.0.1"), notes: "", page: URL(string: "https://example.com/r")!),
            running: v("1.0.0"))
        #expect(UpdateText.available(offer) == "Noctule Scan 1.0.1 is available — you have 1.0.0.")
    }

    @Test func messages() {
        #expect(
            UpdateText.message(for: .upToDate(running: v("1.0.0"), latest: v("1.0.0")))
                == UpdateMessage(
                    title: "You're up to date", body: "Noctule Scan 1.0.0 is the newest version."))
        #expect(
            UpdateText.message(for: .upToDate(running: v("1.1.0-beta.1"), latest: v("1.0.0")))?.body
                == "Noctule Scan 1.1.0-beta.1 is newer than the latest release, 1.0.0.")
        let failTitle = "Couldn't check for updates"
        let cases: [(UpdateCheckFailure, String)] = [
            (.noRelease, "No release has been published yet."),
            (.rateLimited, "GitHub is limiting requests. Try again later."),
            (.unreadable("status 500"), "GitHub sent an answer Noctule Scan couldn't read."),
            (
                .network("The Internet connection appears to be offline."),
                "The Internet connection appears to be offline."
            ),
            (
                .disabledForTesting,
                "Update checks are off with a private settings folder (NOCTULE_SETTINGS_DIR)."
            ),
        ]
        for (failure, body) in cases {
            #expect(
                UpdateText.message(for: .failed(failure)) == UpdateMessage(title: failTitle, body: body))
        }
        #expect(
            UpdateText.message(for: .developmentBuild(versionText: "0.0.0"))
                == UpdateMessage(
                    title: "This is a development build",
                    body:
                        "Version 0.0.0 can't be compared with releases. Builds from a release tag check for updates."
                ))
    }

    @Test func noMessageForAnOffer() {
        let offer = UpdateOffer(
            release: LatestRelease(
                version: v("1.0.1"), notes: "", page: URL(string: "https://example.com/r")!),
            running: v("1.0.0"))
        #expect(UpdateText.message(for: .updateAvailable(offer)) == nil)
    }

    @Test func notesRenderInlineMarkdown() {
        let text = UpdateText.notes("**Fixed** a crash")
        #expect(String(text.characters) == "Fixed a crash")
        let bold = text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(text[$0.range].characters) } == "Fixed")
    }

    @Test func notesDropLinks() {
        let text = UpdateText.notes("See [the page](https://example.com) and <https://example.com>")
        #expect(text.runs.allSatisfy { $0.link == nil })
        #expect(String(text.characters).contains("the page"))
    }

    @Test func notesShowHTMLAsText() {
        let text = UpdateText.notes("<script>x</script>")
        #expect(String(text.characters) == "<script>x</script>")
    }

    @Test func emptyNotes() {
        #expect(String(UpdateText.notes("").characters) == "No release notes.")
        #expect(String(UpdateText.notes(" \n\t ").characters) == "No release notes.")
    }

    @Test func lastCheckedText() {
        let en = Locale(identifier: "en_US")
        let zone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(
            UpdateText.lastChecked(nil, now: now, locale: en, timeZone: zone) == "Last checked: never")
        let today = UpdateText.lastChecked(now, now: now, locale: en, timeZone: zone)
        #expect(today.hasPrefix("Last checked: "))
        #expect(today.contains("today"))
        #expect(
            UpdateText.lastChecked(
                now.addingTimeInterval(-86_400), now: now, locale: en, timeZone: zone
            ).contains("yesterday"))
        let old = UpdateText.lastChecked(
            now.addingTimeInterval(-86_400 * 40), now: now, locale: en, timeZone: zone)
        #expect(old.hasPrefix("Last checked: "))
        #expect(!old.contains("today"))
    }

    @Test func fixedCopy() {
        #expect(UpdateText.windowTitle == "Software Update")
        #expect(UpdateText.headline == "A new version of Noctule Scan is available")
        #expect(UpdateText.automaticToggle == "Check for updates automatically")
        #expect(UpdateText.menuItem == "Check for Updates…")
        #expect(
            UpdateText.settingsFooter
                == "At launch and once a day, Noctule Scan asks GitHub for its latest release (betas aren't included). Nothing is downloaded or installed."
        )
    }
}
