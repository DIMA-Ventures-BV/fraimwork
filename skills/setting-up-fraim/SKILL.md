---
name: setting-up-fraim
description: Set up fraimwork end to end for the user - their own always-on Claude server, as a trial on this Mac or on a cloud server, with phone access over WhatsApp, a server browser, scheduled jobs and file sync. Also resumes a setup that stopped halfway. Use when the user says "set up fraim", "install fraimwork", "I want my own Claude server", "move fraim to a real server", "add WhatsApp to fraim", "continue the fraim setup", or has just installed the fraim plugin. Do NOT use for day-to-day running of an existing setup (use operating-fraim) or for adding skills and MCP servers (use managing-fraim-config).
---

# Setting up fraim

You do the whole setup. The user never types a fraim command.
You ask the user only for the human steps, one at a time, and you continue the moment they confirm.

## Rules

- Run `bin/fraim` from the user's fraimwork checkout (Stage 1), never from the plugin folder.
- fraim exit codes: 0 ok, 1 failure, 2 missing input (it names the missing flag), 3 human step.
- Exit 3 prints one line `HUMAN STEP: ...`. Pass it on in plain words, with the exact place to click, wait, then run the same command again. You run every fraim command yourself, even when that text mentions one.
- Read `$F status --json` after every stage and before Finish.
- Translate for the user. Never relay ports, offsets, instance names, JSON or exit codes; say what works and what the user can do.
- Never paste tokens, keys, `.env` or `secrets.env` values into the chat. Pipe them. Clear the clipboard after reading a secret from it: `pbcopy </dev/null`.
- Ask before you overwrite anything: an existing `~/.config/fraim/`, a server that already runs fraim, `local down --wipe`.
- Keep a checklist with the task tool, one item per stage. Without a task tool or AskUserQuestion (for example headless), keep it in your replies and ask in plain text.
- `$F exec -- <cmd>` runs one command without a shell: for `~`, pipes, `&&` or redirects use `$F exec -- sh -c '<cmd>'`.
- Phone numbers need the country code. fraim accepts `+31 6 1234 5678`, `0031612345678` or `31612345678`. A local number such as `06...` exits 2: ask the user for it with the country code.

## Resuming

The user may stop for hours (Hetzner checks an account before it can be used). When the user comes back:
1. Stage 1, then `$F status --json` (exit 2 "no fraim target" means no stack or server yet) and `$F config status`.
2. Skip every stage whose result already works. Tell the user in one line where you continue.
3. Once the server is deployed, `$F setup [--space S] [--repo OWNER/REPO]` finishes everything that is still open, in order: Tailscale policy, public SSH lock, Claude login, full login, file sync, laptop config, GitHub repositories. It skips what works and stops at the first human step (exit 3): pass that on, then run `$F setup` again.

## Stage 0: what the user needs (say this first, in one message)

- A Claude Pro or Max subscription (they use Claude Code, so normally done).
- For a server: a Hetzner Cloud account. The sign-up includes an ID and payment check that can take a few hours. Say: "Start the sign-up now at https://console.hetzner.cloud. We set up the rest meanwhile."
  Cost: about 7 to 9 euro a month in total (server, its IPv4 address, and daily backups).
- For WhatsApp: a second phone number (a prepaid SIM or eSIM) that is already registered in the **WhatsApp Business** app (install it, enter the number, type the SMS code). It can be a second SIM in the same phone. Without it, skip WhatsApp; it can be added later.
- Platform: written for macOS. On Linux, use `wl-copy`/`wl-paste` or `xclip -selection clipboard -i`/`-o` instead of `pbcopy`/`pbpaste`. On Windows, use WSL 2 with Docker Desktop and run everything inside WSL (untested: tell the user so).

## Stage 1: get the code (no user input)

1. Find the checkout: `~/fraimwork`, then `~/projects/fraimwork`. If neither exists, clone it:
   `git clone "$(git -C "${CLAUDE_PLUGIN_ROOT}" remote get-url origin)" ~/fraimwork`.
   When the plugin folder has no git remote, use `https://github.com/DIMA-Ventures-BV/fraimwork`.
2. Set `F=<checkout>/bin/fraim` and use `$F` for every command.
3. Check the tools: `git`, `ssh`, `jq`; `docker info` only for the Mac trial. Docker missing: "Install OrbStack (https://orbstack.dev) or Docker Desktop, open it once, then tell me." An SSH key is missing: `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519`.

## Stage 2: questions (only what the user has not said yet)

