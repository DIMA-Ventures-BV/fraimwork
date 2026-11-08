#!/usr/bin/env bats
# fraim setup and the steps it automates: Tailscale policy through the API, the one-step
# full login, the prefilled GitHub token page and Syncthing pairing.

load helper

setup() {
  setup_isolated
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export CURL_POSTED="$BATS_TEST_TMPDIR/curl.posted"
  export TS_POLICY="$BATS_TEST_TMPDIR/policy.json"
  export SECURITY_STORE="$BATS_TEST_TMPDIR/keychain"
  : > "$CURL_LOG"
  echo '{}' > "$TS_POLICY"
  # Fake curl for the Tailscale API: GET returns $TS_POLICY with an ETag, POST saves the body.
  cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
out="" headers="" body="" method=GET accept=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) headers="$2"; shift ;;
    -X) method="$2"; shift ;;
    --data-binary) body="${2#@}"; shift ;;
    -H) case "$2" in Accept:*) accept="$2" ;; @*) grep -q '^Authorization: Bearer tskey-api-' "${2#@}" || exit 22 ;; esac; shift ;;
  esac
  shift
done
if [ "$method" = POST ]; then cp "$body" "$CURL_POSTED"; echo '{}' > "${out:-/dev/null}"; exit 0; fi
[ -z "$headers" ] || printf 'HTTP/2 200\r\nETag: "abc123"\r\n\r\n' > "$headers"
case "$accept" in *hujson*) echo '// with comments' > "$out" ;; *) cp "$TS_POLICY" "$out" ;; esac
EOF
  chmod +x "$STUBS/curl"
  # Fake Keychain: never touch the real one.
  cat > "$STUBS/security" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  find-generic-password) [ -s "$SECURITY_STORE" ] && cat "$SECURITY_STORE" ;;
  -i) sed -n 's/.* -w \(.*\)$/\1/p' > "$SECURITY_STORE" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$STUBS/security"
}

with_ts_key() { printf 'tskey-api-SECRETVALUE' > "$SECURITY_STORE"; }

# --- the merge itself ----------------------------------------------------------------

@test "the ports fraim asks for match tailscale/policy.hujson" {
  source "$FRAIM"; set +e
  for p in $(jq -r '.[]' <<<"$TS_FRAIM_PORTS"); do
    grep -qF "\"$p\"" "$REPO/tailscale/policy.hujson" || { echo "missing in policy.hujson: $p"; return 1; }
  done
}

@test "merge into an empty policy adds groups, tag owner, grants and the ssh rule" {
  source "$FRAIM"; set +e
  out="$(echo '{}' | ts_merge_policy '["a@example.org"]')"
  jq -e '.groups["group:fraim-users"] == ["a@example.org"]' <<<"$out"
  jq -e '.tagOwners["tag:fraim"] == ["group:fraim-admins"]' <<<"$out"
  jq -e '.grants | length == 2' <<<"$out"
  jq -e '.ssh[0].users == ["root"]' <<<"$out"
}

@test "merge keeps other rules and only adds missing ports to an old fraim grant" {
  source "$FRAIM"; set +e
  old='{"groups":{"group:fraim-users":["a@x"],"group:fraim-admins":["a@x"],"group:ops":["o@x"]},
        "tagOwners":{"tag:prod":["group:ops"]},
        "acls":[{"action":"accept","src":["group:ops"],"dst":["tag:prod:*"]}],
        "grants":[{"src":["group:fraim-users"],"dst":["tag:fraim"],"ip":["tcp:2222","udp:60000-60010"]}]}'
  out="$(ts_merge_policy '[]' <<<"$old")"
  jq -e '.acls == [{"action":"accept","src":["group:ops"],"dst":["tag:prod:*"]}]' <<<"$out"
  jq -e '.groups["group:ops"] == ["o@x"] and .tagOwners["tag:prod"] == ["group:ops"]' <<<"$out"
  jq -e '[.grants[] | select(.dst == ["tag:fraim"] and .src == ["group:fraim-users"])] | length == 1' <<<"$out"
  jq -e '.grants[0].ip[0:2] == ["tcp:2222","udp:60000-60010"]' <<<"$out"
  jq -e '.grants[0].ip | index("tcp:3100-3149")' <<<"$out"
}

@test "merge is idempotent" {
  source "$FRAIM"; set +e
  once="$(echo '{}' | ts_merge_policy '["a@example.org"]')"
  twice="$(ts_merge_policy '["a@example.org"]' <<<"$once")"
  [ "$(jq -S . <<<"$once")" = "$(jq -S . <<<"$twice")" ]
}

