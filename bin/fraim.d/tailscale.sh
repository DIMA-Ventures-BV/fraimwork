# shellcheck shell=bash disable=SC2034,SC2154
load_group secret

cmd_tailscale() {
  parse_flags "$@"
  case "${POSITIONAL[0]:-}" in
    policy)
      local email
      email="$(flag email)"
      [ -n "$email" ] || usage "fraim tailscale policy --email you@example.com [--email-2 colleague@example.com]"
      local members="\"$email\""
      [ -z "$(flag email-2)" ] || members="$members, \"$(flag email-2)\""
      sed "s/\"owner@example.com\"/$members/g" "$REPO/tailscale/policy.hujson"
      ;;
    key) ts_key_store ;;
    apply)
      local again=""
      [ -z "$(flag email)" ] || again="--email $(flag email)"
      [ -z "$(flag email-2)" ] || again="$again --email-2 $(flag email-2)"
      ts_apply "$again"
      ;;
    reach)
      # Let fraim servers reach one other tailnet device or tag (production, a build box).
      local dst="${POSITIONAL[1]:-}" port
      port="$(flag port)"; port="${port:-22}"
      printf '%s' "$dst" | grep -Eq '^(tag:[a-z0-9][a-z0-9-]{0,62}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3})$' \
        || usage "fraim tailscale reach tag:NAME|100.x.y.z [--port 22] [--yes]"
      printf '%s' "$port" | grep -Eq '^[0-9]{1,5}$' || usage "--port must be a number"
      TS_MERGE=ts_merge_reach TS_REACH_DST="$dst" TS_REACH_PORT="$port" \
        TS_AGAIN="fraim tailscale reach $dst --port $port" ts_apply ""
      ;;
    *) usage "fraim tailscale policy --email ADDRESS | key [--stdin] | apply [--email ADDR] [--yes] | reach tag:NAME|100.x.y.z [--port P] [--yes]" ;;
  esac
}

# --- Tailscale policy through the API ------------------------------------------------
# `fraim tailscale apply` merges the fraim rules into the tailnet's existing policy, so
# nobody pastes policy files by hand. The API token lives in the macOS Keychain (or a
# mode-600 file elsewhere) and only ever reaches curl through a file descriptor.
TS_API="${FRAIM_TS_API:-https://api.tailscale.com/api/v2}"
TS_KEY_SERVICE=fraim-tailscale-api-key
# Must match the fraim grant in tailscale/policy.hujson (a unit test checks this).
TS_FRAIM_PORTS='["tcp:2222-2226","udp:60000-60090","tcp:6080-6084","tcp:8384-8388","tcp:22000-22004","udp:22000-22004","tcp:3100-3149"]'
TS_KEY_STEP="Make a Tailscale API token: open https://login.tailscale.com/admin/settings/keys (check that the tailnet name at the top left is the one your fraim server is on), click 'Generate access token', description fraim, expiry 1 day, and copy it. Then in your own Terminal app (not in the Claude chat) run: fraim tailscale key  and paste it. Then tell Claude 'done'."

ts_key_file() { printf '%s' "$CONFIG_DIR/tailscale-api-key"; }
ts_key() {
  local key=""
  if command -v security >/dev/null; then key="$(security find-generic-password -s "$TS_KEY_SERVICE" -w 2>/dev/null || true)"; fi
  [ -n "$key" ] || key="$(cat "$(ts_key_file)" 2>/dev/null || true)"
  printf '%s' "$key"
}
ts_key_store() {
  local key
  need_secret_input "$TS_KEY_STEP"
  key="$(read_secret_input "Paste the Tailscale API token")"
  case "$key" in tskey-api-*) ;; *) usage "that does not look like a Tailscale API token (tskey-api-...)" ;; esac
  if command -v security >/dev/null; then
    # Through stdin, so the token never shows in the process list.
    printf 'add-generic-password -U -s %s -a %s -w %s\n' "$TS_KEY_SERVICE" "$USER" "$key" | security -i >/dev/null \
      || die "could not save the token in your Keychain"
  else
    mkdir -p "$CONFIG_DIR"
    (umask 077 && printf '%s' "$key" > "$(ts_key_file)")
  fi
  say "Tailscale API token saved on this computer. Claude runs: fraim tailscale apply"
}
ts_curl() {  # curl args...; the token goes in as a header file, never as an argument
  local key
  key="$(ts_key)"
  [ -n "$key" ] || human "$TS_KEY_STEP"
  curl -sS --fail-with-body -H @<(printf 'Authorization: Bearer %s\n' "$key") "$@"
}