Skip every question the user's request already answers ("on a real server", "I have a second number").
Ask the rest in one round, recommended answer first:

1. Where: "Try it on this Mac first (Recommended)" or "Go straight to a server".
2. Phone access: "WhatsApp, my second number is ready" or "Not now".
3. With WhatsApp, in plain text: "Which number is the bot (the second number)?" and "Which is your own number, the one you will message the bot from?" Ask for both with the country code (for example +31 6 ...). They must differ.

Do not ask about networking. A server always uses Tailscale (private network, no open ports).
Use public mode only when the user cannot use Tailscale (for example a work laptop that blocks it), and then say that SSH is open to the internet with key-only login.

When the user picks "Not now" for WhatsApp, say once: "Without WhatsApp your server cannot warn you by itself, and results of scheduled jobs wait on the server until you ask me what they said. Once a week, ask me 'is my server ok?' and I check it for you." Put the same lines in the guide.

Modules: `browser` and `scheduler` always; `whatsapp` when chosen; `sync` on a server.
Then follow **Path A** (Mac trial) or **Path B** (server).

## Path A: trial on this Mac

1. `$F local up --modules <list> [--whatsapp-owner <own number>]`. It finds free ports by itself. Run it in the background. Only when it has not finished after 30 seconds: "It is building; the first time this can take up to 15 minutes."
2. `$F status --json`. Right after `up`, `health.error` "workspace unreachable" means it is still starting: wait 10 seconds and run it again.
   Before login, only `claude-login` may fail; fix any other failure first (`$F logs <service> --tail 80`).
   `claude-session-running` can be ok before login; only `claude-login` ok means Claude works.
3. "Claude login" below.
4. WhatsApp (when chosen): "WhatsApp" below.
5. "Claude config", then "Finish". The server comes later, when the user asks for it (then Path B).

## Path B: server

One list for every case. A step marked *(skip when ...)* is skipped in that case. The cases:
- **New server:** the user creates one at Hetzner in step 4.
- **Existing server:** the user already has an Ubuntu 24.04 server (an IP or an SSH alias such as `myserver`).
- **Tailscale** (default) or **public** (only when the user cannot use Tailscale, for example a work laptop that blocks it).

1. **Safety, in plain words, once:** "Everyone you allow on WhatsApp can ask your server to do anything you could, and the server can read every password or key you give it. So never give it bank, work-production or admin logins." Only then ask whether other people's numbers should be allowed (usually: none).
2. **Public mode warning** *(skip when Tailscale)*: "SSH on this server is open to the internet, protected by your key only."
3. **Tailscale**, human steps, one at a time *(skip when public; skip each sub-step the user already did: `tailscale status` on the Mac shows Connected)*. Do this during Hetzner's account check for a new account.
   1. Account: "Open https://login.tailscale.com/start and sign up (Google or Microsoft login is easiest)."
   2. Mac app: "Download Tailscale from https://tailscale.com/download/mac and open it. Click Allow when macOS asks to add a VPN configuration, then sign in with the same account. Tell me when the menu bar icon shows Connected."
   3. Policy, through the Tailscale API (nobody pastes a policy file): ask "What name is shown at the top right of https://login.tailscale.com/admin?" (an email, or for GitHub logins a name like `name@github`). Then `$F tailscale apply --email <that name>`.
      Without a saved API token it exits 3: pass on its human step (the user makes a 1-day token and runs `fraim tailscale key` in their own Terminal). Run the same command again.
      It merges the fraim rules into the existing policy and keeps every other rule. It exits 3 with the changes: show them in plain words ("lets your devices reach the fraim server on its ports; the server can reach nothing"), and say comments in the policy file are lost but a copy is saved. On yes: `$F tailscale apply --yes --email <that name>`.
   4. Auth key: "Open https://login.tailscale.com/admin/settings/keys, click Generate auth key, turn on Tags and choose tag:fraim, click Generate, copy the key, and tell me 'copied'." Read it with `pbpaste` straight into the `--ts-authkey` flag in step 6. Never show it.
4. **Hetzner server**, human step *(skip when existing server)*, once the account check is done. Give it in one message, and copy the key to the clipboard right before you send it: `pbcopy < ~/.ssh/id_ed25519.pub`.
   1. Open https://console.hetzner.cloud, click "New project", name it `fraim`, open it.
   2. Click "Add server". Location: any in Europe (Falkenstein is fine). Image: Ubuntu 24.04. Type: Shared vCPU, CX23 (x86); when sold out, CAX21 (Arm).
   3. Under "SSH keys": "Add SSH key", paste (it is on your clipboard), name it `laptop`. (When `laptop` already exists, just tick it.)
   4. Under "Backups": tick it (recommended: a copy of the whole server every day, kept 7 days, about 20 percent extra).
   5. Leave the rest. Click "Create & Buy now". When it shows "Running", copy the IPv4 address and give it to me.
   Declined backups: say once that a broken server then loses its files (files synced to the laptop survive), and note "Backups: off" in the guide.
