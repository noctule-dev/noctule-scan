#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# Cuts a release with one command: works out the next version from the latest v tag on origin,
# checks main, runs the full test suite, asks once, tags, pushes, and follows the release workflow
# (.github/workflows/release.yml) to the draft GitHub Release. The owner writes the notes and
# publishes. Nothing here talks to Apple; the pushed tag starts the workflow that does.
# Usage: packaging/cut-release.sh beta | final | patch [--beta] | minor [--beta] | major [--beta]
#        [--first X.Y.Z[-beta.N]]
#   beta    the next beta of the latest beta (v0.1.1-beta.1 -> v0.1.1-beta.2)
#   final   the latest beta, as a final release (v0.1.1-beta.2 -> v0.1.1)
#   patch, minor, major   the next final release after a final one; with --beta, its first beta
#
# Only vX.Y.Z and vX.Y.Z-beta.N tags are read or made. The latest is the highest by semantic-version
# precedence among the tags on origin (git ls-remote), so a tag made only on this Mac never counts;
# none is refused (exit 1) unless --first V is given: then, and only then (else exit 2), the version
# proposed is vV, which must agree with the kind (X.Y.Z-beta.N for beta or --beta, else X.Y.Z). Other
# v tags are listed in a warning and ignored.
# Checks, all before anything changes: branch main; clean tree; fetch; main equals origin/main; the
# tag is new locally and on origin; no release for it; then NOCTULE_NO_USB_DETECTION=1 swift test
# (the whole suite, no way to skip it), logged to build/cut-release-test.log.
#
# The run is found with gh run list for the tag, by headBranch, polled every 5 s up to 24 times. The
# Actions page named when no single run is found comes from origin's URL when that is a GitHub one,
# else https://github.com/noctule-dev/noctule-scan/actions. JSON from gh is read with plutil.
#
# Test-only (the tests' stub gh answers at once): CUT_RELEASE_POLL_SECONDS (default 5) and
# CUT_RELEASE_POLL_LIMIT (default 24).
set -euo pipefail

usage() { echo "usage: $0 beta | final | patch [--beta] | minor [--beta] | major [--beta]   (add --first X.Y.Z[-beta.N] when origin has no release tags)" >&2; exit 2; }
fail() { echo "cut-release: $*" >&2; exit 1; }

kind=""
beta=""
first=""
have_first=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --beta) [[ -z "$beta" ]] || usage; beta=1; shift ;;
        --first)
            [[ -z "$have_first" && $# -ge 2 ]] || usage
            have_first=1; first="$2"; shift 2 ;;
        -*) usage ;;
        *) [[ -z "$kind" ]] || usage; kind="$1"; shift ;;
    esac
done
case "$kind" in
    beta|final) [[ -z "$beta" ]] || usage ;;
    patch|minor|major) ;;
    *) usage ;;
esac

# --first names the version of a repository's first release, so its form must agree with the kind:
# a beta (the kind beta, or --beta) needs X.Y.Z-beta.N, anything else X.Y.Z; no leading v.
if [[ -n "$have_first" ]]; then
    first_num='(0|[1-9][0-9]{0,8})'
    first_final="^$first_num\\.$first_num\\.$first_num\$"
    first_beta="^$first_num\\.$first_num\\.$first_num-beta\\.$first_num\$"
    if [[ "$kind" == "beta" || -n "$beta" ]]; then
        [[ "$first" =~ $first_beta ]] || { echo "cut-release: --first needs X.Y.Z-beta.N with $kind${beta:+ --beta} (got \"$first\")" >&2; exit 2; }
    else
        [[ "$first" =~ $first_final ]] || { echo "cut-release: --first needs X.Y.Z with $kind (got \"$first\")" >&2; exit 2; }
    fi
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

poll_seconds="${CUT_RELEASE_POLL_SECONDS:-5}"
poll_limit="${CUT_RELEASE_POLL_LIMIT:-24}"

# The value at a key path of the JSON on standard input; fails when there is none.
json_get() { plutil -extract "$1" raw -o - - 2>/dev/null; }

