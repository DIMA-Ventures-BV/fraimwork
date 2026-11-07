#!/usr/bin/env bats
# bin/fraim as Claude runs it: no terminal, exit codes 0/1/2/3, a fake server behind ssh.

load helper

setup() { setup_isolated; }

# --- contract: help, unknown commands, no config ----------------------------------

@test "help documents the exit-code contract" {
  run "$FRAIM" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exit codes"* ]]
}

@test "help lists every command the dispatcher knows" {
  run "$FRAIM" help
  for c in init local deploy update use config login lock tailscale exec ask shell chrome \
           browser sync whatsapp status logs support-bundle restart reset-workspace secret; do
    [[ "$output" == *"fraim $c"* ]] || { echo "help misses: $c"; return 1; }
  done
}

@test "--help on any command prints help and runs nothing" {
  run "$FRAIM" deploy root@203.0.113.7 --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exit codes"* ]]
  [ ! -s "$SSH_LOG" ]
}

@test "unknown command exits 2" {
  run "$FRAIM" no-such-command
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "commands without a configured target exit 2 with a next step" {
  for c in status exec logs ask whatsapp; do
    run "$FRAIM" "$c"
    [ "$status" -eq 2 ] || { echo "$c exited $status"; return 1; }
    [[ "$output" == *"fraim local up"* ]]
  done
}

@test "use switches the target file" {
  run "$FRAIM" use local
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CONFIG_HOME/fraim/current")" = local ]
  run "$FRAIM" use server
  [ "$(cat "$XDG_CONFIG_HOME/fraim/current")" = default ]
  run "$FRAIM" use mars
  [ "$status" -eq 2 ]
}

# --- exec ------------------------------------------------------------------------

@test "exec passes arguments to the workspace safely quoted" {
  use_public_target
  run "$FRAIM" exec -- echo 'a b' '$(touch /tmp/x)'
  [ "$status" -eq 0 ]
  grep -qF "claude@test.invalid echo a\\ b \\\$\\(touch\\ /tmp/x\\)" "$SSH_LOG"
}

@test "exec returns the remote exit code" {
  use_public_target
  ssh_handler 'exit 7'
  run "$FRAIM" exec -- false
  [ "$status" -eq 7 ]
}

@test "exec without a command exits 2" {
  use_public_target
  run "$FRAIM" exec --
  [ "$status" -eq 2 ]
}

# --- login and ask -----------------------------------------------------------------

@test "login --token-stdin rejects something that is not a Claude token" {
  use_public_target
  run bash -c "printf 'hunter2' | '$FRAIM' login --token-stdin"
  [ "$status" -eq 2 ]
  [ ! -s "$SSH_STDIN_LOG" ]
}

@test "login --token-stdin sends the token over stdin, never on the command line" {
  use_public_target
  run bash -c "printf ' sk-ant-oat01-SECRETVALUE \n' | '$FRAIM' login --token-stdin"
  [ "$status" -eq 0 ]
  [ "$(cat "$SSH_STDIN_LOG")" = "sk-ant-oat01-SECRETVALUE" ]
  ! grep -q SECRETVALUE "$SSH_LOG"
  ! grep -q SECRETVALUE <<<"$output"
}

@test "ask on a server without login is a human step (exit 3)" {
  use_public_target
  ssh_handler 'case "$REMOTE" in *credentials.json*) exit 1 ;; esac'
  run "$FRAIM" ask "hello"
  [ "$status" -eq 3 ]
  [[ "${lines[0]}" == "HUMAN STEP:"* ]]
}

@test "ask on an unreachable server is a failure, not a login step" {
  use_public_target
  ssh_handler 'exit 255'
  run "$FRAIM" ask "hello"
  [ "$status" -eq 1 ]
  [[ "$output" != *"HUMAN STEP"* ]]
}

@test "ask quotes the prompt and the allowed tools for the remote shell" {
  use_public_target
  prompt='say "hi"; rm -rf ~ $(id) `id`'
  run "$FRAIM" ask "$prompt" --allow 'Bash(git:*)' --json
  [ "$status" -eq 0 ]
  remote="$(tail -1 "$SSH_LOG" | sed 's/.*fraim-claude //')"
  eval "set -- $remote"
  [ "$1" = -p ]
  [ "$2" = "$prompt" ]
  [ "$3" = --allowedTools ]
  [ "$4" = 'Bash(git:*)' ]
  [ "$5 $6" = "--output-format json" ]
}

@test "shell refuses to run without a terminal" {
  use_public_target
  run "$FRAIM" shell
  [ "$status" -eq 2 ]
  [ ! -s "$SSH_LOG" ]
}

# --- whatsapp ------------------------------------------------------------------------

@test "whatsapp status with the module off exits 2, not 3" {
  use_public_target
  ssh_handler 'case "$REMOTE" in *fraim-gateway*) exit 2 ;; esac'
  run "$FRAIM" whatsapp status
  [ "$status" -eq 2 ]
  [[ "$output" == *"module is off"* ]]
}

@test "whatsapp link refuses the owner's own number as the agent number" {
  use_public_target
  ssh_handler 'case "$REMOTE" in
    *"GET /status"*) echo "{\"connected\":false}" ;;
    *WHATSAPP_OWNER*) echo 31612345678 ;;
  esac'
  run "$FRAIM" whatsapp link --number "+31 6 1234 5678"
  [ "$status" -eq 2 ]
  [[ "$output" == *"own second number"* ]]
}