5. **Existing server checks** *(skip when new server)*:
   1. Access: `ssh -o BatchMode=yes -o ConnectTimeout=10 root@<host> true`. On failure, ask the user to add the key from `~/.ssh/id_ed25519.pub` to the server's root account, or for the SSH alias that works.
   2. Confirm, and wait for a clear yes: "fraim turns off password logins and closes every port except SSH on this server. Is anything else running on it, or do you log in with a password?" When yes to either, stop and recommend a new, separate server instead.
   3. Ask: "Does your provider make daily backups of this server?" When no, say once what that risks and note "Backups: off" in the guide.
6. **Init.** The hostname is the name the user gave, else `fraim-<first name, lowercase letters only>`. The time zone comes from the Mac (`/etc/localtime` points to e.g. `.../zoneinfo/Europe/Amsterdam`). Init writes `.env` into the checkout (it is gitignored). Init takes no host; deploy in step 7 takes the IP or SSH alias.
   - Tailscale: `$F init --hostname <name> --access tailscale --ts-authkey <key> --modules <list> --tz "$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')" [--whatsapp-owner <own number>] [--whatsapp-allow <n,n>]`
   - Public: `$F init --hostname <name> --access public --modules <list> --tz "$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')" [--whatsapp-owner <own number>] [--whatsapp-allow <n,n>]`
7. **Deploy:** `$F deploy root@<ip or host>` in the background. Tell the user: "Installing your server, about 5 to 10 minutes. Nothing for you to do."
   Without a terminal it prints only stage lines and a summary, and writes the full log to the path on its "Full log:" line.
   Judge by the exit code. On failure it prints "Failed (exit N)" plus the last 15 log lines: read those first, the full log only when they do not explain it.
   A server that already runs fraim needs `--force-env`: ask first.
   Tailscale: deploy closes public SSH only after it proves the Tailscale route works. When that check fails it exits 3: ask the user to check the Tailscale menu bar icon shows Connected, then run `$F lock`. Do not continue until `lock` succeeds. *(Public: no lock.)*
8. `$F status --json` (deploy already made the server the current target and waited until it answers). If status still says "workspace unreachable", run `$F logs workspace --tail 80` and act on what it shows.
   Report from `services[].state` and the `health.checks` entries with `ok: false`. Before login, only `claude-login` may fail; status then exits 1, which is expected.
9. "Claude login" below (it signs in the server).
10. WhatsApp *(skip when not chosen)*: "WhatsApp" below.
11. "Claude config", then "Finish".

## Claude login

1. Run `$F login`. When `bootstrap.sh` saved a token in the Keychain, this uses it and exits 0: go to step 3. Otherwise it exits 3. Tell the user only this:
   "One step only you can do, because it signs in with your Claude account: open the Terminal app (press Cmd+Space, type Terminal, press Enter), type `claude setup-token` and press Enter. Approve in the browser window that opens. Copy the long token it then prints, and tell me 'copied'. Do not paste it here."
   This is the only command the user types in the whole setup. When they ask why: the token is their account's key, so it must come from their own login.
2. On "copied": `pbpaste | $F login --token-stdin`, then `pbcopy </dev/null`.
3. `$F status --json` must show `claude-login` ok. Then `$F ask "Reply with: pong" --json` proves the server answers.
4. `claude-token-not-expiring` fails a month before the one-year token ends: give the user the step 1 message, then on "copied" run `pbpaste | $F login --token-stdin` and `pbcopy </dev/null` (plain `$F login` stops early because the server is still logged in). Then delete the old Keychain copy: `security delete-generic-password -s fraim-claude-token`.
5. When the user postpones the login, continue and list it as missing in Finish. Later, any `$F ask` exits 3 with the same step: say "your server is not signed in yet" and offer it again.
6. Offer the full login next: the setup-token only lets Claude answer, a full login also gives Remote Control (use the server from the Claude phone app) and the user's claude.ai connectors (Gmail, Drive, ...). Run it with the managing-fraim-spaces skill ("Full login"). Work and personal things in separate spaces: the same skill.

## WhatsApp

