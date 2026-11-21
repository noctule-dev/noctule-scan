# Plan 11: move to `noctule-dev/noctule-scan` with one commit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. This repo's rules (AGENTS.md) apply on top. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The code lives in a new private repository, `noctule-dev/noctule-scan`, whose history is one commit holding exactly today's tracked tree, and the owner's Mac works from a fresh clone of it at `~/projects/noctule/noctule-scan`.

**Architecture:** No code changes. The one commit is built from `git archive main` in an empty directory, so no object from the old repository can reach the new one; the old checkout is set aside as the archive copy of the old checkout and never given the new remote. Identity of content is proven by tree hash: the new commit's tree must equal old `main`'s.

**Tech Stack:** git, GitHub CLI (`gh`, logged in as the owner with `repo` scope; the owner is an admin of `noctule-dev`), SwiftPM for the final check.

**Spec:** `docs/specs/2026-11-13-release-packaging-design.md`, section 5, step 1 (naming in section 3).

## Global Constraints

- New repository: `noctule-dev/noctule-scan`, **private**, default branch `main`, created empty (no README, license or `.gitignore` from GitHub).
- New checkout: `~/projects/noctule/noctule-scan`. Old checkout: moved to the archive copy of the old checkout, kept.
- The new history is exactly one commit, authored with the owner's git identity, message `Initial commit` followed by the co-author line this session uses.
- `docs/specs/` is included (the owner keeps it until the flip to public).
- Git-ignored files copied to the new checkout: `config/dev-scanner.env`, `config/real-names.txt`, `docs/uniden/*.pdf` (three on 2026-11-13). Not copied: `.build/`, `build/`, `.superpowers/`, `.DS_Store`.
- Agent memory: copy the agent's memory folder for this project (11 files on 2026-11-13) from the folder of the old checkout's path to the new checkout's folder.
- Outward-facing actions (pushing the old repository, creating the new one, pushing to it, archiving the old one) each need the owner's go-ahead at the time.
- Every shell that runs `noctule` or tests: `export NOCTULE_NO_USB_DETECTION=1`.

## Review Focus

1. **The deny-list missing in the new checkout:** `RealNamesTests.noRealNamesInTrackedFiles` is *skipped*, not failed, when `config/real-names.txt` is absent. Task 5 checks it ran.
2. **Executable bits or a file lost in the export** (`scripts/*.sh` are 100755): a full test pass wouldn't catch every loss. Task 2's tree-hash equality does.
3. **An old object reaching the new remote:** only the staging directory ever gets the new remote, and Task 3 checks the remote holds one commit.
4. **This session's working directory moves away under it:** Task 4 is the last thing this session does; Tasks 5–6 run in a new session started in the new checkout.
5. **GitHub initialising the new repository** (a README commit makes the push fail or adds a second commit): created with no init flags; Task 3 checks the commit count.

---

### Task 1: Preconditions on the old repository

**Files:** `docs/specs/2026-11-13-plan-11-move-to-noctule-dev.md` (this plan), `docs/specs/2026-11-13-release-packaging-design.md`, `LESSONS.md` (both already edited in this session).

