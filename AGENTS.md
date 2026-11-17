# AGENTS.md

## What this repo is

fraimwork: a personal, always-on Claude Code server (Docker on a small Ubuntu VM, reached over Tailscale, with WhatsApp, a server browser, a scheduler and file sync). The repo is also the `fraim` Claude Code plugin (`.claude-plugin/`, `skills/`) that sets the server up and runs it for non-technical owners. Public repo: `DIMA-Ventures-BV/fraimwork`.

Read `README.md` (its "For developers" table maps the layout) and `docs/decisions.md` before changing behaviour. Topic docs live in `docs/` (spaces, sessions, queue, prompts, secrets, channels, ...).

## Layout in one breath

- `bin/fraim` plus `bin/fraim.d/*.sh`: the CLI Claude drives. `bin/fraim-release`, `bin/fraim-updater`: signed releases and self-update.
- `compose.yaml`: all services; modules (`modules/*.manifest`) are compose profiles.
- `workspace/`: the server's Claude container. `workspace/prompts/` holds every instruction agents get; `workspace/managed-CLAUDE.md` is the server agent's CLAUDE.md, not this repo's.
- `whatsapp/`, `browser/`, `google/`, `secrets/`, `tailscale/`: the other services.
- `tests/unit/*.bats` (with `tests/unit/fakes/`), `tests/node/*.test.mjs`, and e2e scripts in `tests/`.

## Commands

| Command | What | Time |
|---|---|---|
| `make check` | lint + bats + node tests (`.github/local-checks.sh`) | ~1 min |
| `make check-linux` | the same on Ubuntu in Docker; `fraim-release` runs it | ~3 min |
| `make lint` | shellcheck, `node --check`, JSON, compose, hadolint, actionlint, plugin and SKILL.md checks | fast |
| `make test-unit` / `make test-node` | bats / `node --test` only | fast |
| `make test-secrets` | secrets proxy in Docker with a fake API | ~1 min |
| `make e2e` / `make e2e-spaces` | full local stack / two spaces, needs Docker | 10-20 / ~5 min |
| `make e2e-update` | update and rollback on a real Ubuntu VM | ~40 min |

Run `make check` before every PR. CI does not run on push or PR; `/ship` and `/merge` run `.github/local-checks.sh` and `bin/fraim-release` runs `make check-linux`. Run e2e only when a change touches compose, containers, install or update; use the dev box for it if you have one.

## Traps

- **The CLI contract is the product.** `bin/fraim` never prompts without a TTY, never blocks, prints `HUMAN STEP:` for things only a person can do, and exits 0 ok, 1 failure, 2 usage or missing input, 3 human step needed. Keep that for every new command.
- **Readers are non-technical.** README, skills and anything an owner sees on WhatsApp are plain words: no jargon, no file paths in alerts, no links in chief messages.
- **Prompts are owner-overridable defaults.** Edit `workspace/prompts/*.md`, never hard-code agent instructions in scripts; the owner's copy wins (`docs/prompts.md`).
- **Isolation is a decision, not an accident.** The browser and WhatsApp gateway only get their own drop folders and networks; secrets stay in the secrets container and are denied to Claude's Read tool. Do not widen mounts, networks or permissions without a line in `docs/decisions.md`.
- **Releases are signed.** Only `bin/fraim-release vX.Y.Z` from a clean, pushed `main`; it runs `make check-linux` on that commit before signing. Never tag by hand. Rollback restores code, not volume data: a release that migrates data needs migration notes.
- **Lint checks more than syntax.** A SKILL.md `name` must match its folder and have a description of 20+ characters. A Node script without `.mjs`/`.js` must be added to the `node --check` list in `tests/lint.sh`. JSON must parse with `jq`.
- **`tailscale/policy.hujson` is merged into an owner's policy,** never a replacement for it.
- **Public repo.** No secrets, personal paths, phone numbers or owner data in code, tests or docs. `.env*` (except `.env.example`) stays local.
- **Commit style:** one sentence that says what changes for the owner, not which file moved.
