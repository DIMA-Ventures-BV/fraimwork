---
name: setting-up-fraim
description: Set up fraimwork end to end for the user - their own always-on Claude server, first on this Mac and then on a cloud server, with phone access over WhatsApp, a server browser, scheduled jobs and file sync. Use when the user says "set up fraim", "install fraimwork", "I want my own Claude server", "move fraim to a real server", "add WhatsApp to fraim", or has just installed the fraim plugin. Do NOT use for day-to-day running of an existing setup (use operating-fraim) or for adding skills and MCP servers (use managing-fraim-config).
---

# Setting up fraim

You do the whole setup. The user never types a fraim command.
You ask the user only for the steps in "Human steps", one at a time, and you continue the moment they confirm.

## Rules

- Run `bin/fraim` from the user's fraimwork checkout (step 1), never from the plugin folder.
- fraim exit codes: 0 ok, 1 failure, 2 missing input (it names the missing flag), 3 human step.
- Exit 3 prints one line `HUMAN STEP: ...`. Pass it to the user in plain words, with the exact place to click, wait, then run the same command again.
- Read `fraim status --json` after every stage, and report one line per part: works, or what is missing.
- Never paste tokens, keys, `.env` or `secrets.env` values into the chat. Pipe them; do not echo them.
- Ask before you overwrite anything: an existing `~/.config/fraim/`, a server that already runs fraim, `local down --wipe`.
- Keep a short checklist with the task tool, one item per stage. Without a task tool or AskUserQuestion (for example headless), keep the checklist in your replies and ask in plain text.

## Stage 0: before you start (say this first, in one message)

Tell the user what the full setup needs, so nothing blocks halfway:
- A Claude Pro or Max subscription (they already have Claude Code, so this is normally done).
- For a server: a Hetzner Cloud account. Signing up includes an ID and payment check that can take a few hours, so say "start the sign-up now at https://console.hetzner.cloud, we can try it on your Mac meanwhile".
- For WhatsApp: a second phone number (a prepaid SIM or eSIM) with the WhatsApp Business app on it. Without it, skip WhatsApp for now; it can be added later.
- Platform: this flow is written for macOS. On Linux, replace `pbpaste`/`pbcopy` with `wl-paste`/`wl-copy` or `xclip -selection clipboard -o`/`-i`. On Windows, use WSL 2 with Docker Desktop and run everything inside WSL (untested: tell the user so).

## Stage 1: get the code (no user input)

1. Find the checkout: `~/fraimwork`, then `~/projects/fraimwork`. If neither exists, clone it:
   `git clone "$(git -C "${CLAUDE_PLUGIN_ROOT}" remote get-url origin)" ~/fraimwork`.
   When the plugin folder has no git remote, ask the user for the repo URL.
2. Set `F=<checkout>/bin/fraim` and use `$F` for every command.
3. Check the tools: `docker info`, `git`, `ssh`, `jq`. Docker missing on macOS: say "Install OrbStack or Docker Desktop, then tell me". An SSH key is missing: create one with `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519`.

## Stage 2: one round of questions

Ask these together in one question round (AskUserQuestion), with the recommended answer first:

1. Where: "Try it on this Mac first (Recommended)" or "Go straight to a server".
2. Phone access: "WhatsApp, I have a second number ready" or "Not now (Recommended if you have no second number yet)".

Do not ask about networking. A server always uses Tailscale (private network, no open ports).
Use public mode only when the user cannot use Tailscale (for example a work laptop that blocks it), and then say that SSH is exposed to the internet with key-only login.

Modules follow from the answers: `browser` and `scheduler` always; `whatsapp` when chosen; `sync` on a server.

## Stage 3: local

1. Check for another stack: `docker compose ls`. When a `fraim*` project already runs, use `FRAIM_INSTANCE=<name> FRAIM_TARGET=<name>` and a `--port-offset` that no running stack uses; otherwise its network clashes.
   Find the offsets in use: `docker compose -p <project> ps --format '{{.Ports}}'` (SSH 2299 + offset).
   The offset is fixed when the stack is first created. To change it later: `$F local down --wipe` (ask first), then `up` again.
2. `$F local up --modules <list> [--whatsapp-owner <digits>]`. With nothing cached, the first build takes up to 15 minutes; with cached images, seconds. Run it in the background and tell the user it is building.
3. `$F status --json`. Right after `up`, `"error":"workspace unreachable"` means SSH is still starting: wait 10 seconds and run it again.
   Before login, only `claude-login` may fail. Fix any other failure first (`$F logs <service> --tail 80`).
   `claude-session-running` can be ok before login: the session runs but cannot answer. Only `claude-login` ok means Claude works.
4. Claude login inside the stack: see "Server login" below. When the user postpones it, continue with the next stage and list login as missing in Finish.
5. Tell the user what runs now. When the user already chose "local only", skip Stage 4 and go to "Claude config".
   Otherwise ask: "Move it to a real server now, or keep trying it locally?"

## Stage 4: server

1. Human step: the server. First copy the user's public key to the clipboard: `pbcopy < ~/.ssh/id_ed25519.pub`. Then give these steps in one message:
   1. Open https://console.hetzner.cloud and log in (the account check from Stage 0 must be done).
   2. Click "New project", name it `fraim`, open it.
   3. Click "Add server". Location: any in Europe (Falkenstein is fine). Image: Ubuntu 24.04. Type: Shared vCPU, CX23 (x86); when that is sold out, CAX21 (Arm). About 5 to 7 euro a month.
   4. Under "SSH keys", click "Add SSH key", paste (the key is already on the clipboard), name it `laptop`.
   5. Leave the rest. Click "Create & Buy now". When the server shows "Running", copy its IPv4 address and give it to me.
