# Mirror files

A mirror file lists what a space needs: plugins, repos, tools, keys, MCP servers and SSH hosts. `fraim mirror FILE` sets up a space from it. A team keeps one file in a repo, and every person runs it from their own laptop against their own server.

The file holds no keys. A key line names an environment variable or a file on the laptop, and its value goes to the server on stdin when the line runs.

```sh
fraim mirror team.mirror --dry-run          # show what would run
fraim mirror team.mirror                    # run it
fraim mirror team.mirror --only tool,env    # only some kinds
fraim mirror team.mirror --space personal
```

Each line calls the same building block as its own command. A line that is already done is skipped, so after a human step (an OAuth sign-in, a Tailscale change) run the file again. Every line is checked before anything runs.

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

0 every line done or skipped, 1 a line failed (the others still ran), 2 the file has invalid lines (nothing ran), 3 a line waits for a human step (the steps are listed; run the file again afterwards).

## Hosts on a tailnet

A host with a Tailscale address is out of reach until the tailnet policy lets fraim servers in. `fraim host add` then exits 3 and names `fraim tailscale reach tag:TAG`, which adds one grant (`tag:fraim` to that tag, port 22) after the user says yes.
