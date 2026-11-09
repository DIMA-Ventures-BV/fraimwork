# Memory and the server's size

Every Claude Code process on the server takes about 250 to 300 MB, plus about 140 MB for each
browser MCP server it starts. A 4 GB server that starts a few at once (main, two goals, a lead
and the chief writing a message) runs out of memory. Before this was managed, it then swapped
until nothing answered: CPU at 200%, 20,000 disk reads a second, and SSH, Tailscale and
WhatsApp gone until a hard reset (2026-11-09, three times in an hour).

fraim now manages this itself, and every limit comes from the server's own size, so a bigger
server simply runs more at once.

## What does what

| Layer | Where | What it does |
| --- | --- | --- |
| The gate | `fraim-capacity` | One more Claude only when free memory is at least `FRAIM_CLAUDE_MB` (550) plus `FRAIM_MEM_RESERVE_MB` (350) for main, the browser and WhatsApp. Free memory is the smaller of the server's `MemAvailable` and what the container may still use under its cap. |
| Headless runs wait | `fraim-claude -p` | Automations, leads, the chief's messages and the brain wait for room, up to `FRAIM_CAPACITY_WAIT` (1200 s); then the run is not started (exit 75) and says why. |
| Goals wait | `fraim-goal` launch | A goal waits in line (with its heartbeat) until there is room, up to its own time limit. |
| Coding sessions | `fraim-sessions` | A new or reopened session is refused with a plain reason when there is no room, besides the count limit. |
| Closing idle terminals | `fraim-capacity reclaim`, run by the supervisor every 30 s and by anyone waiting | When memory is short: first goal terminals whose result is in, then coding sessions that wait for the owner. Never main, never one that works or asks something. They reopen with their conversation (`send` or a follow-up). A run without the owner closes only goals. |
| Container caps | `compose.yaml`, set by `install.sh` from `MemTotal` | Workspace 75%, scheduler 40% of the server's RAM, no swap inside them: a runaway is stopped in its container, the server stays reachable. Recomputed on every install or update, so a resize adapts. |
| Last resort | `earlyoom` on the server (`install.sh`) | Below 6% free memory (and swap in use) it stops a `claude` process first, never sshd, Tailscale, Docker or herdr. `vm.swappiness=10` keeps swap for emergencies. |
| One MCP copy less | `fraim-entrypoint` | WhatsApp and the lent laptop Chrome (`my-chrome`) are registered for main's folder only (local scope `~/fraim`); goals and sessions work in their own folders and do not start them. |
| No telemetry | `workspace/Dockerfile` | `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1`: each browser MCP copy otherwise starts a 50 MB watchdog. |

A space can also deny MCP servers it does not need, for example a team plugin's own browser
server, which on the server starts a useless extra copy per Claude:
`fraim space policy main --deny "...,plugin:dami-config:chrome-devtools"`.

## Watching it

- `fraim exec -- fraim-capacity status` shows free memory and whether one more Claude fits.
- `~/.local/state/fraim/capacity.log` lists what was closed to free memory, and runs that
  waited too long.
- `fraim status` has the check `memory-headroom` (free memory above the reserve). When it
  fails often, the server is too small for the work it is given: a bigger server type is the
  fix, and the limits follow it on the next update.
