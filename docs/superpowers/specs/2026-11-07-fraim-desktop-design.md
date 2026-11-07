# fraim desktop: a ready-made workspace on top of cmux

## Intent

People download fraim and get a working AI workspace without setup work.
Revenue comes from a paid, managed fraim server. The desktop layer is free and makes that server easy to use.

## Decisions (Michael, 2026-11-07)

- Wrap cmux where possible. Bundle our own setup on top so the user configures nothing.
- "Build it completely": the user skipped the design questions.

## Calls made by Claude (check these)

- **No cmux fork.** The cmux macOS app is GPL-3.0-or-later. A rebranded paid fork must publish its full source and needs a new name. We install stock cmux and add config files only. A commercial license from Manaflow (founders@cmux.com) is the alternative if a fork becomes necessary.
- **cmux install:** Homebrew cask `cmux` when `brew` exists. Otherwise a HUMAN STEP to download it from https://cmux.com.
- **The layer is cmux config, not code inside cmux:** a Dock (`~/.config/cmux/dock.json`) and a "fraim" workspace. Custom sidebars (a JS DSL, 590-line templates) wait for v2.
- **Never touch the user's own cmux settings.** `cmux.json` and Ghostty config stay theirs. Our Dock controls carry ids that start with `fraim-`. We merge them into an existing `dock.json` and leave every other control alone.
- **Claude installs it.** The `setting-up-fraim` skill runs `bin/fraim-desktop install` as a stage. The user never types it.
- **Billing, the managed-server fleet and a website are separate plans.** This plan covers only the desktop layer.

## Dock controls

| id | title | type | content |
|---|---|---|---|
| `fraim-agent` | Agent | terminal | `fraim shell` (attach to the server's Claude) |
| `fraim-status` | Server | terminal | `fraim status` refreshed every 60 s |
| `fraim-browser` | Server browser | browser | URL from `fraim browser --print-url`; left out when that fails |

## Non-goals

A forked or rebranded cmux. Changes to `cmux.json` or Ghostty config. Windows or Linux desktop support.

## Anti-goals

Losing a user's own Dock controls or settings. Writing a secret (VNC password, token) into `dock.json`.
