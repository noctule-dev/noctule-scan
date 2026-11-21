# Plan 12: the hello DMG

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. This repo's rules (AGENTS.md) apply on top. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `packaging/release.sh 0.1.0` on the owner's Mac turns the app into `build/Noctule Scan 0.1.0.dmg`, Developer ID signed, notarized and stapled, that opens and launches on another Mac with only the standard "downloaded from the internet" prompt.

**Architecture:** Four bash scripts under `packaging/` beside a README. `release.sh` validates, builds with the existing `scripts/build-app.sh`, stamps the version into the bundle's copy of `Info.plist`, and calls `notarize.sh` (sign, notarize, staple; one file per call) on the app, `dmg/make-dmg.sh` (plain `hdiutil`), `notarize.sh` again on the DMG, then the Gatekeeper checks. The scripts call Apple's tools by name through `PATH`, so the tests run them against stub `codesign`, `xcrun`, `spctl` and `security` and need no certificate; `release.sh` is tested as a copy inside a throwaway git repository with a stub `scripts/build-app.sh`, so no test builds the real app or touches this checkout's `build/`.

**Tech Stack:** bash (`set -euo pipefail`, as `scripts/build-app.sh`), `codesign`, `xcrun notarytool`/`stapler`, `spctl`, `hdiutil`, `ditto`, `plutil`, `shasum`; Swift Testing in `NoctuleCLIIntegrationTests` with its `Subprocess` helper.

**Spec:** `docs/specs/2026-11-13-release-packaging-design.md`, section 5, step 2 (naming in section 3, anti-goals in section 2).

## Global Constraints

