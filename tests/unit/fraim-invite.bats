#!/usr/bin/env bats
# fraim invite (the operator), fraim attach (the invited laptop, no root on the server),
# fraim mirror scan (names only) and the new mirror lines.

load helper

setup() {
  setup_isolated
  CONF="$XDG_CONFIG_HOME/fraim"
  TOKEN="$(printf 'a%.0s' {1..64})"
  HOSTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEHOSTKEY"
  # port_open needs a real listener; these tests only need the answer.
  cat > "$STUBS/nc" <<'EOF'
#!/usr/bin/env bash
exit "${NC_RC:-0}"
EOF
  chmod +x "$STUBS/nc"
}

make_invite() {  # [JQ_EDIT]
  local key='-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----\n'
  jq -n --arg key "$(printf '%b' "$key")" --arg token "$TOKEN" --arg known "$HOSTKEY" \
    '{v:1,name:"alice",host:"100.64.1.2",port:"2222",known:$known,token:$token,share:"https://login.tailscale.com/share/x",key:$key}' \
    | jq "${1:-.}" | base64 | tr -d '\n' | { printf 'fraim-invite-v1:'; cat; }
}

attached_laptop() {
  make_invite | "$FRAIM" attach --stdin
}

operator_target() {
  mkdir -p "$CONF"
  cat > "$CONF/config" <<EOF
FRAIM_HOST=fraim-alice
FRAIM_ADMIN=root@fraim-alice
FRAIM_ACCESS=tailscale
FRAIM_SSH_PORT=2222
FRAIM_SSH_KEY=
FRAIM_PUBLIC_HOST=
FRAIM_INSTANCE=local
EOF
  ssh_handler '
case "$REMOTE" in
  *"grep -E '"'"'^BIND_IP="*) echo 100.64.1.2 ;;
  *ssh_host_ed25519_key.pub*) echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEHOSTKEY root@x" ;;
esac'
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$STUBS/pbcopy"
  chmod +x "$STUBS/pbcopy"
}

# --- invite ------------------------------------------------------------------------------

@test "invite without a share link stops at the human step and changes nothing" {
  operator_target
  run "$FRAIM" invite alice
  [ "$status" -eq 3 ]
  [[ "$output" == *"HUMAN STEP"*"Share"* ]]
  ! grep -q gate-add "$SSH_LOG"
}

@test "invite refuses a server that is not on Tailscale" {
  use_public_target
  run "$FRAIM" invite alice --no-share
  [ "$status" -eq 1 ]
  [[ "$output" == *"only works for a server on Tailscale"* ]]
}

@test "invite stores only the token hash on the server and never prints the secrets" {
  operator_target
  run "$FRAIM" invite alice --share-url https://login.tailscale.com/share/x
  [ "$status" -eq 0 ]
  file="$CONF/invites/alice.invite"
  [ -n "$(find "$file" -perm 600)" ]
  json="$(cut -d: -f2- "$file" | base64 -d 2>/dev/null || cut -d: -f2- "$file" | base64 -D)"
  token="$(jq -r .token <<<"$json")"
  [[ "$output" != *"$token"* ]]
  [[ "$output" != *"PRIVATE KEY"* ]]
  ! grep -qF "$token" "$SSH_LOG"
  ! grep -qF "$token" "$SSH_STDIN_LOG"
  grep -q 'fraim-secret gate-add alice' "$SSH_LOG"
  grep -q 'fraim-invite-alice' "$SSH_STDIN_LOG"
  [ "$(jq -r .host <<<"$json")" = 100.64.1.2 ]
  [ "$(jq -r .known <<<"$json")" = "$HOSTKEY" ]
}

@test "revoke removes the key line and the gate" {
  operator_target
  run "$FRAIM" invite revoke alice
  [ "$status" -eq 0 ]
  grep -qF "fraim-invite-alice" "$SSH_LOG"
  grep -q 'fraim-secret gate-rm alice' "$SSH_LOG"
}

# --- attach ------------------------------------------------------------------------------

@test "attach stores key, token and pinned host key, with no admin login" {
  run attached_laptop
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connected to alice"* ]]
  grep -qx 'FRAIM_ADMIN=none' "$CONF/alice.config"
  grep -qx 'FRAIM_HOST=100.64.1.2' "$CONF/alice.config"
  [ "$(cat "$CONF/current")" = alice ]
  [ -n "$(find "$HOME/.ssh/fraim-alice" -perm 600)" ]
  [ "$(cat "$CONF/alice.gate")" = "$TOKEN" ]
  grep -qxF "[100.64.1.2]:2222 $HOSTKEY" "$HOME/.fraim/known_hosts-alice"
  [[ "$output" != *"$TOKEN"* ]]
}

