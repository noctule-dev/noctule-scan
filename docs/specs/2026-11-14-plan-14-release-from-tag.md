# Plan 14: releases from a tag

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. This repo's rules (AGENTS.md) apply on top. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** pushing a tag such as `v0.1.1-beta.1` to `noctule-dev/noctule-scan` makes a **draft** GitHub Release holding `noctule-scan-0.1.1-beta.1.dmg` (Developer ID signed, notarized, stapled) and its SHA-256, which the owner publishes by hand.

**Architecture:** a thin workflow, `.github/workflows/release.yml`, on a GitHub-hosted runner (`xcode-27`, the owner's choice after Task 1; see Results), calls two new scripts under `packaging/ci/`. `signing-keychain.sh create|delete` makes (and removes) a temporary keychain holding the Developer ID certificate from the `release` environment's secrets and Apple's public Developer ID G2 intermediate, committed beside it. `release-from-tag.sh <tag> <run number>` checks the tag and the secrets, refuses a tag that isn't on `main` or already has a release, writes the API key to a temporary file (deleted on every exit), runs Plan 12's `packaging/release.sh <version> --build <run number>` (whose DMG is renamed `build/noctule-scan-<version>.dmg` here, the owner's convention), and creates the draft with `gh release create`. Both scripts are tested like Plan 12's, against stub `security`, `codesign`, `xcrun`, `spctl` and a new stub `gh`; the workflow file is checked by text tests.

**Tech Stack:** GitHub Actions (`macos-26` arm64), bash, `security`, `base64`, `gh`, Plan 12's `packaging/*.sh`; Swift Testing in `NoctuleCLIIntegrationTests` (`PackagingTests.swift`'s helpers).

**Spec:** `docs/specs/2026-11-13-release-packaging-design.md`, section 5, step 3. Plan 12 (`docs/specs/2026-11-13-plan-12-hello-dmg.md`) built what this calls, and Plan 13 (`docs/specs/2026-11-14-plan-13-installer-window.md`) made `make-dmg.sh` build the designed window with `dmgbuild`, which needs Python 3.10 or newer on the runner.

## Global Constraints

- Trigger: a pushed tag matching `v*.*.*`, and nothing else. Runner `macos-26` (arm64) or newer; the Xcode is chosen with `xcode-select` explicitly (Task 1 picks it).
- Steps, in order: check out; `NOCTULE_NO_USB_DETECTION=1 swift test`; temporary keychain; `release-from-tag.sh`; keychain deleted with `if: always()`. The API key's temporary file is deleted by the script's `trap` on every exit.
- The release is a **draft**, marked pre-release when the version has a suffix (`-beta.1`). **Publishing stays the owner's manual step.**
- Secrets (organization `noctule-dev`, visible to `noctule-scan` only; set by the owner 2026-11-14): `NOCTULE_DEVELOPER_ID_P12` (base64), `NOCTULE_DEVELOPER_ID_P12_PASSWORD`, `NOCTULE_NOTARY_KEY_P8` (base64), `NOCTULE_NOTARY_KEY_ID`, `NOCTULE_NOTARY_ISSUER`. The keychain's password is generated per run (`openssl rand -base64 24`). The tag ruleset `Release tags` (`v*`, creation/update/deletion/force-push restricted, repository admins bypass) exists (id 27276075).
- **Owner's call (2026-11-14, after the final review):** the five secrets move to the GitHub Environment `release` (deployment rule: tags `v*` only), and the job declares `environment: release`; no organization secrets remain.
- **Nothing secret is printed or tracked:** no secret value, decoded key or password in any output; no `set -x`; no step debug. Plan 12's rule holds: no certificate name or team ID anywhere.
- Plan 12's script rules hold: `#!/bin/bash`, `set -euo pipefail`, mode `100755`, every path quoted, usage errors exit 2 and other failures 1, Apple's tools and `gh` called by name (stubbable).
- File names the scripts write are lower case with no spaces (`noctule-scan-<version>.dmg`); the app bundle and the volume name stay `Noctule Scan`.
- Every third-party action is pinned to a full 40-character commit SHA, with the version in a comment. Job permissions: `contents: write` only.
- **No agent pushes a `v` tag, creates or publishes a release, or runs the workflow's signing steps:** a tag push uploads to Apple. Pushing the probe branch (Task 1) and the PR branch are the owner's go-ahead at the time. Agents never see, print or read a secret's value.
- AGENTS.md: `export NOCTULE_NO_USB_DETECTION=1` in every shell that runs tests.

