# API keys: the secrets proxy

Claude uses your API keys but never sees them. The keys live in a small, separate container (`secrets`). Claude sends its calls to that container with a session token, and the container swaps in the real key and forwards the call to the one API that the key belongs to.

```
Claude (workspace) --session token--> secrets proxy --real key--> https://api.example.com
```

## Add a key

Claude runs the first and the last step. You only paste the key.

1. `fraim secret add openai --upstream https://api.openai.com`
2. In your own Terminal app (not in the Claude chat): `fraim secret set openai`, then paste the key. It stays hidden.
3. `fraim secret list` shows the name, the API and "key set". It never shows a key.

Other APIs send the key in another header. Give the header and the format:

```
fraim secret add anthropic --upstream https://api.anthropic.com --header x-api-key --format '%s'
```

The default is `--header Authorization --format 'Bearer %s'`. To change a key, run `fraim secret set NAME` again. To remove one: `fraim secret rm NAME`.

## How Claude uses a key

In the workspace, `FRAIM_SECRETS_URL` is `http://secrets:8080` and `FRAIM_SECRETS_TOKEN` is the session token.

Claude uses `fraim-api`. Claude Code refuses shell commands that contain a variable, so `fraim-api` reads the token itself and puts it in the header and format of the service.

- List the services: `fraim-api` (name, header, format, API; no keys).
- Call an API: `fraim-api openai /v1/models`. Extra options go to curl; a request body comes from a file (`-X POST -d @body.json`).
- A scheduled job that calls an API needs `Bash(fraim-api NAME:*)` in its tools file.
- An MCP server over HTTP: `fraim-connect`. GitHub: `fraim-repo`. Both already go through the proxy.

Under the hood, `fraim-api openai /v1/models` is the same as this call (the token goes to curl on stdin, so `ps` never shows it):

```
curl -s $FRAIM_SECRETS_URL/openai/v1/models -H "Authorization: Bearer $FRAIM_SECRETS_TOKEN"
```

The proxy refuses a call with a wrong token, no token, or an unknown service (401). Without a session token it refuses everything (503).

## What protects the keys

| Protection | How |
|---|---|
| Claude never holds a key | Keys are only in the `secrets-store` volume of the `secrets` container. The workspace only has the session token. |
| A key only goes to its own API | Each service has one fixed `https://` API. The path cannot change the host. |
| The browser and WhatsApp cannot reach the proxy | The proxy is only on the `secrets` network, which only the workspace and the scheduler join. |
| The proxy network has no internet | `secrets` is an internal network. The proxy uses its own `secrets-out` network to reach the APIs. |
| No command prints a key | `fraim secret set` reads the key from a hidden prompt or stdin, never from the command line. `list` and `/_services` show no keys. |

`SECRETS_TOKEN` is made by `install.sh` (and `fraim local`). It lives in `.env` on the server, which only root can read.

## Limits

- Claude can still *use* every key you add. Add only keys the agent needs, and use read-only or limited keys when the service offers them.
- Root on the server can read the keys. Keep production and company keys off the server.
- An API that echoes request headers back in its answer would show the key to Claude. Do not add such services.
- A key can only contain visible characters, without spaces, quotes, backslashes or braces.

## Tests

`tests/secrets.sh` starts the real proxy in Docker with a fake API and checks 15 things, including the attacks above. It needs Docker and removes everything afterwards.

## Keys a tool reads itself

Some tools cannot go through the proxy: a command-line tool that reads `ACCESS_TOKEN` from its environment, or one that keeps a refresh token in `~/.config/TOOL/credentials.json`. For those:

- `fraim secret env NAME --stdin` puts `NAME=value` in the space's `~/.config/fraim/secrets.env`. Claude starts with it in its environment.
- `fraim secret file PATH --stdin < LOCAL_FILE` writes the file to `~/PATH` in the workspace, mode 600.
- `fraim secret list` shows the names, never the values. `fraim secret env-rm NAME` removes one.

Copy a key from the laptop without showing it: `printenv NAME | fraim secret env NAME --stdin`.

Claude can read these keys, the same as on a laptop. Use the proxy when the tool allows it.

## Tools

`fraim tool add npm:PACKAGE@VERSION uv:PACKAGE@VERSION` installs command-line tools for a space in its home volume (`~/.local`), so they survive updates. Always give an exact version. `fraim tool list` and `fraim tool rm NAME` manage them.

## OAuth sign-ins without copying an address

`fraim connect NAME --url URL --oauth` tunnels the sign-in's `localhost` callback port from the laptop to the workspace and opens the browser. After Approve the browser lands on the server by itself; then `fraim connect NAME --finish`. When the port is busy on the laptop, fraim falls back to `fraim connect NAME --redirect` and a pasted address.
