# Plan 22: Checking for Updates — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac app asks GitHub for the newest stable release of Noctule Scan at launch, every 24 hours and on request, and shows a Software Update window when it is newer than the running app, without ever getting in the way of a scanner session.

**Architecture:** Platform-neutral logic in `NoctuleAppCore/Updates/` (version parsing, the release feed and its decoding, the test-override configuration, the `UpdateChecker` state machine, the copy) over a small preferences store in `NoctuleStore` (`app.json`). The `NoctuleScan` shell adds one AppKit-owned window, a menu item and a Settings section, and the `AppDelegate` owns the checker. `release.sh` stamps a new `NoctuleFullVersion` key so a beta build knows it is a beta.

**Tech Stack:** Swift 6, Swift Testing, Foundation `URLSession`, SwiftUI + AppKit (shell only), bash (`release.sh`).

**Spec:** `docs/specs/2026-11-22-update-check-design.md` (approved by the owner 2026-11-22). Read it first; section numbers below (§n) are its.

## Global Constraints

- Feed URL: `https://api.github.com/repos/noctule-dev/noctule-scan/releases/latest`. Headers: `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: NoctuleScan/<running version>`. Timeout 15 s.
- The release page opened by Download… must start with `https://github.com/noctule-dev/noctule-scan/releases/` (scheme, host and path prefix); anything else is a failed check.
- `app.json` keys: `checkForUpdates` (default `true`), `lastUpdateCheck` (ISO 8601, last *successful* check), `skippedUpdateVersion` (string). Best effort, like the rest of `app.json`: unreadable reads as defaults.
- `Info.plist` key `NoctuleFullVersion`, tracked as `0.0.0`. Running version = `NoctuleFullVersion`, else `CFBundleShortVersionString`. `0.0.0`, missing or unparseable = a development build: never checks automatically.
- With a private `NOCTULE_SETTINGS_DIR` (set and not the standard directory), the GitHub URL is never used; only `NOCTULE_TEST_UPDATE_FEED`.
- Automatic checks never show anything but the update window, never make it key, never activate the app; every automatic outcome is one stderr line `NoctuleScan: HH:mm:ss update check: <text>`. Manual checks show every outcome and make the window key.
- Nothing from a check may throw past the checker, block the main actor, or delay launch, a station session or quit.
- No new art: the window shows `NSApp.applicationIconImage` (placeholder in local builds, official in releases through `NOCTULE_BRANDING_DIR`).
- `NoctuleAppCore` and `NoctuleStore` stay free of AppKit/SwiftUI; `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build` passes after each core task.
- Every new `.swift` file starts with the two-line SPDX notice (AGENTS.md); every new `@Suite` has a `.timeLimit`; every commit is `git commit -s` with the session's attribution lines; run tests with `NOCTULE_NO_USB_DETECTION=1`.
- No test or agent run ever reaches `api.github.com`.

## Review Focus

1. **A check in flight at quit or sleep** (GitHub slow or unreachable): quit must not wait on it and nothing must be presented after `stop()`. Test: Task 6 `stopCancelsAnInFlightCheck`.
2. **The clock moves oddly** (`lastUpdateCheck` in the future after a date change; a Mac asleep for days): the timer never waits more than 24 h and an overdue check runs once, not in a loop. Tests: Task 6 `futureLastCheckWaitsAtMostADay`, `wakeAfterADayChecksOnce`.
3. **The preference turned off while an automatic check is in flight:** its result is logged but not shown. Test: Task 6 `turningOffDropsAnInFlightAutomaticResult`.
4. **`noctule log` rewriting `app.json`** (it sets `lastStationID`) between the app's writes: the update keys and the CLI's keys survive each other. Test: Task 3 `updateKeysAndLastStationSurviveEachOther`.
5. **Hostile or odd release notes** (links, raw HTML, empty body): links are not clickable, HTML shows as text, empty shows "No release notes.". Test: Task 7 `notesDropLinks`, `notesShowHTMLAsText`, `emptyNotes`.

---

### Task 1: The full version in the bundle

**Files:**
- Modify: `Resources/Info.plist` (add `NoctuleFullVersion` = `0.0.0` after `CFBundleVersion`)
- Modify: `packaging/release.sh:82-85` (stamp), `:110-118` (check)
- Modify: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`InfoPlistTests`, `bundleVersions`, `ReleaseTests`)
- Modify: `packaging/README.md` where it says what `release.sh` stamps

**Interfaces:**
- Produces: `Info.plist` key `NoctuleFullVersion` (string), `0.0.0` in the repo, the full tag version (`1.0.1-beta.2`) in a release.

- [ ] **Step 1: Write the failing tests**

