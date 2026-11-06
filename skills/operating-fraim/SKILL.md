---
name: operating-fraim
description: Run an existing fraimwork setup for the user with the fraim CLI - check health, read logs, restart, update, run something on the server, ask the server's Claude, open the server browser, lend laptop Chrome, check WhatsApp and file sync, switch between local and server. Use when the user says "is my server up", "restart fraim", "update fraim", "what is the server doing", "ask my server to ...", "open the server browser", "WhatsApp stopped working", "move fraim to a new server", "remove fraim", or anything about a running fraim. The user never types fraim; you run it. Do NOT use for first-time setup (use setting-up-fraim) or for adding skills and MCP servers (use managing-fraim-config).
---

# Operating fraim

The user never types `fraim`. You run it from their fraimwork checkout (`~/fraimwork` or `~/projects/fraimwork`):
`F=<checkout>/bin/fraim`. Never run it from the plugin folder.

## Contract

- Exit codes: 0 ok, 1 failure, 2 usage or missing input, 3 human step needed.
- Exit 3 prints one line `HUMAN STEP: ...`. Pass it to the user in plain words, wait, then run the same command again.
- Exit 2 names what is missing (for example `missing: --ts-authkey`). Get the value, then run the command again.
- No command prompts or blocks without a terminal. `fraim shell` is for humans only and exits 2 for you.

## Target

`$F use local` or `$F use server` picks the target. Always tell the user which one you acted on.

## Health first

`$F status --json` returns `{target, host, ok, services[{service,state,status}], health{ok, modules, checks[{name,ok}]}}`
and exits non-zero when anything fails. Report only the failing parts, one line each.

| Failing check | First action |
| --- | --- |
| `"error":"workspace unreachable"` | Right after start: wait 10 s and retry. Later: `$F logs workspace --tail 80`, then `$F restart workspace` |
| `claude-login` | Login flow in setting-up-fraim ("Server login") |
| `claude-session-running` | `$F restart workspace`, then status again |
| `whatsapp-connected` | `$F whatsapp status`; if logged out, `$F whatsapp relink` (ask first) |
| `server-browser` | `$F restart browser` |
| `syncthing` | `$F restart syncthing`, then `$F sync --print-url` |
| `disk-below-90-percent` | `$F exec -- du -sh ~/fraim/* ` and tell the user what is large |
| a service not `running` | `$F logs <service> --tail 80`, read it, then `$F restart <service>` |

The scheduler has a container health check, not a doctor check: read its `status` in `services[]` (`unhealthy` means supercronic stopped; `$F restart scheduler`).

Read the logs before you name a cause. A restart that fixes it still gets one line on what the logs showed.

## Commands

| Goal | Command |
| --- | --- |
| Run a command on the server | `$F exec -- <command>` (exit code passes through) |
| Ask the server's Claude | `$F ask "<prompt>" --json`; add `--allow "Read,Bash(git:*)"` when it needs tools. Exit 3 means not logged in: run the login flow |
| Logs | `$F logs [service] --tail N` (never `--follow` in the foreground) |
| Restart | `$F restart [service]`; services: workspace, scheduler, browser, whatsapp, syncthing |
| Rebuild the workspace | `$F reset-workspace` (files and logins stay) |
| Push repo changes to the server | `$F update` |
| Server browser for the user | `$F browser --print-url`, give the user the URL; `$F browser stop` after |
| Lend laptop Chrome to the server | `$F chrome start`, `$F chrome status`, `$F chrome stop` when the job is done |
| WhatsApp | `$F whatsapp status`, `$F whatsapp test` |
| File sync GUI | `$F sync --print-url`; `$F sync stop` after |
| Claude config | `$F config status` (see managing-fraim-config) |

## Move to a new server

1. Ask the user to create the new server (same Hetzner steps as in setting-up-fraim, Stage 4) and give the IP.
2. Back up first: `$F exec -- tar czf - -C ~ fraim > ~/fraim-backup-$(date +%Y%m%d).tgz` on the laptop. Check the file is not empty.
3. `$F deploy root@<new ip>`, then the login flow, then copy the backup in: `$F exec -- tar xzf - -C ~ < <backup>`.
4. WhatsApp: on the old server, nothing to do; on the new one, `$F whatsapp link --number <bot>` and the pairing human step.
5. `$F status --json` on the new server. Only when everything works: tell the user to delete the old server in the Hetzner console, and remove the old machine at https://login.tailscale.com/admin/machines.

## Remove fraim

Confirm first: "This deletes your fraim server and everything on it, after a backup to your laptop. Continue?"
1. Backup: as in "Move", step 2. Tell the user where the file is.
2. Human steps, one at a time:
   - WhatsApp: on the bot phone, Settings, Linked devices, tap fraim, Log out.
   - Hetzner: https://console.hetzner.cloud, the project, the server, Delete. (A deleted server stops costing money; an existing one costs money even when stopped.)
   - Tailscale: https://login.tailscale.com/admin/machines, the fraim machine, Remove. Then https://login.tailscale.com/admin/settings/keys: revoke any fraim auth key left.
   - Claude token: https://claude.ai/settings, revoke the token named for fraim (from `claude setup-token`).
3. Local stack, if any: `$F local down --wipe`.
4. Laptop: `$F config uninstall` removes the fraim plugin links. `~/fraim` and the backup stay; delete them only when the user asks.

## Ask first

`$F local down --wipe` (deletes the stack, its volumes and env file; keeps `~/fraim/claude` and `secrets.env`), `$F whatsapp relink`, `$F deploy` to a server that already runs fraim (`--force-env`), `$F reset-workspace` while a job runs.

## Never

Print `.env`, `secrets.env`, tokens or auth keys in the chat. Pipe them.
