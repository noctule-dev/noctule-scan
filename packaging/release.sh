#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# Cuts a release: builds the app, stamps the version into the bundle, signs, notarizes and staples
# it, packs it into "build/noctule-scan-<version>.dmg", notarizes that, and checks both with
# Gatekeeper (and the app inside the finished DMG, as a user's Mac will, including the version and
# build number it says). The version comes from a git tag: HEAD must be tagged v<version>
# (packaging/cut-release.sh makes the tag). An official release needs the official art: the folder
# NOCTULE_BRANDING_DIR names (or config/branding.env; see scripts/branding.sh); without it only an
# --untagged try goes on, with the placeholder. See packaging/README.md for the one-time Apple setup.
# Usage: packaging/release.sh <version> [--build N] [--allow-dirty] [--untagged]
#   <version>      semantic version, 1.2.3 or 1.2.3-beta.1; the app shows 1.2.3, the DMG the full version
#   --build N      CFBundleVersion (default 0)
#   --allow-dirty  release from a working tree with changes (local practice only)
#   --untagged     release with no tag on HEAD (local practice only); the DMG is named "<version>-untagged"
#                  (with no official art too: "<version>-untagged-unbranded")
set -euo pipefail

usage() { echo "usage: $0 <version> [--build N] [--allow-dirty] [--untagged]" >&2; exit 2; }
fail() { echo "release: $*" >&2; exit 1; }

version=""
build_number=0
allow_dirty=0
untagged=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "release: --build takes a whole number" >&2; exit 2; }
            build_number="$2"; shift 2 ;;
        --allow-dirty) allow_dirty=1; shift ;;
        --untagged) untagged=1; shift ;;
        -*) usage ;;
        *) [[ -z "$version" ]] || usage; version="$1"; shift ;;
    esac
done
[[ -n "$version" ]] || usage
if [[ "$version" == v[0-9]* ]]; then
    echo "release: give the version without the v (${version#v}, not $version)" >&2; exit 2
fi
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
[[ "$version" =~ $semver ]] || { echo "release: $version isn't a version (1.2.3 or 1.2.3-beta.1)" >&2; exit 2; }
short_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"

root="$(cd "$(dirname "$0")/.." && pwd)"
packaging="$root/packaging"

if [[ $allow_dirty -eq 0 && -n "$(git -C "$root" status --porcelain)" ]]; then
    fail "the working tree has changes; commit them, or pass --allow-dirty to try a release locally"
fi

if [[ $untagged -eq 0 ]] && ! git -C "$root" tag --points-at HEAD | grep -qxF "v$version"; then
    fail "HEAD isn't tagged v$version; cut releases with packaging/cut-release.sh (or pass --untagged to try a release locally)"
fi

# shellcheck source=../scripts/branding.sh
source "$root/scripts/branding.sh"
noctule_branding "$root" || fail "the branding folder is unusable; fix NOCTULE_BRANDING_DIR (or config/branding.env), or unset it for the placeholder"
unbranded=0
if [[ -z "$branding_dir" ]]; then
    [[ $untagged -eq 1 ]] || fail "no official art: set NOCTULE_BRANDING_DIR (or config/branding.env) to the design-language repo's builds/noctule-scan folder"
    unbranded=1
else
    # The art is pinned by commit (packaging/branding-ref); a folder that isn't a git checkout isn't checked.
    pinned="$(tr -d '[:space:]' < "$packaging/branding-ref" 2>/dev/null || true)"
    if art_head="$(git -C "$branding_dir" rev-parse HEAD 2>/dev/null)" && [[ -n "$pinned" && "$art_head" != "$pinned" ]]; then
        echo "release: warning: the art at $branding_dir is $art_head, not packaging/branding-ref's $pinned" >&2
    fi
fi
export NOCTULE_BRANDING_DIR="$branding_dir"

# A missing certificate or half-set credentials fail here, in seconds, not after the build.
"$packaging/notarize.sh" --check

"$root/scripts/build-app.sh" release
app="$root/build/Noctule Scan.app"
dmg="$root/build/noctule-scan-$version.dmg"
[[ $untagged -eq 0 ]] || dmg="$root/build/noctule-scan-$version-untagged.dmg"
[[ $unbranded -eq 0 ]] || dmg="$root/build/noctule-scan-$version-untagged-unbranded.dmg"

# Only the bundle's copy: the tracked Resources/Info.plist keeps saying 0.0.0.
plutil -replace CFBundleShortVersionString -string "$short_version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
echo "release: $version (app $short_version, build $build_number)"

"$packaging/notarize.sh" "$app"
"$packaging/dmg/make-dmg.sh" "$app" "$dmg"
"$packaging/notarize.sh" "$dmg"

# spctl's origin= line names the certificate (the owner's name and team): never print it.
gatekeeper() { spctl --assess "$@" 2>&1 | sed '/^origin=/d' >&2; }
gatekeeper --type execute --verbose "$app" || fail "Gatekeeper (app) check failed"
gatekeeper --type open --context context:primary-signature --verbose "$dmg" || fail "Gatekeeper (DMG) check failed"
xcrun stapler validate "$app" || fail "stapler (app) check failed"
xcrun stapler validate "$dmg" || fail "stapler (DMG) check failed"

# The copy a user gets: attach the finished image read-only and assess the app in it. Detached on
# every way out.
mnt=""
detach() {
    if [[ -n "$mnt" ]]; then
        hdiutil detach -force "$mnt" >/dev/null 2>&1 || true
        rmdir "$mnt" 2>/dev/null || true
    fi
}
trap detach EXIT
mnt="$(mktemp -d "${TMPDIR:-/tmp}/noctule-release-check.XXXXXX")"
hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$dmg" >/dev/null || fail "couldn't attach the DMG to check the app in it"
gatekeeper --type execute --verbose "$mnt/Noctule Scan.app" || fail "Gatekeeper (app in the DMG) check failed"
# What a user's Mac will show: the version and build number stamped above, as found in the image.
inside="$mnt/Noctule Scan.app/Contents/Info.plist"
inside_version="$(plutil -extract CFBundleShortVersionString raw "$inside")" || fail "couldn't read the app's version in the DMG"
inside_build="$(plutil -extract CFBundleVersion raw "$inside")" || fail "couldn't read the app's build number in the DMG"
if [[ "$inside_version" != "$short_version" || "$inside_build" != "$build_number" ]]; then
    fail "the app in the DMG says $inside_version (build $inside_build), expected $short_version (build $build_number)"
fi
detach
mnt=""

echo "release: $dmg"
echo "sha256: $(shasum -a 256 "$dmg" | cut -d ' ' -f 1)"
