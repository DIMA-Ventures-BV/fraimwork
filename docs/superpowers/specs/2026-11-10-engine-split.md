# Engine split

Goal: fraimwork is a lightweight harness. It owns what must work and stay safe for everyone. What a person sees and how their agents behave is theirs to build. Releases reach every server without a laptop.

## Four layers

| Layer | Contents | Who changes it |
|---|---|---|
| Engine | Agent runner (with herdr), scheduler, memory limits, updater, secrets proxy, data store, raw API, one plug-in loader | Fraimwork releases |
| Authority | Roles, tool lists, budgets, default contact, what is switched on, records of owner yeses | The owner only; no agent can write it |
| Modules | WhatsApp, Tailscale, file sync, browser, voice, Google, desktop app | The owner switches them on |
| Content | Agents, prompts, styles, pages, buttons, attention rules, triggers, outputs, sources, brain | The owner or the chief |

Test for where a thing goes: if a stranger could want it different, it is content or a module. If it grants power, it is authority.

## Rely on herdr-core

If herdr-core does it, fraimwork uses core and does not build its own. Core runs and connects agents: terminals, status, waiting, parent and child agents, templates, machines, its API. Fraimwork is what core leaves out: the owner, channels, queue, secrets, scheduler and server install. Core's plug-in manifest and published schema are the model for ours.

Core treats every program of one account as trusted, so fraimwork does too. The limit is that no run gets a shell without an owner's yes.

## One door

New code that runs with power (plug-ins, triggers, outputs, sources, automations) and is written by a run nobody watches does not run until the owner says yes. A change the owner makes or asks for in the chat goes live at once. Buttons and pages stay fully the owner's.

## Stages

Each stage ships on its own and reaches servers through stage 1.

1. **Self-updating servers.** Signed releases. Each server installs them itself, checks health and rolls back. Plan: `docs/superpowers/plans/2026-11-10-self-updating-servers.md`.
2. **Tighten approvals and agent limits.** Tie every owner yes to the work it covers. Make roles, budgets and API helper arguments unchangeable by the agent they limit.
3. **No shell without a yes.** A run with no shell cannot start one without the owner's yes for that job. Code written by a run nobody watches waits for one door. A separate Unix user can follow later for customers who need it.
3b. **Agent plumbing on core.** Goals and sessions use core's templates, parent notes and waiting. Fraimwork's own launcher and watcher shrink to what core does not do.
4. **Queue split and API v1.** Store, approval check and a documented raw API stay in the engine. Inbox rules, row wording and chief chat move to content. Add Authorization headers, scoped tokens, CORS and events, so a separate app can be a full screen.
5. **Agent capabilities.** The chief becomes the default agent. The engine knows capabilities and a default contact. Owner-rights chat stays an engine capability.
6. **Modules and channels.** A module manifest declares services, health checks and tools. A channel contract, based on the gateway's routes, makes WhatsApp replaceable. Voice and browser tooling leave the main image. Heavy modules default to off for new installs.
7. **Overrides that survive updates.** Each slot has a version. The owner hears when a copy of theirs is stale. Rollback for every slot. One loader. Public defaults carry no company names.

## Updates: decisions

- Updates install automatically in a night window. An owner can switch this off.
- Rings: `canary` installs at once, `stable` waits 24 hours, so a bad release stops at the canary.
- Releases are signed. The public key ships in the repo and each new release can rotate it.
- A server running a hand-deployed build is never overwritten.
- Owner data lives in volumes. An update only replaces code.
