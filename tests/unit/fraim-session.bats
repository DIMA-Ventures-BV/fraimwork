#!/usr/bin/env bats
# workspace/bin/fraim-session: main loads the Claude Code channel of every module that is on,
# as its manifest declares it, and nothing for a module that is off.

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim" "$T/modules"
  cp "$BATS_TEST_DIRNAME/../../modules/"*.manifest "$T/modules/"
  # A fake Claude that records its arguments, then ends the session loop.
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGS"
kill "$PPID"
EOF
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$T/bin/fraim-herdr"
  chmod +x "$T/bin/"*
  export HOME="$T/home" ARGS="$T/args" FRAIM_MODULES_DIR="$T/modules" PATH="$T/bin:$PATH"
}

@test "with WhatsApp on, main loads its channel" {
  FRAIM_MODULES=browser,whatsapp run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-session"
  [ "$(head -1 "$ARGS")" = "--continue --dangerously-load-development-channels server:whatsapp" ]
}

@test "a new module brings its own channel with no engine change" {
  printf 'id: telegram\nclaude-channel: server:telegram\n' > "$T/modules/telegram.manifest"
  FRAIM_MODULES=whatsapp,telegram run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-session"
  [ "$(head -1 "$ARGS")" = "--continue --dangerously-load-development-channels server:whatsapp --dangerously-load-development-channels server:telegram" ]
}

@test "with no channel module, main loads no channel" {
  FRAIM_MODULES=browser,scheduler run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-session"
  [ "$(head -1 "$ARGS")" = "--continue" ]
}