trap 'echo "cut-release: interrupted; nothing tagged" >&2; exit 130' INT TERM HUP

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$branch" == "main" ]] || fail "you are on ${branch:-no branch}; switch to main"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree isn't clean; commit or stash first"
git fetch -q origin main --tags || fail "couldn't fetch from origin"
local_main="$(git rev-parse main)"
remote_main="$(git rev-parse -q --verify origin/main)" || fail "can't find origin/main; check the origin remote"
if [[ "$local_main" != "$remote_main" ]]; then
    if git merge-base --is-ancestor "$local_main" "$remote_main"; then
        fail "main is behind origin/main; pull first"
    fi
    fail "main has commits origin/main doesn't; push them first (or reset)"
fi

# The tags on origin; peeled (^{}) lines are the same tags again.
remote_tags="$(git ls-remote --tags origin)" || fail "couldn't read the tags on origin"
remote_names=""
while read -r _ ref; do
    [[ -n "${ref:-}" && "$ref" != *'^{}' ]] || continue
    remote_names+="${ref#refs/tags/}"$'\n'
done <<< "$remote_tags"

# Numbers without leading zeros (bash would read them as octal) and of at most nine digits (the sort key's width).
num='(0|[1-9][0-9]{0,8})'
pattern="^v$num\\.$num\\.$num(-beta\\.$num)?\$"
unreadable=""
best_key=""
best_tag=""
while IFS= read -r name; do
    [[ "$name" == v* ]] || continue
    if [[ "$name" =~ $pattern ]]; then
        # A sort key: the three numbers, then 1 for a final or 0 and the beta number, so a final
        # outranks its own betas and every number compares as a number.
        if [[ -n "${BASH_REMATCH[4]}" ]]; then rank=0; n="${BASH_REMATCH[5]}"; else rank=1; n=0; fi
        key="$(printf '%012d%012d%012d%d%012d' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" \
            "$((10#${BASH_REMATCH[3]}))" "$rank" "$((10#$n))")"
        if [[ "$key" > "$best_key" ]]; then best_key="$key"; best_tag="$name"; fi
    else
        unreadable+="${unreadable:+ }$name"
    fi
done <<< "$remote_names"
[[ -z "$unreadable" ]] || echo "cut-release: ignoring tags it can't read: $unreadable" >&2
if [[ -z "$best_tag" ]]; then
    [[ -n "$have_first" ]] || fail "no release tags on origin; pass --first X.Y.Z or X.Y.Z-beta.N for the first release"
    next="$first"
    best_tag="none"
else
    if [[ -n "$have_first" ]]; then
        echo "cut-release: --first is only for a repository with no release tags" >&2
        exit 2
    fi
    [[ "$best_tag" =~ $pattern ]]
fi
major=""; minor=""; patch=""; latest_beta=""; latest_is_beta=""
if [[ "$best_tag" != "none" ]]; then
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
    latest_beta="${BASH_REMATCH[5]:-}"
    [[ -n "${BASH_REMATCH[4]}" ]] && latest_is_beta=1
fi

if [[ "$best_tag" == "none" ]]; then
    :   # the first release: $next is $first, already chosen
elif [[ -n "$latest_is_beta" ]]; then
    case "$kind" in
        beta) next="$major.$minor.$patch-beta.$((latest_beta + 1))" ;;
        final) next="$major.$minor.$patch" ;;
        *) fail "$best_tag isn't final yet; release it with final, or another beta with beta" ;;
    esac
else
    case "$kind" in
        beta) fail "latest is $best_tag (final); use patch --beta, minor --beta or major --beta" ;;
        final) fail "latest is $best_tag, already final" ;;
        patch) next="$major.$minor.$((patch + 1))" ;;
        minor) next="$major.$((minor + 1)).0" ;;
        major) next="$((major + 1)).0.0" ;;
    esac
    [[ -z "$beta" ]] || next="$next-beta.1"
fi
tag="v$next"

if grep -qxF "$tag" <<< "$remote_names"; then
    fail "$tag already exists on origin"
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    fail "$tag exists locally but not on GitHub; delete it with git tag -d $tag"
fi

