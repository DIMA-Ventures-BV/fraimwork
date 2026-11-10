#!/usr/bin/env bats
# workspace/bin/fraim-tty with a fake hc: a sign-in runs in its own herdr terminal, the code
# comes from stdin, and a run without the owner cannot drive it.

setup() {
  TTY="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-tty"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  cp "$BATS_TEST_DIRNAME/fakes/hc" "$T/bin/hc"
  export HC_FAKE="$T/hc" FRAIM_RUNTIME_ENV=/dev/null
  export PATH="$T/bin:$BATS_TEST_DIRNAME/../../workspace/bin:$PATH"
}

@test "start runs the command in tty-NAME and prints the sign-in link" {
  export FAKE_SCREEN='Open https://claude.ai/oauth/authorize?code=abc to sign in'
  run "$TTY" start login -- claude auth login
  [ "$status" -eq 0 ]
  [ "$output" = 'https://claude.ai/oauth/authorize?code=abc' ]
  [ "$(jq -r '.labels.fraim' "$HC_FAKE/t-tty-login.json")" = signin ]
  grep -q 'claude auth login' "$HC_FAKE/tty-login.argv"
}

@test "start fails when the command ends without a link" {
  export FAKE_SCREEN='error: offline
[fraim-tty: finished]'
  run "$TTY" start login -- claude auth login
  [ "$status" -eq 1 ]
  [[ "$output" == *"without showing a sign-in link"* ]]
}

@test "send types one line from stdin, and only into a live sign-in" {
  export FAKE_SCREEN='https://x.example/a'
  "$TTY" start login -- claude auth login
  run bash -c "printf 'CODE-123\r\n' | '$TTY' send login"
  [ "$status" -eq 0 ]
  [ "$(head -1 "$HC_FAKE/tty-login.sent")" = CODE-123 ]
  "$TTY" stop login
  run bash -c "echo X | '$TTY' send login"
  [ "$status" -eq 1 ]
}

@test "wait matches the screen; show prints it" {
  export FAKE_SCREEN='https://x.example/a'
  "$TTY" start mcp-sentry -- claude mcp login sentry
  export FAKE_SCREEN='Authenticated. Done.'
  run "$TTY" wait mcp-sentry 'success|authenticated' 2
  [ "$status" -eq 0 ]
  run "$TTY" wait mcp-sentry 'nope' 1
  [ "$status" -eq 1 ]
  run "$TTY" show mcp-sentry
  [ "$output" = 'Authenticated. Done.' ]
}

@test "a run without the owner cannot type into a sign-in" {
  export FAKE_SCREEN='https://x.example/a'
  "$TTY" start login -- claude auth login
  run bash -c "echo CODE | FRAIM_HEADLESS=1 '$TTY' send login"
  [ "$status" -ne 0 ]
  [ ! -e "$HC_FAKE/tty-login.sent" ]
}

@test "bad names are usage errors" {
  run "$TTY" start 'Bad Name' -- true
  [ "$status" -eq 2 ]
  run "$TTY" nonsense login
  [ "$status" -eq 2 ]
}
