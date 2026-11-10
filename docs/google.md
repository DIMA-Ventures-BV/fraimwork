# Gmail, Drive and Calendar for any agent

`fraim google` runs Gmail, Drive and Calendar as an MCP server in the space's own `google` container. It does not depend on your Claude account: Claude uses it today, and Codex or another MCP client can use it the same way.

```
agent (workspace) --MCP--> google container --your Google token--> Gmail, Drive, Calendar
```

The server is [workspace-mcp](https://github.com/taylorwilsdon/google_workspace_mcp) (MIT). Every Python package is pinned with its hash in `google/requirements.txt`; to update, change the version in `google/requirements.in` and run the `uv pip compile` line from `google/Dockerfile`.

## 1. Make a Google OAuth client (once, about 15 minutes)

1. Open https://console.cloud.google.com and create a project, for example `fraim`.
2. **APIs & Services > Library**: turn on the Gmail API, the Google Drive API and the Google Calendar API.
3. **Google Auth Platform > Branding**: fill in an app name and your email.
4. **Audience**: choose **Internal** if your account is in a Google Workspace. Then Google needs no review, and the login does not expire. With a personal Gmail account, choose External and add yourself as a test user. Google then ends the login after 7 days.
5. **Clients > Create client**: type **Desktop app**. Download the JSON file.

## 2. Set it up

Claude runs this for you:

```
fraim google setup --email you@yourdomain.com --file ~/Downloads/client_secret_....json
```

It turns on the `google` module, starts the container, stores the client file in the container's private volume and adds the `google` MCP server to the space.

## 3. Sign in

1. Ask the agent to search your Gmail. It shows a Google sign-in link.
2. Open it and approve.
3. The browser then shows an error page on `localhost:8000`. That is expected: the sign-in finishes on the server, not on your laptop.
4. Copy that full address. In your own Terminal app (not in the chat), run `fraim google code` and paste it.

`fraim google status` shows `signed in: yes`.

## What the agent can do

| Service | Default | Change with `GOOGLE_PERMISSIONS` |
| --- | --- | --- |
| Gmail | read, labels, drafts. No sending. | `gmail:send` or `gmail:full` |
| Drive | read | `drive:full` |
| Calendar | read | `calendar:full` |

Set `GOOGLE_PERMISSIONS` in the space's env file, for example `GOOGLE_PERMISSIONS=gmail:send drive:readonly calendar:full`. Then restart the container (`fraim restart google`), run `fraim google signout` and sign in again, so Google grants the new scopes.

Mail is untrusted input. A message can try to tell the agent what to do, so leave sending off. To answer a mail, the chief drafts a reply and you approve it in the inbox ([queue.md](queue.md), "Answering people outside"). That needs no extra permission: `google/fraim-reply` in the same container sends it, and it can only answer a mail chain. Do not set `gmail:send`: it gives every agent a send tool that skips your approval.

## What protects the token

| Protection | How |
| --- | --- |
| The agent never holds the Google token | The token and the OAuth client live only in the `google-store` volume of the `google` container. |
| The browser and WhatsApp cannot reach it | The container sits on the internal `secrets` network with the workspace and scheduler only. |
| The sign-in code never passes through the chat | `fraim google code` reads the address from a hidden prompt and sends it over stdin. |

Anything in the workspace can call the MCP server and act as you within the permissions above. That is the point of it; limit the permissions instead.

## Work and personal accounts

One space holds one Google account. A second `fraim google setup` in the same space replaces the first. To use a work Workspace and a personal Gmail, give each its own space, each with its own OAuth client: `fraim google setup --space personal ...`. A client with audience Internal only accepts accounts of its own organization, so a personal Gmail needs its own External client.

## Other agents

The MCP server is at `http://google:8000/mcp` inside the space (streamable HTTP, no key). For Codex: `codex mcp add google --url http://google:8000/mcp`.

## Commands

- `fraim google setup --email E --file F`: store the client and add the MCP server
- `fraim google code`: finish the sign-in (in your own Terminal)
- `fraim google status`: setup and sign-in state
- `fraim google signout`: delete the stored Google token
- `fraim google push --topic T --subscription S --file KEY | --off`: new mail within seconds ([channels.md](channels.md))
