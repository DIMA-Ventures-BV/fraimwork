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

@test "a headless run is marked, so owner-only commands refuse it; a chat session is not" {
  [ -r /etc/fraim/runtime.env ] && skip "this machine has a real runtime.env"
  printf '#!/usr/bin/env bash\necho "headless=${FRAIM_HEADLESS:-0}"\n' > "$T/bin/claude"
  unset FRAIM_HEADLESS
  run fraim-claude -p "hi"
  [ "$output" = "headless=1" ]
  run fraim-claude --dangerously-load-development-channels server:whatsapp
  [ "$output" = "headless=0" ]
}

@test "the owner's own chat message is not headless, and what it starts does not inherit that" {
  [ -r /etc/fraim/runtime.env ] && skip "this machine has a real runtime.env"
  printf '#!/usr/bin/env bash\necho "headless=${FRAIM_HEADLESS:-0} owner=${FRAIM_OWNER_CHAT:-none}"\n' > "$T/bin/claude"
  unset FRAIM_HEADLESS
  FRAIM_OWNER_CHAT=1 run fraim-claude -p "hi"
  [ "$output" = "headless=0 owner=none" ]
  FRAIM_HEADLESS=1 FRAIM_OWNER_CHAT=1 run fraim-claude -p "hi"
  [ "$output" = "headless=1 owner=none" ]
}

@test "every Claude gets the server prompt, and a run nobody watches may not edit prompts" {
  [ -r /etc/fraim/runtime.env ] && skip "this machine has a real runtime.env"
  printf '#!/usr/bin/env bash\necho "the server text"\n' > "$T/bin/fraim-prompt"
  chmod +x "$T/bin/fraim-prompt"
  unset FRAIM_HEADLESS
  run fraim-claude --continue
  [[ "$output" == *"--append-system-prompt-file"* ]]
  [[ "$output" != *"--disallowedTools"* ]]
  grep -q 'the server text' "$HOME/.local/state/fraim/server-prompt.md"
  run fraim-claude -p "hi"
  [[ "$output" == *"Edit(~/fraim/prompts/**)"* ]]
  [ "${lines[1]}" = "-p" ]
}

@test "the server rules never go missing: last copy first, then the shipped one" {
  [ -r /etc/fraim/runtime.env ] && skip "this machine has a real runtime.env"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/fraim-prompt"
  chmod +x "$T/bin/fraim-prompt"
  mkdir -p "$T/shipped"
  printf 'shipped rules\n' > "$T/shipped/server.md"
  export FRAIM_PROMPT_DEFAULTS="$T/shipped"
  run fraim-claude --continue
  [[ "$output" == *"$T/shipped/server.md"* ]]
  mkdir -p "$HOME/.local/state/fraim"
  printf 'last good\n' > "$HOME/.local/state/fraim/server-prompt.md"
  run fraim-claude --continue
  [[ "$output" == *"$HOME/.local/state/fraim/server-prompt.md"* ]]
}