In `InfoPlistTests.identifierAndDevelopmentVersion` add `#expect(plist["NoctuleFullVersion"] as? String == "0.0.0")`. Change `bundleVersions` to also return `full: plist?["NoctuleFullVersion"] as? String`. In `versionInsideTheDMGIsChecked` add `#expect(versions.full == "0.2.0")`. In the beta release test at the `v0.3.0-beta.1` tag, mount the DMG and expect `short == "0.3.0"`, `full == "0.3.0-beta.1"`. New test:

```swift
@Test func wrongFullVersionInsideTheDMGFails() async throws {
    let stubs = try StubTools()
    let repo = try await fakeRepository(in: stubs.directory)
    try await tagHead(repo, "v0.2.0")
    let result = try await release(["0.2.0", "--build", "12"], stubs, repo, ["STUB_PLUTIL_NOOP_KEY": "NoctuleFullVersion"])
    #expect(result.status == 1)
    #expect(result.stderr.contains("release: the app in the DMG says its full version is 0.0.0, expected 0.2.0"), "\(result.stderr)")
    #expect(!result.stdout.contains("sha256:"))
    #expect(try await attachedImages(under: stubs.directory) == false)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'InfoPlistTests|ReleaseTests'`
Expected: FAIL on the new expectations.

- [ ] **Step 3: Implement**

Add the key to `Resources/Info.plist`. In `release.sh` add `plutil -replace NoctuleFullVersion -string "$version" "$app/Contents/Info.plist"` after the two existing `-replace` lines. After the existing short/build comparison (keep it and its message unchanged), read `inside_full="$(plutil -extract NoctuleFullVersion raw "$inside")" || fail "couldn't read the app's full version in the DMG"` and `[[ "$inside_full" == "$version" ]] || fail "the app in the DMG says its full version is $inside_full, expected $version"`. Update `packaging/README.md`'s description of what is stamped.

