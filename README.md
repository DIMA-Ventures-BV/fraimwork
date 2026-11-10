# fraimwork

Your own Claude that is always on. It runs on a small server you rent, keeps working while your laptop and phone are off, and you can talk to it from your laptop, the Claude app on your phone, and WhatsApp.

You do not need to know anything about servers. Claude sets it up for you and only asks you for the few things it cannot do itself.

## Get started

Open the Terminal app (press Cmd+Space, type Terminal, press Enter), paste this line and press Enter:

```
curl -fsSL https://raw.githubusercontent.com/DIMA-Ventures-BV/fraimwork/main/bootstrap.sh | bash
```

It installs Claude Code and the fraim plugin, adds short commands (`c` starts Claude, `cn` continues your last chat, `cr` picks an older one), and asks you once to approve a Claude login in your browser. Then Claude opens and sets up the rest with you. You can run it again at any time.

Already use Claude Code? Type `/plugin marketplace add DIMA-Ventures-BV/fraimwork`, then `/plugin install fraim@fraimwork`, then ask: `Set up fraim for me.`

Want to try it first without renting a server? Ask: `Set up fraim locally so I can try it.` It then runs on your laptop in Docker.

## What Claude will ask you to do

Claude does the rest. You only do these steps, one at a time, when Claude asks:

| Step | Time | Cost |
|---|---|---|
| Rent a server (Claude tells you which one and where to click) | 5 min | about 5 to 9 euro per month |
| Create a free Tailscale account and install the Tailscale app on your laptop and phone | 5 min | free |
| Approve a Claude login in your browser (the setup command does this; otherwise Claude asks you to run `claude setup-token`) | 1 min | your Claude Pro or Max plan |
| Optional, for WhatsApp: a second phone number (prepaid eSIM) with WhatsApp Business, then type a code Claude gives you | 10 min | about 5 to 10 euro once |
| Optional: log in to websites in the server's browser when Claude asks | 1 min each | |

Never paste passwords or tokens into the chat. Claude asks you to copy them and reads them from your clipboard.

## How you use it

