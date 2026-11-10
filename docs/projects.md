# Projects

You install fraim once per person: one server, one WhatsApp number, one chief, one queue. A product plugs into it with a `.fraim/` folder in its own repo. GitHub Actions works the same way: one runner, and each repo carries its own workflows.

## Where a change goes

| It is true for | It goes in |
|---|---|
| Anyone, also a stranger | fraimwork |
| Every project of your team, on the laptop too | Your team's Claude config and its mirror file |
| One product | That product's repo: `AGENTS.md`, `.claude/`, `.fraim/` |
| Only you | `~/fraim` on your server: brain rules, voice, your own automations, what is switched on |

## The folder

```
.fraim/
  needs.mirror                    tools, keys, MCP servers this product needs (docs/mirror.md)
  leads/web-app.md                one lead
  automations/nightly/automation.md
  automations/nightly/check.sh    optional scripts; only automation.md and *.sh belong here
```

A lead file is a normal lead brief with three extra header lines. `schedule` and `budget` are defaults for the first install. After that, each server keeps its own. `tools` is what this lead may use.

```
---
role: lead
schedule: "20 5 * * *"
budget: 3
tools: mcp__linear, mcp__posthog, WebFetch, Bash(npm audit:*)
---
# Lead: web-app

## Area
The web app.
```

## Access

Two places in `.fraim` work together:

- `needs.mirror` says what the server must have: MCP servers, command-line tools, and the names of keys. The values never sit in the repo. They come from the laptop of the person who installs the project, and that person sees where each key goes.
- `tools:` in a lead says which of those this lead uses.

The plan warns when a lead names an MCP server that the server lacks and `needs.mirror` does not add.

Under the default `PERMISSIONS=all`, a `tools:` list is not a wall: every Claude in a space can use everything connected to that space. The wall is the space. A product whose keys must stay apart from another product goes in its own space (`docs/spaces.md`).

## Use it

```sh
fraim project add OWNER/REPO                       # clone, show the plan, exit 3
fraim project add OWNER/REPO --yes --commit SHA    # install what the plan showed
fraim project on REPO web-app nightly              # switch on (or --all)
fraim project update REPO                          # later: show and install what changed
fraim project list
```

To move leads and automations you already run into a repo:

```sh
fraim project export web-app nightly --to path/to/repo/.fraim
```

Commit that folder. `fraim project add` then sees the same items on the server and adopts them. They keep running, with their notes and their on or off state. Read the exported files first: they can hold private details.

## What the plan says

| Word | Meaning |
|---|---|
| new | Not on the server yet. It arrives switched off. |
| update | The repo changed and the server copy did not. The plan shows the diff. It stays on or off as it is. |
| adopt | The server already has exactly this item. It becomes part of the project. |
| keep | You edited it on the server. The repo's new version is not installed. |
| skip | The server has a different item with that name. It is not touched. |
| gone | It left the repo. It stays on the server until you remove it. |

## Safety

Claude on the server runs with permissions skipped, so a repo's `.fraim/` is code that runs with your keys.

- Only the default branch counts, at the one commit the plan showed. Branches and edits in `~/code` have no effect.
- Nothing changes without the owner's yes on the plan. A goal, lead or automation cannot run `fraim-project apply` or `on`.
- A repo cannot add a chief or an engineer, a symbolic link, or an automation that starts a lead.
- Switching on stays per person. Two people who both switch on one lead get two servers working on the same repo.
