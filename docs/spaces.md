# Spaces

A space is a complete, separate fraim on the same server. Each space has its own Claude session, browser, files, secrets proxy, MCP servers and logins. Use spaces to keep work and personal apart, so that text in one (a work email, a WhatsApp message) can never make Claude touch the other (your bank).

```
one server, one Tailscale name
├── main       ports 2222, 6080, 3100-3109 ...   project fraimwork
├── work       ports 2223, 6081, 3110-3119 ...   project fraimwork-work
└── personal   ports 2224, 6082, 3120-3129 ...   project fraimwork-personal
```

## How it works

- A space is the same `compose.yaml`, started as its own Docker Compose project with its own env file (`.env` for main, `.env.space-NAME` for the others). Docker gives every project its own containers, volumes and networks.
- Space n (1 to 4) uses the main space's ports plus n (SSH, browser view, Syncthing), mosh plus 20n, previews plus 10n, and its own subnets in `172.29.0.0/16`.
- `install.sh` starts every space. An update (`fraim update`) rebuilds them all with the same code and checks every space's health. A space that fails to start is reported but never stops the main space. A space stopped with `fraim space rm NAME` stays stopped (`STOPPED=1` in its env file) until `fraim space up NAME`.
- Docker keeps the spaces' networks apart. Ports the server publishes on its own address (previews, browser view, Syncthing GUI) would still be reachable from any container through that address, so `install.sh` adds firewall rules (`/usr/local/sbin/fraim-isolation`, run by the `fraim-isolation` systemd unit) that drop container traffic to the server's own fraim ports.
- Laptop commands take `--space NAME`; without it they work on `main`.

## What is separate, and what is shared

| Separate per space | Shared by all spaces |
| --- | --- |
| Claude session and its login | The server, its disk and memory |
| Files (`~/fraim`, `~/code`), jobs, logs | Tailscale name and firewall |
| Secrets proxy and its keys | Docker images (same fraimwork version) |
| MCP servers, claude.ai connector policy | The Claude account and its usage limit |
| Server browser profile | Root on the server, who can read everything |
| SSH host keys (`fraim host`) | |
| WhatsApp number (if the space has the module) | |

## Access a space can get

| Access | Command | Where the secret lives |
| --- | --- | --- |
| Full Claude login: Remote Control and claude.ai connectors | `fraim login --full --space S` | `~/.claude/.credentials.json` of the space (counts only with the `~/.config/fraim/full-login` marker that command writes) |
| Limit claude.ai connectors | `fraim space policy S --deny 'claude.ai Gmail'` or `--claudeai off` | root-owned `/etc/claude-code/managed-settings.d/50-fraim-space.json` |
| GitHub repos | `fraim repo token` + `fraim repo add OWNER/REPO` | the space's secrets proxy (`github`, `github-api`, `github-mcp`) |
| An SSH host (dev box) | `fraim host add NAME --address IP --user U --authorize-via ALIAS` | a key made for that host, in the space only |
| MCP server without a key | `fraim connect NAME --url URL` | none |
| MCP server with OAuth | `fraim connect NAME --url URL --oauth`, then `--redirect` | Claude Code's OAuth store in the space |
| MCP server with an API key | `fraim connect NAME --url URL --key` | the space's secrets proxy |
| Dev server preview | `fraim preview PORT` or `fraim-preview start PORT` in the space | none |

Every key reaches the server through stdin or a hidden prompt in the user's own Terminal. No key passes through a chat, a command-line argument or a synced folder.

## Limits

- At most four spaces besides main. Each space with a browser uses about 1.5 to 2 GB of memory; two spaces with a browser need a server with 8 GB (Hetzner CX33).
- claude.ai connectors belong to the Claude account. A space with a full login sees all of them unless its policy denies them. One account has one Gmail connector, so work mail and personal mail cannot both come from claude.ai.
- The `serverName` deny list matches the connector's display name. Anthropic warns that names can change, so check `/mcp` in the space after a policy change.
- A space with the whatsapp module needs its own bot number.
- Previews in public mode only open through `fraim preview` on the laptop (a tunnel); in tailscale mode every device on the tailnet can open them.

## Tailscale

The policy from `fraim tailscale policy` allows the ports of main plus four spaces and the preview ports. A tailnet with an older policy only allows port 2222. Then fraim reaches a space's SSH port through the admin login (Tailscale SSH as root, with a ProxyCommand to the space's Tailscale address), so `fraim ... --space NAME` still works for admins. Previews, the browser view and mosh of that space need the new grant.
