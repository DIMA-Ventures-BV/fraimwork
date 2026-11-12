# Live sessions (herdr)

Every Claude Code session on the server runs in a terminal held by
[herdr-core](https://github.com/herdrdev/herdr-core) (`hc`, Apache-2.0). There are three kinds:

| Kind | Name | Started by | Who talks to it |
| --- | --- | --- | --- |
| The always-on session | `main` | the workspace container | WhatsApp, the Claude app, `fraim shell` |
| Goals | `g1`, `g2`, ... | `goal: ...` on WhatsApp, `fraim goal`, leads, the chief | it works alone; the owner can step in |
| Coding sessions | `s1`, `s2`, ... | `fraim session new REPO "task"`, or asking main | the owner, from the laptop or the phone |

Because herdr owns the terminals, every session keeps running when the laptop is closed or the
SSH connection drops, and the owner can look in, answer a question, correct it, or take it over.

## What the owner does

On WhatsApp the owner uses plain words, never ids or commands. The server's Claude (main)
decides by meaning which session a message is for (`fraim-herdr ls` shows each one with its
status and question) and passes it on with `fraim-goal send` or `fraim-sessions send`.

| Want | Laptop | WhatsApp (plain words to main) |
| --- | --- | --- |
| Start coding work on the server | `fraim session new vertelboek "fix the login bug"` | ask main: "work on vertelboek: fix the login bug" |
| See all sessions and their status | `fraim session all` | ask "what is running?" |
| Talk to one | `fraim session send s1 "run the tests"`, `fraim goal send g3 "..."` | say it in your own words; the server's Claude passes it on |
| Answer a question it asks | the same | answer the message in your own words ("tea") |
| See its screen | `fraim session read s1` | ask "what is it doing?" |
| Take it over | `fraim shell s1` (Ctrl+\ leaves, the session keeps running) | the Claude app, for main |
| Close it | `fraim session stop s1` | ask to stop it |

The owner gets a WhatsApp message, written by the chief of staff in plain words (docs/queue.md, "One voice on WhatsApp"), when:

- a goal or coding session asks something or waits for a permission ("The coding session in vertelboek asks you: ..."),
- a coding session finishes a turn ("The coding session in vertelboek is done." with Claude's last message),
- a goal has its result (unchanged from before), or answers a follow-up,
- main stays on a question screen for more than a minute.

## How it works

- **Image.** `workspace/Dockerfile` installs a pinned, checksummed `herdr-core` as
  `/usr/local/bin/herdr-core` and `hc`. Root owns it, so `hc update` cannot replace it; a new
  version comes with a new image.
- **The core.** `fraim-entrypoint` starts `fraim-herdr supervise` as user claude. Every 30 seconds
  it starts the core if needed (`hc server status` starts one), the terminal `main`
  (`fraim-session`), every service in the services file, and `fraim-goal reconcile`. The
  services file (`workspace/services`, one `NAME COMMAND` per line) ships `queue-page`
  (`fraim-queue serve`) and `watch` (`fraim-herdr watch`); the owner's `~/fraim/services`
  wins, so an owner can add or drop a background service without an engine change. The core's socket is `~/.local/state/herdr-core/default/default.sock`
  in the home volume.
- **The scheduler container** shares the home volume and reaches the same core through that
  socket. Any `hc` command starts a core when none answers, so scripts call
  `fraim-herdr hc ...`: in the scheduler it first checks the socket (`fraim-herdr alive`, a
  JSON-RPC call in Python) and fails instead of starting a second core.
- **Status.** Claude Code reports its own status to herdr (OSC 7501): `idle`, `working`, `done`,
  `blocked` (a question or permission, with the question in `msg`), `error`. fraim never reads
  the screen to guess a status. `fraim-herdr watch` follows `hc events` and sends the WhatsApp
  messages above.
- **Labels.** Each terminal has `fraim=main|goal|session|lead|service|shell`; `fraim-herdr ls`
  shows main, goals, sessions and shells.

### Watch them in the Herdr app

`fraim herdr link` on the laptop installs the [Herdr app](https://herdr.dev) when it is missing,
adds the server as Herdr machine `fraim` (SSH to `claude@` on the workspace port, with fraim's
key and known_hosts), makes one Herdr space `fraim` there, and writes its id to
`~/.config/fraim/herdr-space` on the server. From then on main, every lead run, goal and coding
session gets the label `herdr.space=<id>`, so it appears in that space by itself, with Herdr's
own working, done and needs-you status. `fraim herdr unlink` removes both. The laptop reaches the
server, never the reverse. A linked laptop is a shell as user claude: herdr-core has no
permissions per client, so only the owner links.

Link also installs fraim's own look (`desktop/herdr`: the layout `fraim` and the panel mod
`fraim`, Linear-style dark) and switches the window to it. An edited `layouts/fraim.json` is
kept aside as `fraim.json.old-<time>` first. The window:

- **The chief** (main) has its own column that always shows. Its address changes when the
  server restarts it; the panel repoints the column, puts main back in the space, and never
  leaves main's tab the shown one, because closing a tab in Herdr ends its terminal.
- **The sidebar** lists the chief (by its `display:` name), dashboards, whatever works now, the
  team (leads, by their `display:` name) and the automations. A word on the right only when
  something needs the owner: Working, Needs you, Failed, Paused, Off.
- **The work column** beside the chief shows a running agent, the Team view or a dashboard;
  Close hides it. **Team** shows one agent's rules in owner words (when it works, its brief
  section by section without commands, what it can use, the shared brain rules) and its
  activity (reports, work, cards waiting for the owner). **Activity** on the right lists one
  sentence per lead report, newest first, and can be hidden.

The panel only reads the server (`fraim-lead list`, `fraim-auto list`, `fraim-brain show`, the
leads' `runs/`), once a minute. Its Run now buttons run `fraim-lead run` or `fraim-auto run`
there. Herdr has no web view, so pages under `/p/` still open in a browser.

### Dashboards

A dashboard is a file `~/fraim/dashboards/NAME.json` on the server, written by an agent or an
automation; the Herdr panel draws it in the work column and rereads it every 30 seconds:

```json
{ "title": "Sales today", "subtitle": "...", "updated": "2026-11-11 07:00", "source": "Daily Brief",
  "tiles": [{ "label": "Ad spend", "value": "€72.74", "note": "456 clicks", "tone": "good|warn|bad" }],
  "bars": { "title": "Spend by campaign", "unit": "€", "items": [{ "label": "...", "value": 44.33, "note": "...", "tone": "good" }] },
  "notes": ["one plain sentence per note"] }
```

Agents only write data: the panel decides how it looks, and nothing an agent writes runs on
the laptop.

### Lead runs

A lead's scheduled run (the chief's too) is a terminal `lead-NAME` when the core answers, and
`fraim-claude -p` as before when it does not (`FRAIM_LEAD_TERMINAL=0` forces that). The run:

1. opens the terminal in the lead's own folder (main's `claude --continue` must never pick it up)
   with `fraim-claude --fraim-unattended --session-id SID "PROMPT" --allowedTools TOOLS`. The
   flag marks it `FRAIM_HEADLESS=1` and runs it in `dontAsk`, so a tool that is not on its list
   is refused, as in a `-p` run. The task comes before `--allowedTools`: that option takes every
   word after it, so a task after it would add the tools it names.
