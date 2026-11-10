---
name: managing-fraim-spaces
description: Split one fraim server into separate spaces (work, personal, ...) and give a space access to things - a GitHub repo, a dev box or other SSH host, an MCP server (with a key, OAuth or none), claude.ai connectors, Remote Control on the phone, and dev server previews. Use when the user says "keep work and personal apart", "add a personal space", "connect my bank / PostHog / Linear / Sentry to fraim", "let fraim work on repo X", "give fraim access to the dev box", "I want to use fraim from the Claude app", "show me the dev server on my phone", or "which space has what". Do NOT use for first-time setup (setting-up-fraim), health and restarts (operating-fraim), or skills and hooks shared by all machines (managing-fraim-config).
---

# Spaces and access

A space is a separate fraim on the same server: its own Claude session, browser, files, secrets proxy, MCP servers and logins. Spaces cannot see each other's files, keys or networks. `main` always exists; a server holds up to four more.

Run fraim from the user's fraimwork checkout: `F=<checkout>/bin/fraim`. The user never types fraim; you run it. Same contract as always: exit 3 prints one `HUMAN STEP:` line for the user, exit 2 names what is missing.

Every command takes `--space NAME`. Without it, a command works on `main`. Always say which space you acted on.

## Pick the space first

- Work things (company repos, the dev box, company MCP servers) go in a work space.
- Personal things (bank, personal mail, private calendar) go in a personal space.
- Never put a personal key in a space that reads work input (company mail, WhatsApp from colleagues), and the other way round. Text in one space can then never make Claude leak data from the other.

`$F space list --json` shows every space with its SSH port, modules and health.

## Make a space

1. Agree on the name and modules with the user. Default modules: `browser,scheduler`. `whatsapp` needs its own bot number (a second one), `sync` its own laptop folder.
2. `$F space add NAME [--modules browser,scheduler] [--whatsapp-owner N]`. It is safe to run again.
3. A Claude login: `$F login --space NAME --from-space main` reuses the main space's setup-token on the server (no human step). For Remote Control and claude.ai connectors: `$F login --full --space NAME` (see "Full login").
4. In tailscale mode the space's ports are allowed by the fraimwork Tailscale policy (ports 2222-2226, 6080-6084, 3100-3149). With an older policy that only has 2222, fraim reaches the space's SSH through the admin login by itself, so fraim commands work. Previews, the browser view and mosh of that space still need the new ports: run `$F tailscale apply` (it adds the missing ports through the Tailscale API and shows the change first).

Stop a space: `$F space rm NAME` (data kept; `$F space up NAME` starts it again). Delete one for good: `$F space rm NAME --wipe --yes`, only after the user said yes to losing its files, logins and keys.

## Full login (Remote Control, claude.ai connectors)

A setup-token only lets Claude answer. A full login also gives Remote Control (the space appears in the Claude phone app as "<server> <space>") and the user's claude.ai connectors (Gmail, Drive, Calendar, ...).

1. `$F login --full --space NAME`. It exits 3 with a link.
2. Give the user the link. They sign in; when the page shows a code, they run `fraim login --code --space NAME` in their own Terminal app and paste it there, never in the chat.
3. When they say done: `$F login --status --space NAME` shows `full_login: true`.

## Connectors per space

claude.ai connectors belong to the Claude account, so every space with a full login sees all of them. Limit them per space:

- `$F space policy NAME --deny 'claude.ai Gmail,claude.ai Google Drive'` hides those connectors (exact names from `/mcp` in that space).
- `$F space policy NAME --claudeai off` hides all claude.ai connectors in that space.
- `--deny none` clears the list. The policy is a root-owned file; Claude inside the space cannot change it.

## Add an MCP server

Ask which kind it is, or read the service's MCP docs:

| Kind | Command | The user does |
| --- | --- | --- |
| No key | `$F connect NAME --url https://HOST/mcp --space S` | nothing |
| OAuth (Linear, Sentry, Stripe, Notion) | `$F connect NAME --url URL --oauth --space S` | opens the link, signs in, then runs `fraim connect NAME --redirect --space S` in their Terminal and pastes the address bar |
| API key (PostHog, containt, an aggregator) | `$F connect NAME --url URL --key --space S` (add `--header x-api-key --format '%s'` when the service wants that) | runs the printed command in their Terminal and pastes the key |
| Local program | `$F connect NAME --command 'npx -y some-mcp' --space S` | nothing |

A key goes into that space's secrets proxy; Claude in the space only holds a session token. Keys never pass through the chat, an argument or a file in `~/fraim`.

Prefer a claude.ai connector when one exists (no key on the server at all). Use read-only or test-mode keys where the service offers them (Stripe test mode, PostHog read-only, a PSD2 aggregator with read-only bank consent).

