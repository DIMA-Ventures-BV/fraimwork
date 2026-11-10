#!/usr/bin/env bats
# The engine is public: what it ships carries no company or person of ours.

setup() {
  REPO="$BATS_TEST_DIRNAME/../.."
  LEFTOVERS='pupstar|mijnlevensverhalen|mlv-alerts|michael@|fraim-michael'
}

@test "shipped prompts, examples and the tailscale policy name no company or person" {
  run grep -rEil "$LEFTOVERS" "$REPO/workspace/prompts" "$REPO/workspace/automation-kit" "$REPO/tailscale" "$REPO/docs/decisions.md"
  [ "$status" -eq 1 ]
}

@test "the time zone default in compose is neutral" {
  run grep -c 'Europe/Amsterdam' "$REPO/compose.yaml"
  [ "$output" = 0 ]
  grep -q 'TZ: ${TZ:-UTC}' "$REPO/compose.yaml"
}

@test "a server with TZ in its .env keeps it: compose only falls back when it is missing" {
  grep -q '^TZ=' "$REPO/.env.example"
  grep -Fq '[ -f .env ] || cp .env.example .env' "$REPO/bin/fraim"
}