@test "attach does not change the current target of a computer that has one" {
  mkdir -p "$CONF"
  echo other > "$CONF/current"
  run attached_laptop
  [ "$status" -eq 0 ]
  [ "$(cat "$CONF/current")" = other ]
}

@test "attach refuses to replace a server this computer manages" {
  mkdir -p "$CONF"
  printf 'FRAIM_ADMIN=root@x\nFRAIM_HOST=x\nFRAIM_ACCESS=tailscale\n' > "$CONF/alice.config"
  run attached_laptop
  [ "$status" -eq 1 ]
  [[ "$output" == *"already manages"* ]]
  grep -q 'FRAIM_ADMIN=root@x' "$CONF/alice.config"
}

@test "attach without Tailscale access stops at the human step with the share link, and --check continues" {
  export NC_RC=1
  run attached_laptop
  [ "$status" -eq 3 ]
  [[ "$output" == *"https://login.tailscale.com/share/x"* ]]
  [[ "$output" == *"fraim attach --check"* ]]
  export NC_RC=0
  run "$FRAIM" attach --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connected to alice"* ]]
}

@test "attach refuses bad invites" {
  run bash -c "printf 'hello' | '$FRAIM' attach --stdin"
  [ "$status" -eq 2 ]
  for edit in '.host="evil.example"' '.port="22;x"' '.name="../x"' '.token="short"' '.known="x"' '.share="https://evil.example/x"' '.key="x"'; do
    run bash -c "printf '%s' '$(make_invite "$edit")' | '$FRAIM' attach --stdin"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$CONF/alice.config" ]
}

# --- an attached laptop has no admin access ------------------------------------------------

@test "commands that need root explain that the operator does them" {
  attached_laptop
  run "$FRAIM" google status
  [ "$status" -eq 1 ]
  [[ "$output" == *"no admin access"* ]]
  ! grep -q 'root@' "$SSH_LOG"
}

@test "a key goes through the gate on stdin, never as an argument" {
  attached_laptop
  ssh_handler 'case "$REMOTE" in fraim-gate) echo "ok stored" ;; esac'
  run bash -c "printf 'sk-secret-value' | '$FRAIM' secret set openai --stdin"
  [ "$status" -eq 0 ]
  ! grep -qF sk-secret-value "$SSH_LOG"
  ! grep -qF "$TOKEN" "$SSH_LOG"
  grep -qF "$TOKEN" "$SSH_STDIN_LOG"
  grep -qF sk-secret-value "$SSH_STDIN_LOG"
  grep -qP '^set\topenai$' "$SSH_STDIN_LOG" 2>/dev/null || grep -q 'set.openai' "$SSH_STDIN_LOG"
}

@test "a refusal from the gate is a failure" {
  attached_laptop
  ssh_handler 'case "$REMOTE" in fraim-gate) echo "error refused" ;; esac'
  run bash -c "printf 'x' | '$FRAIM' secret set openai --stdin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"* ]]
}

@test "repo add on an attached laptop asks the gate for the GitHub key" {
  attached_laptop
  ssh_handler 'case "$REMOTE" in fraim-gate) echo "ok yes" ;; esac'
  run "$FRAIM" repo add acme/app
  [ "$status" -eq 0 ]
  grep -q 'fraim-repo add acme/app' "$SSH_LOG"
  ! grep -q 'root@' "$SSH_LOG"
}

@test "status on an attached laptop skips the admin part" {
  attached_laptop
  run "$FRAIM" status
  [[ "$output" != *"no admin access"* ]]
  grep -q fraim-doctor "$SSH_LOG"
}

# --- scan --------------------------------------------------------------------------------

