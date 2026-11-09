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

| Want | Laptop | WhatsApp |
| --- | --- | --- |
| Start coding work on the server | `fraim session new vertelboek "fix the login bug"` | ask main: "work on vertelboek: fix the login bug" |
| See all sessions and their status | `fraim session all` | ask "what is running?" |
| Talk to one | `fraim session send s1 "run the tests"`, `fraim goal send g3 "..."` | say it in your own words; the server's Claude passes it on |
| Answer a question it asks | the same | answer the message in your own words ("tea") |
| See its screen | `fraim session read s1` | ask "what is it doing?" |
| Take it over | `fraim shell s1` (Ctrl+\ leaves, the session keeps running) | the Claude app, for main |
| Close it | `fraim session stop s1` | ask to stop it |

The owner gets a WhatsApp message, written by the chief of staff in plain words (docs/queue.md, "One voice on WhatsApp"), when:

- any session asks something or waits for a permission (`s1 needs you: <the question>`),
- a coding session finishes a turn (`s1 is done.` with Claude's last message),
- a goal has its result (unchanged from before), or answers a follow-up (`Goal g3 answered.`),
- main stays on a question screen for more than a minute.

## How it works

- **Image.** `workspace/Dockerfile` installs a pinned, checksummed `herdr-core` as
  `/usr/local/bin/herdr-core` and `hc`. Root owns it, so `hc update` cannot replace it; a new
  version comes with a new image.
- **The core.** `fraim-entrypoint` starts `fraim-herdr supervise` as user claude. Every 30 seconds
  it starts the core if needed (`hc server status` starts one), the terminals `main`
  (`fraim-session`), `queue-page` (`fraim-queue serve`) and `watch` (`fraim-herdr watch`), and
  `fraim-goal reconcile`. The core's socket is `~/.local/state/herdr-core/default/default.sock`
  in the home volume.
- **The scheduler container** shares the home volume and reaches the same core through that
  socket. Any `hc` command starts a core when none answers, so scripts call
  `fraim-herdr hc ...`: in the scheduler it first checks the socket (`fraim-herdr alive`, a
  JSON-RPC call in Python) and fails instead of starting a second core.
- **Status.** Claude Code reports its own status to herdr (OSC 7501): `idle`, `working`, `done`,
  `blocked` (a question or permission, with the question in `msg`), `error`. fraim never reads
  the screen to guess a status. `fraim-herdr watch` follows `hc events` and sends the WhatsApp
  messages above.
- **Labels.** Each terminal has `fraim=main|goal|session|service|shell`; `fraim-herdr ls` shows
  the ones that are not services.

### Goals

`fraim-goal start` writes the goal folder (`goal.md`, `state`, a new `session-id`) and starts a
watcher (`fraim-goal run gN`, in its own process group). The watcher:

1. opens terminal `gN`: `env FRAIM_HEADLESS=1 FRAIM_GOAL=gN fraim-claude --session-id SID
   --permission-mode acceptEdits --allowedTools TOOLS` in `~/fraim`, and waits for Claude's first
   status report;
2. sends the task (the same prompt as before) with `hc send`;
3. waits until the turn ends (`done`), then takes Claude's last message from the transcript
   (`~/.claude/projects/*/SID.jsonl`) as the result: `result.md`, the review queue (first result
   only), and WhatsApp;
4. keeps the terminal open `FRAIM_GOAL_KEEP` seconds (default 1800) for follow-ups, then closes it.

`FRAIM_HEADLESS=1` stays set: a goal is not the owner, so owner-only commands (queue decisions,
brain changes) still refuse inside it, also when the owner types into it.

`fraim-goal send gN TEXT` types into the live terminal (with `--force` when it shows a question,
so the text answers it). For a closed goal it reopens the same conversation
(`fraim-claude --resume SID`) first and starts a watcher in `follow` mode.

The watcher touches `heartbeat` at least every minute and removes it when it exits. A goal is
running while its heartbeat is younger than three minutes; this works across containers, where
a pid does not. After a container restart, `fraim-goal reconcile` gives a goal whose terminal
still runs a new watcher, and fails a running goal whose terminal is gone.

Failures: a session that does not start, a turn that ends on a login or usage-limit message, an
`error` status, a terminal that ends before its result, or `FRAIM_GOAL_TIMEOUT` (default 4
hours) of work. Each becomes a priority 1 queue item, as before.

### Coding sessions

`fraim-sessions new REPO [--] [TASK]` resolves `~/code/REPO` to its real path (it must stay
under the home folder), marks the folder trusted in `~/.claude.json` (otherwise Claude Code
waits at its trust question), opens terminal `sN` with `fraim-claude --session-id SID`, and sends
the task. These sessions are the owner's own: `FRAIM_HEADLESS` is not set. At most
`FRAIM_SESSIONS_MAX` run at once, because each Claude takes 300 to 500 MB. The default
follows the server's memory: 1.5 GB stays free for main, the browser and WhatsApp, and every
500 MB of the rest is one session (4 on a 4 GB server, about 12 on 8 GB, at most 20).
`stop` closes the terminal; `send` reopens it with `--resume`.

## Limits

- A server or container restart ends the running programs. herdr does not restore a process;
  main starts again, a goal fails or gets a new watcher (above), and a coding session can be
  reopened with `send`.
- Memory: on a 4 GB server two extra Claude sessions leave about 850 MB; fraim-michael runs on 8 GB (CX33) since 2026-11-09.
- herdr-core is pre-1.0 (protocol generation 1). fraim pins the version and uses only the CLI.
- The core trusts every process of user claude (no separate API password), as tmux did.
- Phone access is WhatsApp and the Claude app for main; there is no terminal on the phone.
