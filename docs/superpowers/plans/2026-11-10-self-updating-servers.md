# Self-updating Servers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A maintainer publishes one signed release, and every server installs it by itself, checks health and rolls back on failure, with no laptop involved.

**Architecture:** `bin/fraim-release` builds and signs a tarball on the maintainer's laptop and publishes it as a GitHub release. `bin/fraim-updater` runs on the host as root from a systemd timer, outside every container, so no agent can reach it. It reuses `install.sh` and the `.update-lock` marker of the laptop flow.

**Tech Stack:** bash, systemd, `ssh-keygen -Y` signatures (no new dependency), GitHub Releases, bats.

**Spec:** `docs/superpowers/specs/2026-11-10-engine-split.md`

## Global Constraints

- Signature namespace and principal: `fraim-release`.
- Tarball: `fraimwork-vX.Y.Z.tar.gz`, signature `fraimwork-vX.Y.Z.tar.gz.sig`, with a `RELEASE` file holding `version=` and `commit=`.
- Install dir `/opt/fraimwork`. State dir `/var/lib/fraim/updates`. Signers `/etc/fraim/release-signers`, copied from `config/release-signers`.
- `.env` keys: `AUTO_UPDATE` (default `on`), `UPDATE_RING` (`stable` default, `canary`), `UPDATE_WINDOW` (default `3-5`, local hours, end exclusive).
- Stable waits `FRAIM_UPDATE_HOLD_HOURS` (default 24) after publication. Canary waits 0.
- Never touched by an update: `.env`, `.env.*`, `config/authorized_keys`, `.update-lock`, `.public-ssh-locked`, Docker volumes.
- Exit codes of `fraim-updater`: 0 ok or nothing to do, 1 failure, 2 usage, 3 could not check.

## Review Focus

1. A tampered or unsigned tarball: refuse it, change nothing, tell the owner once.
2. A server on a hand-deployed build (`FRAIM_VERSION` is not exactly `vX.Y.Z`): never overwrite it, and say so in `status`.
3. Health gets worse after an update: roll back, mark the release bad, and do not try it again every night.
4. Power loss or reboot during an update: the next run restores the previous code by itself.
5. GitHub offline, rate limited, or a half-finished download: exit 3, change nothing, no message to the owner.

---

### Task 1: Updater core: choose and verify a release

**Files:**
- Create: `bin/fraim-updater`, `config/release-signers`
- Test: `tests/unit/fraim-updater.bats`

**Interfaces:**
- Produces: `fraim-updater check` prints `up-to-date`, `available vX.Y.Z`, `held vX.Y.Z`, `dev-build` or `off`. `fraim-updater status --json` prints `{current, commit, auto, ring, window, latest, last_result, bad}`.
- Test overrides: `FRAIM_UPDATER_DIR`, `FRAIM_UPDATER_STATE`, `FRAIM_UPDATER_SIGNERS`, `FRAIM_UPDATER_NOW` (epoch seconds), `FRAIM_UPDATER_HOUR`.

- [ ] **Step 1:** Write failing tests: picks the highest published vX.Y.Z and ignores drafts and prereleases; `held` while younger than the hold on stable; `available` on canary at once; `dev-build` for `FRAIM_VERSION=abc123` and for `v1.2.3-4-gabc`; `off` for `AUTO_UPDATE=off`; a release listed in `bad` is skipped and a newer one is not; lower or equal versions give `up-to-date`; exit 3 when curl fails; a signature from another key is refused.
- [ ] **Step 2:** Run `bats tests/unit/fraim-updater.bats`. Expected: FAIL, no such file.
- [ ] **Step 3:** Implement. Version order uses `sort -V`. The release list comes from `https://api.github.com/repos/$FRAIM_RELEASES_REPO/releases?per_page=30`. Downloads go to a temp file in the state dir and move into place only when complete. Verify with `ssh-keygen -Y verify -f signers -I fraim-release -n fraim-release -s SIG < TAR`, then require `RELEASE` version to equal the tag.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit.