- [ ] **Step 4: Run them to see them pass**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'InfoPlistTests|ReleaseTests|DiskImageTests'`
Expected: PASS (these suites run one test at a time and make disk images; allow a few minutes).

- [ ] **Step 5: Commit** — `git commit -s -m "packaging: stamp the full version as NoctuleFullVersion"`

---

### Task 2: `AppVersion`

**Files:**
- Create: `Sources/NoctuleAppCore/Updates/AppVersion.swift`
- Test: `Tests/NoctuleAppCoreTests/AppVersionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
      public let major: Int, minor: Int, patch: Int
      public let prerelease: [String]          // [] for a final; ["beta", "4"] for -beta.4
      public init?(_ text: String)             // optional leading "v"
      public var isFinal: Bool                 // prerelease.isEmpty
      public var isDevelopment: Bool           // 0.0.0 with no prerelease
      public var description: String           // "1.2.3" / "1.2.3-beta.4", no "v"
  }
  ```

- [ ] **Step 1: Write the failing tests** (table-driven, `@Suite(.timeLimit(.minutes(1))) struct AppVersionTests`)

- `parses`: `"1.2.3"`, `"v1.2.3"`, `"1.2.3-beta.4"`, `"v0.1.1-beta.4"`, `"10.20.30"` parse; `description` drops the `v`.
- `refuses`: `""`, `"1.2"`, `"1.2.3.4"`, `"01.2.3"`, `"1.2.3-"`, `"1.2.3+meta"`, `"1.2.3-beta..1"`, `"v"`, `" 1.2.3"`, `"latest"` give nil (the same grammar as `release.sh`'s `semver` regex, minus build metadata).
- `orders`: `1.0.0-beta.3 < 1.0.0-beta.10 < 1.0.0 < 1.0.1-beta.1 < 1.0.1 < 1.1.0 < 2.0.0`; `1.0.0-alpha < 1.0.0-beta` (alphanumeric identifiers compare as ASCII, numeric ones as numbers and below alphanumeric, a shorter prefix list first: SemVer 2.0.0 §11); `AppVersion("v1.0.0") == AppVersion("1.0.0")`.
- `development`: `0.0.0` is development; `0.0.0-beta.1`, `0.0.1` aren't.

- [ ] **Step 2: Run to see it fail** — `NOCTULE_NO_USB_DETECTION=1 swift test --filter AppVersionTests` → FAIL (no type).

- [ ] **Step 3: Implement `AppVersion`** — hand parser or `Regex`; precedence per SemVer §11. No dependency.

- [ ] **Step 4: Run to see it pass** — same command → PASS.

- [ ] **Step 5: Commit** — `git commit -s -m "app core: AppVersion, semantic version parsing and order"`

---

### Task 3: Update preferences in `app.json`

**Files:**
- Create: `Sources/NoctuleStore/UpdatePreferences.swift`
- Modify: `Sources/NoctuleStore/LocalSettingsStore.swift` (`AppFile` and its `CodingKeys`/`init(from:)`, a conformance)
- Test: `Tests/NoctuleStoreTests/UpdatePreferencesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct UpdatePreferences: Equatable, Sendable {
      public var checkAutomatically: Bool = true   // app.json "checkForUpdates"
      public var lastChecked: Date? = nil          // "lastUpdateCheck"
      public var skippedVersion: String? = nil     // "skippedUpdateVersion"
      public init()
  }
  public protocol UpdatePreferencesStore: Sendable {
      func updatePreferences() async -> UpdatePreferences
      func saveUpdatePreferences(_ preferences: UpdatePreferences) async   // best effort, never throws
  }
  extension LocalSettingsStore: UpdatePreferencesStore
  public actor InMemoryUpdatePreferences: UpdatePreferencesStore { public init(_ initial: UpdatePreferences = .init()) }
  ```

- [ ] **Step 1: Write the failing tests** (`@Suite(.timeLimit(.minutes(1)))`, each in its own temporary directory, removed after)

- `defaultsWithNoFile`: a fresh store gives `UpdatePreferences()` (on, nil, nil).
- `roundTrip`: save `(false, <date>, "1.0.1")`, a *new* `LocalSettingsStore` on the same directory reads it back equal (dates to the second); the file holds `"checkForUpdates" : false`, `"lastUpdateCheck"`, `"skippedUpdateVersion" : "1.0.1"`.
- `updateKeysAndLastStationSurviveEachOther`: `setLastStationID(a)`, save preferences, `setLastStationID(b)` on a second store instance → preferences unchanged and `lastStationID() == b`; and `storageLocation` survives a preferences save.
- `oldFileReadsDefaults`: an `app.json` of `{"version":1,"lastStationID":"<uuid>"}` reads the update defaults and keeps the station.
- `garbageFileReadsDefaults`: `app.json` of `not json` → defaults, no throw.

- [ ] **Step 2: Run to see it fail** — `NOCTULE_NO_USB_DETECTION=1 swift test --filter UpdatePreferencesTests` → FAIL.

- [ ] **Step 3: Implement** — add the three optional fields to `AppFile` (decoded with `decodeIfPresent`, default `true`/nil); conformance reads/writes through `loadApp()` and `try? write(file, to: "app.json")`.

- [ ] **Step 4: Run to see it pass**, plus `--filter SettingsStoreTests` (unchanged behaviour) → PASS.

- [ ] **Step 5: Commit** — `git commit -s -m "store: update preferences in app.json"`

---

### Task 4: The release feed and its decoding

**Files:**
- Create: `Sources/NoctuleAppCore/Updates/ReleaseFeed.swift`
- Test: `Tests/NoctuleAppCoreTests/ReleaseFeedTests.swift`

**Interfaces:**
- Consumes: `AppVersion` (Task 2).
- Produces:
  ```swift
  public struct LatestRelease: Equatable, Sendable { public let version: AppVersion; public let notes: String; public let page: URL }
  public enum UpdateCheckFailure: Error, Equatable, Sendable {
      case network(String)        // the system's localized message
      case noRelease              // 404
      case rateLimited            // 403, 429
      case unreadable(String)     // anything else; the String is a short log detail ("status 500", "draft", "tag v1.x", "page http://…")
      case disabledForTesting     // private NOCTULE_SETTINGS_DIR, no test feed
  }
  public protocol ReleaseFetching: Sendable { func fetch(_ url: URL) async throws -> (status: Int, body: Data) }
  public struct URLSessionReleaseFetcher: ReleaseFetching { public init(userAgent: String, timeout: Duration = .seconds(15)) }
  public enum ReleaseFeed {
      public static let gitHubLatest: URL          // the Global Constraints URL
      public static let pagePrefix = "https://github.com/noctule-dev/noctule-scan/releases/"
      public static func decode(status: Int, body: Data) -> Result<LatestRelease, UpdateCheckFailure>
      public static func failure(for error: any Error) -> UpdateCheckFailure   // URLError etc. → .network(localizedDescription)
  }
  ```

- [ ] **Step 1: Write the failing tests** (`@Suite(.timeLimit(.minutes(1)))`; bodies are small JSON literals with fictional notes)

- `decodesAStableRelease`: status 200, `{"tag_name":"v1.0.1","prerelease":false,"draft":false,"body":"Fixes.","html_url":"https://github.com/noctule-dev/noctule-scan/releases/tag/v1.0.1"}` → `.success(LatestRelease(version: 1.0.1, notes: "Fixes.", page: …))`; a `null` body → `notes == ""`.
- `refusesWhatIsNotAStableRelease`: `prerelease: true` → `.unreadable("pre-release")`; `draft: true` → `.unreadable("draft")`; `tag_name: "nightly"` → `.unreadable` containing `"tag"`.
- `refusesAPageOffTheRepository`: `html_url` of `http://github.com/noctule-dev/noctule-scan/releases/x`, `https://github.com.evil.example/noctule-dev/noctule-scan/releases/x`, `https://github.com/someone-else/noctule-scan/releases/x`, `https://github.com/noctule-dev/noctule-scan/issues/1` → each `.unreadable` containing `"page"`.
- `mapsStatuses`: 404 → `.noRelease`; 403 and 429 → `.rateLimited`; 500 → `.unreadable("status 500")`; 200 with `not json` → `.unreadable`.
- `mapsNetworkErrors`: `failure(for: URLError(.notConnectedToInternet))` → `.network(<its localizedDescription>)`; a `CancellationError` → `.network` too (never thrown on).
- `fileFeedReadsTheFile`: `URLSessionReleaseFetcher(userAgent: "test").fetch(<file URL of a temp JSON>)` → status 200, the file's bytes; a missing file → status 404. (No network: file URLs only.)
- `requestCarriesTheHeaders`: the fetcher exposes `static func request(for url: URL, userAgent: String, timeout: Duration) -> URLRequest`; assert the three headers and `timeoutInterval == 15`.

