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

- List the services: `curl -s $FRAIM_SECRETS_URL/_services` (name, header, format, API; no keys).
- Call an API: put the token where the key would go, and put the service name in front of the path.

```
curl -s $FRAIM_SECRETS_URL/openai/v1/models -H "Authorization: Bearer $FRAIM_SECRETS_TOKEN"
```

- An MCP server over HTTP: use the URL `${FRAIM_SECRETS_URL}/NAME/mcp` with the header that uses `${FRAIM_SECRETS_TOKEN}`.

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