### Task 2: Apply, health check, roll back, recover

**Files:**
- Modify: `bin/fraim-updater`, `install.sh`, `tests/unit/fraim-updater.bats`

**Interfaces:**
- Produces: `fraim-updater run [--now] [--to vX.Y.Z]`.
- Consumes: `install.sh` with `FRAIM_LOCK_HELD=1`, `fraim-doctor --json` in each space, `fraim-notify`.

- [ ] **Step 1:** Write failing tests with stubbed `docker` and `install.sh`: outside the window nothing runs; `--now` ignores the window; success updates `FRAIM_VERSION` and `FRAIM_COMMIT`, removes the lock, tells the owner; protected files survive with their content; files absent from the release are removed; a new failing doctor check restores the old code and version, writes the release to `bad`, tells the owner; a check that failed before does not count; `install.sh` failure rolls back; running goals defer the update, and after 3 deferrals it goes ahead; a held lock from the laptop means no run; a lock left by the updater with nobody running restores the snapshot; `AUTO_UPDATE=off` blocks a scheduled run but not `--now`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Hold `flock` on `$STATE/lock` for the whole run. Snapshot current code to `$STATE/previous.tar.gz` before applying. Copy with `rsync -a --delete` and the same protect rules as `push_and_rebuild`. Prune unused images after success.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit.

### Task 3: Install on servers

**Files:**
- Modify: `install.sh`, `.env.example`, `workspace/bin/fraim-version-check`, `tests/lint.sh` if needed
- Test: `tests/unit/fraim-updater.bats`

- [ ] **Step 1:** Failing test: `install.sh` text installs `/usr/local/sbin/fraim-updater`, `/etc/fraim/release-signers`, `fraim-updater.service` (oneshot, `TimeoutStartSec=2h`) and `fraim-updater.timer` (hourly, `RandomizedDelaySec=15m`, `Persistent=false`), and lists `rsync` in `base_packages`. `fraim-version-check --notify` does not tell the owner to act when `AUTO_UPDATE` is on.
- [ ] **Step 2:** Implement, following the `fraim-isolation` unit pattern at `install.sh:91-110`. Pass `AUTO_UPDATE` into the workspace env in `compose.yaml`.
- [ ] **Step 3:** Run `make check`. Expected: PASS.
- [ ] **Step 4:** Commit.

### Task 4: Publishing and laptop commands

**Files:**
- Create: `bin/fraim-release`, `tests/unit/fraim-release.bats`
- Modify: `bin/fraim` (add `autoupdate`), `skills/operating-fraim/SKILL.md`, `README.md`

**Interfaces:**
- Produces: `fraim-release vX.Y.Z [--dry-run]`; `fraim autoupdate [status|on|off|canary|stable|now]`.

- [ ] **Step 1:** Failing tests in a temp git repo with a stubbed `gh`: refuses a dirty tree; refuses a branch other than `main` or a HEAD different from `origin/main`; refuses a version not above the highest tag; refuses when the key does not match `config/release-signers`; a good run makes a tarball that `fraim-updater`'s verify accepts, with the correct `RELEASE`, and calls `gh release create` with both files; `--dry-run` publishes nothing and creates no tag. `fraim autoupdate off` sets `AUTO_UPDATE=off` through `admin`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Key path `FRAIM_RELEASE_KEY`, default `~/.config/fraim/release-key`.
- [ ] **Step 4:** Run `make check`. Expected: PASS.
- [ ] **Step 5:** Commit.

### Task 5: Prove it on a real machine

**Files:**
- Create: `tests/e2e-update.sh`
- Modify: `Makefile`

- [ ] **Step 1:** Write `tests/e2e-update.sh`, which runs the updater against a real Linux VM with Docker and a local copy of the release feed. Scenarios: install from v0, update to v1, health-breaking v2 rolls back to v1, tampered v3 is refused, reboot during an update recovers.
- [ ] **Step 2:** Run it. Expected: all scenarios pass, owner data unchanged.
- [ ] **Step 3:** Commit.
