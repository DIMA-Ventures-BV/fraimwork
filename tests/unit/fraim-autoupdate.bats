#!/usr/bin/env bats
# fraim autoupdate: steering the server's own updater from the laptop, behind a fake ssh.

load helper

setup() { setup_isolated; use_public_target; }

@test "help lists autoupdate" {
  run "$FRAIM" help
  [[ "$output" == *"fraim autoupdate"* ]]
}

@test "status asks the updater on the server" {
  run "$FRAIM" autoupdate
  [ "$status" -eq 0 ]
  grep -q 'fraim-updater status --json' "$SSH_LOG"
}

@test "off and canary change the right setting" {
  run "$FRAIM" autoupdate off
  [ "$status" -eq 0 ]
  grep -q 'AUTO_UPDATE=off' "$SSH_LOG"
  run "$FRAIM" autoupdate canary
  [ "$status" -eq 0 ]
  grep -q 'UPDATE_RING=canary' "$SSH_LOG"
}

@test "now installs at once" {
  run "$FRAIM" autoupdate now
  [ "$status" -eq 0 ]
  grep -q 'fraim-updater run --now' "$SSH_LOG"
}

@test "an unknown action is a usage error and reaches nothing" {
  run "$FRAIM" autoupdate sideways
  [ "$status" -eq 2 ]
  ! grep -q fraim-updater "$SSH_LOG"
}

@test "it works on the whole server, not per space" {
  run "$FRAIM" autoupdate status --space work
  [ "$status" -eq 2 ]
}
