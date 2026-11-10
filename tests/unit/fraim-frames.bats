#!/usr/bin/env bats
# fraim-frames: runs the frame reader on one video file.

setup() {
  export FAKE="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE"
  export FRAIM_WHISPER_PYTHON="$FAKE/engine"
  export FRAIM_FRAMES_SCRIPT="$BATS_TEST_TMPDIR/frames.py"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/fraim/inbox"
  VIDEO="$HOME/fraim/inbox/v.mp4"
  echo x > "$VIDEO"
  cat > "$FAKE/engine" <<EOF
#!/bin/sh
echo "\$2.frame.jpg"
exit \${FAKE_ENGINE_EXIT:-0}
EOF
  chmod +x "$FAKE/engine"
  CMD="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-frames"
}

@test "prints the frames of the video" {
  run "$CMD" "$VIDEO"
  [ "$status" -eq 0 ]
  [ "$output" = "$VIDEO.frame.jpg" ]
}

@test "accepts the ~/fraim path the gateway writes" {
  run "$CMD" '~/fraim/inbox/v.mp4'
  [ "$status" -eq 0 ]
  [ "$output" = "$VIDEO.frame.jpg" ]
}

@test "a missing file fails" {
  run "$CMD" "$HOME/fraim/inbox/gone.mp4"
  [ "$status" -eq 1 ]
}

@test "no file is a usage error" {
  run "$CMD"
  [ "$status" -eq 2 ]
}

@test "a reader failure is a failure" {
  FAKE_ENGINE_EXIT=3 run "$CMD" "$VIDEO"
  [ "$status" -eq 3 ]
}
