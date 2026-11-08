#!/usr/bin/env bats
# workspace/bin/fraim-session-command with a fake tmux: only allowed commands, typed only
# once the session is idle, confirmation on WhatsApp.

setup() {
  CMD="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-session-command"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  export KEYS="$T/keys" SCREEN="$T/screen" SENT="$T/sent"
  printf '> \n' > "$SCREEN"
  cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) [ -z "${NO_SESSION:-}" ] ;;
  capture-pane) cat "$SCREEN" ;;
  send-keys)
    shift 3; [ "$1" = -l ] && shift 2; printf '%s\n' "$*" >> "$KEYS"
    # DIALOG=1: the first Enter opens a "Switch model?" menu, the next Enter closes it.
    if [ "$*" = Enter ] && [ -n "${DIALOG:-}" ]; then
      if grep -q 'Switch model' "$SCREEN"; then printf '> \n' > "$SCREEN"; else printf 'Switch model?\n  \xe2\x9d\xaf 1. Yes, switch\n    2. No\n' > "$SCREEN"; fi
    fi ;;
esac
EOF
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$SENT"
EOF
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=whatsapp\n' > "$T/runtime.env"
  export PATH="$T/bin:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env" FRAIM_SESSION_FOREGROUND=1
}

@test "clear types /clear and Enter, then confirms on the chat" {
  run "$CMD" --chat 316@s.whatsapp.net clear
  [ "$status" -eq 0 ]
  [ "$(cat "$KEYS")" = "$(printf '/clear\nEnter')" ]
  grep -q '"text":"Done: /clear"' "$SENT"
}

@test "model accepts only known names" {
  run "$CMD" model opus
  [ "$status" -eq 0 ]
  grep -qx '/model opus' "$KEYS"
  run "$CMD" model 'opus; rm -rf ~'
  [ "$status" -eq 2 ]
  run "$CMD" model
  [ "$status" -eq 2 ]
}

@test "a Switch model? menu gets Yes" {
  DIALOG=1 run "$CMD" model sonnet
  [ "$status" -eq 0 ]
  [ "$(cat "$KEYS")" = "$(printf '/model sonnet\nEnter\nEnter')" ]
  ! grep -q 'Switch model' "$SCREEN"
}

@test "compact focus loses newlines and control characters" {
  run "$CMD" compact "$(printf 'keep the flights\n/login\tnow')"
  [ "$status" -eq 0 ]
  grep -qx '/compact keep the flights /login now' "$KEYS"
}

@test "other commands are refused" {
  for c in login logout config 'clear now' ''; do
    run "$CMD" $c
    [ "$status" -eq 2 ]
  done
  [ ! -s "$KEYS" ]
}

@test "waits while Claude is busy and gives up after the limit" {
  printf '* Thinking... (esc to interrupt)\n' > "$SCREEN"
  FRAIM_SESSION_WAIT=2 run "$CMD" --chat c@s clear
  [ "$status" -eq 1 ]
  [ ! -s "$KEYS" ]
  grep -q 'could not run /clear' "$SENT"
}

@test "background mode returns at once" {
  unset FRAIM_SESSION_FOREGROUND
  run "$CMD" clear
  [ "$status" -eq 0 ]
  [[ "$output" == "Queued: /clear"* ]]
}

@test "no session is an error" {
  NO_SESSION=1 run "$CMD" clear
  [ "$status" -eq 1 ]
}
