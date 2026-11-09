---
name: operating-fraim
description: Run an existing fraimwork setup for the user with the fraim CLI - check health, read logs, restart, update, run something on the server, ask the server's Claude, open the server browser, lend laptop Chrome, check WhatsApp and file sync, switch between local and server. Use when the user says "is my server up", "restart fraim", "update fraim", "what is the server doing", "ask my server to ...", "start a goal on my server", "open the server browser", "WhatsApp stopped working", "move fraim to a new server", "remove fraim", "a fraimwork update is available", or anything about a running fraim. The user never types fraim; you run it. Do NOT use for first-time setup (use setting-up-fraim), for adding skills shared by every machine (use managing-fraim-config), or for spaces, repos, hosts, MCP servers per space, full login and previews (use managing-fraim-spaces).
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

`$F status --json` returns `{target, host, ok, services[{service,state,status}], health{ok, modules, checks[{name,ok}]}, recent_alerts[{time,text}]}`
and exits 1 when any check fails (also `claude-login` before the first login: then exit 1 is expected). Report only the failing parts, one line each.

| Failing check | First action |
| --- | --- |
| `health.error` "workspace unreachable" | Right after start: wait 10 s and retry. Later: `$F logs workspace --tail 80`, then `$F restart workspace` |
| `claude-login` | "Claude login" in setting-up-fraim |
| `claude-session-running` | `$F restart workspace`, then status again |
| `whatsapp-connected` | `$F whatsapp status`; if logged out, `$F whatsapp relink` (ask first) |
| `server-browser` | `$F restart browser` |
| `syncthing` | `$F restart syncthing`, then `$F sync --print-url` |
| `disk-below-90-percent` | `$F exec -- sh -c 'du -sh ~/fraim/*'` and tell the user what is large |
| `jobs-ok` | An automation's last run failed, or it paused itself after 5 failures. `$F auto show <name>` gives the reason; act on it (login, usage limit, timeout, a mistake in automation.md), then `$F auto run <name>` once and `$F auto resume <name>` |
| `plugins-ok` | Loading the Claude config at start failed (usually GitHub was unreachable). Read `$F exec -- cat .local/state/fraim/config-init.log`, then `$F restart workspace` to retry. Everything else keeps working meanwhile |
| a service not `running` | `$F logs <service> --tail 80`, read it, then `$F restart <service>` |

For "what did my jobs say?", read `recent_job_results` (the last 3 answers, with time and job name). Older answers are in `~/fraim/outbox.md` (last 100): `$F exec -- tail -80 fraim/outbox.md`. When that file does not exist, no job has answered yet: say so.

Always read `recent_alerts` too (the last 5 problems, newest last; normal job answers never land there). Report the ones from the last 7 days in plain words, also when every check is ok, because a user without WhatsApp sees them only here. Alerts are history: an alert about a job that was since fixed or removed is not a current problem. The live state is the checks (`jobs-ok`, `plugins-ok`, ...).

The scheduler has a container health check, not a doctor check: read its `status` in `services[]` (`unhealthy` means supercronic stopped; `$F restart scheduler`).

## Restarting

Run each step as its own command; never chain logs, restart and status in one call (a chained call can hit the 2-minute tool limit).
1. `$F restart <service>`.
2. Wait 20 seconds.
3. `$F status --json`. When the service still shows "Restarting", read `$F logs <service> --tail 80`, then restart once more. When it fails again, report what the logs show.

Read the logs before you name a cause. A restart that fixes it still gets one line on what the logs showed.

## Commands

