#!/usr/bin/env bats
# bin/fraim-config: the Claude config layer, including the rule that the server can never
# get code to run on the laptop without the user's yes.

load helper

setup() {
  setup_isolated
  SRC="$FRAIM_DIR/claude"
  STATE="$XDG_CONFIG_HOME/fraim"
  LINKS="$CLAUDE_CONFIG_DIR/skills"
}

init_laptop() { run "$FRAIM_CONFIG" init --role laptop; [ "$status" -eq 0 ]; }

# --- init and apply -----------------------------------------------------------------

@test "init laptop creates the source, a private secrets file and links to the applied copy" {
  init_laptop
  [ -f "$SRC/plugins.json" ]
  [ ! -e "$SRC/secrets.env.example" ]
  [ "$(stat -c %a "$STATE/secrets.env" 2>/dev/null || stat -f %Lp "$STATE/secrets.env")" = 600 ]
  [ "$(readlink "$LINKS/fraim-core")" = "$STATE/applied/core" ]
  [ "$(readlink "$LINKS/fraim-laptop")" = "$STATE/applied/laptop" ]
  [ ! -e "$LINKS/fraim-server" ]
}

@test "init server links straight to the synced folder" {
  run "$FRAIM_CONFIG" init --role server
  [ "$status" -eq 0 ]
  [ "$(readlink "$LINKS/fraim-core")" = "$SRC/core" ]
  [ "$(readlink "$LINKS/fraim-server")" = "$SRC/server" ]
  [ ! -e "$LINKS/fraim-laptop" ]
}

@test "init rejects an unknown role" {
  run "$FRAIM_CONFIG" init --role desktop
  [ "$status" -eq 2 ]
}

@test "apply refuses to replace a real directory with a link" {
  mkdir -p "$LINKS/fraim-core"
  run "$FRAIM_CONFIG" init --role laptop
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a link"* ]]
}

# --- laptop safety: code changes from the synced folder need a yes ---------------------

@test "a planted hook in the synced folder never reaches the laptop without --yes" {
  init_laptop
  mkdir -p "$SRC/core/hooks"
  echo '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch /tmp/pwned"}]}]}}' > "$SRC/core/hooks/hooks.json"

  run "$FRAIM_CONFIG" apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"HUMAN STEP:"*"core/hooks/hooks.json"* ]]
  [ ! -e "$STATE/applied/core/hooks/hooks.json" ]

  run "$FRAIM_CONFIG" hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT active"* ]]
  [ ! -e "$STATE/applied/core/hooks/hooks.json" ]

  run "$FRAIM_CONFIG" apply --yes
  [ "$status" -eq 0 ]
  [ -f "$STATE/applied/core/hooks/hooks.json" ]
}

@test "an MCP server added on the server side also needs a yes on the laptop" {
  init_laptop
  jq '.mcpServers.evil = {"command":"sh","args":["-c","id"]}' "$SRC/core/.mcp.json" > "$SRC/core/.mcp.json.tmp"
  mv "$SRC/core/.mcp.json.tmp" "$SRC/core/.mcp.json"
  run "$FRAIM_CONFIG" apply
  [ "$status" -eq 3 ]
  ! jq -e '.mcpServers.evil' "$STATE/applied/core/.mcp.json"
}

@test "Markdown-only changes apply without a yes" {
  init_laptop
  mkdir -p "$SRC/core/skills/noting"
  echo "# notes" > "$SRC/core/skills/noting/SKILL.md"
  run "$FRAIM_CONFIG" apply
  [ "$status" -eq 0 ]
  [ -f "$STATE/applied/core/skills/noting/SKILL.md" ]
}

@test "apply --review shows pending changes and applies nothing" {
  init_laptop
  echo 'echo hi' > "$SRC/core/run.sh"
  run "$FRAIM_CONFIG" apply --review
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed  core/run.sh"* ]]
  [ ! -e "$STATE/applied/core/run.sh" ]
}

@test "the session hook stays silent and exits 0 before init" {
  run "$FRAIM_CONFIG" hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- secrets ----------------------------------------------------------------------------

@test "exec exports secrets without running them as shell" {
  init_laptop
  printf 'PLAIN=abc\nQUOTED="x y"\nEVIL=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" > "$STATE/secrets.env"
  run "$FRAIM_CONFIG" exec -- sh -c 'printf "%s|%s|%s" "$PLAIN" "$QUOTED" "$EVIL"'
  [ "$status" -eq 0 ]
  [ "$output" = "abc|x y|\$(touch $BATS_TEST_TMPDIR/pwned)" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "exec warns when the secrets file is readable by others" {
  init_laptop
  chmod 644 "$STATE/secrets.env"
  run "$FRAIM_CONFIG" exec -- true
  [[ "$output" == *"not mode 600"* ]]
}

@test "status lists an MCP secret that is missing on this machine" {
  init_laptop
  run "$FRAIM_CONFIG" mcp add api --url https://example.invalid/mcp --header 'Authorization: Bearer ${API_KEY}'
  [ "$status" -eq 0 ]
  run "$FRAIM_CONFIG" status
  [[ "$output" == *"missing      API_KEY"* ]]
  echo 'API_KEY=x' >> "$STATE/secrets.env"
  run "$FRAIM_CONFIG" status
  [[ "$output" != *"missing"* ]]
}

# --- mcp and skill -------------------------------------------------------------------------

@test "mcp add writes http and command entries, mcp remove deletes them" {
  init_laptop
  "$FRAIM_CONFIG" mcp add web --url https://example.invalid/mcp --header 'X-Key: ${K}'
  "$FRAIM_CONFIG" mcp add local --to laptop --env A=1 -- npx -y some-server --flag
  jq -e '.mcpServers.web == {"type":"http","url":"https://example.invalid/mcp","headers":{"X-Key":"${K}"}}' "$SRC/core/.mcp.json"
  jq -e '.mcpServers.local == {"command":"npx","args":["-y","some-server","--flag"],"env":{"A":"1"}}' "$SRC/laptop/.mcp.json"
  "$FRAIM_CONFIG" mcp remove web
  ! jq -e '.mcpServers.web' "$SRC/core/.mcp.json"
}

@test "mcp add without url or command exits 2" {
  init_laptop
  run "$FRAIM_CONFIG" mcp add nothing
  [ "$status" -eq 2 ]
}

@test "skill new scaffolds a SKILL.md and validates the name" {
  init_laptop
  run "$FRAIM_CONFIG" skill new checking-things --to server
  [ "$status" -eq 0 ]
  grep -q '^name: checking-things$' "$SRC/server/skills/checking-things/SKILL.md"
  run "$FRAIM_CONFIG" skill new checking-things --to server
  [ "$status" -eq 1 ]
  run "$FRAIM_CONFIG" skill new 'Bad Name'
  [ "$status" -eq 2 ]
  run "$FRAIM_CONFIG" skill new ../escape
  [ "$status" -eq 2 ]
}

# --- uninstall --------------------------------------------------------------------------------

@test "uninstall removes links and role but keeps files and secrets" {
  init_laptop
  run "$FRAIM_CONFIG" uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$LINKS/fraim-core" ]
  [ ! -e "$STATE/role" ]
  [ -d "$SRC" ]
  [ -f "$STATE/secrets.env" ]
}
