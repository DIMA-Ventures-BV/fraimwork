# Mirror files

A mirror file lists what a space needs: plugins, repos, tools, keys, MCP servers and SSH hosts. `fraim mirror FILE` sets up a space from it. A team keeps one file in a repo, and every person runs it from their own laptop against their own server.

The file holds no keys. A key line names an environment variable or a file on the laptop, and its value goes to the server on stdin when the line runs.

```sh
fraim mirror team.mirror                    # show the plan: what runs, where each key goes
fraim mirror team.mirror --yes              # run it, after the user has seen the plan
fraim mirror team.mirror --yes --only tool,env
fraim mirror team.mirror --yes --space personal
```

Each line calls the same building block as its own command. A line that is already done is skipped (a key or file with the same value, an installed plugin or tool, a signed-in MCP server, a reachable host), so after a human step (an OAuth sign-in, a Tailscale change) run the file again. The space's Claude only restarts when a key or plugin really changed.

## Safety

A mirror file can come from someone else, so:

- Every line is checked before anything runs. No word may start with `-`.
- Without `--yes`, mirror only prints the plan, with the host each `connect ... key` sends its key to, and exits 3. Show it to the user first; `--dry-run` prints the same plan and exits 0.
- `file` lines cannot read or write `~/.ssh`, `~/.gnupg`, `~/.claude`, `~/.claude.json`, `~/.config/fraim`, git config, `~/.local/bin` or shell start-up files.
- A `connect ... key` line that is already connected is skipped. To change its key, run `fraim connect NAME --url URL --key`.
- `host` lines add the space's key to the host's `authorized_keys`, through this laptop. For production, ask first.

## Lines

One item per line. `#` starts a comment.

| Line | Does | Same as |
| --- | --- | --- |
| `plugin MARKETPLACE_URL PLUGIN@MARKETPLACE` | adds the plugin marketplace and installs the plugin (skills, hooks, MCP servers) | `claude plugin install` in the space |
| `repo OWNER/REPO` | clones the repo, or fetches it | `fraim repo add` |
| `tool npm:PKG@VER [uv:PKG@VER ...]` | installs pinned CLIs that are not there yet | `fraim tool add` |
| `env NAME` | copies `$NAME` from this laptop; skipped when it is not set here | `fraim secret env NAME` |
| `file PATH` | copies `~/PATH` from this laptop (mode 600); skipped when it is not here | `fraim secret file PATH` |
| `connect NAME URL oauth` | adds the MCP server and starts its sign-in; skipped when connected | `fraim connect NAME --url URL --oauth` |
| `connect NAME URL key ENVVAR [HEADER [FORMAT]]` | adds the MCP server, its key from `$ENVVAR` goes to the secrets proxy | `fraim connect NAME --url URL --key` |
| `host NAME [LAPTOP_ALIAS]` | gives the space its own SSH key for the host this laptop reaches as `ssh LAPTOP_ALIAS`; skipped when the space already reaches it | `fraim host add NAME --like ALIAS` |

## Example

```
# Team setup. No keys in this file.
plugin https://github.com/acme/claude-config.git acme-config@acme
repo acme/webshop
repo acme/app

tool npm:tiktok-ads-cli@1.0.4 uv:meta-ads@1.0.1
env META_ACCESS_TOKEN
env TIKTOK_ADS_ACCESS_TOKEN
file .config/google-ads-open-cli/credentials.json

connect linear https://mcp.linear.app/mcp oauth
connect posthog https://mcp.posthog.com/mcp key POSTHOG_API_KEY

# Production: writes the space's key into the host's authorized_keys. Ask first.
host app-prod
```

## Exit codes

0 every line done or skipped (or `--dry-run`), 1 a line failed (the others still ran), 2 the file has invalid lines (nothing ran), 3 the plan waits for a yes (no `--yes`), or a line waits for a human step (the steps are listed; run the file again afterwards).

## Hosts on a tailnet

A host with a Tailscale address is out of reach until the tailnet policy lets fraim servers in. `fraim host add` then exits 3 and names `fraim tailscale reach tag:TAG`, which adds one grant (`tag:fraim` to that tag, port 22) after the user says yes.
