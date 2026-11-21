#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# Signs one file with the Developer ID certificate, has Apple notarize it, and staples the ticket.
# The app is signed with the hardened runtime and Resources/NoctuleScan.entitlements (audio input); the
# disk image is signed plain.
# Usage: packaging/notarize.sh <file.app|file.dmg>
#        packaging/notarize.sh --check   (find the certificate and the credentials; nothing is sent)
#
# The certificate: NOCTULE_SIGNING_IDENTITY (a SHA-1 or a name) if set, else the one Developer ID
# Application certificate in the keychain. The credentials: an App Store Connect API key, from
# NOCTULE_NOTARY_KEY (the .p8 path), NOCTULE_NOTARY_KEY_ID and NOCTULE_NOTARY_ISSUER when set (CI),
# else the keychain profile NOCTULE_NOTARY_PROFILE (default noctule-notary). Neither is ever
# printed. Apple's tools are called by name so the tests can stand in for them.
set -euo pipefail

usage() { echo "usage: $0 <file.app|file.dmg> | --check" >&2; exit 2; }
fail() { echo "notarize: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || usage
target="$1"
if [[ "$target" != --check ]]; then
    case "$target" in
        *.app) [[ -d "$target" ]] || usage ;;
        *.dmg) [[ -f "$target" ]] || usage ;;
        *) usage ;;
    esac
fi

# The credentials, as notarytool arguments.
if [[ -n "${NOCTULE_NOTARY_KEY:-}${NOCTULE_NOTARY_KEY_ID:-}${NOCTULE_NOTARY_ISSUER:-}" ]]; then
    [[ -n "${NOCTULE_NOTARY_KEY:-}" && -n "${NOCTULE_NOTARY_KEY_ID:-}" && -n "${NOCTULE_NOTARY_ISSUER:-}" ]] ||
        fail "NOCTULE_NOTARY_KEY, NOCTULE_NOTARY_KEY_ID and NOCTULE_NOTARY_ISSUER go together; set all three or none"
    credentials=(--key "$NOCTULE_NOTARY_KEY" --key-id "$NOCTULE_NOTARY_KEY_ID" --issuer "$NOCTULE_NOTARY_ISSUER")
    source_name="API key"
else
    credentials=(--keychain-profile "${NOCTULE_NOTARY_PROFILE:-noctule-notary}")
    source_name="keychain profile"
fi

# The signing identity.
if [[ -n "${NOCTULE_SIGNING_IDENTITY:-}" ]]; then
    identity="$NOCTULE_SIGNING_IDENTITY"
else
    hashes="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ { print $2 }')"
    count="$(printf '%s' "$hashes" | grep -c . || true)"
    [[ "$count" -ne 0 ]] || fail "no Developer ID Application certificate in the keychain; see packaging/README.md (one-time setup)"
    [[ "$count" -eq 1 ]] || fail "several Developer ID Application certificates; set NOCTULE_SIGNING_IDENTITY to the SHA-1 of the one to use (security find-identity -v -p codesigning)"
    identity="$hashes"
fi

if [[ "$target" == --check ]]; then
    echo "notarize: ready ($source_name)"
    exit 0
fi

name="$(basename "$target")"
entitlements="$(cd "$(dirname "$0")/.." && pwd)/Resources/NoctuleScan.entitlements"
if [[ "$target" == *.app && ! -f "$entitlements" ]]; then
    fail "no entitlements file at $entitlements; the app can't use audio input without it"
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ "$target" == *.app ]]; then
    codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$target"
    codesign --verify --strict "$target"
    upload="$work/$(basename "$target" .app).zip"
    ditto -c -k --keepParent "$target" "$upload"
else
    codesign --force --timestamp --sign "$identity" "$target"
    codesign --verify --strict "$target"
    upload="$target"
fi

submitted=0
answer="$(xcrun notarytool submit "$upload" "${credentials[@]}" --wait --timeout 1h --output-format json)" || submitted=$?
id="$(plutil -extract id raw - <<<"$answer" 2>/dev/null || true)"
status="$(plutil -extract status raw - <<<"$answer" 2>/dev/null || true)"

if [[ $submitted -ne 0 || "$status" != Accepted ]]; then
    message="$(plutil -extract message raw - <<<"$answer" 2>/dev/null || true)"
    [[ -z "$message" ]] || echo "notarize: $message" >&2
    if [[ -n "$id" ]]; then
        xcrun notarytool log "$id" "${credentials[@]}" >&2 || true
    fi
    fail "$name: Apple answered ${status:-nothing usable}; nothing stapled"
fi

xcrun stapler staple "$target"
echo "notarize: $name: accepted and stapled"