- Bundle identifier `app.noctule.scan` (from `org.noctulescan.NoctuleScan`). The tracked `Resources/Info.plist` says `CFBundleShortVersionString` `0.0.0` and `CFBundleVersion` `0`.
- Version argument: semantic versioning, `1.2.3` or `1.2.3-beta.1`; the bundle gets `MAJOR.MINOR.PATCH` (suffix dropped), the DMG the full version: `build/Noctule Scan <version>.dmg`. `CFBundleVersion` is `--build` (default `0`).
- Signing: `codesign --force --options runtime --timestamp --sign <identity>` for the app; the DMG is signed with `--timestamp` (no runtime option). No entitlements file.
- Notarization: App Store Connect API key only. Locally the keychain profile `noctule-notary` (`xcrun notarytool store-credentials noctule-notary --key <p8> --key-id <id> --issuer <issuer>`); in CI (Plan 13) the environment. Both the app (zipped with `ditto -c -k --keepParent`) and the DMG are notarized and stapled.
- **Nothing secret or owner-specific is printed or tracked:** no certificate name or team ID, key ID, issuer or key path in any script's output, in `packaging/README.md`, or in a test fixture beyond obviously fake values. No `set -x`. Commands that carry credentials are never echoed.
- Apple's tools (`codesign`, `xcrun`, `spctl`, `security`) are called by name, never by absolute path, so tests can stub them. `hdiutil`, `ditto`, `plutil`, `git`, `shasum` are never stubbed.
- Scripts are `100755`, start `#!/bin/bash` and `set -euo pipefail`, and quote every path (the app's name has a space). Usage errors exit 2, other failures 1, as `scripts/build-app.sh`.
- `scripts/build-app.sh` stays the development build, unchanged.
- No agent sends anything to Apple (a notarization upload is outward-facing) or runs `release.sh` for real without the owner's go-ahead at the time. No agent creates, exports or reads the owner's certificates or keys.
- AGENTS.md rules hold: `export NOCTULE_NO_USB_DETECTION=1` in every shell that runs tests; the notarized app is launched only on the mocks with a temporary `NOCTULE_SETTINGS_DIR`.

## Review Focus

1. **A checkout path with a space**: every script must work from `/Users/x/My Projects/noctule-scan`. The `release.sh` tests run their fake repository under a directory whose name has a space (Task 4).
2. **Notarization rejected**: `notarytool` reports `Invalid` (or anything but `Accepted`): the run must stop with Apple's log printed, staple nothing, and never print the success lines. Pinned in Task 3 (`notarize.sh`) and Task 4 (`release.sh` prints no `sha256`).
3. **Credentials leaking into output**: a CI log is kept; nothing printed may carry the identity's name or team, the key ID or the issuer. Pinned in Task 3.
4. **The tracked `Info.plist` stamped by accident**: a run, failed or not, must leave the working tree clean. Pinned in Task 4 (`git status --porcelain` empty after a run).
5. **A second run of the same version**: an old DMG or a staging folder from an earlier or interrupted run must not end up inside the new image or make `hdiutil` fail. Pinned in Task 2 (two runs, one DMG with exactly two entries).

---

### Task 1: The bundle identifier and the development version

**Files:**
- Modify: `Resources/Info.plist` (`CFBundleIdentifier`, `CFBundleShortVersionString` `0.1` → `0.0.0`, `CFBundleVersion` `1` → `0`)
- Modify: `AGENTS.md` (the two mentions of `org.noctulescan.NoctuleScan`, in "The Mac app" and "Driving the app"), `LESSONS.md` (the one mention, the 2026-11-09 soak entry). Dated specs and plans stay as written.
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (new; later tasks add to it)

**Interfaces:**
- Produces: in `PackagingTests.swift`, `private let packagingRoot: URL?` (the repository root, found as `AppIconTests.swift`'s `iconRoot` is) and `@Suite struct InfoPlistTests`.

- [x] **Step 1: Write the failing test.** `InfoPlistTests.identifierAndDevelopmentVersion`: decode `Resources/Info.plist` with `PropertyListSerialization`; expect `CFBundleIdentifier == "app.noctule.scan"`, `CFBundleShortVersionString == "0.0.0"`, `CFBundleVersion == "0"`. `InfoPlistTests.oldIdentifierIsGone`: `AGENTS.md`, `LESSONS.md` and `Resources/Info.plist` don't contain `org.noctulescan`.
- [x] **Step 2:** `NOCTULE_NO_USB_DETECTION=1 swift test --filter InfoPlistTests` fails on both.
- [x] **Step 3:** Make the edits above.
- [x] **Step 4:** The filter passes. `scripts/build-app.sh && codesign -dv "build/Noctule Scan.app" 2>&1 | grep Identifier` prints `Identifier=app.noctule.scan`.
- [x] **Step 5: Commit** `build: bundle identifier app.noctule.scan, development version 0.0.0`.

### Task 2: `packaging/dmg/make-dmg.sh`

**Files:**
- Create: `packaging/dmg/make-dmg.sh`
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`@Suite struct MakeDMGTests`)

**Interfaces:**
- Produces: `packaging/dmg/make-dmg.sh <app> <dmg>`: writes a UDZO image at `<dmg>` (replacing one already there), volume name `Noctule Scan`, holding a copy of `<app>` under its own name (copied with `ditto`, so a stapled ticket and the signature survive) and an `Applications` symlink to `/Applications`. Staging in a `mktemp -d` directory removed on every exit (`trap`). Prints `dmg: <path>`. Exit 2 if `<app>` isn't a directory ending `.app` or the argument count is wrong.
- Produces (test support, in `PackagingTests.swift`): `func fakeApp(in: URL, name: String = "Noctule Scan.app") throws -> URL`, a bundle directory with `Contents/Info.plist` (a copy of `Resources/Info.plist`) and an executable `Contents/MacOS/NoctuleScan` (`#!/bin/sh` + `exit 0`); `func runScript(_ relativePath: String, _ arguments: [String], environment: [String: String] = [:], root: URL? = nil, limit: Double = 120) throws -> (status: Int32, stdout: String, stderr: String)`, which launches `<root ?? packagingRoot>/<relativePath>` with `Subprocess` and waits as `AppIconTests.compileIcon` does. Temporary directories for this file come from `temporaryDirectory()` with a subdirectory named `with space`.

- [x] **Step 1: Write the failing tests.**
  - `makesAnImageWithTheAppAndApplications`: run on a fake app to `<tmp>/with space/Noctule Scan 0.1.0.dmg`; status 0; `hdiutil imageinfo -plist` gives `Format` `UDZO`; `hdiutil attach -nobrowse -readonly -plist` (detached with `hdiutil detach` in a `defer`, also on failure) mounts at a path whose last component starts with `Noctule Scan`, listing exactly `Applications` and `Noctule Scan.app`; `Applications` is a symlink to `/Applications`; the copied `Contents/MacOS/NoctuleScan` is executable.
  - `aSecondRunReplacesTheImage`: run twice to the same path (the second after adding a file `extra` inside the source app); both exit 0; the mounted image still lists exactly the two entries, and its app holds `extra`.
  - `refusesWhatIsNotAnApp`: a plain directory, a missing path, and one argument each exit 2 and create no file at `<dmg>`.
- [x] **Step 2:** `swift test --filter MakeDMGTests` fails (no script).
- [x] **Step 3:** Write the script (`chmod 755`).
- [x] **Step 4:** The filter passes; `git ls-files -s packaging/dmg/make-dmg.sh` shows `100755` once added.
- [x] **Step 5: Commit** `packaging: make-dmg.sh, the plain hdiutil image`.

### Task 3: `packaging/notarize.sh`

**Files:**
- Create: `packaging/notarize.sh`
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`@Suite struct NotarizeTests`, and the stubs)

