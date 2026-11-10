#!/usr/bin/env bats
# fraim-transcribe: asks for memory first, then runs the speech engine on one audio file.

setup() {
  export FAKE="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE"
  export PATH="$FAKE:$PATH"
  export FRAIM_RUNTIME_ENV=/dev/null
  export FRAIM_WHISPER_PYTHON="$FAKE/engine"
  export FRAIM_WHISPER_SCRIPT="$BATS_TEST_TMPDIR/transcribe.py"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/fraim/inbox"
  AUDIO="$HOME/fraim/inbox/memo.ogg"
  echo x > "$AUDIO"
  cat > "$FAKE/fraim-capacity" <<EOF
#!/bin/sh
echo "\$*" > "$BATS_TEST_TMPDIR/capacity"
exit \${FAKE_CAPACITY_EXIT:-0}
EOF
  cat > "$FAKE/engine" <<EOF
#!/bin/sh
echo "\$2" > "$BATS_TEST_TMPDIR/engine-file"
echo "bel de drukker"
exit \${FAKE_ENGINE_EXIT:-0}
EOF
  chmod +x "$FAKE/fraim-capacity" "$FAKE/engine"
  CMD="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-transcribe"
}

@test "prints the words of the audio file" {
  run "$CMD" "$AUDIO"
  [ "$status" -eq 0 ]
  [ "$output" = "bel de drukker" ]
}

@test "accepts the ~/fraim path the gateway writes" {
  run "$CMD" '~/fraim/inbox/memo.ogg'
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/engine-file")" = "$AUDIO" ]
}

@test "asks for memory before it starts the engine" {
  run "$CMD" "$AUDIO"
  [ "$(cat "$BATS_TEST_TMPDIR/capacity")" = "wait --max 120" ]
}

@test "does not start the engine when the server has no room" {
  FAKE_CAPACITY_EXIT=1 run "$CMD" "$AUDIO"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/engine-file" ]
}

@test "a missing file fails" {
  run "$CMD" "$HOME/fraim/inbox/gone.ogg"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/engine-file" ]
}

@test "no file is a usage error" {
  run "$CMD"
  [ "$status" -eq 2 ]
}

@test "an engine failure is a failure" {
  FAKE_ENGINE_EXIT=3 run "$CMD" "$AUDIO"
  [ "$status" -eq 3 ]
}