- [ ] **Step 2: Run to see it fail** — `NOCTULE_NO_USB_DETECTION=1 swift test --filter ReleaseFeedTests` → FAIL.

- [ ] **Step 3: Implement** — `Decodable` private struct with `tag_name`, `prerelease`, `draft`, `body: String?`, `html_url`; the page check compares `scheme == "https"`, `host == "github.com"` and `absoluteString.hasPrefix(pagePrefix)`. The fetcher reads `file:` URLs with `Data(contentsOf:)` (missing → 404) and uses an ephemeral `URLSession` (no cookies, no cache) for http(s); a non-HTTP response is an error.

- [ ] **Step 4: Run to see it pass**; then the iOS build (Global Constraints) → PASS / BUILD SUCCEEDED.

- [ ] **Step 5: Commit** — `git commit -s -m "app core: the release feed and its decoding"`

---

### Task 5: The update check's configuration and test overrides

**Files:**
- Create: `Sources/NoctuleAppCore/Updates/UpdateCheckConfiguration.swift`
- Test: `Tests/NoctuleAppCoreTests/UpdateCheckConfigurationTests.swift`

**Interfaces:**
- Consumes: `AppVersion`, `ReleaseFeed.gitHubLatest`, `SessionEnvironment.OverrideKey.settingsDirectory`, `SessionEnvironment.standardSettingsDirectory`, `FileRTSPCooldownStore.samePath`.
- Produces:
  ```swift
  public struct UpdateCheckConfiguration: Equatable, Sendable {
      public var runningVersionText: String      // as found, for messages ("0.0.0")
      public var runningVersion: AppVersion?     // nil or isDevelopment → a development build
      public var feed: URL?                      // nil → .disabledForTesting
      public var isDevelopmentBuild: Bool { runningVersion?.isDevelopment ?? true }
      public static func resolve(variables: [String: String], infoDictionary: [String: Any],
                                 standardSettingsDirectory: URL = SessionEnvironment.standardSettingsDirectory)
          -> (configuration: UpdateCheckConfiguration, notes: [String])
  }
  extension SessionEnvironment.OverrideKey {
      public static let testUpdateFeed = "NOCTULE_TEST_UPDATE_FEED"
      public static let testAppVersion = "NOCTULE_TEST_APP_VERSION"
  }
  ```

- [ ] **Step 1: Write the failing tests** (`@Suite(.timeLimit(.minutes(1)))`; "private" = a temp dir; "standard" = the `standardSettingsDirectory` argument)