fake_claude_setup() {
  mkdir -p "$HOME/.claude/skills/my-skill" "$HOME/.claude/commands" "$HOME/.claude/plugins"
  echo "# me" > "$HOME/.claude/CLAUDE.md"
  echo x > "$HOME/.claude/skills/my-skill/SKILL.md"
  echo x > "$HOME/.claude/commands/go.md"
  cat > "$HOME/.claude.json" <<'EOF'
{"mcpServers":{
 "linear":{"type":"http","url":"https://mcp.linear.app/mcp"},
 "posthog":{"type":"http","url":"https://mcp.posthog.com/mcp","headers":{"Authorization":"Bearer phx_literalsecretvalue123"}},
 "byenv":{"type":"http","url":"https://a.example/mcp","headers":{"x-api-key":"${A_KEY}"}},
 "prodapi":{"type":"http","url":"https://b.example/mcp","headers":{"Authorization":"Bearer ${STRIPE_LIVE_KEY}"}},
 "zapier":{"type":"http","url":"https://hooks.example/s/abc123def456ghi789jkl012mno/mcp"},
 "query":{"type":"http","url":"https://c.example/mcp?api_key=hidden"},
 "tool":{"command":"npx","args":["-y","some-mcp@1.2.3"],"env":{"TOOL_KEY":"tool-secret-value"}},
 "local":{"command":"/usr/local/bin/thing","args":[]},
 "flagged":{"command":"npx","args":["-y","x","--api-key=hunter2"]},
 "github":{"type":"http","url":"https://api.githubcopilot.com/mcp"}
},"projects":{"/p":{"mcpServers":{"onlyhere":{"command":"x"}}}}}
EOF
  cat > "$HOME/.claude/plugins/installed_plugins.json" <<'EOF'
{"plugins":{"good@market":[],"fraim@fraimwork":[],"lost@localdir":[]}}
EOF
  cat > "$HOME/.claude/plugins/known_marketplaces.json" <<'EOF'
{"market":{"source":{"source":"github","repo":"acme/market"}},"localdir":{"source":{"source":"directory","path":"/x"}}}
EOF
  mkdir -p "$HOME/.ssh" "$HOME/projects/app"
  printf 'Host prod.box\n  HostName 1.2.3.4\nHost *\n  User me\nHost github.com\n  User git\n' > "$HOME/.ssh/config"
  git -C "$HOME/projects/app" init -q
  git -C "$HOME/projects/app" remote add origin git@github.com:acme/app.git
  echo token > "$HOME/.npmrc"
}

scan_output() {
  run env -u CLAUDE_CONFIG_DIR MY_API_KEY=envsecret123 PROD_DB_TOKEN=x bash -c "'$REPO/bin/fraim-scan'"
  [ "$status" -eq 0 ]
}

@test "scan never writes a value" {
  fake_claude_setup
  scan_output
  [[ "$output" != *"phx_literalsecretvalue123"* ]]
  [[ "$output" != *"tool-secret-value"* ]]
  [[ "$output" != *"hunter2"* ]]
  [[ "$output" != *"envsecret123"* ]]
  [[ "$output" != *"api_key=hidden"* ]]
  [[ "$output" != *"abc123def456ghi789jkl012mno"* ]]
}

@test "scan turns each kind of connection into the right line" {
  fake_claude_setup
  scan_output
  [[ "$output" == *$'\n'"connect linear https://mcp.linear.app/mcp oauth"* ]]
  [[ "$output" == *$'\n'"connect posthog https://mcp.posthog.com/mcp claudekey Authorization"* ]]
  [[ "$output" == *$'\n'"connect byenv https://a.example/mcp key A_KEY x-api-key %s"* ]]
  [[ "$output" == *$'\n'"stdio tool npx -y some-mcp@1.2.3"* ]]
  [[ "$output" == *$'\n'"#ask: mcpenv tool TOOL_KEY"* ]]
  [[ "$output" == *$'\n'"plugin https://github.com/acme/market.git good@market"* ]]
  [[ "$output" == *"claude CLAUDE.md"* ]]
  [[ "$output" == *"claude skills/my-skill"* ]]
  [[ "$output" == *"claude commands/go.md"* ]]
}

@test "scan keeps keys, repos and hosts off until someone says yes" {
  fake_claude_setup
  scan_output
  [[ "$output" == *"#ask: env MY_API_KEY"* ]]
  [[ "$output" == *"#ask: repo acme/app"* ]]
  [[ "$output" == *"#ask: host prod-box prod.box"* ]]
  [[ "$output" == *"#ask: file .npmrc"* ]]
  [[ "$output" == *"#ask: connect prodapi"* ]]
  [[ "$output" != *"host github-com"* ]]
}

@test "scan names what needs a person, and leaves out fraim itself" {
  fake_claude_setup
  scan_output
  [[ "$output" == *"# manual: MCP server zapier"* ]]
  [[ "$output" == *"# manual: MCP server query"* ]]
  [[ "$output" == *"# manual: MCP server local"* ]]
  [[ "$output" == *"# manual: MCP server flagged"* ]]
  [[ "$output" == *"# manual: MCP server github"* ]]
  [[ "$output" == *"# manual: MCP server onlyhere"* ]]
  [[ "$output" == *"# manual: plugin lost@localdir"* ]]
  [[ "$output" != *"fraim@fraimwork"* ]]
}