@test "whatsapp link with a number hands the pairing code to the human" {
  use_public_target
  ssh_handler 'case "$REMOTE" in
    *"GET /status"*) echo "{\"connected\":false}" ;;
    *WHATSAPP_OWNER*) echo 31612345678 ;;
    *"POST /pair"*) echo "{\"code\":\"ABCD-1234\"}" ;;
  esac'
  run "$FRAIM" whatsapp link --number 31687654321
  [ "$status" -eq 3 ]
  [[ "$output" == "HUMAN STEP:"*"ABCD-1234"* ]]
  grep -qF '"number":"31687654321"' "$SSH_LOG"
}

# --- status --------------------------------------------------------------------------

@test "status --json is valid JSON and exits 0 when healthy" {
  use_public_target
  ssh_handler 'case "$REMOTE" in
    *"docker compose ps"*) echo "{\"Service\":\"workspace\",\"State\":\"running\",\"Status\":\"Up\"}" ;;
    *"fraim-doctor --json"*) echo "{\"ok\":true,\"checks\":[{\"name\":\"claude-login\",\"ok\":true}]}" ;;
  esac'
  run "$FRAIM" status --json
  [ "$status" -eq 0 ]
  jq -e '.ok == true and .services[0].service == "workspace" and .ports.ssh == 2222' <<<"$output"
}

@test "status --json on an unreachable workspace is still JSON, with a non-zero exit" {
  use_public_target
  ssh_handler 'exit 255'
  run --separate-stderr "$FRAIM" status --json
  [ "$status" -ne 0 ]
  jq -e '.ok == false and .health.error == "workspace unreachable"' <<<"$output"
}

# --- support bundle -------------------------------------------------------------------

@test "support-bundle removes tokens, passwords and phone numbers" {
  use_public_target
  ssh_handler 'echo "token sk-ant-oat01-AbC_d-123 auth Bearer eyJhbGciOi.x-y
GATEWAY_TOKEN=s3cret VNC_PASSWORD=pw TS_AUTHKEY=tskey-auth-k1
owner 31612345678 and 33612345678@s.whatsapp.net,4915112345678 and +33 6 12 34 56 78
allow=[\"447700900123\",\"12025550123\"]"'
  run "$FRAIM" support-bundle
  [ "$status" -eq 0 ]
  file="$(head -1 <<<"$output")"
  [ -f "$file" ]
  for secret in AbC_d-123 eyJhbGciOi s3cret "=pw" tskey-auth-k1 \
                31612345678 33612345678 4915112345678 "12 34 56 78" 447700900123 12025550123; do
    ! grep -qF -- "$secret" "$file" || { echo "leaked: $secret"; return 1; }
  done
}

@test "support-bundle keeps dates and short numbers readable" {
  use_public_target
  ssh_handler 'echo "2026-11-07T14:16:00Z exit 255 port 2222 pid 48213"'
  run "$FRAIM" support-bundle
  file="$(head -1 <<<"$output")"
  grep -qF "2026-11-07T14:16:00Z exit 255 port 2222 pid 48213" "$file"
}

# --- tailscale policy --------------------------------------------------------------------

@test "tailscale policy fills in the admin emails" {
  run "$FRAIM" tailscale policy --email a@example.org --email-2 b@example.org
  [ "$status" -eq 0 ]
  [[ "$output" == *'"a@example.org", "b@example.org"'* ]]
  [[ "$output" != *"michael@example.com"* ]]
}

@test "tailscale policy without email exits 2" {
  run "$FRAIM" tailscale policy
  [ "$status" -eq 2 ]
}

# --- secret ------------------------------------------------------------------------

@test "secret without an action exits 2" {
  use_public_target
  run "$FRAIM" secret
  [ "$status" -eq 2 ]
  [ ! -s "$SSH_LOG" ]
}

@test "secret set without a terminal or --stdin is a human step (exit 3)" {
  use_public_target
  run "$FRAIM" secret set openai </dev/null
  [ "$status" -eq 3 ]
  [[ "$output" == *"HUMAN STEP:"* ]]
  [ ! -s "$SSH_STDIN_LOG" ]
}

@test "secret set --stdin sends the key over stdin, never on the command line" {
  use_public_target
  run bash -c "printf 'sk-SECRETVALUE' | '$FRAIM' secret set openai --stdin"
  [ "$status" -eq 0 ]
  [ "$(cat "$SSH_STDIN_LOG")" = "sk-SECRETVALUE" ]
  grep -q "fraim-secret set openai" "$SSH_LOG"
  ! grep -q SECRETVALUE "$SSH_LOG"
  ! grep -q SECRETVALUE <<<"$output"
}

@test "secret add quotes its arguments for the remote shell" {
  use_public_target
  run "$FRAIM" secret add openai --upstream 'https://api.openai.com' --format 'Bearer %s'
  [ "$status" -eq 0 ]
  grep -qF "fraim-secret add openai --upstream https://api.openai.com" "$SSH_LOG"
  grep -qF 'Bearer\ %s' "$SSH_LOG"
}