- `standardSettingsUseGitHub`: no variables, info `["NoctuleFullVersion": "1.0.0", "CFBundleShortVersionString": "1.0.0"]` → feed `ReleaseFeed.gitHubLatest`, running `1.0.0`, notes `[]`.
- `fullVersionWins`: info full `1.0.1-beta.2`, short `1.0.1` → running `1.0.1-beta.2`; full missing or `""` → `1.0.1`.
- `developmentBuilds`: `0.0.0`, no keys, `"garbage"` → `isDevelopmentBuild`.
- `privateSettingsNeverUseGitHub`: `NOCTULE_SETTINGS_DIR=<private>` → feed nil, notes `["no update checks with a private NOCTULE_SETTINGS_DIR"]`.
- `privateSettingsWithATestFeed`: plus `NOCTULE_TEST_UPDATE_FEED=file:///tmp/x.json` → that feed; note `"NOCTULE_TEST_UPDATE_FEED=file:///tmp/x.json (in place of GitHub's latest release)"`. The real GitHub URL given there is honoured the same way.
- `testAppVersion`: private + `NOCTULE_TEST_APP_VERSION=0.9.0` → running `0.9.0`, note `"NOCTULE_TEST_APP_VERSION=0.9.0 (in place of the app's version)"`; `=nope` → note `"ignoring NOCTULE_TEST_APP_VERSION=nope: not a version"`, running unchanged.
- `overridesNeedPrivateSettings`: either override with no `NOCTULE_SETTINGS_DIR`, or with it set to the standard directory (spelled through a symlink too) → ignored, note `"ignoring <KEY>: it needs a private NOCTULE_SETTINGS_DIR"`, feed GitHub.
- `badFeed`: private + `NOCTULE_TEST_UPDATE_FEED=ftp://x` or `not a url` → `"ignoring NOCTULE_TEST_UPDATE_FEED=<v>: not a file, http or https URL"`, feed nil.

- [ ] **Step 2: Run to see it fail** — `--filter UpdateCheckConfigurationTests` → FAIL.
- [ ] **Step 3: Implement `resolve`** — empty values count as unset (as `applyingOverrides`).
- [ ] **Step 4: Run to see it pass**; iOS build → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "app core: update check configuration and its test overrides"`

---

### Task 6: `UpdateChecker`

**Files:**
- Create: `Sources/NoctuleAppCore/Updates/UpdateChecker.swift`
- Test: `Tests/NoctuleAppCoreTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces:
  ```swift
  public enum UpdateCheckTrigger: Sendable, Equatable { case launch, scheduled, manual }
  public struct UpdateOffer: Equatable, Sendable { public let release: LatestRelease; public let running: AppVersion }
  public enum UpdateCheckResult: Equatable, Sendable {
      case updateAvailable(UpdateOffer)
      case upToDate(running: AppVersion, latest: AppVersion)
      case developmentBuild(versionText: String)
      case failed(UpdateCheckFailure)
  }
  @MainActor @Observable public final class UpdateChecker {
      public static let interval: Duration = .seconds(86_400)
      public init(configuration: UpdateCheckConfiguration, preferences: any UpdatePreferencesStore,
                  fetcher: any ReleaseFetching,
                  now: @escaping @Sendable () -> Date = { Date() },
                  sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                  present: @escaping @MainActor (UpdateCheckResult, UpdateCheckTrigger) -> Void,
                  log: @escaping @Sendable (String) -> Void)
      public private(set) var isChecking: Bool
      public private(set) var checksAutomatically: Bool      // loaded by start()
      public private(set) var lastChecked: Date?
      public func start() async                  // load prefs; launch check if on and not development and feed != nil; schedule
      public func checkNow() async               // manual; joins a running check (its result then presented as manual)
      public func setChecksAutomatically(_ on: Bool) async
      public func skip(_ version: AppVersion) async
      public func handleWake()                   // re-evaluate the timer; an overdue check runs once
      public func stop()                         // cancel timer and in-flight check; nothing is presented after
  }
  public enum UpdateCheckLog { public static func line(_ text: String, at: Date = Date(), timeZone: TimeZone = .current) -> String }
  // "NoctuleScan: HH:mm:ss update check: <text>"
  ```

Rules the tests pin (spec §5): a result is **presented** for every manual check (skipped version included), and for an automatic one only when it is `.updateAvailable`, its version isn't `skippedVersion`, and `checksAutomatically` is still true when it arrives. Every automatic check **logs** one line: `Noctule Scan <v> is available`, `up to date (<running>)`, `skipped <v>`, or the failure (`no release published yet`, `rate limited by GitHub`, `<network message>`, `couldn't read GitHub's answer (<detail>)`). `lastChecked` is saved after a successful check only. Next automatic check: `max(lastChecked, lastAttempt) + interval`, clamped to at most `interval` from now (`lastAttempt` is in memory, so a failure waits a full day, never retries sooner). A manual check on a development build presents `.developmentBuild` and fetches nothing; with feed nil, `.failed(.disabledForTesting)`. Comparison: `release.version > running` → update; else `.upToDate`.

- [ ] **Step 1: Write the failing tests** (`@MainActor @Suite(.timeLimit(.minutes(1)))`). Test doubles in the test file: `FakeFetcher` (an actor returning queued `(status, body)` or throwing, counting calls; optionally suspended until released, for in-flight tests), `TestSleeper` (records each requested `Duration` and suspends until the test calls `resume()`; throws `CancellationError` when cancelled), a mutable `now`, `InMemoryUpdatePreferences`, and arrays collecting `present` and `log` calls. Fictional versions throughout.

