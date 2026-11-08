# fraim desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command (`bin/fraim-desktop install`, run by Claude) gives the user stock cmux with a fraim Dock and a fraim workspace.

**Architecture:** A bash CLI in `bin/fraim-desktop` that follows the `bin/fraim` conventions (no prompts, exit 0/1/2/3, `HUMAN STEP:` lines). It installs cmux, merges our controls into `dock.json` with `jq`, and opens a workspace through the `cmux` CLI. The `setting-up-fraim` skill calls it.

**Tech Stack:** bash 3.2 (macOS default), jq, Homebrew cask `cmux`, cmux CLI 0.65+.

**Spec:** `docs/superpowers/specs/2026-11-07-fraim-desktop-design.md`

## Global Constraints

- Follow `bin/fraim` conventions: never prompt without a TTY; exit 0 ok, 1 failure, 2 usage, 3 human step; human-only work prints exactly one `HUMAN STEP: ...` line.
- Never write `~/.config/cmux/cmux.json` or `~/.config/ghostty/config`.
- Our Dock control ids start with `fraim-`. Controls with other ids are never changed or removed.
- Back up `dock.json` to `dock.json.fraim-backup` before every write.
- No secret values in `dock.json`.
- Paths come from `$HOME`, so tests can run with a temporary HOME.
- No emoji in code or output. shellcheck must pass.

## Review Focus

1. `dock.json` exists but holds JSON with comments or invalid JSON: exit 1 with a clear message and no write (test in Task 1).
2. The installer runs twice: the second run changes nothing and keeps one copy of each control (Task 1).
3. No fraim target exists yet, so `fraim browser --print-url` fails: install still succeeds without the browser control (Task 1).
4. cmux is installed but not running: `open` launches it through `cmux <path>` instead of failing on the socket (Task 3).
5. `uninstall` with a user-owned `dock.json`: only `fraim-` controls go; the file stays when other controls remain (Task 1).

---

### Task 1: Dock merge (`dock`, `uninstall` subcommands)

**Files:**
- Create: `bin/fraim-desktop`
- Create: `tests/desktop.sh` (plain bash runner in the style of `tests/e2e-local.sh`: temp HOME, fake binaries on PATH, `ok`/`bad` counters, exit 1 on any failure)

**Interfaces:**
- Produces: `fraim-desktop dock` (write or merge controls), `fraim-desktop uninstall` (remove `fraim-` controls), helper `dock_controls() -> JSON array on stdout`. Env `FRAIM_BIN` (default `<repo>/bin/fraim`) lets tests use a fake.

- [ ] **Step 1: Write the failing tests** in `tests/desktop.sh`:
  - `dock_fresh`: no `dock.json`; after `dock`, `jq -r '.controls[].id'` gives `fraim-agent`, `fraim-status`, `fraim-browser` (fake fraim prints `http://100.64.0.1:6080/vnc.html` for `browser --print-url`).
  - `dock_merge`: existing file with control id `git`; after `dock`, `git` is still first and unchanged; the three `fraim-` controls follow; `dock.json.fraim-backup` equals the old file.
  - `dock_idempotent`: run `dock` twice; `jq '[.controls[]|select(.id|startswith("fraim-"))]|length'` is 3.
  - `dock_no_target`: fake fraim exits 2 on `browser --print-url`; exit 0, ids are `fraim-agent`, `fraim-status` only.
  - `dock_invalid`: file contains `{ // comment`; exit 1, output contains `dock.json is not plain JSON`, file unchanged.
  - `uninstall_keeps_user`: after merge then `uninstall`, only `git` remains. `uninstall_removes_ours`: after fresh then `uninstall`, `dock.json` is gone.
  - `no_secrets`: `grep -i password dock.json` finds nothing.
- [ ] **Step 2: Run** `bash tests/desktop.sh`. Expected: FAIL, `bin/fraim-desktop` not found.
- [ ] **Step 3: Implement** `bin/fraim-desktop` with `dock`, `uninstall`, `help`. Controls per the spec table; `fraim-status` command is `while :; do clear; fraim status; sleep 60; done`; `fraim-browser` has `"chrome": false`. Merge: `jq --argjson ours "$(dock_controls)" '.controls = ([.controls[]? | select(.id|startswith("fraim-")|not)] + $ours)'`. Write through a temp file, then `mv`.
- [ ] **Step 4: Run** `bash tests/desktop.sh` and `shellcheck bin/fraim-desktop tests/desktop.sh`. Expected: all PASS, no shellcheck output.
- [ ] **Step 5: Commit** `git add bin/fraim-desktop tests/desktop.sh` then `git commit -m "Add fraim-desktop: merge fraim controls into the cmux Dock"`.