**Interfaces:**
- Produces: `packaging/notarize.sh --check` resolves the signing identity and the notary credentials, sends nothing anywhere, prints `notarize: ready (<keychain profile|API key>)`, exit 0; or the error below, exit 1. `packaging/notarize.sh <file.app|file.dmg>` signs, verifies, submits, waits and staples that one file. Anything else exits 2.
  - **Identity:** `NOCTULE_SIGNING_IDENTITY` if set (passed to `codesign --sign` as given); else the lines of `security find-identity -v -p codesigning` naming `"Developer ID Application:`: exactly one → its 40-hex SHA-1; none → `notarize: no Developer ID Application certificate in the keychain; see packaging/README.md (one-time setup)`; several → `notarize: several Developer ID Application certificates; set NOCTULE_SIGNING_IDENTITY to the SHA-1 of the one to use (security find-identity -v -p codesigning)`.
  - **Credentials:** if any of `NOCTULE_NOTARY_KEY` (a `.p8` path), `NOCTULE_NOTARY_KEY_ID`, `NOCTULE_NOTARY_ISSUER` is set, all three must be (else `notarize: NOCTULE_NOTARY_KEY, NOCTULE_NOTARY_KEY_ID and NOCTULE_NOTARY_ISSUER go together; set all three or none`) and `notarytool` gets `--key … --key-id … --issuer …`; otherwise `--keychain-profile "${NOCTULE_NOTARY_PROFILE:-noctule-notary}"`.
  - **An app:** `codesign --force --options runtime --timestamp --sign <id> <app>`; `codesign --verify --strict <app>`; `ditto -c -k --keepParent <app> <tmp>/<name>.zip` (temporary directory removed on exit); `xcrun notarytool submit <zip> <creds> --wait --timeout 1h --output-format json`; `xcrun stapler staple <app>`. **A DMG:** `codesign --force --timestamp --sign <id> <dmg>`; `codesign --verify --strict <dmg>`; submit the DMG itself; `xcrun stapler staple <dmg>`.
  - **The verdict:** `status` from the submit's JSON (`plutil -extract status raw -`); unless `Accepted`, run `xcrun notarytool log <id> <creds>`, print its output, print `notarize: <name>: Apple answered <status>; nothing stapled`, exit 1. A submit that exits non-zero is the same failure, with the log fetched only when an `id` was printed. On success prints `notarize: <name>: accepted and stapled`.
- Produces (test support): `struct StubTools` in `PackagingTests.swift`: `init() throws` makes `<tmp>/with space/bin` with executable stubs `codesign`, `xcrun`, `spctl`, `security`, each appending one line `<tool> <args joined by spaces>` to `<tmp>/calls.log` and behaving by environment: `security` prints `STUB_IDENTITIES` (default: one line `  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Test Person (TEAM123456)"` and `     1 valid identities found`); `xcrun notarytool submit` prints `{"id":"stub-1","status":"<STUB_NOTARY_STATUS or Accepted>"}`; `xcrun notarytool log` prints `stub log for stub-1`; `spctl` exits `STUB_SPCTL_STATUS` (default 0); every other call exits 0. `var environment: [String: String]` (`PATH` = the stub `bin` then the inherited `PATH`, plus `STUB_LOG`), `func calls() -> [String]`.