- `launchFindsAnUpdate`: running 1.0.0, feed 1.0.1 → presented `[(.updateAvailable, .launch)]`, log `["Noctule Scan 1.0.1 is available"]`, `lastChecked == now`, saved.
- `launchUpToDateShowsNothing`: feed 1.0.0 → nothing presented, log `up to date (1.0.0)`.
- `betaIsToldAboutItsFinal`: running `1.0.0-beta.3`, feed 1.0.0 → `.updateAvailable`.
- `aheadOfTheRelease`: manual, running `1.1.0-beta.1`, feed 1.0.0 → `.upToDate(running: 1.1.0-beta.1, latest: 1.0.0)`.
- `launchFailureIsOnlyLogged`: 404 → nothing presented, log `no release published yet`, `lastChecked` stays nil; throwing `URLError(.notConnectedToInternet)` → nothing presented, one log line.
- `manualShowsEveryOutcome`: up to date, 404, 403, garbage, network error → each presented with `.manual`, matching `.failed(...)`/`.upToDate`.
- `preferenceOffMeansNoLaunchCheck`: prefs off → `start()` fetches nothing, schedules nothing; `checkNow()` still fetches and presents.
- `developmentBuildNeverChecksByItself`: running `0.0.0` → `start()` fetches nothing; `checkNow()` presents `.developmentBuild(versionText: "0.0.0")`, fetches nothing.
- `noFeedManual`: feed nil → `start()` fetches nothing; `checkNow()` presents `.failed(.disabledForTesting)`.
- `skipHidesThatVersionFromAutomaticChecks`: `skip(1.0.1)` saved; next launch with feed 1.0.1 → nothing presented, log `skipped 1.0.1`; feed 1.0.2 → presented; manual with 1.0.1 → presented.
- `schedulesADayAfterTheLastCheck`: after a successful launch check the sleeper was asked for `interval`; `resume()` → a `.scheduled` check runs.
- `futureLastCheckWaitsAtMostADay`: saved `lastChecked` = now + 3 days, prefs on, launch check fails → requested sleep ≤ `interval`.
- `wakeAfterADayChecksOnce`: after a launch check, advance `now` by 2 days, `handleWake()` → exactly one fetch, then a new sleep of `interval`.
- `turningOnChecksWhenOverdue`: prefs off with `lastChecked` 2 days ago → `setChecksAutomatically(true)` fetches once and saves `true`; with `lastChecked` 1 hour ago → no fetch, a sleep ≤ 23 h.
- `turningOffDropsAnInFlightAutomaticResult`: launch check suspended in the fetcher; `setChecksAutomatically(false)`; release with 1.0.1 → nothing presented, one log line, timer cancelled.
- `manualJoinsARunningCheck`: launch check suspended; `checkNow()` → still one fetch; on release, presented once with `.manual`.
- `isCheckingTracksTheCheck`: true while suspended, false after.
- `stopCancelsAnInFlightCheck`: suspended fetch; `stop()`; release → nothing presented, no `lastChecked`, no further sleeps.
- `logLineFormat`: `UpdateCheckLog.line("up to date (1.0.0)", at: <fixed date>, timeZone: .gmt)` == `"NoctuleScan: 09:41:00 update check: up to date (1.0.0)"`.