2. waits for the turn to end (`done`), `FRAIM_LEAD_TIMEOUT` at most (default 1800 seconds);
3. takes the answer from the transcript, which is also the run's live log,
   then closes the terminal, so it holds no memory after.

The scheduler starts each lead itself, never as the chief's child: a child ends with its
parent, and a lead must run without a chief. The lead's notes, budget and tools work as before.

### Goals

`fraim-goal start` writes the goal folder (`goal.md`, `state`, a new `session-id`) and starts a
watcher (`fraim-goal run gN`, in its own process group). The watcher:

1. opens terminal `gN`: `env FRAIM_HEADLESS=1 FRAIM_GOAL=gN fraim-claude --session-id SID
   --permission-mode acceptEdits --allowedTools TOOLS` in the goal's own folder
   (`~/fraim/goals/gN`, so main's `claude --continue` in `~/fraim` never picks up a goal's
   conversation), and waits for Claude's first status report;
2. sends the task (the same prompt as before) with `hc send`;
3. waits until the turn ends (`done`), then takes Claude's last message from the transcript
   (`~/.claude/projects/*/SID.jsonl`) as the result: `result.md`, the review queue (first result
   only), and WhatsApp;
4. keeps the terminal open `FRAIM_GOAL_KEEP` seconds (default 1800) for follow-ups, then closes it.