# Only gh's "release not found" means there is no such release (as in ci/release-from-tag.sh).
if viewed="$(gh release view "$tag" 2>&1 >/dev/null)"; then
    fail "a release for $tag already exists; delete it or choose another version"
elif [[ "$viewed" != *"release not found"* ]]; then
    reason="${viewed%%$'\n'*}"
    [[ -n "$reason" ]] || reason="gh failed"
    fail "couldn't ask GitHub about releases: $reason"
fi

# The whole suite, in the background so a signal ends the wait at once, and in its own process group
# (set -m) so the signal's trap can end every process the tests started, not just swift. With job
# control on, bash no longer gives a background job /dev/null as input, so it is given here.
# Keep the Mac awake (not the display) while this script runs, through the tests and the watch;
# caffeinate ends with it (-w).
if command -v caffeinate >/dev/null 2>&1; then caffeinate -i -w $$ >/dev/null 2>&1 & fi
mkdir -p "$root/build"
log="$root/build/cut-release-test.log"
set -m
# The owner's shell may hold opt-in variables (the hardware tests, the CI runner's skips); the run drops them.
env -u NOCTULE_CI_RUNNER -u NOCTULE_HARDWARE_TESTS -u NOCTULE_AUDIO_HARDWARE_TESTS -u NOCTULE_RESTART_HARDWARE_TEST \
    -u NOCTULE_SDS150_HARDWARE_TESTS -u NOCTULE_SDS150_PUSH_TEST -u NOCTULE_SDS150_KEEPALIVE_TEST \
    NOCTULE_NO_USB_DETECTION=1 swift test < /dev/null > "$log" 2>&1 &
child=$!
set +m
trap 'kill -TERM -- -"$child" 2>/dev/null || true
      echo "cut-release: interrupted; nothing tagged" >&2; exit 130' INT TERM HUP
echo "cut-release: running the tests (log: $log)"
status=0
wait "$child" || status=$?
trap 'echo "cut-release: interrupted; nothing tagged" >&2; exit 130' INT TERM HUP
if [[ "$status" -ne 0 ]]; then
    tail -n 10 "$log" >&2 || true
    fail "the tests failed; nothing tagged. Log: $log"
fi

sha="$(git rev-parse --short HEAD)"
subject="$(git log -1 --format=%s)"
# Keys pressed during the long test run must not answer the question (drained before it is asked, so
# an answer typed at once is kept). bash 3.2's read -t takes whole seconds.
if [[ -t 0 ]]; then
    while read -r -t 1 -n 1000 _; do :; done
fi
printf 'Tag %s (%s) as %s (latest %s) and push it? This starts the release workflow, which uploads the app to Apple for notarization. [y/N] ' \
    "$sha" "$subject" "$tag" "$best_tag"
answer=""
read -r answer || answer=""
echo
answer="$(tr '[:upper:]' '[:lower:]' <<< "$answer")"
case "$answer" in
    y|yes) ;;
    *) fail "nothing tagged" ;;
esac

# A signal between the tag and the push would leave a half-made release; ignore them for these two.
trap '' INT TERM HUP
git tag -a "$tag" -m "Noctule Scan $next"
if ! git push origin "$tag"; then
    git tag -d "$tag" >/dev/null
    fail "couldn't push $tag; the local tag is removed, nothing was released"
fi
trap 'echo "cut-release: interrupted; $tag is pushed" >&2; exit 130' INT TERM HUP
echo "cut-release: pushed $tag"

