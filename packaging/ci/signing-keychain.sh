#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# The temporary keychain a CI release job signs with.
# Usage: packaging/ci/signing-keychain.sh create   (build it from the two secrets below)
#        packaging/ci/signing-keychain.sh delete   (remove it; fine if it isn't there)
#
# create needs NOCTULE_DEVELOPER_ID_P12 (the Developer ID Application certificate and key, as a
# base64 .p12) and NOCTULE_DEVELOPER_ID_P12_PASSWORD. It makes the keychain with a random password,
# imports the .p12 and Apple's Developer ID G2 intermediate (unless the .p12 brought it along), lets
# codesign use the key without a prompt, and puts the keychain first in the user search list. The
# keychain lives at ${RUNNER_TEMP:-${TMPDIR:-/tmp}}/noctule-signing.keychain-db. No secret is ever
# printed.
# Apple's `security` is called by name so the tests can stand in for it.
set -euo pipefail

usage() { echo "usage: $0 create|delete" >&2; exit 2; }
fail() { echo "signing-keychain: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || usage
action="$1"
[[ "$action" == create || "$action" == delete ]] || usage

here="$(cd "$(dirname "$0")" && pwd)"
directory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
keychain="${directory%/}/noctule-signing.keychain-db"
echo "signing-keychain: $keychain"

if [[ "$action" == delete ]]; then
    if [[ -e "$keychain" ]]; then
        # Deleting a keychain also drops it from the search list.
        security delete-keychain "$keychain"
        echo "signing-keychain: deleted"
    else
        echo "signing-keychain: nothing to delete"
    fi
    exit 0
fi

for name in NOCTULE_DEVELOPER_ID_P12 NOCTULE_DEVELOPER_ID_P12_PASSWORD; do
    [[ -n "${!name:-}" ]] || fail "the secret $name is empty or not visible to this repository"
done

# macOS's base64 -D exits 0 on garbage, so check the secret first. A pasted secret may have
# newlines or spaces; they go.
encoded="$(printf '%s' "$NOCTULE_DEVELOPER_ID_P12" | tr -d '[:space:]')"
[[ "$encoded" =~ ^[A-Za-z0-9+/]+={0,2}$ && $(( ${#encoded} % 4 )) -eq 0 ]] ||
    fail "NOCTULE_DEVELOPER_ID_P12 isn't base64"

mkdir -p "$directory"
p12="$(mktemp "${directory%/}/noctule-developer-id.XXXXXX")"
# Whatever way create ends, the decoded .p12 goes; and unless it finished, so does the keychain it
# made, which holds the private key (set once the keychain exists).
made=""
ok=""
cleanup() {
    rm -f "$p12"
    if [[ -n "$made" && -z "$ok" ]]; then security delete-keychain "$keychain" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
# The check above is the real guard; base64 -D only fails on a write error here.
printf '%s' "$encoded" | base64 -D > "$p12" || fail "couldn't decode NOCTULE_DEVELOPER_ID_P12"

# A keychain left by an earlier run goes first.
[[ ! -e "$keychain" ]] || security delete-keychain "$keychain"

password="$(openssl rand -hex 24)"
security create-keychain -p "$password" "$keychain"
made=1
# Locks after six hours, or on sleep; a release takes far less.
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$p12" -k "$keychain" -P "$NOCTULE_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -f pkcs12
# A .p12 exported with its certificate chain already holds the intermediate, and a second import of
# it fails ("The specified item already exists in the keychain"), so it goes in only if the keychain
# doesn't have it yet. Certificates are told apart by SHA-1; the listing itself is never printed.
intermediate="$here/DeveloperIDG2CA.cer"
wanted="$(shasum -a 1 "$intermediate" | cut -d' ' -f1 | tr 'a-f' 'A-F')"
held="$(security find-certificate -a -Z "$keychain" 2>/dev/null | awk '/^SHA-1 hash:/ { print toupper($3) }' || true)"
if grep -qxF "$wanted" <<< "$held"; then
    echo "signing-keychain: the .p12 already holds Apple's Developer ID G2 intermediate"
else
    security import "$intermediate" -k "$keychain"
fi
# So codesign can use the key without a prompt nobody can answer.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

# Search the new keychain first, then the ones already there (one quoted path per line).
existing=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"
    line="${line#\"}"
    [[ -z "$line" ]] || existing+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" ${existing[@]+"${existing[@]}"}
ok=1
echo "signing-keychain: ready"
