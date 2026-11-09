#!/usr/bin/env bats
# workspace/automation-kit/triggers/slack with a fake fraim-api: finds the channel by name,
# starts from now, then reports only new messages, oldest first.

setup() {
  TRIG="$BATS_TEST_DIRNAME/../../workspace/automation-kit/triggers/slack"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/state"
  export FRAIM_TRIGGER_STATE="$T/state" CALLS="$T/calls" HISTORY="$T/history"
  cat > "$T/bin/fraim-api" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$CALLS"
case "$2" in
  /api/conversations.list*)
    echo '{"ok": true, "channels": [{"id": "C111", "name": "general"}, {"id": "C222", "name": "mlv-alerts"}], "response_metadata": {"next_cursor": ""}}' ;;
  /api/conversations.history*) cat "$HISTORY" ;;
esac
EOF
  chmod +x "$T/bin/fraim-api"
  export PATH="$T/bin:$PATH"
}

@test "check accepts a #name or an id, nothing else" {
  run "$TRIG" --check mlv-alerts
  [ "$status" -eq 0 ]
  run "$TRIG" --check C0123ABCD
  [ "$status" -eq 0 ]
  run "$TRIG" --check 'mlv alerts; rm -rf ~'
  [ "$status" -eq 1 ]
}

@test "the first check finds the channel and only remembers where it is now" {
  echo '{"ok": true, "messages": [{"ts": "1794200000.1", "text": "old"}]}' > "$HISTORY"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$T/state/channel-id")" = C222 ]
  [ -s "$T/state/last-ts" ]
}

@test "later checks print new messages oldest first, on one line each, and move on" {
  echo C222 > "$T/state/channel-id"
  echo 1794200000 > "$T/state/last-ts"
  printf '%s' '{"ok": true, "messages": [
    {"ts": "1794200200.2", "text": "second\nline two"},
    {"ts": "1794200100.1", "text": ":rotating_light: *Serverfout* `cron.question_reminder.not_delivered`"}]}' > "$HISTORY"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"cron.question_reminder.not_delivered"* ]]
  [[ "${lines[1]}" == *"second / line two"* ]]
  [ "$(cat "$T/state/last-ts")" = 1794200200.2 ]
  grep -q 'conversations.history?channel=C222&oldest=1794200000' "$CALLS"
}

@test "nothing new prints nothing; a Slack error is a failure with its reason" {
  echo C222 > "$T/state/channel-id"
  echo 1794200000 > "$T/state/last-ts"
  echo '{"ok": true, "messages": []}' > "$HISTORY"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo '{"ok": false, "error": "not_in_channel"}' > "$HISTORY"
  run "$TRIG" mlv-alerts
  [ "$status" -eq 1 ]
  [[ "$output" == *"not_in_channel"* ]]
}