actions="https://github.com/noctule-dev/noctule-scan/actions"
origin_url="$(git config --get remote.origin.url 2>/dev/null || true)"
if [[ "$origin_url" =~ github\.com[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]]; then
    repository="${BASH_REMATCH[1]%.git}"
    actions="https://github.com/$repository/actions"
fi

# The run for the tag: the workflow's push runs whose headBranch is the tag (gh names a tag there).
run_id=""
run_url=""
found=0
try=0
while [[ "$try" -lt "$poll_limit" ]]; do
    try=$((try + 1))
    runs="$(gh run list --workflow release.yml --event push --limit 30 --json databaseId,headBranch,url 2>/dev/null || true)"
    found=0
    i=0
    while [[ "$i" -lt 100 ]]; do
        branch_i="$(json_get "$i.headBranch" <<< "$runs")" || break
        if [[ "$branch_i" == "$tag" ]]; then
            found=$((found + 1))
            run_id="$(json_get "$i.databaseId" <<< "$runs")"
            run_url="$(json_get "$i.url" <<< "$runs")"
        fi
        i=$((i + 1))
    done
    [[ "$found" -eq 0 ]] || break
    [[ "$try" -ge "$poll_limit" ]] || sleep "$poll_seconds"
done
if [[ "$found" -ne 1 ]]; then
    if [[ "$found" -eq 0 ]]; then
        echo "cut-release: $tag is pushed, but no release run for it appeared. See $actions"
    else
        echo "cut-release: $tag is pushed, but more than one run matches it. See $actions"
    fi
    exit 1
fi
echo "cut-release: release run: $run_url"

# Watching, in the background (in its own process group, so a terminal's Ctrl-C reaches only this
# script, which interrupts the watch itself); the run goes on.
# Its input is /dev/null and it ignores SIGTTOU and SIGTTIN (ignored signals survive exec), so a terminal
# setting or read can't stop it in the background group and hang the wait. The trap is in place before
# the child starts; a signal before $child is set only prints the line.
child=""
trap 'kill -INT "${child:-}" 2>/dev/null || true
      n=0
      while kill -0 "$child" 2>/dev/null && [[ "$n" -lt 20 ]]; do sleep 0.1; n=$((n + 1)); done
      kill -TERM "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      echo "cut-release: the release run goes on: $run_url"; exit 130' INT TERM HUP
set -m
( trap '' TTOU TTIN; exec gh run watch "$run_id" --exit-status ) < /dev/null &
child=$!
set +m
status=0
wait "$child" || status=$?
trap - INT TERM HUP
if [[ "$status" -ne 0 ]]; then
    # gh run watch also exits non-zero when it loses contact with GitHub while the run goes on, so the
    # run itself says whether it failed.
    state="$(gh run view "$run_id" --json status,conclusion 2>/dev/null || true)"
    run_status="$(json_get status <<< "$state")" || run_status=""
    run_conclusion="$(json_get conclusion <<< "$state")" || run_conclusion=""
    if [[ "$run_status" != "completed" ]]; then
        echo "cut-release: stopped following the run (gh run watch exited $status); it goes on: $run_url"
        exit 1
    fi
fi
if [[ "$status" -ne 0 && "$run_conclusion" != "success" ]]; then
    step=""
    details="$(gh run view "$run_id" --json jobs 2>/dev/null || true)"
    j=0
    while [[ "$j" -lt 20 && -z "$step" ]]; do
        json_get "jobs.$j.name" <<< "$details" >/dev/null || break
        s=0
        while [[ "$s" -lt 60 ]]; do
            conclusion="$(json_get "jobs.$j.steps.$s.conclusion" <<< "$details")" || break
            if [[ "$conclusion" == "failure" ]]; then
                step="$(json_get "jobs.$j.steps.$s.name" <<< "$details")"
                break
            fi
            s=$((s + 1))
        done
        j=$((j + 1))
    done
    [[ -z "$step" ]] || echo "cut-release: the failing step: $step"
    echo "cut-release: the release run failed: $run_url"
    echo "cut-release: see the failure list in packaging/README.md; nothing was retried, and $tag stays pushed"
    exit 1
fi

draft="$(gh release view "$tag" --json url,assets 2>/dev/null)" || fail "the run passed, but the draft for $tag can't be read; see $run_url"
echo "cut-release: draft release: $(json_get url <<< "$draft")"
a=0
while [[ "$a" -lt 20 ]]; do
    asset="$(json_get "assets.$a.name" <<< "$draft")" || break
    echo "cut-release: asset: $asset"
    a=$((a + 1))
done
echo "Check it, write the notes, then publish it."
