#!/usr/bin/env bats
# The server browser is heavy, so new installs leave it off. Servers that have it keep it.

load helper

setup() {
  setup_isolated
  use_public_target
}

@test "a new server gets sync, whatsapp and scheduler" {
  grep -qx 'COMPOSE_PROFILES=sync,whatsapp,scheduler' "$REPO/.env.example"
}

@test "fraim local up starts without the browser" {
  grep -q 'env_set COMPOSE_PROFILES scheduler$' "$REPO/bin/fraim.d/local.sh"
  ! grep -q 'env_set COMPOSE_PROFILES browser,scheduler' "$REPO/bin/fraim.d/local.sh"
}

@test "a new space starts without the browser" {
  grep -q 'modules="${modules:-scheduler}"' "$REPO/bin/fraim.d/space.sh"
}

@test "setup explains how to switch the browser on" {
  grep -q 'real browser login' "$REPO/skills/setting-up-fraim/SKILL.md"
  ! grep -q '`browser` and `scheduler` always' "$REPO/skills/setting-up-fraim/SKILL.md"
}

@test "fraim browser says how to switch it on when it is off" {
  ssh_handler 'case "$REMOTE" in *COMPOSE_PROFILES*) echo scheduler,sync ;; esac'
  run "$FRAIM" browser --url-only
  [ "$status" -eq 2 ]
  [[ "$output" == *"space policy main --modules scheduler,sync,browser"* ]]
}

@test "fraim browser goes on when the browser is on" {
  ssh_handler 'case "$REMOTE" in *COMPOSE_PROFILES*) echo browser,scheduler ;; esac'
  run "$FRAIM" browser --url-only
  [[ "$output" == *"public mode has no fixed browser URL"* ]]
}

@test "fraim browser goes on when the server cannot say" {
  run "$FRAIM" browser --url-only
  [[ "$output" == *"public mode has no fixed browser URL"* ]]
}
