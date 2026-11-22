# Packaging

How Noctule Scan becomes a DMG that opens on any Mac with no warning beyond the usual "downloaded from the internet" prompt: built, signed with a Developer ID certificate, notarized by Apple, stapled, and checked with Gatekeeper. Design: `docs/specs/2026-11-13-release-packaging-design.md`.

| File | What it does |
|---|---|
| `release.sh` | version → build → sign → notarize → DMG → notarize → checks |
| `notarize.sh` | signs one file (the app or the DMG), notarizes it, staples the ticket |
| `dmg/make-dmg.sh` | the DMG: the app and an `Applications` link in the designed Finder window (`dmgbuild`, background art from `NOCTULE_BRANDING_DIR`, else the placeholder in `dmg/placeholder/`); `--prepare` only builds the Python environment, so CI can fetch from PyPI before a signing key exists |
| `ci/release-from-tag.sh` | CI: a pushed `v*.*.*` tag to a draft GitHub Release (runs `release.sh`, writes the checksum, `gh release create --draft`) |

`scripts/build-app.sh` stays the everyday development build (signed ad hoc, with the hardened runtime and the entitlements below); `release.sh` calls it.

## Requirements

- **Python 3.10 or newer** for `dmg/make-dmg.sh` (macOS's own `python3` is 3.9 and too old): `brew install python`. The script uses `NOCTULE_PYTHON` if set, else `python3` on `PATH`, and says what to install if neither is new enough.
- **pyenv:** once pyenv is initialised in the shell, `python3` is its shim, and the selected version is used if it is 3.10 or newer; otherwise set `NOCTULE_PYTHON="$(pyenv which python3)"`. If the probe fails (a shim for a version that isn't installed, say) the error shows the probe's first line. The venv is rebuilt by itself if its interpreter goes away (a removed pyenv version, an upgraded Homebrew Python), because it then stops importing `dmgbuild`.
- On first use it makes `build/dmg-venv/` (git-ignored) and installs `dmgbuild` there from PyPI, each wheel pinned by SHA-256 in `dmg/requirements.txt`; that first run needs the network. The environment is reused until `requirements.txt` changes or it stops importing `dmgbuild`, then rebuilt.

## The installer window

The DMG opens as a 640 x 400 pt window (the art, with Finder's title bar on top: `settings.py` gives dmgbuild 640 x 432) with no toolbar, sidebar or status bar: the app's icon on the left, an `Applications` link on the right, an arrow between them and one line telling the user to drag. Icons sit at (170, 214) and (470, 214), on plates drawn into the art at x 104 and 404. The art is `dmg/background.tiff` in the branding folder (`NOCTULE_BRANDING_DIR`; the placeholder's is `dmg/placeholder/background.tiff`), 1x and 2x in one file, copied into the image as `/.background.tiff`. Finder shows its own settings on top of this (path bar, status bar, hidden files and extensions), which the image can't override.

**Changing the art:** the official art lives in the design-language repo (`builds/noctule-scan/`), not here; edit and render it there. The placeholder is `dmg/placeholder/render-placeholder-background.swift`. Move an icon by changing `settings.py` and the plate in the renderer together. Then make an image (`packaging/dmg/make-dmg.sh <app> <dmg>`), open it in Finder and look in Light and Dark appearance. `PlaceholderBackgroundTests` and `MakeDMGTests` pin the sizes and positions.

## One-time Apple setup

Only the account holder can do these, on their own Mac. Nothing here goes in a repository, a log or a chat.

- [ ] **The membership is active.** Sign in at <https://developer.apple.com/account>: the Apple Developer Program shows as active (a new enrollment can take a day or two).
- [ ] **A Developer ID Application certificate.** Xcode › Settings › Accounts › add the Apple ID › select the team › Manage Certificates › **+** › Developer ID Application. It lands in the login keychain. If Xcode won't offer it, use the website instead:
  1. Keychain Access (find it with Spotlight) › menu Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority…: your Apple Account email, any common name, CA email empty, **Saved to disk**. This also puts the private key in the login keychain.
  2. <https://developer.apple.com/account> › Certificates, IDs & Profiles › Certificates › **+** › Developer ID › **Developer ID Application** (not Developer ID Installer, the one beside it, which signs `.pkg` files), profile type **G2 Sub-CA**; upload the request; download the `.cer`.
  3. Import it from Terminal into the login keychain, where it joins its private key: `security import ~/Downloads/<file>.cer -k ~/Library/Keychains/login.keychain-db`. (Double-clicking it, or Keychain Access's import, can fail with `Error: -25294`.)
  4. Install Apple's **Developer ID - G2** intermediate the same way, unless it is already there: `curl -fsSLo ~/Downloads/DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer`, then `security import` it as in step 3. Without it the certificate imports but isn't valid.
  5. The request and the downloaded `.cer` files can then be deleted.

  Check: `security find-identity -v -p codesigning` lists one `Developer ID Application: …` line (`1 valid identities found`). If it finds none, run it without `-v`: an identity marked `CSSMERR_TP_NOT_TRUSTED` lacks the intermediate (step 4); no identity at all means the private key isn't in the login keychain (make a new request).
- [ ] **Back it up.** Keychain Access › login › My Certificates › the Developer ID Application certificate (with its private key underneath) › File › Export Items… › `.p12` with a strong password. Keep the file and the password outside every repository (a password manager holds both well). The private key exists nowhere else, and CI will need it.
- [ ] **An App Store Connect API key.** <https://appstoreconnect.apple.com> › Users and Access › Integrations › App Store Connect API › Team Keys › **+**, access Developer. Download the `.p8`: Apple offers it **once only**. Note the Key ID (on the key's row) and the Issuer ID (above the list). Keep the `.p8` with the `.p12`.
- [ ] **Store the key for notarytool:**

  ```
  xcrun notarytool store-credentials noctule-notary --key <p8> --key-id <id> --issuer <issuer>
  ```

  It checks the key with Apple and keeps it in the login keychain under the profile name `noctule-notary`.
- [ ] **Check:** `packaging/notarize.sh --check` prints `notarize: ready (keychain profile)`. It finds the certificate but doesn't reach Apple: the key itself was checked by `store-credentials`, so a mistyped profile name shows only at the first upload, as `No Keychain password item found for profile`.

## Cutting a release

```
packaging/cut-release.sh beta | final | patch [--beta] | minor [--beta] | major [--beta] [--first X.Y.Z[-beta.N]]
```

This is the one command. Run it from your own Mac, in a clean checkout of `main`. It works out the next version from the latest `v` tag, tests, asks once, tags `main`, pushes the tag, and follows the release workflow to the draft. **It is yours alone: agents never run it** (it pushes a tag, and a tag push sends the app to Apple).

**The kinds.** You say what kind of release it is; the script does the arithmetic. The latest version is the highest `v` tag on `origin` by version order (not by date), among tags shaped `vX.Y.Z` or `vX.Y.Z-beta.N`. With none, there is nothing to count from: it refuses with `cut-release: no release tags on origin; pass --first X.Y.Z or X.Y.Z-beta.N for the first release` (exit 1, nothing done). A tag counts even when its release was never made (`v0.1.1-beta.1` has none, so the next beta is `v0.1.1-beta.2`).

| Kind | If the latest is a beta `X.Y.Z-beta.N` | If the latest is final `X.Y.Z` |
|---|---|---|
| `beta` | `X.Y.Z-beta.(N+1)` | refused; use `patch --beta`, `minor --beta` or `major --beta` |
| `final` | `X.Y.Z` | refused: already final |
| `patch` | refused: release the beta with `final`, or make another with `beta` | `X.Y.(Z+1)` |
| `minor` | refused (same) | `X.(Y+1).0` |
| `major` | refused (same) | `(X+1).0.0` |
| any of those with `--beta` | refused (same) | the same bump, ending `-beta.1` |

**The first release.** In a repository with no release tags, `--first V` (before or after the kind; the kind is still required) names the version, and it proposes `vV`: `packaging/cut-release.sh beta --first 0.1.1-beta.4`. `V` has no leading `v` and must agree with the kind: `X.Y.Z-beta.N` for `beta` or any kind with `--beta`, `X.Y.Z` for the others; otherwise it is a usage error (exit 2, nothing done). With any release tag on origin, `--first` is refused (`cut-release: --first is only for a repository with no release tags`, exit 2). The prompt then says `(latest none)`; everything after the version is chosen (the tag and release checks, the tests, the prompt) is the same.

Only `-beta.N` pre-releases exist. Any other `v` tag is named in a warning (`cut-release: ignoring tags it can't read: …`) and left out of the count.

**What it checks, in order, before it changes anything:**

1. You are on `main` and the working tree is clean.
2. After `git fetch origin main --tags`, `main` equals `origin/main` (behind: pull; ahead: push or reset).
3. The next tag exists neither on `origin` nor, alone, in your clone (`exists locally but not on GitHub; delete it with git tag -d v<next>`), and `gh release view` finds no release for it.
4. The full `NOCTULE_NO_USB_DETECTION=1 swift test` passes, in one plain run as on any developer Mac, logged to `build/cut-release-test.log` (about six minutes; there is no way to skip it). The run is made without `NOCTULE_CI_RUNNER` and the hardware-test variables (`NOCTULE_HARDWARE_TESTS` and the other opt-in ones), so a shell that has them set gets the same run as any other Mac. A failure prints the log's last lines and its path, and tags nothing.

**The prompt.** It then asks once, on standard input: `Tag <short sha> (<subject>) as v<next> (latest v<latest>) and push it? This starts the release workflow, which uploads the app to Apple for notarization. [y/N]`. `y`, `yes` and their capitals (`Y`, `YES`) say yes; anything else (an empty answer, end of input) prints `cut-release: nothing tagged` and exits 1.

**Then** it makes the annotated tag `v<next>` and pushes it; if the push fails it removes the local tag and exits 1. It looks for the workflow's run of that tag (polling every 5 s for up to 2 minutes), prints `cut-release: release run: <url>`, and follows it. When the run passes it prints `cut-release: draft release: <url>`, one `cut-release: asset: <name>` line per asset, and `Check it, write the notes, then publish it.` Publishing stays your click.

**Ctrl-C.** During the tests or before the tag is made it ends the `swift test` it started and the processes in its group and exits 130 with `cut-release: interrupted; nothing tagged`. Once the tag is being made and pushed, Ctrl-C waits until that pair is done, so a tag is never half made. Between the push and finding the run it exits 130 with `cut-release: interrupted; v<next> is pushed`. While following the run it stops only the watching (it sends the watch SIGINT, then SIGTERM after about 2 s if it is still there, and waits for it, so the line below is not lost under `gh`'s screen; the watch gets no keyboard input and ignores the terminal's stop signals, so it can't freeze the script): `cut-release: the release run goes on: <url>`, exit 130, and the run carries on without you.

Keys pressed during the tests are thrown away before the question is asked, when standard input is a terminal.

Ctrl-C is not a promise about every process: Foundation's `Process` puts each child in its own process group, so a process a test launched (a mock scanner, `noctule`, the app) may outlive the interrupted run, as with Ctrl-C on a plain `swift test`. They are mocks with temporary settings and end by themselves or by hand.

**If the run isn't found, or fails.** The tag stays pushed in both cases, and nothing is retried.

- `cut-release: v<next> is pushed, but no release run for it appeared. See <actions url>` (or `… more than one run matches it`), exit 1: look at the repository's Actions page (the message names it) and follow the run there. Don't push the tag again.
- `cut-release: stopped following the run (gh run watch exited <N>); it goes on: <url>`, exit 1: `gh run watch` also exits non-zero when it loses contact with GitHub (network drop, Mac asleep, token hiccup), and the run itself was neither completed nor read. This is not a failure: open the URL and follow the run there. Don't make a new version or delete the draft because of this line. (A run that finished while the watch was lost is read as it ended: success goes on to the draft, failure is reported below.) The script also holds the Mac awake with `caffeinate -i` while it runs.
- `cut-release: the failing step: <name>` and `cut-release: the release run failed: <url>`, exit 1: read the run's log, then the failure list under "Releases from a tag". A failure in a test step, before any key exists, needs a code fix on `main` and a new version (the tag stays on its commit; run `cut-release.sh` again for the next number). One after notarization started may have left a draft: delete it first.
- `cut-release: the run passed, but the draft for v<next> can't be read; see <run url>`: open the run and the Releases page by hand.

Two environment variables exist for the script's own tests and are never set by hand: `CUT_RELEASE_POLL_SECONDS` and `CUT_RELEASE_POLL_LIMIT` (the pause between looks for the run, and how many looks).

**The manual route.** If `cut-release.sh` can't be used, the tag by hand still works: see "Cut it" under "Releases from a tag". You then pick the version yourself, and nothing runs the tests or checks the number first.

### Building by hand with release.sh

`cut-release.sh` and the workflow run this; you rarely do.

```
packaging/release.sh <version> [--build N] [--allow-dirty] [--untagged]
```

`<version>` must be tagged: `HEAD` has to carry the tag `v<version>` (the full version, `-beta.N` included), or the run stops before building anything with `release: HEAD isn't tagged v<version>; cut releases with packaging/cut-release.sh (or pass --untagged to try a release locally)`. The tag is the only source of a release's version. `--untagged` skips that check for a local try and names the DMG `build/noctule-scan-<version>-untagged.dmg` (`…-untagged-unbranded.dmg` when it was built on the placeholder art, see "Branding"), so it can't pass for a release. From a clean working tree (`--allow-dirty` lets you try one with changes, locally only), it:

1. Checks the version and the tree, then finds the certificate and the credentials (`notarize.sh --check`), so a missing one fails in seconds rather than after the build.
2. Builds the app (`scripts/build-app.sh release`).
3. Stamps the version into the built bundle's `Info.plist`: `CFBundleShortVersionString` is `MAJOR.MINOR.PATCH` (a pre-release suffix is dropped, since macOS takes only numbers there) `CFBundleVersion` is `--build` (default `0`), and `NoctuleFullVersion` is the whole version, suffix included (`1.0.1-beta.2`; the update check reads it). The tracked `Resources/Info.plist` keeps `0.0.0`, `0` and `0.0.0`, so a development build is plainly one.
4. Signs the app with the hardened runtime and `Resources/NoctuleScan.entitlements` (audio input, for a USB scanner's line-in; `NSMicrophoneUsageDescription` in `Info.plist` is the prompt's text), zips it, has Apple notarize it, and staples the ticket to the app, so it launches offline once it is out of the DMG.
5. Makes `build/noctule-scan-<version>.dmg` (the full version, suffix included) and signs, notarizes and staples that too.
6. Checks both: `spctl --assess` (Gatekeeper accepts the app to run and the DMG to open) and `stapler validate` (both carry their ticket). Then it attaches the finished DMG read-only, has Gatekeeper assess the app inside it, the copy a user gets, and reads that copy's `CFBundleShortVersionString` and `CFBundleVersion`: they must equal the version and build number the run was given, else `release: the app in the DMG says <v> (build <n>), expected <v> (build <n>)`; its `NoctuleFullVersion` must equal the full version, else `release: the app in the DMG says its full version is <v>, expected <v>`. Any miss fails the run.
7. Prints the DMG's path and its SHA-256.

Notarization usually takes a few minutes per file; a new team's first submissions can take far longer (the first app upload took about 50 minutes on 2026-11-13). The run waits up to an hour for each.

**Keep the Mac unlocked until the run ends.** `notarytool` keeps its profile in the part of the keychain that can be read only while the Mac is unlocked: with the screen locked it answers `No Keychain password item found for profile: noctule-notary`, as if the profile didn't exist. An upload already under way finishes; the next one fails. If that happens after the app was accepted, unlock the Mac and finish by hand rather than run `release.sh` again (which would upload the app again): `packaging/notarize.sh "build/noctule-scan-<version>.dmg"`, then the checks at the end of `release.sh`.

**If Apple answers `Invalid`**, the run prints Apple's log (a JSON list of `issues`, each with a `path` and a `message`) and staples nothing. Fix what it names and run again.

**If the run sits at the DMG step for minutes**, `hdiutil` may be stuck in `newfs_apfs` (seen once; `LESSONS.md` 2026-11-13): find it under `diskimages-helper` with `ps -axo pid,ppid,etime,command`, kill it, check `hdiutil info` for a leftover image, and run again.

### Branding

The app icon and the DMG's background come from a branding folder, `builds/noctule-scan` in the private design-language repo; this repo holds only a placeholder (`dmg/placeholder/`, and a plain icon), so anyone can build it. Which art a build uses (`scripts/branding.sh`):

- `NOCTULE_BRANDING_DIR` set to a folder: that folder. It must hold `AppIcon.icon` and `dmg/background.tiff`, else the build fails. Set to the empty string: the placeholder, and `config/branding.env` is not read (the tests do this).
- Unset: `NOCTULE_BRANDING_DIR` from `config/branding.env` (git-ignored; copy `config/branding.env.example`; a relative path counts from the repo root), else the placeholder.

`release.sh` refuses an official release (a tagged one) without art (`release: no official art: …`), and warns `release: warning: the art at <dir> is <head>, not packaging/branding-ref's <ref>` when the folder's git `HEAD` isn't the pinned commit. An `--untagged` build on the placeholder is named `…-untagged-unbranded.dmg`.

**`packaging/branding-ref`** pins the design-language commit the release uses (a full 40-character SHA). The tag workflow reads it, checks out `builds/noctule-scan` from `noctule-dev/noctule-design-language` at that commit into `branding/`, and gives only the build, sign and notarize step `NOCTULE_BRANDING_DIR`, so the tests run on the placeholder. After the art changes: merge the change in the design-language repo, write the new commit's SHA into `packaging/branding-ref`, and open a pull request here.

**The deploy key.** The design-language repo is private, so the workflow reads it with a read-only deploy key: an SSH key pair whose public half is a read-only deploy key on `noctule-dev/noctule-design-language` and whose private half is the secret `NOCTULE_BRANDING_DEPLOY_KEY` in this repo's `release` environment. The owner creates it (agents never read or set it). Without it the tag run fails at "Check out the branding", before anything is signed or sent to Apple.

### Settings

| Variable | Default | Meaning |
|---|---|---|
| `NOCTULE_SIGNING_IDENTITY` | the one Developer ID Application certificate in the keychain | the certificate to sign with, by SHA-1 (from `security find-identity -v -p codesigning`); needed only when there are several |
| `NOCTULE_NOTARY_PROFILE` | `noctule-notary` | the notarytool keychain profile |
| `NOCTULE_NOTARY_KEY`, `NOCTULE_NOTARY_KEY_ID`, `NOCTULE_NOTARY_ISSUER` | unset | the API key's `.p8` path, Key ID and Issuer ID, in place of the profile (for CI); all three or none |

The scripts never print the certificate's name, the team, the key or its IDs.

### Releases from a tag

Pushing a version tag on `main` makes a draft GitHub Release with the signed, notarized DMG. You do the pushing; the workflow (`.github/workflows/release.yml`) does the rest.

**Before you tag**

- Run the full `swift test` on your Mac (`cut-release.sh` does it for you). The runner skips six timing tests (see "Flakes on the runner"), so only a local run covers them.
- The tag must be on a commit that is on `main`: `release-from-tag.sh` refuses any other.
- The app's minimum macOS stays 26.0, but CI builds and tests on macOS 27 only. Launching the finished app once on a Mac running macOS 26 is worth doing before you publish (your call).

**Cut it** (the manual route; `cut-release.sh` does these steps and more)

```
git checkout main && git pull
git tag v0.1.1-beta.1
git push origin v0.1.1-beta.1
```

The tag is the version (`v0.1.1-beta.1` releases `0.1.1-beta.1`), and the run number becomes the build number. The `Release tags` ruleset only lets repository admins push `v` tags, and blocks deleting or moving one (admins bypass it); don't tag until you mean it, because a tag push sends the app to Apple.

The workflow triggers on `v*.*.*`, while the ruleset covers `v*`: a tag like `v1.0` (two parts) is accepted by the ruleset but starts no release.

**What happens.** The job runs on the `xcode-27-xlarge` runner (an M2 Pro VM, 5 cores, billed per minute): it first checks the tag (`ci/release-from-tag.sh --preflight`: it is on `main`, has no release yet, `GH_TOKEN` is there; no Apple secret is read), selects Xcode 27.2, builds and runs the tests (in two steps: everything in parallel, then the nine timing-sensitive suites one at a time; the seven tests marked `.skippedOnCIRunner` skip themselves), fetches the DMG tooling from PyPI (`make-dmg.sh --prepare`, before any key exists), makes a temporary signing keychain (`ci/signing-keychain.sh create`), runs `ci/release-from-tag.sh`, and always deletes the keychain afterwards (`delete`). `release-from-tag.sh` writes the notary key to a private temporary file, runs `release.sh <version> --build <run number>`, writes `noctule-scan-<version>.dmg.sha256`, and creates a **draft** release on the tag with the DMG and the checksum attached and the checksum in the notes.

**Where to look.** The draft is under the repository's Releases (everyone with write access to the repository sees it; the public doesn't). A version with a suffix (`-beta.1`) is marked pre-release. Check it: download the DMG, `shasum -a 256 -c` against the `.sha256` file, open it, drag the app out, launch it. Then write the notes and publish. Nothing is public until you publish it.

**Cost.** The first complete run (`v0.1.1-beta.3`, 2026-11-15) took 12 minutes wall time: about 1 minute building the tests, 9 minutes testing, and 1 minute 35 seconds in the release step (build, sign, both notarizations, the DMG and the draft). GitHub's timing API gives no billable figure for the run (`"billable": {}`). Notarization can take longer than it did that day (a few minutes per file is usual, and far longer for a new team).

**If it fails**

- **In the test steps, or anywhere before "Build, sign, notarize and draft the release":** this happens before any key exists and before anything reaches Apple. Re-running the job (`gh run rerun <id> --failed`, or the Actions page) fits only a flaky test or a runner problem. A code fix needs a new commit on `main` and a new tag: the tag is fixed to its commit, and the ruleset blocks moving it. Six tests are known to be flaky on the runner's 3 cores and skip themselves there (see "The runner"). A test step that runs out of time (15 minutes to build, 20 to test) or a test that outlasts its suite's limit fails the run and names the step or the test; look at the end of that step's log.
- **After notarization started:** read the run log. If a draft was made, delete it, then push a new tag (the ruleset blocks deleting or moving a `v` tag unless you're an admin; a new tag is simpler).
- What the messages mean (each starts with the script's name):
  - `signing-keychain: the secret NAME is empty or not visible to this repository`, or `release-from-tag: the secret NAME …`: the secret is missing or empty, or isn't set in the `release` environment (Settings › Environments › release); see below.
  - `NOCTULE_DEVELOPER_ID_P12 isn't base64`, `couldn't decode NOCTULE_DEVELOPER_ID_P12`, `NOCTULE_NOTARY_KEY_P8 isn't base64`, `NOCTULE_NOTARY_KEY_P8 isn't a .p8 key`: the secret was stored wrongly; set it again from the file with `base64 -i`.
  - `release-from-tag: GH_TOKEN is empty`: the workflow didn't pass its token to the step.
  - `release-from-tag: origin/main isn't there; fetch it`: the checkout was shallow; the workflow uses `fetch-depth: 0`.
  - `release-from-tag: <tag> isn't on main; tag a commit that is`: the tag stays (the ruleset blocks deleting it unless you're an admin); push a new tag on a commit that is on `main`.
  - `release-from-tag: a release for <tag> already exists; delete it or push a new tag`: a draft from an earlier run is there.
  - `release-from-tag: couldn't ask GitHub about releases: <reason>`: `gh release view` failed for a reason other than "release not found" (a bad token, no network, no `gh`); fix that and re-run. The `Check the tag` step (`--preflight`) prints the same messages as the full run's checks, and fails the job before any build.
  - `security: SecKeychainItemImport: The specified item already exists in the keychain.` in **Create the signing keychain**: a run from a tag cut before 2026-11-15 (`v0.1.1-beta.2` failed this way), whose `signing-keychain.sh` imported Apple's G2 intermediate even when the `.p12` secret had brought it along with its certificate chain. Since then the script imports the intermediate only when the keychain doesn't hold it yet (it prints `signing-keychain: the .p12 already holds Apple's Developer ID G2 intermediate` when it skips it), so a `.p12` works with or without its chain. Re-running the old tag's job fails the same way: cut a new version.
  - Anything from `release.sh` or `notarize.sh` (`Invalid`, the checks at the end): as in "Cutting a release" above.

**Time limits.** The `Build the tests` step has `timeout-minutes: 15` and each `Test` step 20. Every suite in `NoctuleCLIIntegrationTests` and `NoctuleMockScannerTests` has a `.timeLimit(.minutes(N))`, which Swift Testing applies to each test in the suite (whole minutes only; most are 1, the disk-image suites 2). A hang therefore fails the job in minutes, before the keychain exists, and the failure names the stuck test. The first tag (`v0.1.1-beta.1`, 2026-11-14) went silent for 66 minutes in the parallel test step and had to be cancelled (`LESSONS.md` 2026-11-14); nothing reached Apple. A probe on a throwaway branch ran the same steps three times and saw no hang, so that stall's cause is **not known**. Suites in other targets have no suite limit, only the step's 20 minutes.

**Flakes on the runner.** Both workflows (`ci.yml` and `release.yml`) set `NOCTULE_CI_RUNNER: "1"` for the whole job (nothing else sets it). A test that can't run reliably on a CI runner carries the trait `.skippedOnCIRunner("<reason>")` (`Sources/NoctuleKitTestSupport/CIRunner.swift`), which disables it only while that variable is non-empty: it still runs on every developer Mac. No test has it at present: the 2026-11-22 sweep rewrote the last ones to wait for conditions instead of fixed windows (LESSONS.md); use it only for a pure timing measurement the runner can't make, with the reason. The workflow never `--skip`s a single test (`ReleaseWorkflowTests` checks); mark the test instead.

**The runner.** CI and releases run on `xcode-27-xlarge`, the org's larger GitHub-hosted runner (an Apple M2 Pro VM, 5 cores, 14 GB, billed per minute), on GitHub's Xcode 27 public-preview image, chosen because the free `xcode-27` runner (3 cores) flaked on the timing-sensitive tests and `macos-26`'s newest Xcode (26.6) can't build the code. A preview image has no uptime guarantee. When Xcode 27.2 leaves it, or a general-availability `macos-27` label appears, change `runs-on` and the `xcode-select` path in both workflows, and the same two values in `ReleaseWorkflowTests` and `CIWorkflowTests`, which pin them.

**Secrets.** Six environment secrets of the `release` environment in `noctule-scan` (Settings › Environments › release), not organization secrets: `NOCTULE_DEVELOPER_ID_P12` (the certificate and private key as base64), `NOCTULE_DEVELOPER_ID_P12_PASSWORD`, `NOCTULE_NOTARY_KEY_P8` (the API key as base64), `NOCTULE_NOTARY_KEY_ID` and `NOCTULE_NOTARY_ISSUER` (the five signing ones), and `NOCTULE_BRANDING_DEPLOY_KEY` (the read-only deploy key for the design-language art). The workflow uses them only in the signing steps, and its job declares `environment: release`. The environment's deployment rule admits only `v*` tags, so a workflow on a branch can't read them even if it names the environment. Why: organization secrets reach any workflow run in the repository, so anyone who can push a branch could add a workflow that reads the signing and notary secrets; the `Release tags` ruleset only limits who starts `release.yml`. To replace one (a new certificate, a rotated API key), only you do this, never an agent: for a file, `base64 -i <file> | pbcopy`, then paste it into Settings › Environments › release › Environment secrets; or from a terminal, `gh secret set NAME --env release --repo noctule-dev/noctule-scan` (it prompts for the value). The next tag picks it up. No organization secret of the same name may remain in `noctule-dev`: other workflows could still read it. Keep the originals with the backup described under "One-time Apple setup".

## Versions

Semantic versioning. The git tag is the version: `v0.2.0` releases `0.2.0`; `release.sh` takes it without the `v`.

- **Major:** something a user must deal with (a settings or hit-log format that can't be carried forward, a dropped scanner model or macOS version). **Minor:** features. **Patch:** fixes only.
- `0.x` until the first public release, which is `1.0.0`.
- Pre-releases (`0.3.0-beta.1`) are allowed: the DMG's name carries the suffix, the app shows `0.3.0`.
