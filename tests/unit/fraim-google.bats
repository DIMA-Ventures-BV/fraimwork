#!/usr/bin/env bats
# fraim google: Gmail, Drive and Calendar as an MCP server in the space's own google
# container. The OAuth client and the sign-in address travel on stdin, never in a command.

load helper

setup() {
  setup_isolated
  use_public_target
  CLIENT_FILE="$BATS_TEST_TMPDIR/client_secret.json"
  printf '%s' '{"installed":{"client_id":"1-x.apps.googleusercontent.com","client_secret":"GOCSPX-test-4711"}}' > "$CLIENT_FILE"
}

@test "google setup enables the module, stores the client over stdin and registers the MCP server" {
  ssh_handler 'case "$REMOTE" in *"grep -E"*) printf "COMPOSE_PROFILES=browser,scheduler\n" ;; esac'
  run "$FRAIM" google setup --email me@example.com --file "$CLIENT_FILE"
  [ "$status" -eq 0 ]
  grep -qF 'COMPOSE_PROFILES' "$SSH_LOG"
  grep -qF 'browser\,scheduler\,google' "$SSH_LOG"
  grep -qF 'docker compose up -d --build google' "$SSH_LOG"
  grep -qF 'exec -T google fraim-google set-client me@example.com' "$SSH_LOG"
  grep -qF 'fraim-connect internal google http://google:8000/mcp' "$SSH_LOG"
  grep -qF 'GOCSPX-test-4711' "$SSH_STDIN_LOG"
  ! grep -qF 'GOCSPX-test-4711' "$SSH_LOG"
  [[ "$output" == *"fraim google code"* ]]
}

@test "google setup keeps the module list when google is already on" {
  ssh_handler 'case "$REMOTE" in *"grep -E"*) printf "COMPOSE_PROFILES=google,browser\n" ;; esac'
  run "$FRAIM" google setup --email me@example.com --file "$CLIENT_FILE"
  [ "$status" -eq 0 ]
  ! grep -qF 'google\,browser\,google' "$SSH_LOG"
}

@test "google setup needs an email and a client file" {
  run "$FRAIM" google setup --file "$CLIENT_FILE"
  [ "$status" -eq 2 ]
  run "$FRAIM" google setup --email me@example.com
  [ "$status" -eq 2 ]
  run "$FRAIM" google setup --email me@example.com --file "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 1 ]
}

@test "google code without a terminal hands the human the command" {
  run "$FRAIM" google code </dev/null
  [ "$status" -eq 3 ]
  [[ "$output" == *"fraim google code"* ]]
}

@test "google code sends the address over stdin only" {
  run "$FRAIM" google code --stdin <<<'http://localhost:8000/oauth2callback?state=s&code=4/secret-code'
  [ "$status" -eq 0 ]
  grep -qF 'exec -T google fraim-google callback' "$SSH_LOG"
  grep -qF '4/secret-code' "$SSH_STDIN_LOG"
  ! grep -qF '4/secret-code' "$SSH_LOG"
}

@test "connect refuses the name google" {
  run "$FRAIM" connect google --url https://example.com/mcp
  [ "$status" -eq 2 ]
}

@test "google push sends the key over stdin only" {
  KEY_FILE="$BATS_TEST_TMPDIR/key.json"
  printf '%s' '{"type":"service_account","private_key":"PRIVATE-4711"}' > "$KEY_FILE"
  run "$FRAIM" google push --topic projects/p/topics/t --subscription projects/p/subscriptions/s --file "$KEY_FILE"
  [ "$status" -eq 0 ]
  grep -qF 'fraim-google set-push projects/p/topics/t projects/p/subscriptions/s' "$SSH_LOG"
  grep -qF 'PRIVATE-4711' "$SSH_STDIN_LOG"
  ! grep -qF 'PRIVATE-4711' "$SSH_LOG"
}

@test "google push needs a topic, a subscription and a key" {
  run "$FRAIM" google push --subscription projects/p/subscriptions/s --file /dev/null
  [ "$status" -eq 2 ]
  run "$FRAIM" google push --topic projects/p/topics/t --subscription projects/p/subscriptions/s
  [ "$status" -eq 2 ]
}

@test "google push --off goes back to checking" {
  run "$FRAIM" google push --off
  [ "$status" -eq 0 ]
  grep -qF 'fraim-google clear-push' "$SSH_LOG"
}
