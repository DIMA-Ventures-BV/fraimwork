---
name: connecting-to-fraim
description: Connect this computer to a fraim server that someone else set up, and move the user's existing Claude setup to it - MCP servers, plugins, skills, API keys, repositories and SSH hosts. Use when the user says "connect me to my fraim", "I got a fraim invite", "join my fraim server", "move my Claude setup to my fraim server", or when the session starts with that request. Do NOT use to build a new server (use setting-up-fraim) or to run a server this computer already manages (use operating-fraim).
---

# Connecting to fraim

The server already exists. Someone else runs it. You connect this computer and move the user's setup to it.
The user never types a fraim command. You run every command yourself.

## Rules

- Exit codes: 0 ok, 1 failure, 2 usage, 3 human step. Exit 3 prints `HUMAN STEP: ...`: pass it on in plain words, wait, then run the command it names.
- An invite and every key stay out of the chat. Pipe them. Never `cat`, `echo` or print an invite, `~/.claude.json`, `.env` files or a key file. Read Claude's setup only through `fraim mirror scan`.
- Move nothing that is marked `#ask:` before the user said yes to that line.
- Say this once, before anything moves: "The person who runs your server has admin access to it, so they can read every key you put there. Leave out bank, payment and production logins."
- This computer has no admin access. When a command says "no admin access", tell the user that the person who runs their server does that step.

## Step 1: get the code

1. Find the checkout: `~/fraimwork`, then `~/projects/fraimwork`. If neither exists: `git clone https://github.com/DIMA-Ventures-BV/fraimwork ~/fraimwork`.
2. Set `F=<checkout>/bin/fraim`. Check that `git`, `ssh` and `jq` exist. An SSH key is not needed: the invite holds one.

## Step 2: connect

1. Ask the user to copy the invite they received, and to say "copied". An invite in a file also works.
2. Run `pbpaste | $F attach --stdin`, or `$F attach --file PATH`. When this computer already has another fraim, add `--use`.
3. Run `pbcopy </dev/null` to clear the clipboard.
4. Exit 3 means Tailscale is not ready. Pass the steps on, one at a time. After "done", run `$F attach --check`.
5. Run `$F status --json`. Report in plain words if the server works. A missing Claude login or WhatsApp is a step for the person who runs the server: say so and continue.

## Step 3: list the user's setup

1. Run `$F mirror scan --out ~/.config/fraim/my-setup.mirror`.
2. Read that file. It holds names only.
3. Show the user three short groups, in plain words:
   - **Moves when you say yes:** plugins, skills, commands, `CLAUDE.md`, MCP servers.
   - **Your choice, line by line:** every `#ask:` line. Name the ones marked risky first, and recommend leaving those out.
   - **Needs you by hand:** every `# manual:` line.
4. Ask which `#ask:` lines to include. One question, with "none of these" as an option.
5. For each yes, remove `#ask: ` from that line with the Edit tool. Remove any line the user rejected from the "moves" group.

## Step 4: GitHub first

Do this only when a `repo` line is on.

1. Run `gh auth status`. When it works, ask: "Your server gets the same GitHub access as this computer. OK?" On yes: `gh auth token | $F repo token --stdin`.
2. Without `gh`, or on no: run `$F repo token`. It prints a human step for a limited token.

## Step 5: move it

1. Run `$F mirror ~/.config/fraim/my-setup.mirror`. It exits 3 with the plan. Show the user the plan in plain words: where each key goes.
2. On yes, run `$F mirror ~/.config/fraim/my-setup.mirror --yes`.
3. Exit 3 lists sign-ins. Give them one at a time. After each "done", run the `--finish` command it names.
4. Run the `--yes` command again until nothing waits. Lines already done are skipped.
5. A failed line: read its error, fix what you can, and report the rest.

## Step 6: the workspace (macOS only)

1. Run `<checkout>/bin/fraim-desktop install`, then `<checkout>/bin/fraim-desktop open`.

## Step 7: prove it and finish

1. Run `$F ask "Reply with: pong" --json`.
2. For one moved MCP server, ask the server to use it: `$F ask "Use <server> to list one thing" --allow "mcp__<server>__*"`.
3. Report, in this order:
   - What now works on the server, by name.
   - What the user left out, and what still needs a person.
   - claude.ai connectors such as Gmail work after the full login. The person who runs the server sends that link.
   - One next thing to try: "Ask your server what is on your calendar."