- [x] **Step 1:** Commit them on a branch and fast-forward `main` (as for the design commit): message `docs: Plan 11, moving to noctule-dev; memory note in the move lesson`.
- [x] **Step 2:** Check: `git status --porcelain` prints nothing; for every ref in `refs/heads` and `refs/remotes/origin` (not `HEAD`), `git rev-list --count main..<ref>` is `0`; `git stash list` is empty.
- [x] **Step 3 (owner's go-ahead):** `git push origin main`, so the archive on GitHub holds everything. Expected: `git status -sb` shows `main...origin/main` with no ahead/behind.

### Task 2: Build the one commit

**Interfaces:** Produces `$STAGE`, a directory holding the new repository (record its path for Task 3).

- [x] **Step 1:** `OLD=<old checkout>; STAGE="$(mktemp -d)/noctule-scan"; mkdir -p "$STAGE"; git -C "$OLD" archive main | tar -x -C "$STAGE"`.
- [x] **Step 2:** `git -C "$STAGE" init -b main`, `git -C "$STAGE" add -A`, then commit with the message in Global Constraints.
- [x] **Step 3: Verify.** `git -C "$STAGE" rev-parse 'HEAD^{tree}'` equals `git -C "$OLD" rev-parse 'main^{tree}'`; `git -C "$STAGE" rev-list --count HEAD` is `1`; `git -C "$STAGE" remote` prints nothing; `git -C "$STAGE" log -1 --format='%an <%ae>'` is the owner's identity (`git -C "$OLD" config user.name`/`user.email`). Any mismatch: stop, delete `$STAGE`, report.

### Task 3: Create the repository and push (owner's go-ahead)

**Interfaces:** Consumes `$STAGE`.

- [x] **Step 1:** `gh repo view noctule-dev/noctule-scan` fails with "Could not resolve" (it must not exist yet).
- [x] **Step 2:** `gh repo create noctule-dev/noctule-scan --private --description "Control, listen to and log Uniden SDS scanners on the Mac"` (no `--add-readme`, `--license` or `--gitignore`).
- [x] **Step 3:** `git -C "$STAGE" remote add origin https://github.com/noctule-dev/noctule-scan.git` and `git -C "$STAGE" push -u origin main`.
- [x] **Step 4: Verify.** `gh api repos/noctule-dev/noctule-scan --jq '[.private, .default_branch] | @tsv'` prints `true	main`; `gh api 'repos/noctule-dev/noctule-scan/commits?per_page=2' --jq length` prints `1`; that commit's SHA equals `git -C "$STAGE" rev-parse HEAD`.

### Task 4: Switch the owner's Mac over (last task of this session)

- [x] **Step 1:** Check nothing holds the old checkout: no `noctule`, `noctule-mock-scanner` or `NoctuleScan` process running from it (`pgrep -fl '<old checkout>/'` prints nothing), and no other Claude session is working in it (ask the owner).
- [x] **Step 2:** `mv <old checkout> <old checkout archive>`.
- [x] **Step 3:** `git clone https://github.com/noctule-dev/noctule-scan.git ~/projects/noctule/noctule-scan`; then delete `$STAGE`'s parent temporary directory.
- [x] **Step 4:** Copy the git-ignored files listed in Global Constraints from the archive, keeping their paths (`cp -p`). Verify: `git -C ~/projects/noctule/noctule-scan status --porcelain` prints nothing, and `status --ignored --porcelain` lists exactly `config/dev-scanner.env`, `config/real-names.txt` and the three `docs/uniden/*.pdf`.
- [x] **Step 5:** Copy the memory folder as in Global Constraints (`mkdir -p`, `cp -p`). Verify: 11 files, `MEMORY.md` among them.
- [x] **Step 6:** Tell the owner to quit this session and start `claude` in `~/projects/noctule/noctule-scan` for Tasks 5 and 6.

### Task 5: Verify the new checkout (new session)

- [x] **Step 1:** `git log --oneline` shows one commit; `git remote -v` names `noctule-dev/noctule-scan`; `git status -sb` shows `main...origin/main`.
- [x] **Step 2:** `swift build` succeeds with no `Stale file` warning.
- [x] **Step 3:** `NOCTULE_NO_USB_DETECTION=1 swift test` passes, and its output shows `noRealNamesInTrackedFiles` passed, not skipped.
- [x] **Step 4:** `scripts/build-app.sh release` ends with `built …/noctule-scan/build/Noctule Scan.app (release)`, no warnings.
- [x] **Step 5:** Read `MEMORY.md` in the new memory folder: the session sees the recalled memories (the project-status entry among them).

### Task 6: Archive the old repository (owner's go-ahead)

- [x] **Step 1:** `gh repo archive <earlier personal repo> --yes`.
- [x] **Step 2: Verify.** `gh api repos/<earlier personal repo> --jq '[.archived, .private] | @tsv'` prints `true	true`.
- [x] **Step 3:** Report to the owner: what moved, where the old history now lives (the earlier personal repository, archived and private; the archive copy of the old checkout), and that deleting either is their call.

## Results (2026-11-13)

All six tasks are done; the owner gave each outward-facing step its go-ahead.

- **Tasks 1–4** (the session in the old checkout): `main` pushed to the earlier personal repository before the export; the one commit (`5ad9030`, `Initial commit`, the owner's identity) built from `git archive main`; its tree, `13288fb`, equals old `main`'s; `noctule-dev/noctule-scan` created private with default branch `main`, and the remote holds one commit; the old checkout moved to the archive copy of the old checkout (still on `main...origin/main` against the earlier personal repository, never given the new remote); the fresh clone at `~/projects/noctule/noctule-scan`, with `config/dev-scanner.env`, `config/real-names.txt` and the three `docs/uniden/*.pdf` copied in and nothing else untracked; the 11 memory files copied.
- **Task 5** (a new session in the new checkout): one commit, `origin` is `noctule-dev/noctule-scan`, `main...origin/main`; `swift build` with no `Stale file` warning; `NOCTULE_NO_USB_DETECTION=1 swift test` passed, 278 Swift Testing tests in 15 suites, `noRealNamesInTrackedFiles` among them run and passed (the deny-list is present), and no failure beyond the known issues the SDS150 hardware suite's mock tests expect; `scripts/build-app.sh release` ended `built …/noctule-scan/build/Noctule Scan.app (release)` with no warnings; the session recalled its memories.
- **Task 6:** `gh repo archive` from the agent was refused by Claude Code's auto-mode permission check (a write to GitHub), so the owner ran it with `!`; GitHub answered that the earlier personal repository was already archived, and `gh api` shows it `archived: true`, `private: true`.

The old history, Plan 1's unsanitized fixtures included, now lives only in the archived earlier personal repository and in the archive copy of the old checkout. Deleting either is the owner's call. PR numbers and commit hashes in the specs and `LESSONS.md` written before this move refer to the old repository.
