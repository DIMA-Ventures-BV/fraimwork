#!/usr/bin/env bats
# workspace/bin/fraim-session-command with a fake hc: only allowed commands, typed only
# once the session is not working, confirmation on WhatsApp.

setup() {
  CMD="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-session-command"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/hc"
  export SENT="$T/sent" HC_FAKE="$T/hc" FAKE_SEND_STATE=idle
  cp "$BATS_TEST_DIRNAME/fakes/hc" "$T/bin/hc"
  jq -n '{address: "main", name: "main", labels: {fraim: "main"}, state: "live", status: {state: "idle"}, turn: 3}' > "$T/hc/t-main.json"
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$SENT"
EOF
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=whatsapp\n' > "$T/runtime.env"
  export PATH="$T/bin:$BATS_TEST_DIRNAME/../../workspace/bin:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env" FRAIM_SESSION_FOREGROUND=1
}

sent() { sed -n '/^---$/!p' "$HC_FAKE/main.sent" 2>/dev/null; }

@test "clear sends /clear, then confirms on the chat" {
  run "$CMD" --chat 316@s.whatsapp.net clear
  [ "$status" -eq 0 ]
  [ "$(sent)" = /clear ]
  grep -q '"text":"Done: /clear"' "$SENT"
}

@test "model accepts only known names" {
  run "$CMD" model opus
  [ "$status" -eq 0 ]
  [ "$(sent)" = '/model opus' ]
  run "$CMD" model 'opus; rm -rf ~'
  [ "$status" -eq 2 ]
  run "$CMD" model
  [ "$status" -eq 2 ]
}

@test "a Switch model? menu gets Yes" {
  FAKE_SCREEN="$(printf 'Switch model?\n  \xe2\x9d\xaf 1. Yes, switch\n    2. No')" run "$CMD" model sonnet
  [ "$status" -eq 0 ]
  [ "$(sent)" = '/model sonnet' ]
  [ "$(cat "$HC_FAKE/main.keys")" = enter ]
}

@test "compact focus loses newlines and control characters" {
  run "$CMD" compact "$(printf 'keep the flights\n/login\tnow')"
  [ "$status" -eq 0 ]
  [ "$(sent)" = '/compact keep the flights /login now' ]
}

@test "other commands are refused" {
  for c in login logout config 'clear now' ''; do
    run "$CMD" $c
    [ "$status" -eq 2 ]
  done
  [ ! -s "$HC_FAKE/main.sent" ]
}

@test "waits while Claude is working and gives up after the limit" {
  jq '.status.state = "working"' "$T/hc/t-main.json" > "$T/m" && mv "$T/m" "$T/hc/t-main.json"
  FRAIM_SESSION_WAIT=2 run "$CMD" --chat c@s clear
  [ "$status" -eq 1 ]
  [ ! -s "$HC_FAKE/main.sent" ]
  grep -q 'could not run /clear' "$SENT"
}

@test "background mode returns at once" {
  unset FRAIM_SESSION_FOREGROUND
  run "$CMD" clear
  [ "$status" -eq 0 ]
  [[ "$output" == "Queued: /clear"* ]]
}

@test "no session is an error" {
  rm "$T/hc/t-main.json"
  run "$CMD" clear
  [ "$status" -eq 1 ]
}

@test "a run without the owner cannot type into main" {
  FRAIM_HEADLESS=1 run "$CMD" clear
  [ "$status" -eq 1 ]
  [ -z "$(sent)" ]
}