| Goal | Command |
| --- | --- |
| Run a command on the server | `$F exec -- <command>` (exit code passes through) |
| Ask the server's Claude | `$F ask "<prompt>" --json`; add `--allow "Read,Bash(git:*)"` when it needs tools. Exit 3 means not logged in: run the login flow |
| Logs | `$F logs [service] --tail N` (never `--follow` in the foreground) |
| Restart | `$F restart [service]`; services: workspace, scheduler, browser, whatsapp, syncthing. See "Restarting" below |
| Rebuild the workspace | `$F reset-workspace` (files and logins stay) |
| Update fraim | See "Updating" below |
| Server browser for the user | `$F browser --print-url`. Line 1 is the URL (its port can differ from 6080: fraim picks a free one), line 2 the VNC password. Give the user both lines. The tunnel stays open until `$F browser stop`; run that when the user is done |
| Lend laptop Chrome to the server | `$F chrome start`, `$F chrome status`, `$F chrome stop` when the job is done |
| WhatsApp | `$F whatsapp status`, `$F whatsapp test` |
| Background goal (a longer task; result on WhatsApp) | `$F goal "TASK"`, `$F goal list`, `$F goal show g1`, `$F goal stop g1`. On WhatsApp the owner asks in plain words. Tools: `~/fraim/goals/tools` on the server (default Read, Glob, Grep, Edit, Write, WebSearch, Bash, the server browser; edits are accepted, other tools are refused). The result also lands in the review queue |
| Review queue (goal results, lead ideas, decisions; see docs/queue.md) | `$F queue` opens the page, `$F queue list`, `$F queue approve q3 [NOTE]`, `$F queue reject q3 "WHY"`, `$F queue dismiss q3`. Only approve or reject when the user says so. On WhatsApp the owner answers in plain words |
| Lead agents and the chief of staff | Ask the user for the area and what the lead may start alone, then `$F lead new NAME --area "..." [--at "0 7 * * 1-5"] [--budget 3]`, then write the brief with `$F exec -- fraim-lead show NAME` and edit `~/fraim/leads/NAME/lead.md` (synced folder). `$F lead new chief --chief` adds the chief of staff: a morning digest, plus event runs when goal results, failures or automation answers land in the queue (`$F lead events chief [--off] [--every 30m]`). `$F lead ask -- "..."` gives the chief a request now (on WhatsApp the owner just asks in plain words); `$F lead tell NAME -- "..."` leaves a note for a lead's next run. `$F lead list`, `$F lead run NAME`, `$F lead pause NAME`. Needs the scheduler module |
| Learned preferences (brain, see docs/brain.md) | `$F brain` shows the rules, `$F brain note "PREFERENCE"` adds one at once, `$F brain why r3` shows its source, `$F brain forget r3`, `$F brain undo`, `$F brain history`, `$F brain distill` proposes changes now (they wait in the queue), `$F brain skills` lists learned skills. On WhatsApp the owner says it in plain words |
| Clear, compact or switch model of the always-on session | The owner says it on WhatsApp in plain words; the server's Claude uses its `session_command` tool (owner chats only). From the laptop: `$F exec -- fraim-session-command clear` (or `compact [FOCUS]`, `model opus|sonnet|haiku|default`) |
| File sync GUI | `$F sync --print-url`; `$F sync stop` after |
| Claude config | `$F config status` (see managing-fraim-config) |
| Open the user's workspace (macOS) | `<checkout>/bin/fraim-desktop open`; `fraim-desktop install` first when cmux is missing, `fraim-desktop dock` after the server changed |

## Make an automation

An automation runs on the server when its trigger fires (a schedule, an interval, new files in a folder, a changed web page, or right after another automation), also while the laptop is off. It is one file: `~/fraim/automations/<name>/automation.md`. The building-automations skill (on the server) has every setting and explains plugins: the owner's own triggers and outputs in `~/fraim/automations/_triggers` and `_outputs`. For anything beyond a plain schedule, hand the whole request to the server: `$F ask "<the request>"`, so the server Claude follows that skill. Steps for a plain schedule, each its own command:

1. `$F auto catalog` lists the triggers, outputs and examples on this server. Confirm in words: when it runs ("every weekday at 8:00, server time zone `health.timezone`"), what the answer should contain, and where it goes. Pick a short name in lowercase letters and dashes.
2. Write the file (or start from an example: `$F auto new <name> --from <example>`):
   ```
   $F exec -- sh -c 'mkdir -p fraim/automations/<name> && cat > fraim/automations/<name>/automation.md' <<'EOF'
   ---
   description: <one line>
   schedule: "0 8 * * 1-5"
   tools: Read, Grep, WebSearch
   output: whatsapp
   ---
   <the prompt>. If there is nothing to report, answer with exactly: SILENT
   EOF
   ```
   Use `every: 30m` instead of `schedule` for an interval. A website needs `WebFetch(domain:<site>)` in `tools` (WebFetch is never pre-approved; for weather, `WebFetch(domain:wttr.in)`). Never add fraim-notify: the runner delivers the answer itself.
3. `$F auto check <name>`, and fix each mistake it names.
4. `$F auto run <name> --dry`: show the user the answer (nothing is delivered). Change the prompt until the user is happy.
5. `$F exec -- fraim-auto sync` makes the schedule live now (otherwise within a minute).
6. Add it to the user's guide (`~/fraim/fraim-guide.md`): name, trigger, what it does.