- [ ] **Step 2: Run to see it fail** — `--filter UpdateCheckerTests` → FAIL.
- [ ] **Step 3: Implement** — one `Task` for the timer and one for the in-flight check, both cancelled by `stop()`; the fetch runs off the main actor; a generation counter or the task identity decides whether a returning result is still wanted.
- [ ] **Step 4: Run to see it pass**; iOS build → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "app core: UpdateChecker"`

---

### Task 7: The words and the release notes

**Files:**
- Create: `Sources/NoctuleAppCore/Updates/UpdateText.swift`
- Test: `Tests/NoctuleAppCoreTests/UpdateTextTests.swift`

**Interfaces:**
- Consumes: Task 6's types.
- Produces:
  ```swift
  public struct UpdateMessage: Equatable, Sendable { public let title: String; public let body: String }
  public enum UpdateText {
      public static let windowTitle = "Software Update"
      public static let headline = "A new version of Noctule Scan is available"
      public static func available(_ offer: UpdateOffer) -> String
      public static func message(for result: UpdateCheckResult) -> UpdateMessage?   // nil for .updateAvailable
      public static func notes(_ body: String) -> AttributedString
      public static func lastChecked(_ date: Date?, now: Date) -> String
      public static let automaticToggle = "Check for updates automatically"
      public static let settingsFooter = "At launch and once a day, Noctule Scan asks GitHub for its latest release (betas aren't included). Nothing is downloaded or installed."
      public static let menuItem = "Check for Updates…"
  }
  ```

- [ ] **Step 1: Write the failing tests** (`@Suite(.timeLimit(.minutes(1)))`; exact copy from spec §6)

- `availableLine`: offer 1.0.1 / running 1.0.0 → `"Noctule Scan 1.0.1 is available — you have 1.0.0."`
- `messages`: `.upToDate(1.0.0, 1.0.0)` → `("You're up to date", "Noctule Scan 1.0.0 is the newest version.")`; `.upToDate(1.1.0-beta.1, 1.0.0)` → body `"Noctule Scan 1.1.0-beta.1 is newer than the latest release, 1.0.0."`; `.failed(.noRelease)` → `("Couldn't check for updates", "No release has been published yet.")`; `.rateLimited` → `"GitHub is limiting requests. Try again later."`; `.unreadable(_)` → `"GitHub sent an answer Noctule Scan couldn't read."`; `.network("The Internet connection appears to be offline.")` → that text; `.disabledForTesting` → `"Update checks are off with a private settings folder (NOCTULE_SETTINGS_DIR)."`; `.developmentBuild("0.0.0")` → `("This is a development build", "Version 0.0.0 can't be compared with releases. Builds from a release tag check for updates.")`.
- `notesRenderInlineMarkdown`: `"**Fixed** a crash"` → characters `"Fixed a crash"` with bold on `Fixed`.
- `notesDropLinks`: `"See [the page](https://example.com) and <https://example.com>"` → no run has a `.link` attribute.
- `notesShowHTMLAsText`: `"<script>x</script>"` → the characters are kept as written.
- `emptyNotes`: `""` and whitespace-only → `"No release notes."`
- `lastCheckedText`: nil → `"Last checked: never"`; a date → starts `"Last checked: "` and uses `Date.RelativeFormatStyle`/`formatted(date: .abbreviated, time: .shortened)` (builder's call which; the test pins the prefix and that today reads "today").

- [ ] **Step 2: Run to see it fail** — `--filter UpdateTextTests` → FAIL.
- [ ] **Step 3: Implement** — `AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`, falling back to plain text on throw; strip `.link` from every run.
- [ ] **Step 4: Run to see it pass**; iOS build → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "app core: update check copy and release notes"`

---

### Task 8: The window, the menu item and the app's wiring

**Files:**
- Create: `Sources/NoctuleScan/Updates/UpdateWindowController.swift` (an `NSWindowController` the delegate owns; hosts `UpdateWindowView` in an `NSHostingController`)
- Create: `Sources/NoctuleScan/Updates/UpdateWindowView.swift`
- Modify: `Sources/NoctuleScan/AppDelegate.swift` (own `updates: UpdateChecker`; start after launch; `handleWake()` beside the wake observer; `stop()` first in `applicationShouldTerminate` and the refused-quit path; print configuration notes as `NoctuleScan: test override: <note>`)
- Modify: `Sources/NoctuleScan/NoctuleScanApp.swift` (`CommandGroup(after: .appInfo)` with `UpdateText.menuItem`, disabled while `isChecking`)
- Test: `Tests/NoctuleCLIIntegrationTests/AppLifecycleIntegrationTests.swift` (two tests)

