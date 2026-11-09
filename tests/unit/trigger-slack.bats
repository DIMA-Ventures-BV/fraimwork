#!/usr/bin/env bats
# workspace/automation-kit/triggers/slack with a fake fraim-api: finds a public channel by name
# (and forgets it when the name changes), starts from now, then reports every new message once,
# all pages, oldest first, without joins; errors say why and do not move the cursor.

setup() {
  TRIG="$BATS_TEST_DIRNAME/../../workspace/automation-kit/triggers/slack"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/state" "$T/pages"
  export FRAIM_TRIGGER_STATE="$T/state" CALLS="$T/calls" PAGES="$T/pages"
  # History pages: $PAGES/history-<cursor or first>.json; list pages likewise.
  cat > "$T/bin/fraim-api" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$CALLS"
[ ! -e "$PAGES/down" ] || { echo "curl: (22) The requested URL returned error: 429" >&2; exit 22; }
cursor="$(printf '%s' "$2" | sed -n 's/.*cursor=\([^&]*\).*/\1/p')"
case "$2" in
  /api/conversations.list*) cat "$PAGES/list-${cursor:-first}.json" ;;
  /api/conversations.history*) cat "$PAGES/history-${cursor:-first}.json" ;;
esac
EOF
  chmod +x "$T/bin/fraim-api"
  export PATH="$T/bin:$PATH"
  echo '{"ok": true, "channels": [{"id": "C111", "name": "general"}], "response_metadata": {"next_cursor": "p2"}}' > "$PAGES/list-first.json"
  echo '{"ok": true, "channels": [{"id": "C222", "name": "mlv-alerts"}], "response_metadata": {"next_cursor": ""}}' > "$PAGES/list-p2.json"
}

started() { printf 'mlv-alerts\tC222\n' > "$T/state/channel"; echo 1794200000 > "$T/state/last-ts"; }

@test "check accepts a name or an id, nothing else" {
  run "$TRIG" --check mlv-alerts
  [ "$status" -eq 0 ]
  run "$TRIG" --check '#mlv-alerts'
  [ "$status" -eq 0 ]
  run "$TRIG" --check C0123ABCD
  [ "$status" -eq 0 ]
  for bad in 'mlv alerts' 'CA&latest=1' "$(printf 'ok\nC1/../x')" 'Mlv-Alerts'; do
    run "$TRIG" --check "$bad"
    [ "$status" -eq 1 ]
  done
}

@test "the first check finds a public channel on a later page and only remembers where it is now" {
  echo '{"ok": true, "messages": [{"ts": "1794200000.1", "text": "old"}]}' > "$PAGES/history-first.json"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$T/state/channel")" = "$(printf 'mlv-alerts\tC222')" ]
  [ -s "$T/state/last-ts" ]
  grep -q 'types=public_channel' "$CALLS"
  ! grep -q 'private_channel' "$CALLS"
}

@test "an id is used as it is; another name starts over" {
  started
  echo '{"ok": true, "messages": []}' > "$PAGES/history-first.json"
  run "$TRIG" C0999AAAA
  grep -q 'channel=C0999AAAA' "$CALLS"
  ! grep -q conversations.list "$CALLS"
  run "$TRIG" general
  [ "$(cut -f2 "$T/state/channel")" = C111 ]
  [ -z "$output" ]
}

@test "every page of new messages is read, oldest first, without joins, and only then the cursor moves" {
  started
  printf '%s' '{"ok": true, "has_more": true, "response_metadata": {"next_cursor": "h2"}, "messages": [
    {"ts": "1794200300.1", "text": "third `b.event`"},
    {"ts": "1794200250.1", "subtype": "channel_join", "text": "<@U1> has joined"}]}' > "$PAGES/history-first.json"
  printf '%s' '{"ok": true, "has_more": false, "messages": [
    {"ts": "1794200200.1", "subtype": "bot_message", "text": "", "attachments": [{"fallback": "second from attachment"}]},
    {"ts": "1794200100.1", "text": "first\nline two"}]}' > "$PAGES/history-h2.json"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *"first / line two"* ]]
  [[ "${lines[1]}" == *"second from attachment"* ]]
  [[ "${lines[2]}" == *'third `b.event`'* ]]
  [[ "$output" != *joined* ]]
  [ "$(cat "$T/state/last-ts")" = 1794200300.1 ]
}

@test "a Slack error or an unreachable Slack says why and keeps the cursor" {
  started
  echo '{"ok": false, "error": "not_in_channel"}' > "$PAGES/history-first.json"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 1 ]
  [[ "$output" == *"not_in_channel"* ]]
  [ "$(cat "$T/state/last-ts")" = 1794200000 ]
  touch "$PAGES/down"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 1 ]
  [[ "$output" == *"429"* ]]
  [ "$(cat "$T/state/last-ts")" = 1794200000 ]
}

@test "a channel name nobody can see is a clear error" {
  echo '{"ok": true, "channels": [], "response_metadata": {"next_cursor": ""}}' > "$PAGES/list-first.json"
  run "$TRIG" nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no public channel 'nope'"* ]]
}
