#!/usr/bin/env bats
# The WhatsApp channel prompt of main, and the repair when WhatsApp cannot reach Claude.

setup() {
  HERDR="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-herdr"
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$T/bin" "$T/home/.config/fraim" "$T/hc"
  export HOME="$T/home" HC_FAKE="$T/hc" SENT="$T/sent" GATEWAY_STATUS="$T/status"
  cp "$BATS_TEST_DIRNAME/fakes/hc" "$T/bin/hc"
  printf '#!/usr/bin/env bash\nprintf "notify %%s\\n" "$*" >> "$SENT"\n' > "$T/bin/fraim-notify"
  printf '#!/usr/bin/env bash\ncat "$GATEWAY_STATUS"\n' > "$T/bin/fraim-gateway"
  chmod +x "$T/bin/hc" "$T/bin/fraim-notify" "$T/bin/fraim-gateway"
  printf 'FRAIM_MODULES=whatsapp\n' > "$T/runtime.env"
  echo token > "$HOME/.config/fraim/claude-token"
  echo '{"connected":true,"listeners":0,"queued":2}' > "$GATEWAY_STATUS"
  export PATH="$T/bin:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env" FRAIM_HEAL_MISSES=2 FRAIM_HEAL_RESTARTS=1
  hc run --bg --name main --label fraim=main -- fraim-session >/dev/null
  PROMPT=$'  Channels: server:whatsapp\n\n  ❯ 1. I am using this for local development\n    2. Exit\n\n  Enter to confirm · Esc to cancel'
}

listeners() { jq -n --argjson n "$1" '{connected:true,listeners:$n,queued:0}' > "$GATEWAY_STATUS"; }
main_state() { jq -r '.state' "$HC_FAKE/t-main.json"; }

@test "a prompt at the bottom of the screen gets Enter" {
  FAKE_SCREEN="$PROMPT" run "$HERDR" confirm-channel --once
  [ "$status" -eq 0 ]
  grep -qx enter "$HC_FAKE/main.keys"
}

@test "an old prompt higher on the screen gets no Enter" {
  FAKE_SCREEN="$PROMPT"$'\nfraim: Claude stopped.\n\n  > \n  bypass permissions on\n  status\n  line\n  more\n' run "$HERDR" confirm-channel --once
  [ "$status" -eq 0 ]
  [ ! -f "$HC_FAKE/main.keys" ]
}

@test "main restarts only after several checks without a listener" {
  "$HERDR" heal
  [ "$(main_state)" = live ]
  "$HERDR" heal
  [ "$(main_state)" = finished ]
}

@test "a listener clears the count" {
  "$HERDR" heal
  listeners 1
  "$HERDR" heal
  listeners 0
  "$HERDR" heal
  [ "$(main_state)" = live ]
}

@test "a working main is not restarted" {
  jq '.status.state = "working"' "$HC_FAKE/t-main.json" > "$T/m"
  mv "$T/m" "$HC_FAKE/t-main.json"
  "$HERDR" heal
  "$HERDR" heal
  "$HERDR" heal
  [ "$(main_state)" = live ]
}

@test "before the Claude login nothing restarts" {
  rm "$HOME/.config/fraim/claude-token"
  "$HERDR" heal
  "$HERDR" heal
  [ "$(main_state)" = live ]
}

@test "an older gateway without the count changes nothing" {
  echo '{"connected":true}' > "$GATEWAY_STATUS"
  "$HERDR" heal
  "$HERDR" heal
  [ "$(main_state)" = live ]
}

@test "after the last failed restart the owner hears it once" {
  "$HERDR" heal
  "$HERDR" heal
  hc rm main
  hc run --bg --name main --label fraim=main -- fraim-session >/dev/null
  "$HERDR" heal
  "$HERDR" heal
  "$HERDR" heal
  "$HERDR" heal
  [ "$(main_state)" = live ]
  [ "$(grep -c 'does not receive WhatsApp' "$SENT")" -eq 1 ]
}