**Interfaces:**
- Consumes: Tasks 5–7. `UpdateChecker.present` is `UpdateWindowController.show(_ result: UpdateCheckResult, trigger: UpdateCheckTrigger)`; its log closure writes `UpdateCheckLog.line(text)` to stderr.
- Produces: `AppDelegate.updates` (for Task 9's Settings section).

Window rules (spec §6.1, §6.3): one window, reused; `.updateAvailable` shows icon (`NSApp.applicationIconImage`), headline, `UpdateText.available`, notes (`UpdateText.notes`) in a ~150 pt scroll area, **Skip This Version** (left; `skip`, close), **Later** (`.cancelAction`, close), **Download…** (`.defaultAction`; `NSWorkspace.shared.open(release.page)`, close). Any other result shows its `UpdateMessage` with the icon and one **OK** (`.defaultAction`) — in this same non-modal window, never `NSAlert.runModal` (a modal alert would block quit, AGENTS.md "Quit"). The close button = Later. **Focus:** `.manual` → `NSApp.activate()` then `makeKeyAndOrderFront`; otherwise `orderFront(nil)` only (no `makeKey`, no `activate`), and `canBecomeKey` stays true so a click focuses it.

- [ ] **Step 1: Write the failing integration tests** (in the USB or network run fixture already there; both launch through the suite's safety environment)

- `updateCheckOffWithPrivateSettings`: launch with no update overrides → stderr contains `NoctuleScan: test override: no update checks with a private NOCTULE_SETTINGS_DIR` and no line containing `update check:`; quit exits 0 within 15 s.
- `updateCheckUsesTheTestFeed`: write `latest.json` (tag `v1.0.0`, stable, `html_url` under the repo, fictional notes) into the run's root; launch with `NOCTULE_TEST_UPDATE_FEED=<its file URL>`, `NOCTULE_TEST_APP_VERSION=0.9.0` → within 10 s stderr contains `update check: Noctule Scan 1.0.0 is available`; the station still starts (`waitForLock(by:within:)` holds within 30 s); SIGTERM exits 0 within 15 s with the window open.

- [ ] **Step 2: Run to see them fail** — `scripts/build-app.sh` not needed (the suite uses the built binary); `NOCTULE_NO_USB_DETECTION=1 swift build && NOCTULE_NO_USB_DETECTION=1 swift test --filter 'AppLifecycleIntegrationTests/updateCheck'` → FAIL.
- [ ] **Step 3: Implement** the controller, view, delegate wiring and menu item.
- [ ] **Step 4: Run to see them pass**, then the whole `AppLifecycleIntegrationTests` → PASS.
- [ ] **Step 5: Commit** — `git commit -s -m "app: Software Update window and Check for Updates…"`

---

### Task 9: Settings › General › Updates, docs and hand checks

**Files:**
- Modify: `Sources/NoctuleScan/Settings/SettingsView.swift` (`GeneralSettingsTab` gets the checker; new `Section` "Updates"; frame height raised so all three sections fit without scrolling)
- Modify: `Sources/NoctuleScan/NoctuleScanApp.swift` (pass `appDelegate.updates` into `SettingsView`)
- Modify: `AGENTS.md` (the feature under "The Mac app"; the two overrides under "Launching it"; the rule "no test or agent run reaches GitHub: a private settings directory never uses it"), `docs/specs/README.md` (this plan under Plans), `docs/specs/2026-11-22-update-check-design.md` (a closing "What was built" note), `LESSONS.md` (anything that surprised you, dated)

Section (spec §6.4): a `Toggle(UpdateText.automaticToggle)` bound to `checksAutomatically` through `setChecksAutomatically`; a row with `UpdateText.lastChecked(updates.lastChecked, now: .now)` and **Check Now** (`checkNow()`, disabled while `isChecking`); footer `UpdateText.settingsFooter` in the existing caption style.

- [ ] **Step 1: Build and run the full suite** — `NOCTULE_NO_USB_DETECTION=1 swift build && NOCTULE_NO_USB_DETECTION=1 swift test` → PASS (Settings has no unit tests of its own; the copy is pinned in Task 7, the behaviour in Task 6).
- [ ] **Step 2: iOS build** (Global Constraints) → BUILD SUCCEEDED.
- [ ] **Step 3: Hand checks on the mocks** (AGENTS.md "Launching it": `scripts/build-app.sh`, a temp `D`, a mock station, `NOCTULE_SETTINGS_DIR="$D/settings"`, `NOCTULE_NO_USB_DETECTION=1`, plus `NOCTULE_TEST_UPDATE_FEED=file://$D/latest.json` and `NOCTULE_TEST_APP_VERSION=0.9.0`), by hand or by driving the app:
  1. Launch: the station window opens and keeps keyboard focus (press a mapped key: it reaches the mock's `--verbose` log); the Software Update window is in front, not key, with the placeholder icon. Click it; Return = Download… opens the page in the browser.
  2. Later, relaunch: shown again. Skip, relaunch: not shown; stderr `update check: skipped 1.0.0`. Check for Updates…: shown, and key.
  3. `latest.json` at `0.9.0`: Check for Updates… → "You're up to date". Delete it: → "Couldn't check for updates". Without `NOCTULE_TEST_APP_VERSION`: → "This is a development build".
  4. Settings › General: switch off and on (`app.json` follows), Last checked updates, Check Now = the menu item; the tab fits.
  5. ⌘Q with the update window open quits within 15 s; the mock shows `leaked-sessions=0` / `active-subscriptions=0`.
  Delete `$D` afterwards.
- [ ] **Step 4: Update the docs listed above.**
- [ ] **Step 5: Commit** — `git commit -s -m "app: Updates settings; docs for Plan 22"`

**After merge (the owner's call when):** publish 1.0.0; then one end-to-end check with a local build, a private settings directory, `NOCTULE_TEST_APP_VERSION=0.9.0` and `NOCTULE_TEST_UPDATE_FEED=https://api.github.com/repos/noctule-dev/noctule-scan/releases/latest` shows 1.0.0's window; the installed 1.0.0's Check for Updates… says "You're up to date" (spec §7).