2. Tailscale, human steps, one at a time:
   1. Account: "Open https://login.tailscale.com/start and sign up (Google or Microsoft login is easiest)." Skip when they already have one.
   2. Laptop app: run `brew install --cask tailscale` yourself, then: "Open Tailscale from Applications and sign in with the same account. Tell me when the menu bar icon shows Connected."
   3. Policy: `$F tailscale policy --email <their login email> | pbcopy` puts the filled-in policy on the clipboard.
      Ask first: "Do other devices already use this Tailscale account?" When yes, ask them to paste their current policy from https://login.tailscale.com/admin/acls into a file you name, and merge the fraim parts into it instead of replacing it: replacing removes their existing access between devices.
      Then: "Open https://login.tailscale.com/admin/acls, select all text in the editor, paste, and click Save."
   4. Auth key: "Open https://login.tailscale.com/admin/settings/keys, click Generate auth key, turn on Tags and choose tag:fraim, click Generate, copy the key, and tell me 'copied'." Then read it with `pbpaste` into the `--ts-authkey` flag. Never show it in the chat.
3. `$F init --hostname fraim-<user> --access tailscale|public [--ts-authkey <key>] --modules <list> --tz <tz> [--whatsapp-owner <digits>] [--whatsapp-allow <n,n>]`.
4. `$F deploy root@<ip>`. This takes several minutes: run it in the background and report progress. A server that already runs fraim needs `--force-env`: ask first.
   With Tailscale, deploy closes public SSH only after it proves SSH over Tailscale works. When that check fails it exits 3: once the user confirms the laptop shows Tailscale Connected, run `$F lock`.
5. `$F use server`, then `$F status --json`.

## Server login

1. Run `$F login`. It exits 3 with a human step. Tell the user only this: "Open Terminal, run `claude setup-token`, approve in the browser, copy the token it prints, and tell me 'copied'. Do not paste it here."
   You run every fraim command yourself, even when the HUMAN STEP text mentions one.
2. When the user says copied, run `pbpaste | $F login --token-stdin`. The token never appears in the chat. Clear the clipboard after: `pbcopy </dev/null`.
3. `$F status --json` must now show `claude-login` ok. Then `$F ask "Reply with: pong" --json` proves the server's Claude answers.

## WhatsApp

1. `$F whatsapp link --number <bot number>`. It prints a pairing code.
   Without `--number` it writes a QR code to `~/.fraim/whatsapp-qr.png` and exits 3: show the user that file.
2. Human step: "On the bot phone, open WhatsApp, Settings, Linked devices, Link a device, Link with phone number instead, and enter code <code>."
3. Wait for `$F whatsapp status` to show connected, then `$F whatsapp test`. Ask the user to confirm the message arrived.

## Claude config on both machines

1. `$F config status` first. When it already shows a role, the laptop is set up: skip `init` and keep the existing files.
   Otherwise `$F config init --role laptop` on this Mac. The server (or the local stack, which plays the server role) ran `init --role server` at start.
2. With `sync` enabled: run `$F sync --print-url` and follow its `HUMAN STEP:` lines for the Syncthing pairing. `$F sync stop` when done.
3. `$F config status` here and `$F exec -- fraim-config status` on the server. Both must show their role linked.
   With sync, the fingerprints must match once sync has run. A local stack without sync has its own copy, so its fingerprint can differ.

## Finish

Report, in this order:
1. One line per part: Claude session, browser, scheduler, WhatsApp, sync, config. Each says works or what is missing.
2. How the user reaches the server from now on: WhatsApp the bot, or ask you ("ask my server to ...", which uses `$F ask`).
3. The one next thing worth doing, for example "Send the bot 'what can you do?'".
4. Write the owner's one-page guide to `~/fraim/fraim-guide.md` on the server (`$F exec -- sh -c 'cat > ~/fraim/fraim-guide.md'` with the text on stdin).
   With sync on, it also appears in the laptop's `~/fraim`. Open it for the user on the laptop. Use this outline and fill in the real values:

   ```
   # Your fraim server
   What it is: your own Claude that keeps running when your laptop is closed.
   Talk to it: WhatsApp <bot number> | the Claude app on your phone | ask Claude on your laptop "ask my server ..."
   Things to try: "What's in my inbox?" | "Every weekday at 8, summarise ..." | "Send me <file>"
   Your files: ~/fraim on the laptop and the server (same folder)
   When something is wrong: ask Claude on your laptop "check fraim" or message the bot "are you ok?"
   Costs: Hetzner server about 5-7 euro a month; Claude uses your own subscription
   To stop or move fraim: ask Claude on your laptop "remove fraim" or "move fraim to a new server"
   Set up on: <date>, server <hostname>, help: <the person who set it up, if any>
   ```

## Human steps (the complete list)

1. Install Docker, if missing.
2. Hetzner sign-up (can take hours: start early), then create the server and give the IP.
3. Tailscale: account, app sign-in on the laptop, policy paste, auth key.
4. Approve the Claude login in the browser.
5. Enter the WhatsApp pairing code on the bot phone.
6. Accept the Syncthing device pairing (sync only).
7. Website logins and 2FA in the server browser, only when a job needs a site.