1. Prepare the user first, because the pairing code is valid for only about 1 minute: "Take the phone with the bot number and open the WhatsApp Business app (not your normal WhatsApp). Tell me when you have it open."
2. `$F whatsapp link --number <bot number>`. It prints a pairing code. (Without `--number` it writes a QR code to `~/.fraim/whatsapp-qr.png` and exits 3: show the user that file.)
3. Human step, right away: "In WhatsApp Business: on iPhone tap Settings, on Android tap the three dots. Then Linked devices, Link a device, 'Link with phone number instead', and type this code: <code>."
   When the code expired (after about 1 minute), run step 2 again for a fresh code.
4. Wait until `$F whatsapp status` shows connected, then `$F whatsapp test`. Ask the user to confirm that the message arrived on their own phone.

## Claude config

1. `$F config status`. Exit 2 "no role yet" is normal on a new laptop. When it shows a role, skip `init`.
   Otherwise `$F config init --role laptop`. It also adds the official plugin marketplace and an empty `secrets.env`; that is not an overwrite, so no question is needed. The server (or the Mac trial, which plays the server role) ran `init --role server` at start.
2. Server with `sync`: `$F sync pair`. It pairs the laptop's Syncthing with the server and shares `~/fraim` on both sides, with a `.stignore` that keeps keys and env files out. Its only human step is installing and opening the Syncthing app. Run this before `config init` above when `~/fraim/claude` should come from the server.
3. `$F config status` here and `$F exec -- fraim-config status` on the server. Both must show their role linked.
   With sync, the fingerprints must match once sync has run. Without sync (and in a Mac trial) they match right after setup but are independent copies: a later change on one side does not reach the other.

## Finish

Report, in this order:
1. One line per part, in plain words: Claude (`claude-login`), browser (`server-browser`), scheduler (its `services[]` status: healthy), WhatsApp, sync, config. Each says works or what is missing.
2. How the user reaches the server from now on: WhatsApp the bot, or ask you ("ask my server to ...", which uses `$F ask`).
3. The one next thing worth doing, for example "Send the bot 'what can you do?'".
4. The one-page guide. Server: write `~/fraim/fraim-guide.md` on the server (`$F exec -- sh -c 'cat > ~/fraim/fraim-guide.md'`, text on stdin); with sync it also appears on the laptop.
   Login skipped or failed: still write the full guide; on the "Talk to it" line add "Not signed in yet: ask Claude on your laptop to finish the login."
   Mac trial: write `~/fraim-guide.md` on the laptop only (a trial's files disappear with `local down --wipe`) and drop the server lines.
   Without sync the server's guide is not on the laptop: show its full text in your reply as well.
   Open it for the user. Fill in real values; leave out lines for parts that are off. "Your files": mention the laptop only when sync is on. "Costs": for an existing server, write "your provider's price" instead of the Hetzner amount:

   ```
   # Your fraim server
   What it is: your own Claude that keeps running when your laptop is closed.
   Talk to it: WhatsApp <bot number> | the Claude app on your phone | ask Claude on your laptop "ask my server ..."
   Things to try: "What's in my inbox?" | "Every weekday at 8, summarise ..." | "Send me <file>"
   Your files: ~/fraim on the laptop and the server (same folder)
   Safety: never give it bank, work-production or admin logins
   When something is wrong: ask Claude on your laptop "check fraim" or message the bot "are you ok?" <without WhatsApp: "Ask Claude on your laptop 'is my server ok?' once a week: the server cannot warn you by itself.">

   Costs: <new Hetzner server: about 7-9 euro a month (server, address, backups) | existing server: your provider's price>; Claude uses your own subscription
   To stop or move fraim: ask Claude on your laptop "remove fraim" or "move fraim to a new server"
   Set up on: <date>, server <hostname>, help: <the person who set it up, if any>

   ## Your jobs
   (none yet; ask Claude "every weekday at 8, ..." to add one)
   ```

## Human steps (the complete list)

1. Install Docker (Mac trial only, when missing).
2. Hetzner sign-up (start early: the check can take hours), then create the server and give the IP.
3. Tailscale: account, Mac app with the VPN Allow prompt, a 1-day API token (`fraim tailscale key`) and a yes to the policy change, auth key.
4. Run `claude setup-token` and approve in the browser.
5. Enter the WhatsApp pairing code in WhatsApp Business.
6. Install and open the Syncthing app (sync only; `fraim sync pair` does the pairing).
7. Website logins and 2FA in the server browser, only when a job needs a site.