## Review Focus

1. **A run that fails or is cancelled halfway**: the keychain (with the private key) and the decoded API key must not outlive the run. Pinned in Task 2 (`deleteRemovesTheKeychain`, `deleteWithNoKeychainIsFine`), Task 3 (`keyFileIsRemovedOnFailure`) and Task 4 (`cleanupRunsAlways`).
2. **A fresh runner's keychain without Apple's G2 intermediate**: `security find-identity -v` then counts no valid identity and `notarize.sh` says "no certificate" (LESSONS.md 2026-11-13). Pinned in Task 2 (`createImportsTheCertificateAndTheIntermediate`, `intermediateIsApplesG2`).
3. **A tag pushed again, or a release already there**: the run must stop before anything goes to Apple, not notarize twice and then fail at `gh release create`. Pinned in Task 3 (`existingReleaseStopsBeforeApple`).
4. **A tag on a commit that isn't on `main`** (a feature branch, a commit later force-pushed away): refused before Apple. Pinned in Task 3 (`tagNotOnMainIsRefused`). *(designer's call: the design doesn't require it; it costs one `git` call.)*
5. **A secret missing or mangled** (visibility changed, a newline in the base64, the `.p12` password wrong): the run must name which secret, never print its value, and stop before the build. Pinned in Task 2 (`missingSecretsAreNamed`) and Task 3 (`missingSecretIsNamed`, `badBase64KeyStopsTheRun`, `outputCarriesNoSecrets`).

**Owner's call (2026-11-14):** file names are lower case with no spaces: `release.sh` writes `build/noctule-scan-<version>.dmg` (was `build/Noctule Scan <version>.dmg`), and the release assets are that DMG and `noctule-scan-<version>.dmg.sha256`. The app bundle (`Noctule Scan.app`) and the DMG's volume name (`Noctule Scan`) keep their spaces: they are the names a user sees in Finder.

**Designer's calls** (recorded for the owner): Apple's public `DeveloperIDG2CA.cer` (SHA-256 `f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a`, valid to 2031-09-17) is committed rather than downloaded per run. The workflow's `timeout-minutes` is 180 (two notarizations with `notarize.sh`'s 1 h limit each, plus tests and build); Task 6 measures a real run.

---

### Task 1: Probe the runner (no secrets)

**Files:**
- Create (on a throwaway branch `probe/release-runner`, never merged): `.github/workflows/probe.yml`
- Modify: this plan (Results)

