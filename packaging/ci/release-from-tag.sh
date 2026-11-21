#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# Turns a pushed version tag into a draft GitHub Release: runs packaging/release.sh for the tag's
# version, writes the DMG's checksum, and creates the draft with both files attached. The owner
# writes the notes and publishes.
# Usage: packaging/ci/release-from-tag.sh <tag> <run number>
#        packaging/ci/release-from-tag.sh --preflight <tag>
#   --preflight   only the checks that need no Apple secret (needs GH_TOKEN, not the NOTARY ones)
#   <tag>         v followed by the version, e.g. v0.2.0 or v0.2.0-beta.1 (release.sh checks the rest)
#   <run number>  becomes the app's CFBundleVersion
#
# Secrets, from the environment (never printed): NOCTULE_NOTARY_KEY_P8 (the App Store Connect API
# key, .p8, as base64), NOCTULE_NOTARY_KEY_ID, NOCTULE_NOTARY_ISSUER and GH_TOKEN. The signing
# keychain (ci/signing-keychain.sh) is made before this runs. Everything that can be checked without
# Apple (secrets, the tag being on main, no release yet) is checked before anything is sent there.
# gh runs in the repository, so it finds it from the checkout's origin.
set -euo pipefail

usage() { echo "usage: $0 <tag> <run number> | $0 --preflight <tag>" >&2; exit 2; }
fail() { echo "release-from-tag: $*" >&2; exit 1; }

preflight=""
if [[ "${1:-}" == "--preflight" ]]; then
    [[ $# -eq 2 ]] || usage
    preflight=1
    tag="$2"
    run_number=""
else
    [[ $# -eq 2 ]] || usage
    tag="$1"
    run_number="$2"
    [[ "$run_number" =~ ^[0-9]+$ ]] || usage
fi
[[ "$tag" =~ ^v[0-9] ]] || usage
version="${tag#v}"

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

# The checks that need no Apple secret. --preflight runs only these; a full run repeats them.
[[ -n "${GH_TOKEN:-}" ]] || fail "GH_TOKEN is empty"

git -C "$root" rev-parse --verify --quiet origin/main >/dev/null ||
    fail "origin/main isn't there; fetch it (actions/checkout with fetch-depth: 0)"
git -C "$root" merge-base --is-ancestor "$tag^{commit}" origin/main >/dev/null 2>&1 ||
    fail "$tag isn't on main; tag a commit that is"

# Only gh's "release not found" means there is no such release; any other failure (no gh, a bad
# token, no network) must not read as "none", or the run would go on to Apple and fail at create.
if viewed="$(gh release view "$tag" 2>&1 >/dev/null)"; then
    fail "a release for $tag already exists; delete it or push a new tag"
elif [[ "$viewed" != *"release not found"* ]]; then
    reason="${viewed%%$'\n'*}"
    [[ -n "$reason" ]] || reason="gh failed"
    fail "couldn't ask GitHub about releases: $reason"
fi

if [[ -n "$preflight" ]]; then
    echo "release-from-tag: $tag can be released"
    exit 0
fi

for name in NOCTULE_NOTARY_KEY_P8 NOCTULE_NOTARY_KEY_ID NOCTULE_NOTARY_ISSUER; do
    [[ -n "${!name:-}" ]] || fail "the secret $name is empty or not visible to this repository"
done

# The API key, in a private directory that goes however the run ends.
directory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$directory"
keydir="$(mktemp -d "${directory%/}/noctule-notary.XXXXXX")"
trap 'rm -rf "$keydir"' EXIT
# macOS's base64 -D exits 0 on garbage, so check the secret first (as signing-keychain.sh does).
encoded="$(printf '%s' "$NOCTULE_NOTARY_KEY_P8" | tr -d '[:space:]')"
[[ "$encoded" =~ ^[A-Za-z0-9+/]+={0,2}$ && $(( ${#encoded} % 4 )) -eq 0 ]] ||
    fail "NOCTULE_NOTARY_KEY_P8 isn't base64"
# Private to this file only: release.sh and the build must keep the usual umask, or the app would
# ship unreadable to other accounts. (mktemp -d already made the directory 700.)
(umask 077; printf '%s' "$encoded" | base64 -D > "$keydir/AuthKey.p8") || fail "NOCTULE_NOTARY_KEY_P8 isn't base64"
[[ "$(head -n 1 "$keydir/AuthKey.p8" | tr -d '\r')" == "-----BEGIN PRIVATE KEY-----" ]] ||
    fail "NOCTULE_NOTARY_KEY_P8 isn't a .p8 key"
# notarize.sh reads the three together.
export NOCTULE_NOTARY_KEY="$keydir/AuthKey.p8"
export NOCTULE_NOTARY_KEY_ID NOCTULE_NOTARY_ISSUER

env -u GH_TOKEN -u NOCTULE_NOTARY_KEY_P8 "$root/packaging/release.sh" "$version" --build "$run_number"

name="noctule-scan-$version.dmg"
dmg="$root/build/$name"
checksum="$dmg.sha256"
# "<hex>  <name>", the form shasum -c reads.
(cd "$root/build" && shasum -a 256 "$name") > "$checksum"
hex="$(cut -d ' ' -f 1 "$checksum")"

flags=(--draft --verify-tag)
[[ "$version" == *-* ]] && flags+=(--prerelease)
gh release create "$tag" "$dmg" "$checksum" "${flags[@]}" --title "Noctule Scan $version" \
    --notes "Draft made by the release workflow (run $run_number). SHA-256 of $name: $hex. Write the notes, then publish."
echo "release-from-tag: draft release $tag created"
