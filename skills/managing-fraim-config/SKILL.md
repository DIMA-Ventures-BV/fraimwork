---
name: managing-fraim-config
description: Add, change or remove a skill, agent, hook or MCP server in this fraimwork setup so it reaches every machine (laptop and server). Use when the user says "add the X MCP", "make a skill for Y", "why is MCP Z missing on the server", "keep the server the same as my laptop", or asks where Claude config lives. Do NOT use for a single repo's own config (that repo's .mcp.json and .claude/), or for the server's security policy (/etc/claude-code/managed-settings.json, owned by the fraimwork image).
---

# Managing fraimwork's Claude config

The source of truth is `~/fraim/claude/` (the `source` line of `$F config status` shows the real path). Syncthing keeps it equal on the laptop and the server.
Run fraim from the user's fraimwork checkout: `F=<checkout>/bin/fraim` (`~/fraimwork` or `~/projects/fraimwork`).
Never edit `~/.claude/skills/fraim-*` (or `$CLAUDE_CONFIG_DIR/skills/fraim-*`): those are links into this folder.

## Where things go

| The user wants it | Folder |
| --- | --- |
| on every machine | `~/fraim/claude/core/` |
| on laptops only (local browser, phone, desktop) | `~/fraim/claude/laptop/` |
| on the server only (scheduled jobs, server integrations) | `~/fraim/claude/server/` |
| in one repo only | that repo's `.mcp.json` or `.claude/skills/`, not here |

Inside a plugin folder: `skills/<name>/SKILL.md`, `agents/<name>.md`, `hooks/hooks.json`, `.mcp.json`.

## Add an MCP server

1. Run `$F config mcp add <name> --url <url>` for a remote server, or
   `$F config mcp add <name> -- <command> <args>` for a local one. Add `--to laptop|server` when it is not for every machine.
2. A secret goes in the entry as `${KEY}` (required) or `${KEY:-}` (optional), never as a value.
   Example: `$F config mcp add linear --url https://mcp.linear.app/mcp`; a header token: `--header 'Authorization: Bearer ${LINEAR_API_KEY}'`.
3. Tell the user to add `KEY=value` to `~/.config/fraim/secrets.env` on each machine that needs it.
   You do not write secret values yourself, and you never read that file.
4. Tell the user to restart Claude (new MCP servers load at session start). Run `$F config status` to check for missing keys.
5. An OAuth server (no key) needs `/mcp` login once on each machine.

## Add a skill

1. Run `$F config skill new <gerund-name>` (`--to laptop|server` when needed).
2. Write the description first: what it does, "Use when ..." with the user's own words, "Do NOT use for ...".
3. Keep SKILL.md under 500 lines. Move long material to `references/<topic>.md`, one level deep.
   Move repeatable, exact work into `scripts/` and tell Claude to run the script.
4. New skills load in the next session, or now with `/reload-plugins`.

## Add a third-party plugin

Add the marketplace to `marketplaces` and the `plugin@marketplace` id to `plugins.all`, `plugins.laptop` or
`plugins.server` in `~/fraim/claude/plugins.json`. Each machine installs it at its next session start.

## Check parity

`$F config status` on both machines. Equal `fingerprint` lines mean core and plugins.json are the same.
A `missing` line names secrets that one machine lacks.
