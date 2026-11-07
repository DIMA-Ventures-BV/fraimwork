#!/usr/bin/env bats
# Pure helpers in bin/fraim, loaded by sourcing the script.

load helper

setup() {
  setup_isolated
  # shellcheck source=/dev/null
  source "$FRAIM"
  set +e
}

# --- normalize_phone ---------------------------------------------------------------

@test "normalize_phone accepts international formats" {
  [ "$(normalize_phone '+31 6 1234 5678')" = 31612345678 ]
  [ "$(normalize_phone '0031612345678')" = 31612345678 ]
  [ "$(normalize_phone '31-6-12345678')" = 31612345678 ]
  [ "$(normalize_phone '+1 (415) 555-0100')" = 14155550100 ]
}

@test "normalize_phone rejects local and malformed numbers with exit 2" {
  for bad in 0612345678 "" abc 12345 1234567890123456; do
    run normalize_phone "$bad"
    [ "$status" -eq 2 ] || { echo "accepted: '$bad'"; return 1; }
  done
}

@test "normalize_phone_list normalizes each entry and skips blanks" {
  [ "$(normalize_phone_list '+31 6 1234 5678, ,0049 151 1234 5678')" = 31612345678,4915112345678 ]
  [ "$(normalize_phone_list '')" = "" ]
}

@test "normalize_phone_list fails on one bad entry" {
  run normalize_phone_list '31612345678,0612345678'
  [ "$status" -eq 2 ]
}

# --- parse_flags / flag -------------------------------------------------------------

@test "parse_flags reads --key value, --key=value and bare switches" {
  parse_flags deploy --ssh-key ~/.ssh/k --access=public --json root@1.2.3.4
  [ "$(flag ssh-key)" = ~/.ssh/k ]
  [ "$(flag access)" = public ]
  [ "$(flag json)" = 1 ]
  [ "${POSITIONAL[*]}" = "deploy root@1.2.3.4" ]
}

@test "parse_flags stops at --" {
  parse_flags --json -- --not-a-flag x
  [ "$(flag json)" = 1 ]
  [ "$(flag not-a-flag)" = "" ]
  [ "${POSITIONAL[*]}" = "--not-a-flag x" ]
}

@test "a switch followed by another flag does not swallow it" {
  parse_flags --force --to v0.1.2
  [ "$(flag force)" = 1 ]
  [ "$(flag to)" = v0.1.2 ]
}

# --- value: never prompts without a terminal ----------------------------------------

@test "value uses the flag, else the default, and never reads stdin without a tty" {
  parse_flags --access public
  [ "$(value access 'Access' tailscale </dev/null)" = public ]
  parse_flags
  [ "$(echo typed | value access 'Access' tailscale)" = tailscale ]
}

# --- env files ---------------------------------------------------------------------------

@test "env_set replaces an existing key and appends a new one" {
  ENV_FILE="$BATS_TEST_TMPDIR/.env"
  printf 'A=1\nB=2\n' > "$ENV_FILE"
  env_set A 9
  env_set C 3
  [ "$(cat "$ENV_FILE")" = "$(printf 'A=9\nB=2\nC=3')" ]
  [ "$(env_get A)" = 9 ]
  [ ! -e "$ENV_FILE.bak" ]
}

@test "has_module matches whole module names only" {
  ENV_FILE="$BATS_TEST_TMPDIR/.env"
  printf 'COMPOSE_PROFILES=sync,browser\n' > "$ENV_FILE"
  has_module browser
  ! has_module whatsapp
  ! has_module brows
}

# --- with_timeout ------------------------------------------------------------------------

@test "with_timeout kills a command that runs too long" {
  run with_timeout 1 sleep 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"no answer from the server within 1s"* ]]
}

@test "with_timeout passes the exit code of a fast command" {
  run with_timeout 5 sh -c 'exit 4'
  [ "$status" -eq 4 ]
}