- [x] **Step 1: Write the failing tests** (each on a fake app or a small DMG from Task 2's script, with `StubTools`):
  - `checkFindsTheOneIdentity`: `--check` exits 0 printing `ready (keychain profile)`; `calls()` is only the `security find-identity` line.
  - `checkWithNoIdentity` (`STUB_IDENTITIES` = `     0 valid identities found`) and `checkWithTwoIdentities` (two `Developer ID Application:` lines, distinct hashes): exit 1 with the two messages above; with two, `NOCTULE_SIGNING_IDENTITY=ABC` makes `--check` pass without calling `security`.
  - `partialAPIKeyIsRefused`: only `NOCTULE_NOTARY_KEY_ID` set → exit 1, the message above, no `xcrun` call.
  - `appIsSignedNotarizedAndStapled`: exit 0; `calls()` in order: `security …`, `codesign --force --options runtime --timestamp --sign 0123…4567 <app>`, `codesign --verify --strict <app>`, `xcrun notarytool submit <…>.zip --keychain-profile noctule-notary --wait --timeout 1h --output-format json`, `xcrun stapler staple <app>`; stdout ends `accepted and stapled`.
  - `dmgIsSignedWithoutRuntime`: the `codesign` sign line has `--timestamp` and no `--options`; the submit names the `.dmg`.
  - `apiKeyCredentialsAreUsed`: all three variables set (`/tmp/fake.p8`, `KEYID12345`, `issuer-0000`): the submit line has `--key /tmp/fake.p8 --key-id KEYID12345 --issuer issuer-0000` and no `--keychain-profile`.
  - `rejectionPrintsTheLogAndStaplesNothing` (`STUB_NOTARY_STATUS=Invalid`): exit 1; output holds `stub log for stub-1` and `Apple answered Invalid; nothing stapled`; no `stapler` call.
  - `outputCarriesNoCredentials`: across the runs above (API key and keychain profile, success and rejection), stdout + stderr never contain `Test Person`, `TEAM123456`, `0123456789ABCDEF`, `KEYID12345`, `issuer-0000` or `fake.p8`.
  - `refusesOtherFiles`: a `.zip`, a missing path, no argument: exit 2, no `codesign` call.
- [x] **Step 2:** `swift test --filter NotarizeTests` fails.
- [x] **Step 3:** Write the script (`chmod 755`).
- [x] **Step 4:** The filter passes.
- [x] **Step 5: Commit** `packaging: notarize.sh, Developer ID signing and notarization`.

### Task 4: `packaging/release.sh`

**Files:**
- Create: `packaging/release.sh`
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`@Suite struct ReleaseTests`)

**Interfaces:**
- Consumes: `make-dmg.sh <app> <dmg>` (Task 2), `notarize.sh --check` and `notarize.sh <file>` (Task 3), `scripts/build-app.sh release` (makes `<root>/build/Noctule Scan.app`).
- Produces: `packaging/release.sh <version> [--build N] [--allow-dirty]`, `root` being the script's `..`, in this order, stopping at the first failure:
  1. Arguments: `<version>` must match `^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$`; a leading `v` gets `release: give the version without the v (0.1.0, not v0.1.0)`, anything else `release: <version> isn't a version (1.2.3 or 1.2.3-beta.1)`; `--build` takes a whole number. Exit 2.
  2. `git -C <root> status --porcelain` not empty → `release: the working tree has changes; commit them, or pass --allow-dirty to try a release locally`, exit 1.
  3. `notarize.sh --check` (a missing certificate fails in seconds, before the build).
  4. `scripts/build-app.sh release`.
  5. Stamp `build/Noctule Scan.app/Contents/Info.plist` with `plutil -replace`: `CFBundleShortVersionString` = `MAJOR.MINOR.PATCH`, `CFBundleVersion` = the build number.
  6. `notarize.sh` on the app; 7. `make-dmg.sh` to `build/Noctule Scan <version>.dmg`; 8. `notarize.sh` on the DMG.
  9. Checks: `spctl --assess --type execute --verbose <app>`, `spctl --assess --type open --context context:primary-signature --verbose <dmg>`, `xcrun stapler validate <app>`, `xcrun stapler validate <dmg>`; any non-zero → `release: <which> check failed`, exit 1.
  10. Prints `release: <dmg path>` and `sha256: <hex>` (from `shasum -a 256`).

