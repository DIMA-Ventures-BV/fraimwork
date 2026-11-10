# Connect someone's laptop to a server you run

The operator builds and runs the server. The person keeps their own Claude on their own laptop. One invite connects that laptop, and their Claude moves their setup to the server.

## What the operator does

1. Share the server with the person in the Tailscale admin console, and copy the link.
2. `fraim invite NAME --share-url LINK`. Add `FRAIM_TARGET=...` when you run more servers.
3. Send the person the invite file by a private channel. The command prints the one line they run in a terminal.

`fraim invite list` shows the invites. `fraim invite revoke NAME` ends one.

## What the person does

They run the one line, copy the invite, and answer their Claude. The `connecting-to-fraim` skill does the rest.

Only they can do these steps:

- Install Tailscale and accept the shared server.
- Say yes or no to each key, repository and host.
- Click Approve once for each OAuth sign-in.

## What the laptop can do

| Can | Cannot |
| --- | --- |
| Log in to the workspace as the `claude` user | Log in to the server as root |
| Store API keys through the secrets gate | Read a stored key |
| Add MCP servers, repositories, tools and files | Update, restart or back up the server |

## How it is protected

- The invite holds a login key made for this one person, so it is only useful from a device that Tailscale lets in. `fraim invite` refuses a server with public SSH.
- The invite pins the server's SSH host key, so the laptop never has to trust a first connection.
- The secrets gate listens on the private `secrets` network. The server keeps only the hash of the laptop's token, so Claude on the server cannot use the gate.
- The key and the token travel on stdin, never as a command-line argument.
- The operator has root on the server and can read every key on it. The person hears this before anything moves.

## What moves

`fraim mirror scan` writes a mirror file from the laptop's Claude setup. It holds names only.

| Moves after one yes | Asks line by line (`#ask:`) | Needs a person (`# manual:`) |
| --- | --- | --- |
| Plugins from a public marketplace | Keys in the environment | MCP servers that run a local program |
| Skills, commands, agents, `CLAUDE.md` | Key files of command-line tools | An address or argument that holds a secret |
| MCP servers with OAuth or one key header | Repositories and SSH hosts | `settings.json` and hooks |
| | Key names that look like money or production | claude.ai connectors (they come with the full login) |

The scan never copies `~/.ssh` or `~/.claude/settings.json`. The server gets its own SSH key for each host.

## Limits

- Tailscale sharing has not been tested end to end with a real second account.
- Shared devices also need a policy rule that lets them reach the server's ports.
- The invited laptop has no file sync, because pairing Syncthing needs admin access.
- All spaces on a server read the same `authorized_keys` file, so an invite can log in to every space whose port the laptop can reach.
- The server needs an update that includes the gate before it accepts an invite.
