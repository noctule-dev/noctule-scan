# CI: a fast path for documentation-only pull requests

Date: 2026-11-21. Status: approved by the owner ("Let's do 1", after the options for shorter CI runs). Branch: `ci/docs-fast-path`.

## Why

`ci.yml` takes about 17 minutes on every pull request (1.8 min to build the tests, 10.3 min of parallel tests, 4.8 min of one-at-a-time suites, 0.3 min for the app and iOS builds; PR #2's run). A pull request that changes only documentation waits as long as one that changes code. The aim is wall-clock time for the owner, not money: the repository is public and its runs are free.

Documentation is itself under test here (`RepositoryFilesTests` pins `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, the code of conduct and the issue chooser; `RepositoryHygieneTests` keeps assistant links out of every tracked file; `CIWorkflowTests` covers the workflows), so a documentation-only pull request still builds the tests and runs those suites. It skips the rest: about 3 minutes instead of 17.

## Rules

1. **One job, still named `build`.** The `main` ruleset requires the `build` check. A workflow skipped by a `paths` filter never reports, which would leave such a pull request waiting forever, so there is no `paths`/`paths-ignore` filter: steps inside the job are skipped by `if:` instead.
2. **The classifier is a script, `scripts/ci-changes.sh <base> <head>`.** It prints `docs` or `code` on stdout and exits 0; it exits 2 with a usage line on a wrong argument count, or when git can't compare the two (`ci-changes: can't compare <base> and <head>`). It lists the changed paths with `git diff --no-renames --name-only <base>...<head>` (the merge base, as GitHub shows a pull request; `--no-renames` so a file moved from code into `docs/` counts on both sides).
3. **`docs` only when every changed path is documentation**, and there is at least one. Documentation is: a path under `docs/` or `images/`; `LICENSE`; `NOTICE`; or a file ending in `.md` that is not under `Sources/`, `Tests/` or `Resources/` (those can be bundled resources or fixtures; the match ignores case, since the runner's file system does, so `sources/x.md` is `code`). Everything else is `code`, including `.github/`, `scripts/`, `packaging/` files that aren't `.md`, `Package.swift`, and an empty diff. When in doubt, `code`.
4. **Only pull requests are classified.** A step `Classify the change` (`id: changes`, `if: github.event_name == 'pull_request'`) runs after the DCO step and writes `scope=<docs|code>` to `$GITHUB_OUTPUT` in two lines, so the runner's `bash -e` fails the step when the script fails: `scope=$(scripts/ci-changes.sh "${{ github.event.pull_request.base.sha }}" "${{ github.event.pull_request.head.sha }}")`, then `echo "scope=$scope" >> "$GITHUB_OUTPUT"`. A push to `main` has no classification and always runs everything; `release.yml` is unchanged and always runs everything.
5. **What a `docs` pull request runs:** the checkout, the DCO step, `Select Xcode`, `Build the tests`, and a new step `Test (documentation checks)` (`if: steps.changes.outputs.scope == 'docs'`, `timeout-minutes: 10`): `swift test --skip-build --filter "RepositoryFilesTests|RepositoryHygieneTests|CIWorkflowTests|PrivateWordsTests|RealNamesTests|InfoPlistTests|PlaceholderBackgroundTests"` (`InfoPlistTests` and `PlaceholderBackgroundTests` hold the tests that read `AGENTS.md`, `LESSONS.md` and everything under `packaging/`, `.md` files included; the deny-list suites skip on the runner, where their git-ignored lists are absent; they are named so the filter stays right if that changes).
6. **What it skips:** `Test (parallel)`, `Test (timing-sensitive suites, one at a time)`, `Build the app` and `Check the shared code builds for iOS` each get `if: steps.changes.outputs.scope != 'docs'` (true on a push, where the output is empty). Their `run:` commands don't change, so `ciTestsAsTheReleaseJobDoes` still holds.
7. **Safety stays as it is.** No new action, permission, secret or trigger. A pull request can always change its own workflow or this script, as it already can change `ci.yml`; CODEOWNERS routes `/.github/` and `/scripts/` to the maintainer, and both count as `code`.

## Tests (`CIWorkflowTests`)

- The classifier, on temporary repositories like the DCO tests' (`ciChanges…`): only `README.md` → `docs`; a file under `docs/specs/` and one under `images/` → `docs`; `LICENSE` and `NOTICE` → `docs`; a `.swift` file → `code`; a mix of `README.md` and a `.swift` file → `code`; `Sources/X/notes.md`, `Tests/X/fixture.md`, `Resources/x.md` → `code`; a file moved from `Sources/` to `docs/` (`git mv`) → `code`; `.github/workflows/ci.yml` → `code`; `scripts/x.sh` → `code`; `Package.swift` → `code`; base equal to head (no changes) → `code`; one argument → exit 2 with `usage:`; an unknown revision → exit 2.
- The workflow: the `Classify the change` step exists with `id: changes`, the pull-request `if:` and the script's exact arguments; it comes after the DCO step and before `Build the tests`; `Test (documentation checks)` has the docs `if:` and exactly the filter above; the four full steps each carry `if: steps.changes.outputs.scope != 'docs'`; `Build the tests` and the DCO step carry no scope condition; there is still exactly one job and it is `build`; no `paths` or `paths-ignore` key appears anywhere in `ci.yml`.
- The new script starts with the SPDX notice (`RepositoryHygieneTests` already checks).

## Docs

- `AGENTS.md`'s `ci.yml` paragraph (Repository hygiene): a documentation-only pull request runs only the repository suites (this file's rule 3 in brief); pushes to `main` and releases always run everything.
- `CONTRIBUTING.md`, if it describes what CI runs: the same in one sentence.
- `docs/specs/README.md`: index this file.

## Proving it

After the merge, a documentation-only pull request should show `build` passing in about 3 minutes with the four full steps skipped; a code pull request still runs all of them.
