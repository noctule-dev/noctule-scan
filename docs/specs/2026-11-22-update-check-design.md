# Checking for updates

Plan 22's design. The Mac app tells its user when a newer stable release of Noctule Scan is on GitHub. It never downloads or installs anything itself.

Labels follow `docs/specs/README.md`: **(owner)** is the owner's decision, **(designer's call)** a default chosen while designing that the owner hasn't ruled on.

## 1. Why, and why now

The codebase is ready for a 1.0.0 release. The owner wants update checking **in 1.0.0 itself** (owner): anyone who downloads a release without it never hears about the next one. So this lands first, then 1.0.0 is cut.

Success: someone running 1.0.0 who launches the app after 1.0.1 is published sees a window saying so, with the release notes and a way to get it, and nothing about the check ever gets in the way of using a scanner.

## 2. Goals, non-goals, anti-goals

**Goals**
- Check GitHub's `noctule-dev/noctule-scan` releases for a newer **stable** release, betas excluded (owner).
- Check when the app starts (owner), and once every 24 hours while it keeps running, since the app can run for days logging (designer's call).
- A **Check for Updates…** menu item for an explicit check (owner), under About in the Noctule Scan menu.
- A preference to turn the automatic check off, **on by default** (owner). The menu item works either way.
- When an update is found, the window from the mockups (owner chose option 1; §6.1).

**Non-goals**
- Downloading, verifying or installing an update (no Sparkle, owner). The user downloads the DMG from the release page as today.
- The `noctule` command line. It doesn't check, and gets no `--version` change here.
- iPad and iPhone. The core is platform-neutral so it could be reused, but nothing is wired up there.
- Beta channels (owner, 2026-11-22): there is none. Only stable releases are ever offered, to anyone. A beta *build* does check, and is told about stable releases newer than it, including its own final (1.0.0-beta.3 is told about 1.0.0), so people on a beta get moved onto the proper release (owner).

**Anti-goals** (a failure even if it works)
- Any effect of a failed check on the app: no crash, no hang, no delay to the station window or its session, no alert at launch (owner). Failures at launch and from the timer are silent apart from one stderr line.
- Nagging: the same skipped version shown again by the automatic checks.
- Sending anything but the request itself: no identifiers, no analytics. GitHub sees the IP address, the app's version in the `User-Agent`, and nothing else.
- Opening any URL the network handed us without checking it (§5.4).
- Any test, or any agent's run of the app on the mocks, reaching `api.github.com`.

## 3. Constraints

- **Entitlements.** None needed. The app is not sandboxed (`Resources/NoctuleScan.entitlements` holds only the audio-input entitlement), so `com.apple.security.network.client` doesn't apply, and the hardened runtime doesn't limit outbound connections. The request is HTTPS to a host with a modern certificate, so App Transport Security needs no exception; macOS's local-network prompt (`NSLocalNetworkUsageDescription`) is for the LAN, not GitHub. If the app is ever sandboxed, it needs `network.client` for this and for the SDS200 alike.
- **The release process already fits.** A `vX.Y.Z-beta.N` tag's release is made with `--prerelease` (`packaging/ci/release-from-tag.sh`), finals without; drafts are invisible to the API. So GitHub's "latest release" endpoint already returns exactly "the newest published stable release". Until one exists (today only `v0.1.1-beta.4`, a pre-release) it answers 404.
- **Versions.** `release.sh` stamps a release build's `CFBundleShortVersionString` from its tag with **only the three numbers** (`short_version`: a `1.0.1-beta.2` app says `1.0.1`; the DMG's name carries the full version). The tracked `Info.plist` and every local build stay `0.0.0`. So the bundle's usual version can't tell a beta from its final, and this plan adds one (§5.0).
- **Branding** (owner, 2026-11-22). The window shows the app's own icon at run time (`NSApp.applicationIconImage`), so a local build shows the placeholder art and a release build the official art, through the existing `NOCTULE_BRANDING_DIR` mechanism. No new art, no art in the repository (`RepositoryHygieneTests`).
- **Code layout** (AGENTS.md): the logic goes in `NoctuleAppCore` (builds for iOS; no AppKit or SwiftUI), the window, menu item and settings section in `NoctuleScan`. New files carry the SPDX notice; new suites a `.timeLimit`.
- **Unauthenticated GitHub API**: 60 requests an hour per IP. We make about one a day per running app.

