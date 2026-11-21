# Release packaging: a private home, a signed DMG, tag-driven releases

> **Note (2026-11-20, Plan 21):** the icon and the installer background no longer live in this repository. Since Plan 21 the icon is in the design-language repository's `builds/noctule-scan/AppIcon.icon`, and this repository builds the placeholder `Resources/Placeholder/AppIcon.icon` unless `NOCTULE_BRANDING_DIR` names that folder. Paths below name where the art was when this was written.

Status: design for review (2026-11-13). Labels mark whose decision each point is: **(owner)** or **(designer's call)**, as in the main design.

## 1. Intent

Noctule Scan will ship publicly. The owner wants a user's first contact with it (download, install, first launch) to feel like any well-made Mac app, with nothing that reads as "untrusted developer". **(owner)** The owner enrolled in the Apple Developer Program on 2026-11-12 and is new to Apple's signing and notarization; part of this work is walking them through the one-time setup.

It evolves in layers: a stripped-down "hello DMG" first, then a custom DMG window, terms, Homebrew and the rest, one at a time. **(owner)**

The code will be made public once it is polished, but the specs never will be: specs make a clean-room rewrite trivial for anyone with AI coding tools, where public code is protected by copyright and its license. Code public, knowledge private. **(owner)** For now `docs/specs/` stays in the repository; the owner will remove it and rewrite the history before the flip to public. **(owner)** *(Superseded 2026-11-20: `docs/specs/2026-11-20-open-source-prep-design.md` replaces "remove it and rewrite the history"; the specs are cleaned and published with an index, and the code and specs are public under Apache 2.0.)* `AGENTS.md` and `LESSONS.md` stay in it and go public with it. **(owner)**

## 2. Goals, non-goals, anti-goals

Goals:
- The repository lives, private, in the `noctule-dev` GitHub organization, with a fresh history of one commit. **(owner)**
- A DMG, Developer ID signed, notarized and stapled, that opens on another Mac with no Gatekeeper warning beyond the usual "downloaded from the internet" prompt.
- Releases are cut by tagging `main`; a GitHub Actions workflow builds and packages them. **(owner)**
- Semantic versioning. **(owner)**

Non-goals for this round:
- A custom DMG window (background, icon layout), terms or a license agreement, Homebrew, the `noctule` CLI in the package, a universal (Intel) build, automatic updates. Each is a later layer; nothing here may block one.
- Choosing the public license, making the repository public, and removing the specs from it and from its history (all at the flip).

Anti-goals (failures even if everything technically works):
- Anything in a public place (a release, its notes, a DMG) that carries a spec.
- A signing certificate, private key, API key or password in a tracked file, a log, or a shell history.
- A release job that runs on the owner's Mac, where the real scanners and real settings are.

## 3. Constraints

- **Naming** **(owner: hyphenated names, the `noctule.app` domain; the patterns are the designer's)**. The owner owns `noctule.app`, the parent domain for every Noctule product. GitHub repositories are `noctule-dev/noctule-<product>` (this one `noctule-dev/noctule-scan`; the one exception is the Homebrew tap, which Homebrew requires to be named `homebrew-<name>`: `noctule-dev/homebrew-tap`), local checkouts `~/projects/noctule/noctule-<product>`, and bundle identifiers `app.noctule.<product>` (this app `app.noctule.scan`). Swift module and target names (`NoctuleScan`, `NoctuleKit`, …) and the settings folder (`NoctuleScan`) are code, not repository names, and don't change.

- Build: SwiftPM (`swift-tools-version: 6.2`), no Xcode project. `scripts/build-app.sh` assembles `build/Noctule Scan.app` and signs it ad hoc; the app icon is compiled with `actool` from `Resources/AppIcon.icon`, which needs an Xcode that knows Icon Composer files (Xcode 26 or later). The owner's Mac has Xcode 27.2.
- `LSMinimumSystemVersion` is 26.0. The app is unsandboxed and has no entitlements.
- `noctule-dev` is on GitHub's Team plan. macOS runner minutes on private repositories count 10×.
- `CFBundleShortVersionString` takes only `MAJOR.MINOR.PATCH` integers: no pre-release suffix.
- The rules in `AGENTS.md` hold throughout: no owner-specific values in tracked files, `RealNamesTests`, never launching the app against real settings, and tests with `NOCTULE_NO_USB_DETECTION=1`.

## 4. Approaches considered

**How the repository moves.** (a) A GitHub transfer, keeping history, PRs and issues. (b) A new, empty repository given one commit of today's tree, specs included, so the code appears all at once. **Chosen: (b).** **(owner)** The commit is made from an export of the tree (`git archive`), never from the old repository's objects, and the old checkout is set aside rather than reused, so no old branch or object can reach the new remote. **(designer's call)**

**How the DMG is made.** (A) `hdiutil`, built into macOS: no dependencies, a plain Finder window. (B) `dmgbuild` (Python): a settings file for background, icon layout and a license agreement; a dependency. (C) `create-dmg`: styles the window by scripting Finder, which needs automation permission and is unreliable on a build server; no license agreement. **Chosen: (A) now, (B) when the custom window and terms arrive**; signing and notarizing don't change with that switch. **(owner picked A over B and C)** **Update 2026-11-14:** option B arrived with Plan 13 (`docs/specs/2026-11-14-plan-13-installer-window.md`): `dmgbuild` in a hash-pinned venv, the designed window; the license agreement is still to come.

**Where releases build.** (1) GitHub's hosted macOS runners: a clean machine each time, credentials in GitHub's encrypted secrets, nothing on the owner's Mac; costs runner minutes and may carry an older Xcode. (2) A self-hosted runner on the owner's Mac: free, the owner's Xcode, but a GitHub job would run beside the real scanners and settings, and only while that Mac is awake. **Chosen: (1).** **(designer's recommendation; the owner agreed to tag-driven releases and to the order below)**

**Notarization credentials.** An app-specific password, or an App Store Connect API key. **Chosen: the API key**, on the owner's Mac and in CI alike, so there is one way of doing it. **(designer's call)**

## 5. The work, in three steps

Built in this order, each with its own plan. **(owner)**

### Step 1: a fresh private home in `noctule-dev`, one commit

Done on 2026-11-13 by Plan 11 (`docs/specs/2026-11-13-plan-11-move-to-noctule-dev.md`, Results).

1. Preconditions: everything wanted is committed on `main` (this design and the 2026-11-13 `LESSONS.md` entry included), `main` is pushed, and no local or remote branch is ahead of `main` (true on 2026-11-13).
2. In a new empty directory: extract `git archive main` from the current checkout; `git init -b main`; one commit with the owner's identity. Before committing, list the files and compare them with `git ls-files` in the old checkout: the same set, nothing git-ignored.
3. Create private `noctule-dev/noctule-scan` (section 3's naming) and push that commit as `main`.
4. On the maintainer's Mac: move the old checkout aside as an archive; clone `noctule-dev/noctule-scan` to its new path; copy the agent's memory folder for this project from the folder of the old path to the new one; copy the git-ignored files across from the archive: `config/dev-scanner.env`, `config/real-names.txt`, `docs/uniden/*.pdf` (not `.build/`, `build/` or `.superpowers/`).
5. Verify in the new checkout: `git log` shows one commit; `swift build`; `NOCTULE_NO_USB_DETECTION=1 swift test` passes with `RealNamesTests` running (the deny-list is present).
6. Archive the earlier personal repository on GitHub (read-only, still private), since it holds the full history. Deleting it, and the local archive, is the owner's call, later.

Creating the repository, pushing and archiving are done with the owner's go-ahead at the time.

### Step 2: the hello DMG

Done on 2026-11-14 by Plan 12 (`docs/specs/2026-11-13-plan-12-hello-dmg.md`, Results).

**The owner's one-time Apple setup** (the plan writes this up as a checklist in `packaging/README.md` and walks the owner through it; none of it can be done by an agent):
1. Confirm the developer membership is active at developer.apple.com/account (a new enrollment can take a day or two).
2. Create a **Developer ID Application** certificate: Xcode › Settings › Accounts › add the Apple ID › Manage Certificates › + › Developer ID Application. Only the account holder can.
3. Back it up: export it with its private key from Keychain Access as a password-protected `.p12`, kept outside every repository. It is needed for CI, and the private key exists nowhere else.
4. Create an **App Store Connect API key** (App Store Connect › Users and Access › Integrations › Team Keys). The `.p8` downloads once only; note the Key ID and Issuer ID.
5. Store it for local use: `xcrun notarytool store-credentials noctule-notary --key <p8> --key-id <id> --issuer <issuer>`, which keeps it in the login keychain.

**The bundle identifier** changes first, from `org.noctulescan.NoctuleScan` to `app.noctule.scan`: in `Resources/Info.plist` and in `AGENTS.md`'s and `LESSONS.md`'s mentions (the dated specs and plans that name the old one are left as written). Nothing in the code uses it. On the owner's Mac the app asks for Local Network permission again once. It is done before the first Developer ID signature, since after the first public release a change would silently reset users' preferences and that permission. **(designer's call on timing)**

**The layout** (`packaging/`, **owner's idea; the name and split are the designer's**):

```
packaging/
  README.md       the one-time Apple setup; how to cut a release, locally and by tag
  release.sh      version → build → sign → notarize → each package
  notarize.sh     shared by every format: sign with Developer ID, notarize, staple
  dmg/
    make-dmg.sh   the hello DMG (hdiutil)
```

`scripts/build-app.sh` stays the everyday development build; `release.sh` calls it. A `packaging/homebrew/` folder arrives with the Homebrew layer, alongside a separate tap repository (`noctule-dev/homebrew-tap`).

**`packaging/release.sh <version> [--build N]`**:
1. Validates `<version>` as semantic versioning (`1.2.3` or `1.2.3-beta.1`). Refuses a dirty tree unless `--allow-dirty` (local practice only).
2. `scripts/build-app.sh release`.
3. Stamps the bundle's copy of `Info.plist` (never the tracked file): `CFBundleShortVersionString` = `MAJOR.MINOR.PATCH` (any pre-release suffix dropped), `CFBundleVersion` = `--build` (default `0`).
4. `notarize.sh` on the app: `codesign --force --options runtime --timestamp --sign "Developer ID Application: …"`; `codesign --verify --strict`; zip it (`ditto -c -k --keepParent`), `xcrun notarytool submit --wait`, `xcrun stapler staple` the app.
5. `dmg/make-dmg.sh`: a staging folder with the stapled app and an `Applications` symlink, `hdiutil create -format UDZO -volname "Noctule Scan"`, written to `build/Noctule Scan <version>.dmg` (the full version, suffix included).
6. `notarize.sh` on the DMG: sign it, notarize it, staple it.
7. Checks, failing the run on any miss: `spctl --assess --type execute` on the app, `spctl --assess --type open --context context:primary-signature` on the DMG, `stapler validate` on both. It prints the DMG's path and SHA-256.

Notarizing twice (the app, then the DMG) lets the app carry its own ticket once it has been dragged out of the DMG, so its first launch works offline. **(designer's call)**

Credentials: locally, the signing identity comes from the login keychain and notarization from the `noctule-notary` profile. In CI, from the environment (section 5, step 3). `notarize.sh` takes whichever is set and logs neither.

No entitlements are expected under the hardened runtime: the app uses the network, IOKit serial ports and audio output, none of which needs one. **This is checked, not assumed:** the notarized app is run on the mock (network and serial), as `AGENTS.md` describes, before step 2 is called done.

**Semantic versioning** **(owner; the specifics are the designer's)**:
- The git tag is the version: `v0.2.0` releases `0.2.0`. The tracked `Info.plist` says `0.0.0` and `0`, so a development build is plainly one.
- Major: something a user must deal with (a settings or hit-log format that can't be carried forward, a dropped scanner model or macOS version). Minor: features. Patch: fixes only.
- `0.x` until the first public release, which is `1.0.0`, when the repository flips to public.
- Pre-releases (`v0.3.0-beta.1`) are allowed: the DMG name carries the suffix, the app shows `0.3.0`.
- Later: `noctule --version` reads the same version, once the CLI ships.

Done means: the owner runs `packaging/release.sh 0.1.0` on their Mac, the checks pass, and the DMG, copied to a second Mac or a fresh user account (by AirDrop or a download, so it carries the quarantine flag), opens and launches with only the standard prompt.

### Step 3: releases from a tag

Done on 2026-11-16 by Plan 14 (`docs/specs/2026-11-14-plan-14-release-from-tag.md`, Results) and Plan 15 (`docs/specs/2026-11-14-plan-15-cut-release.md`): the first complete run was `v0.1.1-beta.3` on 2026-11-15.

- `.github/workflows/release.yml`, on a pushed tag matching `v*.*.*`, on a GitHub-hosted macOS runner (`macos-26` or newer). Early in the plan: confirm the code builds and `actool` compiles the icon with that image's Xcode, and choose the Xcode with `xcode-select` explicitly.
- Steps: check out; `NOCTULE_NO_USB_DETECTION=1 swift test` (hardware tests skip themselves); import the certificate into a temporary keychain made for the run and deleted after it, in every exit path; write the API key to a temporary file, deleted likewise; `packaging/release.sh <tag without v> --build <run number>`; create a **draft** GitHub Release for the tag (marked pre-release when the version has a suffix) with the DMG and its SHA-256 attached. The owner publishes it by hand. **(designer's call: publishing stays a manual step)**
- Secrets, set once on the **`noctule-dev` organization** for the Noctule repositories that release: the `.p12` (base64) and its password, the `.p8` (base64), the Key ID, the Issuer ID. The temporary keychain's password is generated per run.
- A ruleset on the organization or repository limits who can create `v*` tags.
- Cost check: one release run's minutes (tests, build, two notarization waits) is measured on the first run and noted in `packaging/README.md`.

Done means: pushing `v0.1.1` (or a `-beta.1`) produces a draft release whose DMG passes the same checks as step 2.

## 6. Open items

For the owner:
- **The name on the signature.** An individual developer account signs as the person; a company name needs an organization account (a legal entity and a D-U-N-S number), which Apple can convert to later. Not needed for the hello DMG; decide before `1.0.0`.
- **At the flip to public:** *(Superseded 2026-11-20: `docs/specs/2026-11-20-open-source-prep-design.md` replaces "remove `docs/specs/`"; the specs are cleaned and published with an index.)* ~~remove `docs/specs/` and rewrite the history;~~ reword `ACKNOWLEDGMENTS.md` and `docs/uniden/README.md`, which point at the protocol spec; choose the license; write a contributor guide. The old history (in the earlier personal repository and the archive copy of the old checkout) must stay private.
- **The tracked files still tell the story:** `LESSONS.md` entries, specs and plans are dated, and `AGENTS.md` names plans, PR-era branches and hardware sessions. One commit hides the history, not the record in the files; decide before the flip how much of that goes public.

Left to the builder:
- The exact runner image and Xcode version (step 3), and whether the full test suite fits the minutes; if not, which subset a release runs.
- Script details: argument parsing, messages, the temporary paths.
