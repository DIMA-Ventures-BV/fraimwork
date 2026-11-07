# fraimwork.app v0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A downloadable `fraimwork.app` (zip, ad-hoc signed, arm64) built by GitHub Actions from the fork, with the cmux brand, telemetry, update feed and Manaflow cloud removed.

**Architecture:** All work happens on branch `fraimwork` in `DIMA-Ventures-BV/fraimwork-app` (GPL-3.0 fork of manaflow-ai/cmux). That branch deletes every upstream workflow and adds one: `fraimwork-build.yml`. Rebranding uses build settings and plist values, not a project rename, so upstream merges stay small.

**Tech Stack:** Xcode 26 on GitHub `macos-26` runners, prebuilt GhosttyKit from manaflow-ai/ghostty releases (sha256-pinned), Swift, Rust, Go 1.26.

**Spec:** this plan's "Decisions" section plus `docs/superpowers/specs/2026-11-07-fraim-desktop-design.md` (the Dock layer moves into the app in v1).

## Decisions

- Michael, 2026-11-07: own native app named "fraimwork"; public fork created with his OK.
- Claude's calls (check these):
  - v0 is unsigned (ad-hoc). Users must right-click > Open once. A Developer ID ($99/yr) and notarization come in v1.
  - The project, scheme and module names stay `cmux` internally. Only what a user sees changes. This keeps upstream merges cheap.
  - The CLI inside the bundle is renamed `fraimwork` (users type it; it must not say cmux). The upstream `cmux` name stays as a symlink only if the app itself calls it by that path.
  - Off in v0: PostHog, Sparkle checks, Sentry, cmux.com sign-in and cloud, feedback endpoint, iroh relay, tunnel extension. They come back only with our own endpoints.
  - Bundle id `nl.dimaventures.fraimwork`.
  - Local Mac work happens in a shallow clone under the scratchpad (disk is 97% full). Builds run only in CI.

## Global Constraints

- Never push to `main` of the fork. Only branch `fraimwork`.
- Turn on Actions for the fork only after `.github/workflows/` on `fraimwork` holds just `fraimwork-build.yml`. Make `fraimwork` the default branch first, so no upstream cron runs from `main`.
- No Manaflow secrets, URLs or keys in our build. Keep the GhosttyKit download: it is a public, checksum-pinned release asset.
- Every changed file keeps its GPL header. Add `NOTICE-fraimwork.md` stating the fork and changes (GPL-3.0 section 5a).
- No "cmux" text visible to a user in the app name, menus, About window, permission prompts or Dock.

## Review Focus

1. A user opens the app for the first time: macOS Gatekeeper blocks an unsigned app. The release notes must say right-click > Open.
2. An existing cmux install on the same Mac: the two apps must not share settings, socket or bundle id. Check `~/.config/cmux` sharing and the socket path.
3. Telemetry really off: no request to posthog.com, sentry.io or cmux.com on launch (check with `nettop` or Little Snitch in the smoke test).
4. Sparkle: no update prompt pointing at cmux releases.
5. The CLI name: `fraimwork --help` works from the app's terminals; shell integration that calls `cmux` internally still works.

---

### Task 1: Clean branch and CI build of the unchanged app

**Files:** fork repo: delete `.github/workflows/*`; create `.github/workflows/fraimwork-build.yml`, `NOTICE-fraimwork.md`.

- [ ] Shallow clone (`--depth 1 --filter=blob:limit=5m`, no submodules) into the scratchpad; create branch `fraimwork`.
- [ ] Write `fraimwork-build.yml`: `workflow_dispatch` plus push to `fraimwork`; `macos-26`; checkout with recursive submodules; select Xcode 26; download the Metal toolchain; install Rust and Go; `scripts/ensure-ghosttykit.sh` (prebuilt); the `xcodebuild -scheme cmux -configuration Release ... CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES build`; `codesign --force --deep -s -`; zip; upload artifact.
- [ ] Push the branch. Set it as default. Enable Actions. Dispatch the workflow.
- [ ] Expected: a green run with a `.app` zip artifact. Record the build time.
- [ ] Commit: "Build the app on GitHub runners; drop upstream workflows".

### Task 2: Rebrand what users see

**Files:** `cmux.xcodeproj/project.pbxproj` (Release and Debug `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER` for app, tunnel and docktile), `Resources/Info.plist` (permission strings, URL scheme), `Assets.xcassets/AppIcon.appiconset`, `AppIcon.icon/`, `Resources/cmux.sdef` names, the `cmux-cli` target's `PRODUCT_NAME`.

- [ ] Add a CI check step before the build: `grep` the built app's `Info.plist`, `MainMenu`, `.strings` files for `cmux` (case-insensitive). It fails the build when user-visible text still says cmux. Run it on the unchanged app: expected FAIL.
- [ ] Change the values above; new icon (placeholder from the fraimwork logo until a designer delivers).
- [ ] Expected: the check passes; the artifact is `fraimwork.app` with id `nl.dimaventures.fraimwork`.
- [ ] Commit: "Rename the app to fraimwork".

### Task 3: Remove outbound services

**Files:** `Sources/PostHogAnalytics.swift`, `Resources/Info.plist` (`SUFeedURL`, `SUEnableAutomaticChecks`), `CLI/CLISocketSentryTelemetry.swift`, `Packages/Shared/CmuxAuthRuntime/.../AuthConfig.swift`, `FeedbackComposerSettings.swift`, iroh build settings; the tunnel extension target is removed from the app's embed phase.

- [ ] Add a CI check: `strings` on the built binary must not contain `phc_opOVu7`, `ingest.us.sentry.io`, `cmux.com/api`, `manaflow-ai/cmux/releases`. Expected: FAIL on Task 2's build.
- [ ] Make each service a no-op behind a single `FRAIMWORK_DISABLE_UPSTREAM_SERVICES` compile flag, so upstream merges touch few lines.
- [ ] Expected: the check passes; the app launches in the smoke test (Task 4) without network calls to those hosts.
- [ ] Commit: "Turn off upstream telemetry, updates and cloud".

### Task 4: Smoke test and first release

- [ ] Download the artifact on this Mac, right-click > Open. Check: window opens, terminal works, About says fraimwork, no update prompt, `fraimwork ping` answers from inside, an existing cmux install still works alongside.
- [ ] Watch outbound connections for 2 minutes after launch.
- [ ] Publish a GitHub pre-release `v0.1.0` on the fork with the zip and right-click > Open instructions.
- [ ] Update fraimwork `README.md` with the download link.

## Later plans

1. v1: Developer ID signing and notarization; our own Sparkle feed.
2. v1: fraim Dock, server status and onboarding built into the app (replaces `bin/fraim-desktop`).
3. Weekly upstream merge job.