- [x] **Step 1: Write the failing tests.** A helper `fakeRepository() throws -> URL` makes `<tmp>/with space/repo` holding a copy of `packaging/` (modes kept), a copy of `Resources/Info.plist`, and a stub `scripts/build-app.sh` that, like the real one, makes `build/Noctule Scan.app` with `fakeApp`'s layout by copying `Resources/Info.plist` into it, and appends `build` to `$STUB_LOG`; then `git init -b main`, `git add -A`, a commit (`-c user.name=Test -c user.email=test@example.invalid`), and a `.gitignore` of `build/` committed with it. Tests run `<repo>/packaging/release.sh` with `StubTools`' environment.
  - `fullRunStampsSignsAndPackages`: `0.3.0-beta.1 --build 7` exits 0; the bundle's `Info.plist` says `0.3.0` and `7`; `build/Noctule Scan 0.3.0-beta.1.dmg` exists; `calls()` holds, in this order with other lines (more `security` lookups, `codesign --verify`) allowed between, `security`, `build`, the app's `codesign` sign, its `notarytool submit` (a `.zip`), `stapler staple <app>`, the DMG's sign, submit and staple, `spctl … --type execute`, `spctl … --type open`, `stapler validate` ×2; stdout's `sha256:` equals `shasum -a 256` of the DMG; `git status --porcelain` is empty (the repository's `Resources/Info.plist` still says `0.0.0` and `0`).
  - `defaultBuildNumberIsZero`: `0.1.0` → `CFBundleVersion` `0`, DMG `Noctule Scan 0.1.0.dmg`.
  - `badVersionsBuildNothing`: `v0.1.0`, `0.1`, `1.2.3+meta`, `01.2.3`, `0.1.0 --build x`: exit 2, the matching message, no `build` and no `security` in `calls()`.
  - `dirtyTreeIsRefused`: an untracked file in the repository → exit 1 with the message, no `build`; the same with `--allow-dirty` exits 0.
  - `missingCertificateStopsBeforeTheBuild`: `STUB_IDENTITIES` = none → exit 1, no `build`.
  - `rejectedAppStopsTheRun`: `STUB_NOTARY_STATUS=Invalid` → exit 1, no DMG file, no `sha256:` in stdout, `git status --porcelain` empty.
  - `failedGatekeeperCheckFailsTheRun`: `STUB_SPCTL_STATUS=3` → exit 1, `check failed` in stderr, no `sha256:`.
- [x] **Step 2:** `swift test --filter ReleaseTests` fails.
- [x] **Step 3:** Write the script (`chmod 755`).
- [x] **Step 4:** `NOCTULE_NO_USB_DETECTION=1 swift test` passes in full (with `noRealNamesInTrackedFiles` run, not skipped).
- [x] **Step 5: Commit** `packaging: release.sh, version to notarized DMG`.

### Task 5: The README, the owner's Apple setup, and the first real release

**Files:**
- Create: `packaging/README.md`
- Modify: `AGENTS.md` (Build and test: one bullet for `packaging/release.sh`, pointing at the README, saying agents run it for real or send anything to Apple only with the owner's go-ahead), this plan (results)

- [x] **Step 1:** Write `packaging/README.md`: the one-time Apple setup as a checklist, the design's five steps verbatim in substance (membership, Developer ID Application certificate, `.p12` backup outside every repository, App Store Connect API key with its one-time `.p8` download, `notarytool store-credentials noctule-notary`), with placeholders only (`<p8>`, `<id>`, `<issuer>`); cutting a release (`packaging/release.sh 0.1.0 [--build N]`, what each step does, what the checks mean, where the DMG lands, the variables `NOCTULE_SIGNING_IDENTITY`, `NOCTULE_NOTARY_PROFILE`, `NOCTULE_NOTARY_KEY`/`_KEY_ID`/`_ISSUER`); semantic versioning (design §5's bullets); what to do when Apple answers `Invalid` (the printed log). Releases from a tag: "arrives with step 3". Then add the AGENTS.md bullet. Commit `docs: packaging README and AGENTS.md entry`.
- [x] **Step 2 (owner):** Walk the owner through the README's setup, one item at a time; the agent never sees the `.p12`, `.p8` or their passwords. Check: `packaging/notarize.sh --check` prints `ready (keychain profile)`.
- [x] **Step 3 (owner's go-ahead):** `packaging/release.sh 0.1.0` on this branch, with the tree clean. Expected: both `accepted and stapled` lines, all four checks pass, `release:` and `sha256:` printed. If Apple answers `Invalid`, its log says why; record it in LESSONS.md before changing anything.
- [x] **Step 4: The hardened runtime needs no entitlements.** Copy the app out of the DMG to a temporary directory and run it there on the network mock and on the serial mock, exactly as AGENTS.md's two "run it on the mock by hand" recipes say, with that binary in place of `build/…`: it connects, plays audio (network) and shows the display; quit from the app's menu; the mocks report `leaked-sessions=0` and `active-subscriptions=0`. If something the runtime blocks fails, stop and report it: adding an entitlement is the owner's decision.
- [x] **Step 5 (owner):** Copy the DMG to a second Mac or a fresh user account by AirDrop or a download (so it carries the quarantine flag); open it, drag the app to Applications, launch: only the standard prompt. The owner reports what they saw.
- [x] **Step 6:** Record the results in this plan (no certificate name, team ID or key ID; the DMG's SHA-256 is fine), tick the design's step 2 as done, add a LESSONS.md entry for anything that surprised us. Delete the test DMG from `build/` if the owner doesn't want to keep it. Commit; PR.

## Results (2026-11-13 – 14)

- **Tasks 1–4 and Task 5 Step 1:** built natively on `feature/hello-dmg`; full suite green; final review by a fresh reviewer: no Critical, three Important fixed with tests that failed first (`hdiutilFailureIsReported`, `failedSubmitPrintsApplesMessage`, `gatekeeperOutputCarriesNoIdentity`); deferred minors: `stapler staple` not retried, the same identity listed twice reads as "several", no tests for a submit that fails with an `id`, non-JSON submit output, or a rejected DMG in `release.sh`.
- **Step 2 (owner's Apple setup):** done. Xcode wouldn't create the certificate; the website route took three tries (a Developer ID Installer certificate first; Keychain Access imports failing with `-25294`; then no Developer ID - G2 intermediate on the Mac). README and LESSONS.md say how. The API key has Developer access; the profile is `noctule-notary`; the certificate is backed up as a `.p12`. `notarize.sh --check` printed `ready (keychain profile)`.
- **Step 3 (first real release, `0.1.0`, build `0`, from `eddf075`):** the app was accepted and stapled after about 50 minutes in Apple's queue (a new team's first submission). The DMG's upload then failed with `No Keychain password item found for profile: noctule-notary`: the Mac's screen had locked during the wait, and `notarytool`'s profile can't be read while it is (LESSONS.md; README says to keep the Mac unlocked). Once unlocked, the DMG was finished by hand (`notarize.sh` on it, accepted and stapled within minutes, then `release.sh`'s four checks): `spctl` accepted both (`source=Notarized Developer ID`), `stapler validate` passed on both. The app: `app.noctule.scan`, arm64, hardened runtime (`flags=0x10000(runtime)`), no entitlements, `codesign --verify --strict --deep` passes. `build/Noctule Scan 0.1.0.dmg`, 4,289,593 bytes, SHA-256 `1a8c48d4c5f06c7cb271a4a027b4dd06d8c8d5f4cbd7b6e30c5e36a62dc5b801`. One `--verbose` makes `spctl` print no `origin=` line (`-vv` does); `release.sh` filters it either way.
- **Step 4 (the notarized app on the mocks):** the app, copied out of the DMG (stapled ticket and signature intact), ran from a temporary directory with a private `NOCTULE_SETTINGS_DIR` and `NOCTULE_NO_USB_DETECTION=1`. Network mock: `MDL`, `VER`, `PSI`, `STS`, RTSP `SETUP`/`PLAY`, three WAV recordings written; quit from its menu, exit 0, `PSI,0` and `TEARDOWN`, `leaked-sessions=0`. Serial SDS150 mock: `MDL`, `VER`, `PSI,100`, `STS`, `GCS`; quit, exit 0, `PSI,0` last, `active-subscriptions=0`. Neither mock received `KEY`, `MSV`, `MSM` or `POF`. The hardened runtime needs no entitlements.
- **Step 5 (the DMG on a second Mac or a fresh user account):** passed; the owner reported it on 2026-11-14.
- **Step 6:** results recorded here; the release design's step 2 is marked done. Nothing surprised us, so no LESSONS.md entry. The size above was first written as 4,287,903 bytes; the SHA-256 was right, and `stat` gives 4,289,593.
