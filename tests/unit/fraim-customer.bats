#!/usr/bin/env bats
# fraim customer: servers we run for other people, kept apart from the operator's own fraim.

load helper

setup() {
  setup_isolated
  export SECURITY_STORE="$BATS_TEST_TMPDIR/keychain"
  export TS_POLICY="$BATS_TEST_TMPDIR/policy.json"
  export KEY_REQUEST="$BATS_TEST_TMPDIR/key-request.json"
  export CLOUD_LOG="$BATS_TEST_TMPDIR/cloud.log"
  printf 'tskey-api-SECRETVALUE' > "$SECURITY_STORE"
  echo '{"tagOwners":{"tag:fraim-customer":["group:fraim-admins"]}}' > "$TS_POLICY"
  mkdir -p "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
  cat > "$STUBS/security" <<'EOF'
#!/usr/bin/env bash
[ "$1" = find-generic-password ] || exit 1
case "$*" in *fraim-tailscale-api-key*) cat "$SECURITY_STORE" ;; *) echo OPERATOR-TOKEN ;; esac
EOF
  cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
out="" body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --data-binary) body="${2#@}"; shift ;;
    -H|-D|-X) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */keys) cp "$body" "$KEY_REQUEST"; echo '{"key":"tskey-auth-ONETIME"}' > "$out" ;;
  *) cat "$TS_POLICY" ;;
esac
EOF
  cat > "$STUBS/fraim-cloud" <<'EOF'
#!/usr/bin/env bash
printf '%s HCLOUD_CONTEXT=%s\n' "$*" "${HCLOUD_CONTEXT:-}" >> "$CLOUD_LOG"
case "$*" in *--yes*) echo root@203.0.113.9 ;; *) echo 'this costs money' >&2; exit 2 ;; esac
EOF
  for t in rsync scp hcloud; do printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/$t"; done
  chmod +x "$STUBS/security" "$STUBS/curl" "$STUBS/fraim-cloud" "$STUBS/rsync" "$STUBS/scp" "$STUBS/hcloud"
  export FRAIM_CLOUD_BIN="$STUBS/fraim-cloud"
  # The test deploys write config/authorized_keys in the checkout: keep the real one.
  AUTH="$REPO/config/authorized_keys"
  if [ -f "$AUTH" ]; then cp "$AUTH" "$BATS_TEST_TMPDIR/authorized_keys.real"; fi
  # Not logged in, WhatsApp not linked.
  ssh_handler 'case "$REMOTE" in
    *full-login*credentials*) exit 1 ;;
    *"fraim-tty start login"*) echo https://claude.ai/signin/TEST ;;
    *"fraim-gateway GET /status"*) echo "{\"connected\":false}" ;;
    *"fraim-gateway POST /pair"*) echo "{\"code\":\"ABCD-1234\"}" ;;
  esac'
}

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/authorized_keys.real" ]; then
    cp "$BATS_TEST_TMPDIR/authorized_keys.real" "$AUTH"
  else
    rm -f "$AUTH"
  fi
}

add() { run "$FRAIM" customer add alice --owner +31611111111 --bot +31622222222 --hcloud-context fraimwork "$@"; }

@test "the customer tag gets operator access and no outgoing grant" {
  source "$FRAIM"; set +e
  out="$(echo '{"groups":{"group:fraim-admins":["a@example.org"]},"grants":[{"src":["tag:fraim"],"dst":["tag:prod"],"ip":["tcp:22"]}]}' | ts_merge_customers)"
  [ "$(jq -r '.tagOwners["tag:fraim-customer"][0]' <<<"$out")" = group:fraim-admins ]
  jq -e 'any(.grants[]; .src == ["group:fraim-admins"] and .dst == ["tag:fraim-customer"] and (.ip | index("tcp:22")))' <<<"$out" >/dev/null
  jq -e 'any(.ssh[]; .dst == ["tag:fraim-customer"] and .users == ["root"])' <<<"$out" >/dev/null
  run jq -e 'any(.grants[]; .src | index("tag:fraim-customer"))' <<<"$out"
  [ "$status" -ne 0 ]
  # The person a server is shared with gets the fraim ports, not the root login on 22.
  jq -e 'any(.grants[]; .src == ["autogroup:shared"] and .dst == ["tag:fraim-customer"] and (.ip | index("tcp:2222-2226")) and (.ip | index("tcp:22") | not))' <<<"$out" >/dev/null
  jq -e 'any(.grants[]; .src == ["tag:fraim"] and .dst == ["tag:prod"])' <<<"$out" >/dev/null
}

@test "the merge stops when there is no operator group" {
  source "$FRAIM"; set +e
  run ts_merge_customers <<<'{}'
  [ "$status" -ne 0 ]
}