# --- tailscale key / apply -----------------------------------------------------------

@test "tailscale apply without a saved token is a human step" {
  run "$FRAIM" tailscale apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"HUMAN STEP:"*"fraim tailscale key"* ]]
}

@test "tailscale key --stdin rejects something that is not an API token" {
  run bash -c "printf 'nope' | '$FRAIM' tailscale key --stdin"
  [ "$status" -eq 2 ]
  [ ! -s "$SECURITY_STORE" ]
}

@test "tailscale key --stdin saves the token through stdin, never as an argument" {
  run bash -c "printf 'tskey-api-SECRETVALUE\n' | '$FRAIM' tailscale key --stdin"
  [ "$status" -eq 0 ]
  [ "$(cat "$SECURITY_STORE")" = tskey-api-SECRETVALUE ]
  ! grep -q SECRETVALUE <<<"$output"
}

@test "tailscale apply shows the change and waits for a yes" {
  with_ts_key
  run "$FRAIM" tailscale apply --email a@example.org
  [ "$status" -eq 3 ]
  grep -qE '^\+ +"tcp:2222-2226"' <<<"$output"
  [[ "$output" == *"fraim tailscale apply --yes --email a@example.org"* ]]
  [ ! -e "$CURL_POSTED" ]
  ! grep -q SECRETVALUE "$CURL_LOG"
}

@test "tailscale apply --yes saves a backup and posts with If-Match" {
  with_ts_key
  run "$FRAIM" tailscale apply --email a@example.org --yes
  [ "$status" -eq 0 ]
  jq -e '.groups["group:fraim-users"] == ["a@example.org"]' "$CURL_POSTED"
  grep -q 'If-Match: "abc123"' "$CURL_LOG"
  ls "$HOME/.fraim"/tailscale-policy-*.hujson
  ! grep -q SECRETVALUE "$CURL_LOG"
}

@test "tailscale apply changes nothing when the policy already allows fraim" {
  with_ts_key
  source "$FRAIM"; set +e
  echo '{}' | ts_merge_policy '["a@example.org"]' > "$TS_POLICY"
  run "$FRAIM" tailscale apply --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already allows"* ]]
  [ ! -e "$CURL_POSTED" ]
}

@test "tailscale apply without an email on a policy without fraim users exits 2" {
  with_ts_key
  run "$FRAIM" tailscale apply --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"--email"* ]]
}

# --- login --full ----------------------------------------------------------------------

@test "login --full reuses a sign-in that is already waiting" {
  use_public_target
  ssh_handler 'case "$REMOTE" in
    *"test -f ~/.config/fraim/full-login"*) exit 1 ;;
    *"fraim-tty show login"*) echo "https://claude.ai/oauth/authorize?code=WAITING" ;;
  esac'
  run "$FRAIM" login --full
  [ "$status" -eq 3 ]
  [[ "$output" == *"code=WAITING"* ]]
  ! grep -q 'fraim-tty start' "$SSH_LOG"
}

@test "login --full --restart starts a new sign-in" {
  use_public_target
  ssh_handler 'case "$REMOTE" in
    *"test -f ~/.config/fraim/full-login"*) exit 1 ;;
    *"fraim-tty start"*) echo "https://claude.ai/oauth/authorize?code=NEW" ;;
  esac'
  run "$FRAIM" login --full --restart
  [ "$status" -eq 3 ]
  [[ "$output" == *"code=NEW"* ]]
}

# --- repo token ------------------------------------------------------------------------

@test "repo token points the human at a prefilled GitHub page for the owner" {
  use_public_target
  run "$FRAIM" repo token --owner DAMI-Ventures
  [ "$status" -eq 3 ]
  [[ "$output" == *"personal-access-tokens/new?"*"contents=write"*"pull_requests=write"*"target_name=DAMI-Ventures"* ]]
}

# --- sync pair -------------------------------------------------------------------------

@test "sync pair on a space without the sync module exits 2" {
  use_public_target
  ssh_handler 'case "$REMOTE" in *COMPOSE_PROFILES*) echo browser,scheduler ;; esac'
  run "$FRAIM" sync pair
  [ "$status" -eq 2 ]
}

@test "sync pair without Syncthing on the laptop is a human step" {
  use_public_target
  export FRAIM_SYNCTHING_CONFIG="$BATS_TEST_TMPDIR/none.xml"
  ssh_handler 'case "$REMOTE" in *COMPOSE_PROFILES*) echo browser,sync ;; esac'
  run "$FRAIM" sync pair
  [ "$status" -eq 3 ]
  [[ "$output" == *"HUMAN STEP:"*"brew install --cask syncthing"* ]]
}
