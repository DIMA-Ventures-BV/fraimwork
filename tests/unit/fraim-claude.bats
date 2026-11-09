#!/usr/bin/env bats
# workspace/bin/fraim-claude: the permission mode every Claude on the server starts with.

setup() {
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home"
  cp "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-claude" "$T/bin/"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$T/bin/claude"
  chmod +x "$T/bin/"*
  export HOME="$T/home" PATH="$T/bin:/usr/bin:/bin"
  unset FRAIM_PERMISSIONS CLAUDE_CODE_OAUTH_TOKEN
}

@test "by default Claude starts without permission prompts" {
  [ -r /etc/fraim/runtime.env ] && skip "this machine has a real runtime.env"
  run fraim-claude -p "hi"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--dangerously-skip-permissions" ]
  [ "${lines[1]}" = "-p" ]
}

@test "PERMISSIONS=ask keeps the prompts and the allowed-tools limit" {
  [ -r /etc/fraim/runtime.env ] && skip "this machine has a real runtime.env"
  FRAIM_PERMISSIONS=ask run fraim-claude -p "hi"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
  [ "${lines[0]}" = "-p" ]
}
