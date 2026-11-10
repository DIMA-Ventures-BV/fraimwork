# Decisions and test status

## Decided by Michael (2026-11-06)

| Topic | Decision |
|---|---|
| Platform | Claude Code plus our own setup layer, not Hermes or OpenClaw |
| Users | Tens of non-technical people. Claude runs every `fraim` command; humans only do `HUMAN STEP` items. |
| Repo | Public at `DIMA-Ventures-BV/fraimwork`. |
| Backups | Hetzner paid backups, as a recommended setup step. No backup job of our own. |
| Updates | Release tags `vX.Y.Z`. `fraim update` installs the latest tag, checks health, and rolls back on failure. |
| Sandbox | No Claude Code sandbox inside the container. The container is the boundary. |
| Central heartbeat | Not built. |
| Tailnets | One tailnet per person. Everyone in `group:fraim-users` can reach every `tag:fraim` server on a tailnet. |
| Untrusted input isolation | The browser (uid 1100) and the WhatsApp gateway only get their own drop folder (`downloads`, `inbox` volumes), never the rest of `~/fraim`, and each has its own network with the workspace. Secrets (`~/.config/fraim`, Claude credentials, `/etc/fraim`) are denied to Claude's Read tool; WebFetch is never pre-approved. Tested 2026-11-07. |
| Lock-out recovery (tailscale mode) | No root password is set at deploy. If Tailscale breaks after public SSH is closed: Hetzner Cloud > server > Rescue > "Reset root password", then Console, log in as root, run `tailscale up --ssh` (or `ufw allow OpenSSH`). The operating-fraim skill guides this. |
| Update rollback | Restores code and rebuilds; data in Docker volumes is not rolled back. A release that migrates volume data needs its own migration notes. |

## Open for Michael

- Publish the repo (cannot be undone).

## Test status

| Part | Status |
|---|---|
| Local stack on macOS Docker (all modules except sync) | Tested, e2e 28/28 |
| Novice setup from the skills only (local) | Tested by a fresh Claude, no blockers |
| `fraim init` + `fraim deploy` + `install.sh` in public mode on a fresh Ubuntu 24.04 VM (arm64) | Tested: all 5 services up, status correct |
| Novice setup on an existing server from the skills only (public mode, VM) | Tested by 3 fresh Claude agents in a row; the last pass had no blockers and also handled "is my server ok", opening the server browser and restarting it. Login, WhatsApp and sync were skipped |
| Browser restart | Tested on the VM: 3 restarts in a row, the browser is up and healthy each time |
| Server reboot (public mode VM) | Tested: all 5 services and the Claude tmux session come back on their own (before herdr) |
| Live sessions in herdr (docs/sessions.md) | Tested on a live server (2026-11-09): main with WhatsApp and Remote Control, a coding session with a question answered on WhatsApp, close and reopen with its memory, a goal with result, queue item and a follow-up answer; the owner got every WhatsApp message. `fraim shell` attach over SSH and a server reboot not tested yet |
| `fraim update` with rollback | Tested on the VM (tree of 19:29): normal update; a second concurrent update is refused; an interrupted update shows `unfinished_update` and `--recover` repairs it; a broken release is detected and rolled back; a server whose workspace is down is repaired; piped output does not hang and leaves no orphan processes; the browser tunnel picks a free port |
| Tailscale mode (`tailscale up`, policy, `fraim lock`) | **Not tested end to end** |
| Syncthing with a real laptop | Not tested |
| WhatsApp with a real number (pairing code, messages, approvals, files) | Not tested |
| Remote Control from the Claude phone app | Not tested |
| mosh | Not tested |