`FRAIM_HEADLESS=1` stays set: a goal is not the owner, so owner-only commands (queue decisions,
brain changes) still refuse inside it, also when the owner types into it.

`fraim-goal send gN TEXT` types into the live terminal. When the goal shows a question
(status `blocked`, kind `question`) the text is the answer (`--force`); a permission prompt is
refused, because typed text plus Enter would pick its default "Yes". For a closed goal it
reopens the same conversation (`fraim-claude --resume SID`) first and starts a watcher in
`follow` mode. It touches `last-send` first, so the watcher never closes the terminal (keep time)
with that message still in it.

While a goal is not working the watcher sleeps on core's event stream (`hc events --terminal`),
so it reacts at once to a status change; `hc wait` returns at once for a terminal that is not
working, so it only serves while Claude works. It still wakes every `FRAIM_GOAL_POLL` seconds
(default 60), because retries, the keep time, the time limit and a finished background task
are not core events.

The watcher touches `heartbeat` at least every minute and removes it when it exits. A goal is
running while its heartbeat is younger than three minutes; this works across containers, where
a pid does not. After a container restart, `fraim-goal reconcile` gives a goal whose terminal
still runs a new watcher, and fails a running goal whose terminal is gone.

A core that does not answer (busy, restarting) is never taken for a terminal that is gone:
`fraim-herdr state` says `unknown`, and nothing is replaced, killed or failed on it. Only `gone`
(hc exit 3) or `finished` is.

A message that does not go out (WhatsApp down) waits in `unsent` and is tried again every
watcher round; what is left when the watcher ends goes to the alerts, which `fraim status`
reports.

Failures: a session that does not start, a turn that ends on a short login or usage-limit
message (a longer answer that only discusses rate limits is a result), an `error` status, a
terminal that ends before its result, or `FRAIM_GOAL_TIMEOUT` (default 4 hours), also while it
waits on an unanswered question. Each becomes a priority 1 queue item, as before.

### Coding sessions

`fraim-sessions new REPO [--] [TASK]` resolves `~/code/REPO` to its real path (it must stay
under `~/code`, also through symlinks, so never `~/.claude` or another home folder), marks the
folder trusted in `~/.claude.json` (`fraim-herdr trust`: a copy renamed into place, because
running Claudes rewrite that file too; otherwise Claude Code waits at its trust question),
opens terminal `sN` with `fraim-claude --session-id SID`, and sends the task.

These sessions are the owner's own: `FRAIM_HEADLESS` is not set in them. So a run without the
owner (a goal, lead or automation, which has `FRAIM_HEADLESS=1`) may not start, steer or stop
one, and `fraim-herdr hc` lets it drive only goals (`gN`), never main or a session; reading
stays open. It may also start, end and remove a lead's run terminal (`lead-NAME`), never type
into one. Otherwise a goal that read a hostile page could have a session approve its own
work. Like every `FRAIM_HEADLESS` check this is a guard for Claude's own tools, not a sandbox:
a run with Bash could still call `hc` directly. The text of a finished session's last message
is shortened and tokens or keys in it are hidden (`fraim-herdr redact`) before it goes to
WhatsApp. A new session opens only when the server has memory for one more Claude
(`fraim-capacity`); `FRAIM_SESSIONS_MAX`, when set, also caps how many run at once.
`stop` closes the terminal; `send` reopens it with `--resume`.

## Limits

- A server or container restart ends the running programs. herdr does not restore a process;
  main starts again, a goal fails or gets a new watcher (above), and a coding session can be
  reopened with `send`.
- Memory: on a 4 GB server two extra Claude sessions leave about 850 MB; fraim-michael runs on 8 GB (CX33) since 2026-11-11.
- herdr-core is pre-1.0 (protocol generation 1). fraim pins the version and uses only the CLI.
- The core trusts every process of user claude (no separate API password).
- Phone access is WhatsApp and the Claude app for main; there is no terminal on the phone.