- **On your laptop:** keep talking to Claude as usual. Ask it to "send this to my fraim server" or "check on the job you started".
- **In your workspace (macOS):** setup opens a [cmux](https://cmux.com) window with your server's Claude on the left and a panel with server status and the server browser on the right. Ask Claude to "open my workspace" any time. cmux is GPL-3.0 software, installed unmodified from Homebrew; fraim only adds its own Dock controls and leaves your cmux settings alone.
- **fraimwork app (test build):** our own macOS app, a GPL-3.0 fork of cmux without its telemetry or update checks. Download [fraimwork 0.1.1](https://github.com/DIMA-Ventures-BV/fraimwork-app/releases/tag/v0.1.1) (Apple Silicon, not signed yet: right-click > Open the first time).
- **On your phone:** use the Claude app (Remote Control, after a full login: ask Claude to "turn on Remote Control for fraim"), or send a WhatsApp message to your agent's number. Voice messages work too: your server turns them into text itself, so the audio stays on your server.
- **Work and personal apart:** ask Claude to "add a personal space". Each space is its own agent with its own files, keys and connections, so your bank never sits next to your work mail (see `docs/spaces.md`).
- **Connect things:** ask Claude to "connect Linear / PostHog / my GitHub repo / my dev box to fraim". Keys go into the secrets container through your own Terminal, never through the chat.
- **Bigger tasks:** ask for it on WhatsApp in your own words. The server works on it in the background, while you can keep chatting, and sends the result when it is done. Ask what is running, or to stop one. Say "start fresh", "compact" or "switch to Opus" and your agent runs /clear, /compact or /model on itself. From the laptop: ask Claude to "start a goal on my server".
- **Live sessions:** every Claude on the server runs in a terminal that keeps going with the laptop closed (herdr, see `docs/sessions.md`). Start coding work with `fraim session new vertelboek "fix the login bug"` or by asking on WhatsApp. When a session asks something or finishes, you get a WhatsApp message; answer in your own words, or take it over with `fraim shell s1`.
- **One review queue:** goal results, with screenshots, wait for you on one page (`fraim queue` on the laptop) and on WhatsApp, where you answer in your own words. A rejection sends the work back with your reason, and your reasons become rules the agents follow (see `docs/queue.md`).
- **Lead agents:** ask Claude to "add a lead for my web app". A lead checks its area every morning, starts small fixes and proposes ideas in your queue. A chief of staff ranks the queue, sends one daily digest, and during the day routes new work (a finished goal, a failure, a request from mail or Linear, or anything you ask for on WhatsApp) to a goal, a lead or you.
- **Add a product:** a repo can carry its own leads and automations in a `.fraim/` folder. Ask Claude to "add this project to fraim". They arrive switched off and you choose what runs (see `docs/projects.md`).
- **While you sleep:** ask Claude to schedule a job, for example "every morning at 8, summarize my inbox and WhatsApp me".
- **Approvals:** before your agent does something risky, it asks you on WhatsApp. Reply with the code it shows, for example `yes abcde`.
- **Change anything:** say it in your own words, for example "the chief of staff should be more direct" or "stop telling me about X". Everything your agents are told is a text file that is yours to change, for one agent or for all of them (see `docs/prompts.md`).
- **Limits:** your agent uses your normal Claude plan. Scheduled jobs and WhatsApp chats count toward its usage limits. When a limit is reached, a job fails and you get a WhatsApp message with the reason; it works again when the limit resets.
- **Problems:** your server checks itself every hour and sends you a WhatsApp message when something breaks, and again when it is fixed. If you need help, ask Claude to "make a fraim support bundle" and send that file to whoever helps you; passwords and phone numbers are removed from it.

## Is it safe?

- Your server is private. With Tailscale, nothing on it is reachable from the internet, and the server can never connect to your laptop or phone.
- Everyone on your WhatsApp allowlist can ask your agent to do anything you could. Only add people you fully trust. Only you can approve risky actions.
- Websites you log in to in the server's browser stay logged in, and your agent can use them. Only log in where it needs access.
- Keep production passwords and company secrets off the server.
- API keys you give your agent stay in a separate container. The agent can use them but never sees them (see `docs/secrets.md`).
- WhatsApp support uses the unofficial WhatsApp Web protocol. Use a separate number, never your personal one. For customer-facing use, switch to the official WhatsApp Business API.
- Every action the agent takes is logged on the server in `~/.local/state/fraim/audit.jsonl`.

## For developers

Claude drives everything through `bin/fraim`, a CLI written for agents: it never prompts without a terminal, never blocks, prints `HUMAN STEP:` lines for things only a person can do, and uses exit codes 0 ok, 1 failure, 2 usage or missing input, 3 human step needed. Run `bin/fraim help` for every command.

| Path | What |
|---|---|
| `compose.yaml` | All services. Modules are compose profiles: `sync`, `browser`, `whatsapp`, `scheduler`. Every space starts this file as its own compose project (`docs/spaces.md`). |
| `install.sh` | Server setup on Ubuntu 24.04: Docker, Tailscale, firewall, secrets. Safe to run again. |
| `bin/fraim` | The CLI Claude uses. |
| `bin/fraim-config` | Claude configuration shared between laptop and server (see `docs/config.md`). |
| `skills/` | The Claude Code skills that set up and operate fraim. |
| `workspace/` | The server's Claude Code container: SSH, herdr sessions, scheduler, helper scripts. |
| `workspace/prompts/` | Every instruction agents get, as default files. The owner's files win (`fraim-prompt`, `docs/prompts.md`). |
| `workspace/channel/` | The WhatsApp channel for Claude Code, with approvals over WhatsApp. |
| `whatsapp/` | WhatsApp gateway: linked device, allowlist, internal API. |
| `browser/` | The server's Chrome with a persistent profile and a screen viewer (noVNC). |
| `tailscale/policy.hujson` | Tailscale access policy (merge it into an existing policy, do not replace). |
| `tests/` | Unit tests (`make check`), and end-to-end tests against throwaway local stacks (`make e2e`, `make e2e-spaces`). |