- [ ] **Step 1:** Write `probe.yml`: `on: push: branches: [probe/release-runner]`, one job on `macos-26`, `timeout-minutes: 60`, `permissions: contents: read`, `env: NOCTULE_NO_USB_DETECTION: "1"`. Steps (each `run:` prints a heading): check out (`actions/checkout`, pinned SHA); `ls -d /Applications/Xcode*.app; xcodebuild -version; sw_vers`; `sudo xcode-select -s` the newest non-beta `Xcode_26*.app` listed (the step prints which), then `xcodebuild -version; swift --version`; `which -a python3; python3 --version` (Plan 13's `make-dmg.sh` needs 3.10 or newer: record which one the image has, and if the default is older, the path of a newer one for `NOCTULE_PYTHON`); `time scripts/build-app.sh release` and `codesign -dv "build/Noctule Scan.app" 2>&1 | grep Identifier` and `ls "build/Noctule Scan.app/Contents/Resources"` (expects `AppIcon.icns`, `Assets.car`); `time swift test 2>&1 | tail -40` with `continue-on-error: true`; `security find-certificate -a -c "Developer ID Certification Authority" -Z /Library/Keychains/System.keychain /System/Library/Keychains/SystemRootCertificates.keychain | grep -E 'SHA-256|labl'`.
- [ ] **Step 2 (owner's go-ahead: it pushes a branch and spends Actions minutes):** push the branch; `gh run watch` until it ends; save the log (`gh run view <id> --log`) to the git-ignored `.superpowers/sdd/<plan>/probe.log`.
- [ ] **Step 3:** Record in Results: the Xcode versions on the image and the one chosen; whether the release build and the icon compile passed; the test summary and its time; which tests (if any) fail only on the runner and why; the billable minutes (`gh api repos/noctule-dev/noctule-scan/actions/runs/<id>/timing`). If the code doesn't build with the image's Xcode, or the icon doesn't compile, **stop and report**: the fix (a newer image, a code change) is the owner's call. If some tests fail only on the runner (a GUI launch, a timing flake), record a `Ruling:` on the subset the release runs (`swift test --skip <Suite>`), the cost if wrong being a regression that only the full local run catches.
- [ ] **Step 4:** Delete the remote branch (`git push origin --delete probe/release-runner`) and the local one. Commit the Results: `docs: Plan 14 runner probe`.

### Task 2: `packaging/ci/signing-keychain.sh`

**Files:**
- Create: `packaging/ci/signing-keychain.sh`, `packaging/ci/DeveloperIDG2CA.cer` (from https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer)
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`@Suite struct SigningKeychainTests`; `StubTools` grows)

**Interfaces:**
- Produces: `packaging/ci/signing-keychain.sh create` and `… delete`; anything else exits 2. The keychain is `${RUNNER_TEMP:-${TMPDIR:-/tmp}}/noctule-signing.keychain-db` (printed as `signing-keychain: <path>`).
  - `create`: needs `NOCTULE_DEVELOPER_ID_P12` and `NOCTULE_DEVELOPER_ID_P12_PASSWORD` non-empty, else `signing-keychain: the secret <NAME> is empty or not visible to this repository`, exit 1, nothing called. Deletes a keychain already at the path first. Decodes the `.p12` (`base64 -D`) into a `mktemp` file under the same directory, removed by `trap` on every exit (a decode failure: `signing-keychain: NOCTULE_DEVELOPER_ID_P12 isn't base64`, exit 1). Then: `security create-keychain -p <pw> <kc>`; `security set-keychain-settings -lut 21600 <kc>`; `security unlock-keychain -p <pw> <kc>`; `security import <p12> -k <kc> -P <p12 password> -T /usr/bin/codesign -f pkcs12`; `security import <repo>/packaging/ci/DeveloperIDG2CA.cer -k <kc>`; `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> <kc>`; `security list-keychains -d user -s <kc> <each keychain `security list-keychains -d user` printed, quotes stripped>`. Prints `signing-keychain: ready`.
  - `delete`: if the keychain file exists, `security delete-keychain <kc>` (which also drops it from the search list); prints `signing-keychain: deleted` or `signing-keychain: nothing to delete`; exit 0 either way.
- Produces (test support): `StubTools`' `security` stub also answers `list-keychains -d user` (no `-s`) with `    "/Users/test/Library/Keychains/login.keychain-db"`; every other new subcommand records and exits 0. `STUB_SECURITY_FAIL=<subcommand>` makes that subcommand exit 1.

- [ ] **Step 1: Write the failing tests** (`RUNNER_TEMP` = a test directory under `with space`; `P12` = base64 of the bytes `fake-p12`; password `p12-secret-pw`):
  - `createImportsTheCertificateAndTheIntermediate`: exit 0; `calls()` in this order: `security create-keychain -p <x> <kc>`, `set-keychain-settings -lut 21600 <kc>`, `unlock-keychain -p <x> <kc>`, `import <RUNNER_TEMP>/<…> -k <kc> -P p12-secret-pw -T /usr/bin/codesign -f pkcs12`, `import <repo>/packaging/ci/DeveloperIDG2CA.cer -k <kc>`, `set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <x> <kc>`, `list-keychains -d user` then `list-keychains -d user -s <kc> /Users/test/Library/Keychains/login.keychain-db`; the three `<x>` are equal and at least 24 characters; afterwards `RUNNER_TEMP` is empty (the stub makes no keychain file, and the decoded `.p12` is gone).
  - `aFailedImportLeavesNoP12` (`STUB_SECURITY_FAIL=import`): exit 1; no decoded `.p12` left in `RUNNER_TEMP`.
  - `missingSecretsAreNamed`: each of the two unset (and each set to empty) → exit 1, the message naming it, no `security` call.
  - `badBase64IsRefused`: `NOCTULE_DEVELOPER_ID_P12` = `not base64!!` → exit 1, the message, no `security import`.
  - `deleteRemovesTheKeychain`: a file at the keychain path → exit 0, `security delete-keychain <kc>`. `deleteWithNoKeychainIsFine`: no file → exit 0, no `security` call.
  - `outputCarriesNoSecrets`: across the runs above, stdout + stderr never contain `p12-secret-pw`, `fake-p12`, its base64, or the generated keychain password (read from `calls()`).
  - `intermediateIsApplesG2`: `shasum -a 256 packaging/ci/DeveloperIDG2CA.cer` is `f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a`.
  - `refusesOtherArguments`: none, `make`, two arguments → exit 2.
- [ ] **Step 2:** `NOCTULE_NO_USB_DETECTION=1 swift test --filter SigningKeychainTests` fails.
- [ ] **Step 3:** Download the certificate (check its SHA-256), write the script (`chmod 755`).
- [ ] **Step 4:** The filter passes.
- [ ] **Step 5: Commit** `packaging: signing-keychain.sh, the CI keychain`.

### Task 3: `packaging/ci/release-from-tag.sh`

**Files:**
- Create: `packaging/ci/release-from-tag.sh`
- Modify: `packaging/release.sh` (the DMG's name: `dmg="$root/build/noctule-scan-$version.dmg"` and its header comment; the Gatekeeper check of the app inside the stapled DMG), `packaging/dmg/make-dmg.sh` (`--prepare`), `packaging/README.md` and `AGENTS.md` (their mentions of `build/Noctule Scan <version>.dmg`, and `--prepare`)
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`@Suite struct ReleaseFromTagTests`; `StubTools` gets `gh`; `ReleaseTests`' three DMG paths become `build/noctule-scan-<version>.dmg`)

**Interfaces:**
- Consumes: `packaging/release.sh <version> --build N` (Plan 12; writes `build/noctule-scan-<version>.dmg` after this task's rename, prints `release: <dmg path>` and `sha256: <hex>`), and the API key variables `notarize.sh` reads (`NOCTULE_NOTARY_KEY`, `_KEY_ID`, `_ISSUER`).
- Produces: `packaging/ci/release-from-tag.sh <tag> <run number>`, `root` the script's `../..`, stopping at the first failure:
  1. Arguments: two; `<tag>` starts with `v` followed by a digit, `<run number>` a whole number; else usage, exit 2. (Full version syntax is `release.sh`'s check.)
  2. `NOCTULE_NOTARY_KEY_P8`, `NOCTULE_NOTARY_KEY_ID`, `NOCTULE_NOTARY_ISSUER`, `GH_TOKEN` non-empty, else `release-from-tag: the secret <NAME> is empty or not visible to this repository` (for `GH_TOKEN`: `release-from-tag: GH_TOKEN is empty`), exit 1.
  3. `git -C <root> merge-base --is-ancestor <tag>^{commit} origin/main`, else `release-from-tag: <tag> isn't on main; tag a commit that is`, exit 1.
  4. `gh release view <tag>` exiting 0 → `release-from-tag: a release for <tag> already exists; delete it or push a new tag`, exit 1. (Any non-zero exit means none.)
  5. The key: `umask 077`; `mktemp -d` under `${RUNNER_TEMP:-${TMPDIR:-/tmp}}`, removed by `trap` on every exit; `base64 -D` into `<dir>/AuthKey.p8` (failure: `release-from-tag: NOCTULE_NOTARY_KEY_P8 isn't base64`); its first line must be `-----BEGIN PRIVATE KEY-----`, else `release-from-tag: NOCTULE_NOTARY_KEY_P8 isn't a .p8 key`; exit 1 either way. Export `NOCTULE_NOTARY_KEY=<dir>/AuthKey.p8`.
  6. `<root>/packaging/release.sh <tag without v> --build <run number>`.
  7. Write `build/noctule-scan-<version>.dmg.sha256` as `<hex>  noctule-scan-<version>.dmg` (`shasum -a 256` run in `build/`).
  8. `gh release create <tag> <dmg> <sha file> --draft --verify-tag --title "Noctule Scan <version>" --notes "<notes>"`, plus `--prerelease` when the version has a `-`. Notes: `Draft made by the release workflow (run <n>). SHA-256 of noctule-scan-<version>.dmg: <hex>. Write the notes, then publish.`
  9. Prints `release-from-tag: draft release <tag> created`.
- Produces (carried from Plan 13, folded in with the owner's go-ahead 2026-11-14):
  - `packaging/dmg/make-dmg.sh --prepare` (and no other argument; with others, usage, exit 2): finds Python and builds or reuses the hash-pinned environment exactly as a normal run does, then prints `make-dmg: dmgbuild ready in <venv>` and exits 0, making no image. The workflow runs it before the keychain exists, so the PyPI fetch never happens with a key in a keychain.
  - `release.sh`, after `xcrun stapler validate` of the DMG: attaches the finished DMG read-only (`hdiutil attach -readonly -nobrowse -mountpoint <mktemp -d>`), runs `gatekeeper --type execute --verbose "<mount>/Noctule Scan.app"` (else `release: Gatekeeper (app in the DMG) check failed`, exit 1), and detaches (`hdiutil detach -force`, then removes the mount directory) on every exit, by `trap`. The check a user's Gatekeeper makes on the copy they get.
- Produces (test support): a `gh` stub in `StubTools`: records `gh <args>`; `release view` exits `${STUB_GH_VIEW_STATUS:-1}`; `release create` exits `${STUB_GH_CREATE_STATUS:-0}` after checking each argument naming a file under `build/` exists (exit 3 if not). The `xcrun` stub, when `STUB_KEY_COPY` is set, copies the file after `--key` there before answering. `fakeRepository` gains `origin/main` (`git update-ref refs/remotes/origin/main HEAD`) and a tag helper.

- [ ] **Step 1: Write the failing tests** (the fake repository from Plan 12's `ReleaseTests`; `NOCTULE_NOTARY_KEY_P8` = base64 of `-----BEGIN PRIVATE KEY-----\nfake-key-body\n-----END PRIVATE KEY-----\n`, `NOCTULE_NOTARY_KEY_ID=KEYID12345`, `NOCTULE_NOTARY_ISSUER=issuer-0000`, `GH_TOKEN=gh-token-secret`, `RUNNER_TEMP` a test directory):
  - `draftReleaseForAFinalVersion`: tag `v0.2.0` on `HEAD`, run `12` → exit 0; `calls()` in order: `gh release view v0.2.0`, `security …`, `build release`, the app's and the DMG's `notarytool submit … --key <RUNNER_TEMP>/…/AuthKey.p8 --key-id KEYID12345 --issuer issuer-0000 …`, `gh release create v0.2.0 <…>/build/noctule-scan-0.2.0.dmg <…>/build/noctule-scan-0.2.0.dmg.sha256 --draft --verify-tag --title Noctule Scan 0.2.0 --notes …`; no `--prerelease`; the bundle's `CFBundleVersion` is `12`; the `.sha256` file is `<shasum of the dmg>  noctule-scan-0.2.0.dmg`; no file in `build/` has a space or a capital letter but the app bundle; the `STUB_KEY_COPY` file equals the decoded key; `RUNNER_TEMP` is empty afterwards.
  - `preReleaseForASuffix`: `v0.2.0-beta.1` → `--prerelease`, assets named `noctule-scan-0.2.0-beta.1.dmg[.sha256]`, the app's short version `0.2.0`.
  - `existingReleaseStopsBeforeApple` (`STUB_GH_VIEW_STATUS=0`): exit 1, the message; no `security`, `build`, `xcrun` or `gh release create`.
  - `tagNotOnMainIsRefused`: tag a commit made on a side branch after `origin/main` → exit 1, the message, no `gh` call at all, no `xcrun`.
  - `missingSecretIsNamed`: each of the four unset → exit 1 naming it; no `gh`, no `security`.
  - `badBase64KeyStopsTheRun` (`not base64!!`) and `notAKeyStopsTheRun` (base64 of `hello`): exit 1, the messages, no `build`; `RUNNER_TEMP` empty.
  - `keyFileIsRemovedOnFailure` (`STUB_NOTARY_STATUS=Invalid`): exit 1, no `gh release create`, `RUNNER_TEMP` empty.
  - `failedCreateFailsTheRun` (`STUB_GH_CREATE_STATUS=1`): exit 1, no `created` line.
  - `outputCarriesNoSecrets`: across the runs above, stdout + stderr never contain `KEYID12345`, `issuer-0000`, `fake-key-body`, the key's base64, `gh-token-secret`, `Test Person` or `TEAM123456`.
  - `refusesBadArguments`: `0.2.0` (no `v`), `vfoo`, one argument, run number `x` → exit 2, no `gh` call.
  - In `MakeDMGTests`: `prepareBuildsOnlyTheEnvironment` (`--prepare` with the shared test environment → exit 0, the `ready` line naming it, its `requirements.sha256` present, no `.dmg` anywhere in the test directory) and `prepareTakesNoOtherArguments` (`--prepare <app>`, `--prepare <app> <dmg>` → exit 2).
  - In `ReleaseTests`: `releaseChecksTheAppInsideTheDMG` (the `spctl` calls include `--assess --type execute --verbose <path>/Noctule Scan.app` with `<path>` not the repository's `build/`, after the DMG's `stapler validate`; afterwards `hdiutil info` lists no image under the test directory) and `failedCheckInsideTheDMGDetaches` (the `spctl` stub, with `STUB_SPCTL_FAIL_MATCH` set to a string, exits 3 when its arguments contain it; set to the mount directory's prefix → exit 1, the message, no `release:` DMG line, nothing left attached).
- [ ] **Step 2:** `swift test --filter ReleaseFromTagTests` fails, and so does `ReleaseTests` once its paths say `noctule-scan-…`, and the new `MakeDMGTests`.
- [ ] **Step 3:** Rename the DMG in `release.sh` (and its mentions in the README and AGENTS.md); add the in-DMG check and `make-dmg.sh --prepare`; write the script (`chmod 755`).
- [ ] **Step 4:** The filter passes, and so do `ReleaseTests`, `MakeDMGTests` and `NotarizeTests` (the stub changes).
- [ ] **Step 5: Commit** `packaging: release-from-tag.sh, tag to draft release`.

### Task 4: `.github/workflows/release.yml`

**Files:**
- Create: `.github/workflows/release.yml`
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`@Suite struct ReleaseWorkflowTests`, reading the file as text)

**Interfaces:**
- Consumes: Task 1's runner and Xcode path; `signing-keychain.sh create|delete` (Task 2); `release-from-tag.sh <tag> <run number>` (Task 3).
- Produces: one job `release`: `runs-on: macos-26` (or Task 1's), `timeout-minutes: 180`, `permissions: contents: write`, `concurrency: { group: release-${{ github.ref_name }}, cancel-in-progress: false }`, `env: NOCTULE_NO_USB_DETECTION: "1"` and `NOCTULE_PYTHON: <Task 1's Python 3.10+ path>` (always explicit, never whatever `python3` comes first on `PATH`). Steps: `actions/checkout` (pinned, `fetch-depth: 0`, so `origin/main` and the tag are there); `sudo xcode-select -s <Task 1's path>` then `xcodebuild -version`; `swift test` (Task 1's subset if it ruled one); `packaging/dmg/make-dmg.sh --prepare` (Task 3: the PyPI fetch, before any key exists); `packaging/ci/signing-keychain.sh create` with the two `.p12` secrets in that step's `env:`; `packaging/ci/release-from-tag.sh "$GITHUB_REF_NAME" "$GITHUB_RUN_NUMBER"` with the three API key secrets and `GH_TOKEN: ${{ github.token }}` in that step's `env:`; last, `packaging/ci/signing-keychain.sh delete` with `if: always()`.

- [ ] **Step 1: Write the failing tests:**
  - `triggersOnVersionTagsOnly`: the `on:` block is `push:` with `tags:` `'v*.*.*'` and no `branches`, `pull_request`, `workflow_dispatch` or `schedule`.
  - `runnerAndXcodeArePinned`: `runs-on: macos-26` (or the chosen label); a line `sudo xcode-select -s /Applications/Xcode_`; `timeout-minutes: 180`.
  - `actionsArePinnedBySHA`: every `uses:` value is `<owner>/<repo>@<40 hex>`.
  - `eachSecretAppearsOnceInItsStep`: each of the five secret names appears exactly once as `${{ secrets.<NAME> }}`; the two `.p12` ones inside the step whose `run:` calls `signing-keychain.sh create`, the three API key ones inside the step calling `release-from-tag.sh`; no secret in a job- or workflow-level `env:`.
  - `cleanupRunsAlways`: the last step runs `signing-keychain.sh delete` and has `if: always()`.
  - `noDebugOutput`: no `set -x`, `ACTIONS_STEP_DEBUG` or `ACTIONS_RUNNER_DEBUG`.
  - `testsRunBeforeSigning`: the `swift test` step comes before the keychain step.
  - `dmgEnvironmentIsBuiltBeforeSigning`: a step runs `make-dmg.sh --prepare`, after `swift test` and before the keychain step.
  - `pythonIsChosenExplicitly`: the job's `env:` sets `NOCTULE_PYTHON` to an absolute path.
- [ ] **Step 2:** `swift test --filter ReleaseWorkflowTests` fails.
- [ ] **Step 3:** Write the workflow. If `actionlint` is installed (`brew install actionlint`, owner's call), run it; otherwise note that it wasn't.
- [ ] **Step 4:** `NOCTULE_NO_USB_DETECTION=1 swift test` passes in full (with `noRealNamesInTrackedFiles` run).
- [ ] **Step 5: Commit** `ci: release workflow on version tags`.

### Task 5: Documentation

**Files:**
- Modify: `packaging/README.md` ("Releases from a tag": how to cut one, `git tag v0.1.1-beta.1 && git push origin v0.1.1-beta.1` on `main`; where the draft appears; checking and publishing it; that a pre-release suffix marks it pre-release; what each failure message means; the secrets and the ruleset by name, never values; how to rotate a secret; the measured cost placeholder Task 6 fills), `AGENTS.md` (the Releases bullet: tags and the workflow; **agents never push a `v` tag or publish a release**; a tag push sends the app to Apple), `docs/specs/2026-11-13-release-packaging-design.md` (nothing until Task 6).
- Test: `noRealNamesInTrackedFiles`; and grep the diff for the secrets' values' shapes (no base64 blobs, no 10-character key IDs).

- [ ] **Step 1:** Write both. **Step 2:** `swift test --filter RealNamesTests` passes. **Step 3: Commit** `docs: releases from a tag`.
- [ ] **Step 4:** Final whole-branch review by a fresh reviewer (most capable model), fixes with failing tests first, then push the branch and open the PR (owner's go-ahead). The owner merges.

### Task 6: The first release from a tag (owner)

- [x] **Step 1 (owner):** on `main` after the merge, `git tag v0.1.1-beta.1 && git push origin v0.1.1-beta.1`. The agent watches read-only (`gh run watch`). _(It took three tags; the release is `v0.1.1-beta.3`. See Results.)_
- [x] **Step 2:** On success: `gh release download v0.1.1-beta.1 -D <tmp>`; `shasum -a 256 -c` the `.sha256`; `spctl --assess --type open --context context:primary-signature -v` on the DMG (filtering `origin=`); `xcrun stapler validate` on the DMG and on the app inside it (mounted read-only, detached in every path); the app's `CFBundleShortVersionString` is `0.1.1` and `CFBundleVersion` the run number. On failure: read the log for the failing step, record it, and fix forward on a new branch; a run that reached Apple and failed after is recorded in LESSONS.md before anything changes.
- [x] **Step 3 (owner):** download the DMG from the draft in a browser on a second Mac or a fresh account and open it, as Plan 12 Task 5 Step 5: only the standard prompt.
- [x] **Step 4:** Measure: `gh api repos/noctule-dev/noctule-scan/actions/runs/<id>/timing` (billable minutes) and the run's wall time; write both into `packaging/README.md`. Tick the design's step 3 as done (`Done on <date> by Plan 14 …`, as steps 1 and 2). Results in this plan. The owner decides whether to publish or delete the beta draft. Commit; PR; the owner merges.

## Carried from Plan 13

From Plan 13's final review (`.superpowers/sdd/2026-11-14-plan-13-installer-window/final-review.md`). **Folded into Tasks 3 and 4 with the owner's go-ahead (2026-11-14):** the explicit `NOCTULE_PYTHON` (Task 4), `make-dmg.sh --prepare` before the keychain (Tasks 3 and 4), and the Gatekeeper check of the app inside the stapled DMG (Task 3).

- Set `NOCTULE_PYTHON` explicitly on the runner, to the Python 3.10+ Task 1 records, rather than whatever `python3` the image puts first on `PATH`.
- Build `build/dmg-venv` (the hash-pinned `dmgbuild` install, which fetches from PyPI) in a step **before** `signing-keychain.sh create`, so a PyPI outage fails the job before any signing and the fetch happens with no key in a keychain. The hashes make this defence in depth. `swift test` builds its own temporary venv, so the release step may still download once.
- `make-dmg.sh` now checks the app inside the image (compares the copy with the source, and its signature when the source's verifies); `release.sh` doesn't assess the copy in the finished, stapled DMG. Consider `spctl --assess --type execute` on the app inside the mounted DMG after stapling: the check a user's Gatekeeper makes.

## Results

**Task 1 (2026-11-14), runner probe** (throwaway branch `probe/release-runner`, five runs, deleted afterwards):
- `macos-26` (arm64; macOS 26.7.2; Xcode 26.0–26.6, default 26.6, Swift 6.3.3): the release build **fails**, four Swift 6.3 errors (`SendingClosureRisksDataRace`, `POSIXSocket.swift:99–100`, `RTPReceiver.swift:148–149`) that Xcode 27.2 accepts. **Owner's call:** the `xcode-27` image (GitHub's public preview, arm64, macOS 27.0.1; Xcode 27.0, 27.1 (default), 27.2), Xcode chosen with `sudo xcode-select -s /Applications/Xcode_27.2.app` (Xcode 27.2, 27B52, Swift 6.4.2: the owner's local version). The app's deployment target stays macOS 26.0.
- On `xcode-27`: `scripts/build-app.sh release` passes in about 50 s; the icon compiles (`AppIcon.icns`, `Assets.car`); `Identifier=app.noctule.scan`. Python: `/opt/homebrew/bin/python3` (3.15.x), used as `NOCTULE_PYTHON`; `/usr/bin/python3` is 3.9.6. Apple's Developer ID G2 intermediate (SHA-256 `F16CD3C5…D2DF3A`) is in the image's System keychain (the committed copy is imported anyway).
- Tests: the full `swift test` in parallel took 404 s and failed only in `MockSDS200Tests`, `MockSerialScannerTests` (all timing out together at about 6 s), `KeepAliveOnTheMock` and `ScannerClientTests/pushUpdatesAreStampedOnArrival`. With those four suites `--no-parallel`, all pass but `pushUpdatesAreStampedOnArrival` (a 70–130 ms window), and the rest pass in parallel (314 s). A fifth run with the exact release commands then tripped `StationRunnerTests/neverLeavesAHitInProgressUnrecorded` once (no `PSI,0` in the mock's log; it passed in the two runs before).
- **Ruling (R6):** the release builds the tests once, runs everything but those four suites in parallel, then those four one test at a time, skipping only `pushUpdatesAreStampedOnArrival`. Cost if wrong: a regression in push arrival stamping is caught only by the full local run. **Ruling (R8):** no skip for the `StationRunnerTests` flake; a test failure comes before any key exists, so the remedy is a re-run. Follow-up: whether `StationRunner.stop()`'s `PSI,0` can go unobserved under load, or only the harness reads the mock too early.
- Time: each probe job took 7–8 min wall time (build about 50 s, tests 5–7 min); GitHub's timing API reports no billable figure for these runs. LESSONS.md 2026-11-14.

**Task 6 (2026-11-15 and 2026-11-16), the first release from a tag: `v0.1.1-beta.3`.**
- **Step 1, three tags.** `v0.1.1-beta.1` (2026-11-14, run 43652944695) failed on a flaky test and then stalled for 66 minutes in the parallel test step; it was cancelled, and nothing reached Apple. Plan 15 followed from it (time limits, the `.skippedOnCIRunner` trait, `packaging/cut-release.sh`). `v0.1.1-beta.2` (2026-11-15, run 43735546765) passed its tests and failed at "Create the signing keychain": the `.p12` secret carries its chain, so the script's own import of the intermediate was a duplicate; nothing reached Apple; fixed by PR #7. `v0.1.1-beta.3` (2026-11-15, run 43742975776, run number 3) passed every step and left the draft pre-release "Noctule Scan 0.1.1-beta.3" with `noctule-scan-0.1.1-beta.3.dmg` (4,646,933 bytes) and its `.sha256`. Both later tags were cut with `cut-release.sh beta`. The first two tags stay without releases. LESSONS.md 2026-11-14 and 2026-11-15.
- **Step 2, the draft's assets, downloaded with `gh release download` on 2026-11-16:** `shasum -a 256 -c` says `OK`; `spctl --assess --type open --context context:primary-signature` accepts the DMG (`source=Notarized Developer ID`); `stapler validate` passes on the DMG and on the app inside it (mounted read-only, then detached); `spctl --assess --type execute` accepts that app and `codesign --verify --strict --deep` passes; its `CFBundleShortVersionString` is `0.1.1`, its `CFBundleVersion` `3` (the run number) and its identifier `app.noctule.scan`.
- **Step 3 (owner), passed:** the owner reported on 2026-11-16 that the DMG, downloaded from the release to a clean Mac, ran and Gatekeeper did not complain.
- **Step 4, the cost:** the run took 12 min 10 s (`run_duration_ms` 730000): about 1 min building the tests, 8 min 17 s in the parallel test step, 51 s in the one-at-a-time suites, and 1 min 35 s in the release step (build, sign, two notarizations, the DMG, the draft). GitHub's timing API gives no billable figure for it (`"billable": {}`), as for the probe runs. Written into `packaging/README.md`; the design's step 3 is marked done.
- The 66-minute stall has not come back in the runs since (three probe runs and two release runs) and is still unexplained; the time limits bound it.
- **The beta draft was deleted on 2026-11-16, at the owner's request** (`gh release delete v0.1.1-beta.3`), unpublished, with its DMG and `.sha256`. The tag `v0.1.1-beta.3` stays, like the two before it, so the next beta is `v0.1.1-beta.4`.