Where answers go: the outputs in the file, and always `~/fraim/outbox.md`. Without WhatsApp, say up front: "Results wait on the server until you ask me what they said."

Other commands: `$F auto` (list), `$F auto show <name>`, `$F auto runs <name>`, `$F auto pause <name>`, `$F auto resume <name>`. To remove one: `$F exec -- rm -r fraim/automations/<name>`. With Syncthing on, the user can also edit the file in `~/fraim/automations` on the laptop.

## Locked out (server unreachable)

When: Tailscale mode, `$F status` cannot reach the server, and `tailscale status` on this Mac shows the Mac connected but the fraim machine offline (public SSH is closed by design).
First check the simple causes: the Mac's Tailscale icon says Connected; the server shows "Running" in the Hetzner console (ask the user). Then the human steps, one at a time:

1. "Open https://console.hetzner.cloud, your fraim project, the server, the Rescue tab, and click Reset root password. Save the password in your password manager. Do not paste it here."
2. "On the same server page, click the Console icon (>_ at the top right). Log in as `root` with that password." (Typing, not pasting, may be needed in that window.)
3. "Type `tailscale up --ssh` and press Enter. Tell me what it prints in a few words."
   When that does not bring the machine back online within a minute: "Type `ufw allow OpenSSH` and press Enter." This opens public SSH again, so you can repair it.
4. With public SSH open, repair it yourself: `ssh root@<public_host> 'systemctl restart tailscaled; tailscale up --ssh; tailscale status'`.
   `public_host` comes from `$F status --json` (it is there even when the server is unreachable). When it is null (an older setup), ask the user for the IPv4 address on the Hetzner server page.
   Never ask the user to type more than step 3.
5. `$F status`. When the server is reachable over Tailscale again, `$F lock` closes public SSH. Do not stop before `lock` succeeds.
6. Tell the user: "Fixed. You can delete the root password from your password manager, or keep it for emergencies." No root password is set at deploy (see docs/decisions.md).

## Updating

Triggers: the user says "a fraimwork update is available" (the server sends this on WhatsApp once a week), "update fraim", or you see it yourself with `$F exec -- fraim-version-check` (exit 10 = an update exists, 0 = up to date, 3 = could not check: tell the user "I could not check for updates", never "up to date").
1. Tell the user: "Updating fraim, this takes a few minutes. Your files stay."
2. `$F update` in the background (`--to vX.Y.Z` for a given version). On a server it reinstalls, so allow several minutes. It prints stage lines and a summary; the full log path is on its "Full log:" line. On failure, read the 15 lines it prints first.
3. Exit 0: report the new version and run `$F status --json`.
   Exit 1: the update failed and fraim rolled back. Read whether the rollback passed health, and tell the user in one line: "The update failed, your server is back on the old version and works" (or, when the rollback failed too, follow "Health first").
   Exit 2: the checkout has local changes. Tell the user; never discard them yourself.
   Unfinished update (`unfinished_update` in `$F status --json`, or update says "an update is already running or did not finish"): ask the user "Is another Claude window updating fraim right now?" Only when no: `$F update --recover`.
   Update or rollback failed for an unclear reason: the server may be installing its own system updates. Wait 10 minutes and run the same command once more before you report it as broken.
   A line "Already failing before the update (ignored): <checks>" lists problems that existed before the update. The update did not cause them and they do not block it.
   Report them separately ("These were already broken before: ..."), then handle each with the table in "Health first".
4. The checkout is a detached HEAD at the release tag after an update. Never `git pull`, `git checkout` or `git reset` in it: `$F update` is the only way to move it.

## Move to a new server

1. Ask the user to create the new server (setting-up-fraim, Path B step 3; the SSH key `laptop` already exists, so they tick it instead of adding it) and give the IP.
2. Back up first: `$F exec -- tar czf - -C ~ fraim > ~/fraim-backup-$(date +%Y%m%d).tgz` on the laptop. Check the file is not empty.
   (Hetzner backups restore a whole server in place; they do not move data to a new server.)
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

`$F local down --wipe` (deletes the stack with every file inside it, its volumes and env file; keeps the laptop's `~/fraim/claude` and `secrets.env`. When the stack was the user's only fraim, also run `$F config uninstall`), `$F whatsapp relink`, `$F deploy` to a server that already runs fraim (`--force-env`), `$F reset-workspace` while a job runs.

## Never

Start a second `$F update` while one may still run (another Claude window can be updating too).

Print `.env`, `secrets.env`, tokens or auth keys in the chat. Pipe them.