`$F connect list --space S`, `$F connect rm NAME --space S` (also deletes its key).

## Gmail, Drive and Calendar without a Claude account

`fraim google` runs Gmail, Drive and Calendar as the space's own MCP server, so it works for any agent (Claude or Codex), not only through claude.ai. Use it when the user wants Google independent of their Claude account. Full steps for the user: `docs/google.md`.

1. The user makes a Google OAuth client of type **Desktop app** (docs/google.md, about 15 minutes, once) and downloads its JSON.
2. `$F google setup --email USER@DOMAIN --file ~/Downloads/client_secret_....json --space S` starts the google container and registers the `google` MCP server. Claude never reads the file itself.
3. In the space, call a Gmail tool (for example `search_gmail_messages`). It returns a Google sign-in link: give it to the user.
4. After approving, the browser shows an error page on `localhost:8000`. That is expected. The user runs `fraim google code --space S` in their own Terminal and pastes that address.
5. `$F google status --space S` shows `signed in: yes`.

Default permissions: Gmail read, label and draft (no send), Drive and Calendar read-only. `GOOGLE_PERMISSIONS` in the space env changes that (for example `gmail:send drive:full calendar:full`); then `$F google signout` and sign in again for the new scopes.

## A GitHub repo

1. `$F repo token --space S` exits 3 with how to make a fine-grained token (only the needed repos; Contents and Pull requests read and write). The user pastes it in their own Terminal.
2. `$F repo add OWNER/REPO --space S` clones it to `~/code/REPO` in the space.

git, the GitHub API (`$FRAIM_SECRETS_URL/github-api/...`) and the `github-mcp` MCP server (pull requests, issues) all go through the proxy. The space's commits use the laptop's git name and email. Never give a space a token that can approve or merge on its own: keep a human review on protected branches.

## An SSH host (a dev box)

1. `$F host add NAME --like LAPTOP_SSH_ALIAS --space S` when `ssh LAPTOP_SSH_ALIAS` works on this laptop: fraim copies the address, user, port and the host keys this laptop trusts, makes the space its own key and installs it through that alias.
2. `$F host add NAME --address HOST --user USER --space S [--authorize-via ALIAS]` for a host the laptop has no alias for. Without `--authorize-via`, it exits 3 with the key line for the user to add to the host's `~/.ssh/authorized_keys`. Then `$F host test NAME --space S`.
3. A Tailscale address (100.64.0.0/10): the tailnet policy keeps fraim servers away from other devices, so `host add` exits 3. Ask the user, then `$F tailscale reach tag:TAG` (or the address); it shows the policy change and waits for `--yes`.

Production hosts: installing the key changes the host's `authorized_keys`, and the space can then write there. Ask the user before each step. In the space, `ssh NAME`, `rsync` and tools such as mutagen reach the host. `$F host rm NAME --space S --authorize-via ALIAS` revokes it again.

## A whole setup from one file (fraim mirror)

`$F mirror FILE --space S` runs every line of a mirror file (docs/mirror.md): plugins, repos, tools, keys from this laptop, MCP servers and SSH hosts. Without `--yes` it prints the plan (where each key goes) and exits 3: show the plan to the user, and on yes run it again with `--yes`. Lines that are done are skipped, so after a human step run it again. `--only KIND,...` runs a part.

## A product's own setup (fraim project)

A repo can carry a `.fraim/` folder with its leads, automations and needs (docs/projects.md). `$F project add OWNER/REPO --space S` prints the plan and exits 3: show the plan to the user, and on yes run the `--yes --commit SHA` line it prints. New items arrive switched off. Ask the user which to start, then `$F project on REPO ITEM...`. Later: `$F project update REPO`. To move leads that already run into a repo: `$F project export ITEM... --to REPO/.fraim`, and have the user read the files before they are committed.

## Previews on the phone

A dev server in a space (on any port) shows on the user's phone or laptop:

- `$F preview PORT --space S` prints the URL. In tailscale mode it works on every device on the tailnet; in public mode fraim opens a tunnel on this laptop.
- Claude inside the space can run `fraim-preview start PORT` itself and send the URL.
- `$F preview stop all --space S` when done. Ten previews per space at most.

## Example: work and personal on one server

1. `$F space add personal`
2. `$F login --full --space personal`
3. `$F space policy main --deny 'claude.ai Gmail'` and `$F space policy personal --deny 'claude.ai Slack'` (whichever account each connector belongs to).
4. Work: `$F repo token`, `$F repo add OWNER/REPO`, `$F host add devbox --address IP --user dev --authorize-via devbox`.
5. Personal: `$F connect bank --url https://API/mcp --key --space personal`.
