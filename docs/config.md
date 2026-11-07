# Claude config: skills, agents, hooks and MCP servers

fraimwork keeps your Claude Code setup equal on the laptop and the server with native
Claude Code features only. There is no extra config tool to learn.

## How it works

1. `~/fraim/claude/` holds your config. Syncthing already syncs `~/fraim` two-way, so the folder is the same on every machine.
2. The folder holds three plugin folders: `core/` (every machine), `laptop/` and `server/`.
3. `fraim config apply` links `core` and this machine's role folder into `~/.claude/skills/`.
   Claude Code loads each linked folder live as a plugin (`fraim-core@skills-dir`). There is no install step and no cache.
4. Secrets never sync. Each machine keeps `~/.config/fraim/secrets.env` (mode 600), and the launcher loads it.
   MCP entries refer to a secret as `${KEY}`.

```
~/fraim/claude/                      synced
  core/      .claude-plugin/plugin.json  skills/  agents/  hooks/  .mcp.json
  laptop/    same layout, laptops only
  server/    same layout, server only
  plugins.json                       third-party plugins: all / laptop / server
~/.config/fraim/secrets.env          per machine, never synced
~/.claude/skills/fraim-core   ->     ~/fraim/claude/core
~/.claude/skills/fraim-<role> ->     ~/fraim/claude/<role>
```

## Set up

1. Server first (it is always on): the workspace entrypoint runs `fraim-config init --role server`.
   This copies the template into `~/fraim/claude` when the folder does not exist yet.
2. Laptop, after Syncthing has synced `~/fraim`: `fraim config init --role laptop`.
   `init` keeps an existing `~/fraim/claude`, so the laptop never overwrites the server's copy.
3. Run `fraim config status` on both machines. The `fingerprint` lines must match.

## Laptop safety

The server can write to the synced `~/fraim/claude`. So the laptop never loads that folder directly: `fraim config apply` copies it to `~/.config/fraim/applied`, and Claude Code loads the copy.
Changes to `.md` files are copied at the next session start. Any other change (hooks, `.mcp.json`, `plugin.json`, `plugins.json`, scripts) can run code, so it stays inactive until the user approves it: `fraim config apply --review` shows it, and `fraim config apply --yes` activates it.
The server loads the synced folder directly: only the trusted laptop and the server itself write to it.

## Add an MCP server

```
fraim config mcp add linear --url https://mcp.linear.app/mcp
fraim config mcp add posthog --url https://mcp-eu.posthog.com/mcp --header 'Authorization: Bearer ${POSTHOG_API_KEY}'
fraim config mcp add mobile --to laptop -- mcp-server-mobile
fraim config mcp list
fraim config mcp remove mobile --to laptop
```

1. Use `--to laptop` or `--to server` when the server is not for every machine. The default is `core`.
2. Put a secret in the entry as `${KEY}` (required) or `${KEY:-}` (optional). Never put the value in `.mcp.json`.
3. Add `KEY=value` to `~/.config/fraim/secrets.env` on each machine that needs it.
   Give the server only the keys it needs.
4. Restart Claude. MCP servers load at session start.
5. An OAuth server (no key, for example Linear or Sentry) needs `/mcp` login once on each machine.
   On the server, log in inside `fraim shell`.

`fraim config status` lists the keys that a machine is missing. The fraim plugin's SessionStart hook also tells Claude about them.

You normally just ask Claude: "add the Linear MCP for every machine". The `managing-fraim-config` skill in the fraim plugin tells it where things go.

## Add a skill

```
fraim config skill new summarizing-invoices
fraim config skill new checking-backups --to server
```

Follow Anthropic's skill practice:

- **Name:** lowercase with hyphens, preferably a gerund ("summarizing-invoices").
- **Description:** what the skill does, "Use when ..." with the words a user would say, and "Do NOT use for ...". Claude picks a skill by its description alone.
- **SKILL.md:** under 500 lines, steps in order.
- **Long reference material:** `references/<topic>.md`, one level deep, linked from SKILL.md.
- **Exact, repeatable work:** a script in `scripts/` that the skill tells Claude to run.
- **Test it:** use the `skill-creator` skill (from the official marketplace) for evals.
- **Pick the right tool:** a hook for what must always happen, a skill for know-how, an MCP server for access to an external system, CLAUDE.md for short project facts.

A new skill loads in the next session, or now with `/reload-plugins`.

## Add a third-party plugin

Edit `~/fraim/claude/plugins.json`:

```json
{
  "marketplaces": { "claude-plugins-official": "anthropics/claude-plugins-official" },
  "plugins": {
    "all": ["superpowers@claude-plugins-official"],
    "laptop": [],
    "server": []
  }
}
```

Each machine installs new entries at its next session start (the SessionStart hook runs `apply`), or now with `fraim config apply`.
`apply` never uninstalls a plugin. Remove one by hand with `claude plugin uninstall <id>` on each machine.

## Secrets

`~/.config/fraim/secrets.env` holds one `KEY=value` per line. The script reads it as data and never runs it as shell.
A value can be a 1Password reference (`op://vault/item/field`). Then `op run` resolves the whole file at launch.
On the server, use a 1Password service account scoped to one vault that holds only the server's keys.

Every server entry point (tmux session, scheduled job, WhatsApp channel) starts Claude through
`fraim-config exec -- claude ...`. A process started another way gets no secrets.

## Security model

**In plain words: Claude on the server can read every secret that is loaded on that server, and anyone on the WhatsApp allow list can ask it to use them. Never put bank, production or admin credentials on a fraim server.**

The server's Claude can read everything that the `claude` user can read. fraimwork does not try to hide
files from Claude inside the container. It keeps dangerous things out of the container instead.

| Guard | How |
| --- | --- |
| The container is the boundary | Claude runs as user `claude`, with no `sudo` and no Docker socket |
| No private keys inside | the container holds no SSH private keys; host keys are root-only |
| Few secrets | `secrets.env` on the server holds only the keys the server's jobs need. Never production credentials |
| Server cannot reach the laptop | the Tailscale policy has no grant with the server as source |
| Audit trail | every tool call is logged to `~/.local/state/fraim/audit.jsonl` |

Limits to know:

- A loaded secret is in the Claude process environment. A Bash `env` call can print it. Give the server a key only when a job needs it.
- A `Read()` deny rule blocks the Read tool only, not `cat` through Bash.
- No Claude Code sandbox, by decision (2026-11-06). Inside Docker on Ubuntu 24.04 it needs a host AppArmor change
  (`kernel.apparmor_restrict_unprivileged_userns=1` blocks bubblewrap) and weaker container security, and it would still not hide loaded secrets.
  Tested with `@anthropic-ai/sandbox-runtime` 0.0.81: it fails even in a privileged container on a stock 24.04 host.

## Commands

| Command | Does |
| --- | --- |
| `fraim config init --role laptop\|server` | Create `~/fraim/claude` from the template if it is missing, then apply |
| `fraim config apply [--force]` | Link the plugins and install the third-party plugins from plugins.json |
| `fraim config status` | Role, fingerprint, secrets, missing keys, MCP servers |
| `fraim config mcp list\|add\|remove` | Edit a plugin's `.mcp.json` |
| `fraim config skill new <name>` | Scaffold a skill |
| `fraim config exec -- <cmd>` | Run a command with this machine's secrets |

## What fraimwork does not do

- **Repo config:** a repo's own `.mcp.json`, `.claude/settings.json` and `.claude/skills/` stay in that repo and travel with git.
- **Server policy:** `/etc/claude-code/managed-settings.json` is part of the workspace image. A plugin cannot loosen it: Claude Code reads only the `agent` and `subagentStatusLine` keys from a plugin's settings.
- **Allowlist:** if the image sets `strictKnownMarketplaces`, the list needs a `skills-dir` entry. Without one, the `fraim-*` plugins stop loading.
