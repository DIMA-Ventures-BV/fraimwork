#!/usr/bin/env bats
# Voice is 622 MB in the image, and only useful with WhatsApp.

setup() {
  ROOT="$BATS_TEST_DIRNAME/../.."
  export FRAIM_RUNTIME_ENV=/dev/null HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/fraim/inbox"
  echo x > "$HOME/fraim/inbox/memo.ogg"
}

@test "a server without voice says so and fails like any failed transcript" {
  FRAIM_WHISPER_MODEL_DIR="$BATS_TEST_TMPDIR/none" run "$ROOT/workspace/bin/fraim-transcribe" "$HOME/fraim/inbox/memo.ogg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"voice is not installed"* ]]
}

@test "the image only gets the speech engine with VOICE=on, and pictures always work" {
  grep -q '^ARG VOICE=on' "$ROOT/workspace/Dockerfile"
  grep -q 'if \[ "${VOICE}" = on \]' "$ROOT/workspace/Dockerfile"
  grep -q 'pillow==' "$ROOT/workspace/Dockerfile"
}

@test "compose passes the setting to the build, on by default for existing servers" {
  grep -q 'VOICE: ${VOICE:-on}' "$ROOT/compose.yaml"
}

@test "voice is a server-wide setting: every space shares one image" {
  grep -q 'for key in .*VOICE' "$ROOT/install.sh"
  grep -q "|VOICE|\||VOICE'" "$ROOT/bin/fraim.d/space.sh"
}

@test "install.sh turns voice on when any space uses WhatsApp" {
  grep -q "grep -qs '^COMPOSE_PROFILES=.*whatsapp' .env .env.space-\*" "$ROOT/install.sh"
}