## 4. Approaches considered

- **A. GitHub's REST API, `GET https://api.github.com/repos/noctule-dev/noctule-scan/releases/latest`, with `URLSession`, and our own small semantic-version comparison.** *(Chosen; the owner agreed.)* One call that already excludes pre-releases and drafts and returns the tag, the release page's URL and the notes.
- B. The releases Atom feed (`/releases.atom`). It doesn't say which entries are pre-releases, so we'd guess from tag names; more parsing for a weaker filter.
- C. Following the website's `github.com/…/releases/latest` redirect. Relies on website behaviour and gives no release notes.
- D. A version file on noctule.app published by the release workflow. Independent of GitHub, but more machinery, and the owner asked for GitHub.
- A version-comparison package was rejected too: the first dependency added just to parse `1.2.3-beta.4`, about 40 lines to write.

## 5. Behaviour

### 5.0 The app's full version (owner: option b, 2026-11-22)

- A new `Info.plist` key, **`NoctuleFullVersion`**, holds the full version from the tag (`1.0.1` or `1.0.1-beta.2`). The tracked `Info.plist` has it as `0.0.0`, like `CFBundleShortVersionString`, so local builds stay development builds.
- `release.sh` stamps it with the full `$version` beside the existing two `plutil -replace` lines, and its check of the app inside the finished DMG also requires `NoctuleFullVersion` to equal `$version` (failing the release otherwise). `PackagingTests` cover both, against their stubs.
- `CFBundleShortVersionString` stays the three numbers (Apple's form; About and Finder show `1.0.1`).
- The checker reads `NoctuleFullVersion`, and falls back to `CFBundleShortVersionString` when the key is missing or empty.
- Rejected: (a) the full version in `CFBundleShortVersionString` (Apple expects three numbers; About and Finder would show the suffix); (c) leaving betas equal to their final (a beta user would never be told about that final).

### 5.1 What counts as newer

- The running version is the app's full version (§5.0). The release's is its `tag_name` with the leading `v` removed. Both are parsed as `MAJOR.MINOR.PATCH` with an optional `-beta.N`; precedence is semantic-version order (`1.0.0-beta.4` < `1.0.0` < `1.0.1`).
- **An update** is a release whose version is greater than the running one. So a 1.0.1-beta user is told about 1.0.1, and a 1.0.0 user isn't told about anything older or equal.
- A reply that is defensively odd (`prerelease` or `draft` true, a tag that doesn't parse) is treated as a failed check (§5.3), never as an update.
- **A development build** (a running version of `0.0.0`, or one that doesn't parse) never checks automatically. A manual check says it's a development build (§6.3) and sends nothing.

### 5.2 When it checks

- **At launch**, if the preference is on and it isn't a development build: one check, started after launch finishes, in the background. It doesn't wait on, or hold up, the station picker, the station window or any session.
- **Every 24 hours while running**, if the preference is on: 24 hours after the last *completed* check (stored, §5.5). Over sleep, a check that fell due runs after the next full wake (designer's call). Turning the preference off stops the timer; turning it on starts it, checking at once if the last check is more than 24 hours old (designer's call).
- **Manual**, from the menu item or the Check Now button (§6.4): whatever the preference.
- **One check at a time.** A manual check while another is running joins it rather than starting a second request; the menu item and Check Now are disabled while one runs (designer's call).

### 5.3 Failures

Every way a check can fail ends the same way: no network, DNS, a timeout (15 s, designer's call), TLS, a non-200 status (404 when there's no stable release yet, 403 when rate-limited, 5xx), a body that doesn't decode, a tag that doesn't parse, an `html_url` that fails §5.4.

- **An automatic check** writes one line to stderr, `NoctuleScan: HH:mm:ss update check: <reason>` (the `SessionWarningLog` time format), and nothing else: no alert, no badge, and "Last checked" isn't updated (designer's call: "last checked" means last *successful* check).
- **A manual check** shows "Couldn't check for updates" with a short, plain reason (§6.3).
- No retries beyond the next scheduled check. Nothing thrown escapes the checker; it runs off the main actor and only hops to it to show a result.

### 5.4 The release page link

**Download…** opens the release's `html_url` in the default browser, but only if it is `https://github.com/noctule-dev/noctule-scan/releases/…` (scheme, host and path prefix checked). Anything else is a failed check (§5.3). The release notes are shown as text (§6.1); links in them aren't followed by the app.

### 5.5 What is remembered

In `app.json` (`LocalSettingsStore`'s `AppFile`, read and written by the app and the command line alike; new keys optional with defaults, so older files read fine):

| Key | Meaning | Default |
|---|---|---|
| `checkForUpdates` | the preference | `true` |
| `lastUpdateCheck` | when the last successful check finished (ISO 8601) | absent |
| `skippedUpdateVersion` | the version the user skipped, e.g. `"1.0.1"` | absent |

These are this Mac's, not part of Export Settings (the archive doesn't include `app.json` today). `app.json` stays best-effort, as now: an unreadable file reads as defaults (so the check is on).

### 5.6 Skip and Later

- **Skip This Version** saves `skippedUpdateVersion`. Automatic checks then don't show that version; a newer one shows. **A manual check always shows an update, skipped or not** (designer's call; the mockups' note, accepted).
- **Later** closes the window and saves nothing; the next automatic check (next launch, or 24 hours on) shows it again.
- **Download…** opens the page (§5.4) and closes the window, saving nothing.

## 6. The UI (mockups accepted by the owner, 2026-11-22)

### 6.1 The update window

A normal window titled "Software Update", not a modal alert and not a sheet: the station window and its session go on behind it. At most one exists; a later check that finds an update refreshes it with the newer content.

**Focus** (owner accepted the designer's pick, 2026-11-22). The Scanner view sends mapped keys, Return and Esc from the key window to the scanner, so:

- **An automatic check** (launch or the 24-hour timer) orders the window in front of the app's windows **without making it key and without activating the app**. Keys keep going to the station window until the user clicks the update window. If the app is in the background, the window is there when the user comes back; no Dock bounce, no notification.
- **A manual check** (the menu item or Check Now) makes it key and brings it forward: the user just asked.
- So Return (Download…) and Esc (Later) only ever act once the user has given the window focus. A hand check and, where it can be tested, a test cover "an automatic check's window doesn't take the key window from a station window".

- The app's icon (§3, branding), then **A new version of Noctule Scan is available** and **Noctule Scan 1.0.1 is available — you have 1.0.0.**
- **Release notes**: the release's `body`, in a scrolling area about 150 pt tall. Rendered as Markdown where SwiftUI can (`AttributedString(markdown:)` with inline-only parsing is acceptable; full block rendering is the builder's call), plain text otherwise. No web view, no remote images. An empty body shows "No release notes."
- Buttons: **Skip This Version** on the left; **Later** and **Download…** (the default, Return) on the right. Esc and the close button act as Later.

### 6.2 The menu item

**Check for Updates…** directly under **About Noctule Scan** in the app menu, no shortcut. Disabled while a check runs. Found an update: the window. Otherwise: §6.3.

### 6.3 A manual check's other answers

Alerts with one **OK** button, shown only for manual checks:

- **You're up to date** — "Noctule Scan 1.0.0 is the newest version." (Also when a running beta is newer than the latest stable release, e.g. 1.1.0-beta.1 against 1.0.0: "Noctule Scan 1.1.0-beta.1 is newer than the latest release, 1.0.0.", designer's call.)
- **Couldn't check for updates** — a plain reason: the system's own message for network errors; "No release has been published yet." for 404; "GitHub is limiting requests. Try again later." for 403/429; "GitHub sent an answer Noctule Scan couldn't read." for the rest.
- **This is a development build** — "Version 0.0.0 can't be compared with releases. Builds from a release tag check for updates."

### 6.4 Settings › General

A new **Updates** section below Export and Import:

- **Check for updates automatically** (a switch, on by default).
- **Last checked today at 9:41** (relative date and time; "Never" before the first successful check) and a **Check Now** button, which is the menu item.
- Footer: "At launch and once a day, Noctule Scan asks GitHub for its latest release (betas aren't included). Nothing is downloaded or installed."

The General tab is a fixed 600 × 420 today; it grows to fit.

## 7. Testing and agent safety

- **No test reaches GitHub.** The checker takes its fetch as an injected protocol; tests feed it canned replies (200 with a newer, equal, older, pre-release, draft or unparseable release; 404; 403; 500; garbage; a slow reply past the timeout; a hostile `html_url`) and a stepped clock for the 24-hour timer, skip, later and "last checked".
- **Version parsing and order** have their own table-driven tests.
- **The app never asks GitHub while it runs on a private settings directory** (designer's call): with `NOCTULE_SETTINGS_DIR` set to anything but the standard directory, the real URL is never used; only the test feed below is. Together with the `0.0.0` rule, this keeps `AppLifecycleIntegrationTests`, hand checks and computer-use runs off the network, and a test pins it.
- **Test-only overrides** (`SessionEnvironment.applyingOverrides` style; honoured only with a private `NOCTULE_SETTINGS_DIR`, otherwise `ignoring …`; printed as `NoctuleScan: test override: …` when in effect):
  - `NOCTULE_TEST_UPDATE_FEED=<URL>`: in place of the GitHub URL. A `file://` JSON file or an `http://127.0.0.1` server, or, for the one end-to-end check below, the real GitHub URL spelled out.
  - `NOCTULE_TEST_APP_VERSION=<version>`: in place of the app's full version (§5.0), so a `0.0.0` build can act as, say, 0.9.0 or 1.0.1-beta.2.
- **Hand checks on the mocks** (and by driving the app): the window from a launch check, each button, Esc, the menu item's four outcomes, the switch, Check Now, and a check failing while a mock station's session runs untouched.
- **One end-to-end check, after 1.0.0 is published** (the owner's call when): a local build with `NOCTULE_TEST_APP_VERSION=0.9.0` and `NOCTULE_TEST_UPDATE_FEED` set to the real GitHub URL shows 1.0.0's window; then the installed 1.0.0 says "You're up to date". **No throwaway release is needed** for any of this (the owner offered one).
- Documentation: AGENTS.md gets the feature, the overrides and the "never reaches GitHub from a private settings directory" rule; `docs/specs/README.md` lists this design and the plan.

## 8. Left to the builder

- Type and file names, how the checker is owned (likely by the `AppDelegate`, beside the `SessionRegistry`), and how the window is presented (a SwiftUI `Window` scene or an `NSWindow`), as long as §6.1's focus rules hold (ordering front without becoming key is easiest with an `NSWindow`/`NSPanel` the delegate owns).
- The `User-Agent` string (something like `NoctuleScan/<version>`), `Accept: application/vnd.github+json` and the `X-GitHub-Api-Version` header.
- How much Markdown the notes render (§6.1), within "no web view, no remote content".
- Exact wording of the stderr reasons.

## 9. What was built

Plan 22 (`2026-11-22-plan-22-update-check.md`) built §§5–7 as designed. `UpdateChecker` (an `@MainActor @Observable` object the `AppDelegate` owns), the feed parser, version ordering and all copy (`UpdateText`) are in `NoctuleAppCore`, so iOS can reuse them; the Software Update window is an `NSWindow` the app's `UpdateWindowController` owns (ordered front without becoming key for an automatic check, §6.1), the menu item sits under About, and Settings › General › Updates holds the switch, "Last checked" and Check Now (§6.4). The 24-hour timer sleeps on `SuspendingClock`. Both test overrides are honoured only with a private `NOCTULE_SETTINGS_DIR`.

The final review's fixes changed five things. The launch check starts 5 s after launch finishes, because a window ordered front before SwiftUI's launch routing opened the station window ended up behind it (and the network gets time after a login). `SuspendingClock` runs during a dark wake (Power Nap), so the app cancels the timer at `NSWorkspace.willSleepNotification` (`handleSleep()`); after a full wake `handleWake()` sets it again and runs an overdue check no sooner than 10 s after the wake, and the fetch waits for connectivity within its 15 s limit, so a check right after a wake doesn't fail for want of Wi-Fi and then wait a day. No automatic check starts within 60 s of the last one, on the monotonic clock, whatever the wall clock does. And an automatic result's window refuses to become key until it is clicked (or a manual check shows it), so closing another window can't hand it the focus.

The hand checks on the mocks are the plan's Task 9 Step 3 list; their results are recorded here when they are run. The one end-to-end check against GitHub waits for 1.0.0 to be published (§7).