# The current policy (JSON) on stdin, the fraim rules merged in on stdout. Existing rules
# are kept; a fraim grant that is already there only gains missing ports.
ts_merge_policy() {  # EMAILS_JSON
  jq --argjson emails "$1" --argjson ports "$TS_FRAIM_PORTS" '
    def union($a; $b): $a + ($b - $a);
    def same($a; $b): ($a | sort) == ($b | sort);
    def ensure_grant($src; $dst; $ip):
      if any(.grants[]?; same(.src; $src) and same(.dst; $dst))
      then .grants |= map(if same(.src; $src) and same(.dst; $dst) then .ip = union(.ip // []; $ip) else . end)
      else .grants = ((.grants // []) + [{src: $src, dst: $dst, ip: $ip}]) end;
    .groups = (.groups // {})
    | .groups["group:fraim-users"] = union(.groups["group:fraim-users"] // []; $emails)
    | .groups["group:fraim-admins"] = union(.groups["group:fraim-admins"] // []; $emails)
    | .tagOwners = (.tagOwners // {})
    | .tagOwners["tag:fraim"] = union(.tagOwners["tag:fraim"] // []; ["group:fraim-admins"])
    | ensure_grant(["group:fraim-users"]; ["tag:fraim"]; $ports)
    | ensure_grant(["group:fraim-admins"]; ["tag:fraim"]; ["tcp:22"])
    | if any(.ssh[]?; .action == "accept" and same(.src; ["group:fraim-admins"]) and same(.dst; ["tag:fraim"]) and ((.users // []) | index("root")))
      then . else .ssh = ((.ssh // []) + [{action: "accept", src: ["group:fraim-admins"], dst: ["tag:fraim"], users: ["root"]}]) end'
}

# The current policy on stdin; out: a grant from every fraim server to one device or tag.
ts_merge_reach() {
  jq --arg dst "$TS_REACH_DST" --arg ip "tcp:$TS_REACH_PORT" '
    def same($a; $b): ($a | sort) == ($b | sort);
    if any(.grants[]?; same(.src; ["tag:fraim"]) and same(.dst; [$dst]))
    then .grants |= map(if same(.src; ["tag:fraim"]) and same(.dst; [$dst]) then .ip = ((.ip // []) + ([$ip] - (.ip // []))) else . end)
    else .grants = ((.grants // []) + [{src: ["tag:fraim"], dst: [$dst], ip: [$ip]}]) end'
}

ts_apply() {
  local tmp etag emails="[]" e
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  for e in "$(flag email)" "$(flag email-2)"; do
    [ -z "$e" ] || emails="$(jq -c --arg e "$e" '. + [$e]' <<<"$emails")"
  done
  ts_curl -D "$tmp/headers" -H 'Accept: application/json' "$TS_API/tailnet/-/acl" -o "$tmp/current.json" \
    || { if grep -q ' 401' "$tmp/headers" 2>/dev/null; then human "The Tailscale API token expired or is wrong. $TS_KEY_STEP"; fi; die "could not read the Tailscale policy: $(cat "$tmp/current.json" 2>/dev/null)"; }
  etag="$(grep -i '^etag:' "$tmp/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')"
  if [ -z "${TS_MERGE:-}" ] && [ "$emails" = "[]" ] && ! jq -e '(.groups["group:fraim-users"] // []) | length > 0' "$tmp/current.json" >/dev/null; then
    usage "the policy has no group:fraim-users yet; add --email with the address you log in to Tailscale with"
  fi
  "${TS_MERGE:-ts_merge_policy}" "$emails" < "$tmp/current.json" > "$tmp/merged.json"
  if [ "$(jq -S . "$tmp/current.json")" = "$(jq -S . "$tmp/merged.json")" ]; then
    say "The Tailscale policy already allows this."
    return 0
  fi
  say "Changes to the Tailscale policy (- now, + after):"
  diff -u <(jq -S . "$tmp/current.json") <(jq -S . "$tmp/merged.json") | tail -n +3 || true
  if [ -z "$(flag yes)" ]; then
    human "Show the user the policy changes above and ask whether to apply them. The API stores the policy as JSON, so comments in the policy file are lost (a copy with comments is saved first). On yes, Claude runs: ${TS_AGAIN:-fraim tailscale apply} --yes${1:+ $1}"
  fi
  mkdir -p "$STATE_DIR"
  local backup
  backup="$STATE_DIR/tailscale-policy-$(date +%Y%m%d-%H%M%S).hujson"
  ts_curl -H 'Accept: application/hujson' "$TS_API/tailnet/-/acl" -o "$backup" || die "could not save a copy of the current policy; nothing was changed"
  ts_curl -X POST -H "If-Match: $etag" -H 'Content-Type: application/json' --data-binary @"$tmp/merged.json" \
    "$TS_API/tailnet/-/acl" -o "$tmp/result.json" \
    || die "Tailscale refused the new policy (nothing was changed): $(cat "$tmp/result.json" 2>/dev/null)"
  say "Tailscale policy updated. The old policy, with its comments, is saved in $backup"
}
