# ~/fraim/claude

Your Claude Code skills, agents, hooks and MCP servers, equal on every machine.
Syncthing syncs this folder between the laptop and the server. `fraim config apply`
links each plugin folder into `~/.claude/skills/`, and Claude Code loads it from there live.

| Folder | Loaded on |
| --- | --- |
| `core/` | every machine |
| `laptop/` | laptops only |
| `server/` | the server only |
| `plugins.json` | third-party plugins to install (`all`, `laptop`, `server`) |

Secrets are never in this folder. Each machine keeps its own `~/.config/fraim/secrets.env`.

Common commands:

```
fraim config mcp add linear --url https://mcp.linear.app/mcp
fraim config skill new summarizing-invoices
fraim config status
```

See docs/config.md in the fraimwork repo for the full guide.