@test "a scan file is accepted by mirror as it is" {
  fake_claude_setup
  use_public_target
  env -u CLAUDE_CONFIG_DIR "$REPO/bin/fraim-scan" --out "$BATS_TEST_TMPDIR/me.mirror"
  [ -n "$(find "$BATS_TEST_TMPDIR/me.mirror" -perm 600)" ]
  run "$FRAIM" mirror "$BATS_TEST_TMPDIR/me.mirror" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"stdio   add MCP server tool: runs npx -y some-mcp@1.2.3"* ]]
  [[ "$output" != *"phx_literal"* ]]
}

# --- new mirror lines ----------------------------------------------------------------------

mirror_with() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/m.mirror"
  run "$FRAIM" mirror "$BATS_TEST_TMPDIR/m.mirror" --dry-run
}

@test "mirror refuses unsafe new lines" {
  use_public_target
  for line in 'stdio x curl -y evil' 'stdio x npx a;rm' 'claude settings.json' 'claude skills/../hooks' 'claude ../.ssh/id' 'mcpenv x lower' 'connect x https://a.b/c claudekey' 'connect x https://a.b/c claudekey -H'; do
    mirror_with "$line"
    [ "$status" -eq 2 ]
  done
}

@test "claudekey sends the key from this computer's Claude on stdin, without Bearer" {
  use_public_target
  printf '{"mcpServers":{"posthog":{"headers":{"Authorization":"Bearer phx_value"}}}}' > "$HOME/.claude.json"
  echo 'connect posthog https://mcp.posthog.com/mcp claudekey Authorization' > "$BATS_TEST_TMPDIR/m.mirror"
  run env -u CLAUDE_CONFIG_DIR "$FRAIM" mirror "$BATS_TEST_TMPDIR/m.mirror" --yes
  [ "$status" -eq 0 ]
  ! grep -qF phx_value "$SSH_LOG"
  grep -qF phx_value "$SSH_STDIN_LOG"
  ! grep -qF 'Bearer phx_value' "$SSH_STDIN_LOG"
  grep -q 'fraim-connect proxied posthog' "$SSH_LOG"
}

@test "mcpenv copies one value on stdin" {
  use_public_target
  printf '{"mcpServers":{"tool":{"env":{"TOOL_KEY":"tool-value"}}}}' > "$HOME/.claude.json"
  echo 'mcpenv tool TOOL_KEY' > "$BATS_TEST_TMPDIR/m.mirror"
  run env -u CLAUDE_CONFIG_DIR "$FRAIM" mirror "$BATS_TEST_TMPDIR/m.mirror" --yes
  [ "$status" -eq 0 ]
  ! grep -qF tool-value "$SSH_LOG"
  grep -qF tool-value "$SSH_STDIN_LOG"
  grep -q 'fraim-env set TOOL_KEY' "$SSH_LOG"
}

@test "claude does not replace what the space already has" {
  use_public_target
  mkdir -p "$HOME/.claude/skills/my-skill"
  echo x > "$HOME/.claude/skills/my-skill/SKILL.md"
  ssh_handler 'case "$REMOTE" in "test -e"*) exit 0 ;; esac'
  echo 'claude skills/my-skill' > "$BATS_TEST_TMPDIR/m.mirror"
  run env -u CLAUDE_CONFIG_DIR "$FRAIM" mirror "$BATS_TEST_TMPDIR/m.mirror" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has one"* ]]
  ! grep -q 'tar -xf' "$SSH_LOG"
}

@test "claude copies a skill when the space has none" {
  use_public_target
  mkdir -p "$HOME/.claude/skills/my-skill"
  echo x > "$HOME/.claude/skills/my-skill/SKILL.md"
  ssh_handler 'case "$REMOTE" in "test -e"*) exit 1 ;; esac'
  echo 'claude skills/my-skill' > "$BATS_TEST_TMPDIR/m.mirror"
  run env -u CLAUDE_CONFIG_DIR "$FRAIM" mirror "$BATS_TEST_TMPDIR/m.mirror" --yes
  [ "$status" -eq 0 ]
  grep -q 'tar -xf - -C ~/.claude' "$SSH_LOG"
}

@test "stdio adds the server through the normal command" {
  use_public_target
  echo 'stdio tool npx -y some-mcp@1.2.3' > "$BATS_TEST_TMPDIR/m.mirror"
  run "$FRAIM" mirror "$BATS_TEST_TMPDIR/m.mirror" --yes
  [ "$status" -eq 0 ]
  grep -qF 'fraim-connect stdio tool -- npx -y some-mcp@1.2.3' "$SSH_LOG"
}