### Task 2: cmux install (`install` subcommand)

**Files:**
- Modify: `bin/fraim-desktop`
- Modify: `tests/desktop.sh`

**Interfaces:**
- Consumes: `fraim-desktop dock` from Task 1.
- Produces: `fraim-desktop install` = ensure cmux, then `dock`. Env `FRAIM_CMUX_APP` (default `/Applications/cmux.app`) for tests.

- [ ] **Step 1: Write the failing tests:**
  - `install_present`: `FRAIM_CMUX_APP` points at an existing temp dir; fake `brew` records calls; exit 0, `brew` not called, `dock.json` written.
  - `install_brew`: app missing; fake `brew` creates the app dir when called with `install --cask cmux`; exit 0, the call log holds exactly `install --cask cmux`.
  - `install_no_brew`: app missing, no `brew` on PATH; exit 3, output has exactly one line starting `HUMAN STEP:` containing `https://cmux.com`; no `dock.json` written.
  - `install_no_tty`: run with `</dev/null`; finishes within 10 s (no prompt).
- [ ] **Step 2: Run** `bash tests/desktop.sh`. Expected: the four new tests FAIL.
- [ ] **Step 3: Implement** `install`: app present, done; else `brew install --cask cmux` with `NONINTERACTIVE=1`; else print the HUMAN STEP line and exit 3; then run `dock`. Missing `jq`: exit 1 naming `brew install jq`.
- [ ] **Step 4: Run** tests and shellcheck. Expected: all PASS.
- [ ] **Step 5: Commit** `git commit -m "fraim-desktop install: get stock cmux from Homebrew"` (stage both files by path).

### Task 3: fraim workspace (`open` subcommand)

**Files:**
- Modify: `bin/fraim-desktop`
- Modify: `tests/desktop.sh`

**Interfaces:**
- Consumes: `install` from Task 2.
- Produces: `fraim-desktop open` = open a cmux workspace named `fraim` in `$HOME/fraim` (create the folder when missing) running `fraim shell`. Env `FRAIM_CMUX_BIN` (default `/Applications/cmux.app/Contents/Resources/bin/cmux`).

- [ ] **Step 1: Write the failing tests** with a fake cmux that logs its arguments:
  - `open_running`: fake `cmux ping` exits 0; log contains `new-workspace --name fraim --cwd $HOME/fraim --command fraim shell`.
  - `open_not_running`: fake `cmux ping` exits 1; log first contains `$HOME/fraim` as a bare path argument (launches cmux), then the `new-workspace` call.
  - `open_existing`: fake `cmux list-workspaces` prints a row named `fraim`; no `new-workspace` call, a `select-workspace` call instead.
- [ ] **Step 2: Run** tests. Expected: FAIL.
- [ ] **Step 3: Implement** `open`. Check the real CLI names first with `cmux help navigate` and `cmux help start`, and adjust the test strings when they differ (the spec only fixes the behavior). After a launch, poll `cmux ping` up to 10 s.
- [ ] **Step 4: Run** tests and shellcheck. Expected: PASS. Then run `bin/fraim-desktop open` once against the real cmux on this Mac and check a `fraim` workspace appears.
- [ ] **Step 5: Commit** `git commit -m "fraim-desktop open: a ready fraim workspace in cmux"`.

### Task 4: Claude runs it during setup

**Files:**
- Modify: `skills/setting-up-fraim/SKILL.md` (new stage before Finish)
- Modify: `skills/operating-fraim/SKILL.md` (one line: "open my workspace" runs `fraim-desktop open`)
- Modify: `README.md` (one short section: the workspace, cmux is GPL-3.0 and installed unmodified)

**Interfaces:**
- Consumes: `install`, `open`, exit codes from Tasks 1 to 3.

- [ ] **Step 1: Write the stage:** "Stage N: your workspace (macOS only)". Run `<checkout>/bin/fraim-desktop install`; on exit 3 relay the HUMAN STEP in plain words and rerun; then `open`. Tell the user in one line: "Your workspace is open. Talk to your agent in the left panel; the right panel shows your server."
- [ ] **Step 2: Check** the skill with a dry read: every command in it exists in `bin/fraim-desktop help`.
- [ ] **Step 3: Run** `bash tests/desktop.sh` one final time. Expected: all PASS.
- [ ] **Step 4: Commit** `git commit -m "Set up the cmux workspace as part of fraim setup"`.

## Later plans (not in this one)

1. Managed servers: fleet update, alerts to DAMI, per-client config repo.
2. Billing and sign-up: Stripe subscription that triggers `fraim cloud create`.
3. v2 desktop: a custom cmux sidebar with server and plan status.