@test "merging the customer rules twice changes nothing" {
  source "$FRAIM"; set +e
  once="$(echo '{"groups":{"group:fraim-admins":["a@example.org"]}}' | ts_merge_customers)"
  twice="$(ts_merge_customers <<<"$once")"
  [ "$(jq -S . <<<"$once")" = "$(jq -S . <<<"$twice")" ]
}

@test "add asks for the Hetzner project before it creates anything" {
  run "$FRAIM" customer add alice --owner +31611111111 --bot +31622222222
  [ "$status" -eq 2 ]
  [[ "$output" == *hcloud-context* ]]
  [ ! -f "$CLOUD_LOG" ]
}

@test "add rejects the same number for owner and bot, and local numbers" {
  run "$FRAIM" customer add alice --owner +31611111111 --bot +31611111111 --hcloud-context x
  [ "$status" -eq 2 ]
  run "$FRAIM" customer add alice --owner 0611111111 --bot +31622222222 --hcloud-context x
  [ "$status" -eq 2 ]
}

@test "add without --yes stops at the cost and writes no auth key" {
  add
  [ "$status" -eq 2 ]
  [[ "$output" == *"costs money"* ]]
  [ ! -f "$KEY_REQUEST" ]
}

@test "add stops when the Tailscale policy has no customer tag" {
  echo '{}' > "$TS_POLICY"
  add --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"fraim tailscale customers"* ]]
  [ ! -f "$CLOUD_LOG" ]
}

@test "add deploys in its own target and leaves the operator's fraim alone" {
  mkdir -p "$XDG_CONFIG_HOME/fraim"
  echo 'FRAIM_HOST=mine' > "$XDG_CONFIG_HOME/fraim/config"
  echo default > "$XDG_CONFIG_HOME/fraim/current"
  add --yes
  [ "$status" -eq 3 ]
  [ "$(cat "$XDG_CONFIG_HOME/fraim/config")" = 'FRAIM_HOST=mine' ]
  [ "$(cat "$XDG_CONFIG_HOME/fraim/current")" = default ]
  grep -q '^FRAIM_HOST=fraim-alice$' "$XDG_CONFIG_HOME/fraim/alice.config"
  env="$XDG_CONFIG_HOME/fraim/customers/alice.env"
  grep -q '^TS_TAG=tag:fraim-customer$' "$env"
  grep -q '^WHATSAPP_OWNER=31611111111$' "$env"
  grep -q '^TS_AUTHKEY=$' "$env"
  [ "$(stat -f %Lp "$env" 2>/dev/null || stat -c %a "$env")" = 600 ]
  grep -q 'HCLOUD_CONTEXT=fraimwork' "$CLOUD_LOG"
  jq -e '.capabilities.devices.create | .reusable == false and .preauthorized == true and .tags == ["tag:fraim-customer"]' "$KEY_REQUEST" >/dev/null
}

@test "the login step sends the customer a link and never uses the operator's token" {
  add --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"https://claude.ai/signin/TEST"* ]]
  [[ "$output" == *"FRAIM_TARGET=alice fraim login --code"* ]]
  run grep -c OPERATOR-TOKEN "$SSH_STDIN_LOG"
  [ "$output" = 0 ] || [ "$status" -ne 0 ]
}

@test "after the login the next run gives the WhatsApp code without a new server" {
  add --yes
  : > "$CLOUD_LOG"
  ssh_handler 'case "$REMOTE" in
    *"fraim-gateway GET /status"*) echo "{\"connected\":false}" ;;
    *"fraim-gateway POST /pair"*) echo "{\"code\":\"ABCD-1234\"}" ;;
  esac'
  add --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *ABCD-1234* ]]
  [ ! -s "$CLOUD_LOG" ]
}

@test "without a bot number the server is built and WhatsApp waits for the number" {
  add --yes
  ssh_handler 'exit 0'
  run "$FRAIM" customer add alice --owner +31611111111 --hcloud-context fraimwork --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"second phone number"* ]]
  [ ! -f "$XDG_CONFIG_HOME/fraim/customers/alice.done" ]
}

@test "a linked WhatsApp finishes the setup and a later run does nothing" {
  add --yes
  ssh_handler 'case "$REMOTE" in *"fraim-gateway GET /status"*) echo "{\"connected\":true}" ;; esac'
  add --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice is ready"* ]]
  add --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already set up"* ]]
}

@test "list shows each customer's state" {
  mkdir -p "$XDG_CONFIG_HOME/fraim/customers"
  : > "$XDG_CONFIG_HOME/fraim/customers/bob.env"
  run "$FRAIM" customer list
  [ "$status" -eq 0 ]
  [[ "$output" == bob* ]]
  [[ "$output" == *"setup not finished"* ]]
}

@test "update of an unknown customer is refused" {
  run "$FRAIM" customer update nobody
  [ "$status" -eq 2 ]
}
