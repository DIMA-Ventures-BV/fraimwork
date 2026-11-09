#!/usr/bin/env bats
# workspace/automation-kit/examples/production-errors/check.sh with a fake slack trigger and a
# fake fraim-goal: one goal per new error kind, at most 3 a run, the rest kept, repeats
# skipped, alert text only ever a plain argument, Slack trouble told once.

setup() {
  CHECK="$BATS_TEST_DIRNAME/../../workspace/automation-kit/examples/production-errors/check.sh"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/automations/_triggers"
  export HOME="$T/home" GOALS="$T/goals" SENT="$T/sent" FEED="$T/feed" FRAIM_AUTOMATION=errors
  : > "$FEED"
  # The owner's own slack plugin replaces the built-in one: like the real one, it writes new
  # lines to FRAIM_TRIGGER_INBOX when that is set (and prints them otherwise), once.
  cat > "$HOME/fraim/automations/_triggers/slack" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$FEED.down" ] || { echo "Slack said: not_in_channel" >&2; exit 1; }
if [ -n "${FRAIM_TRIGGER_INBOX:-}" ]; then cat "$FEED" >> "$FRAIM_TRIGGER_INBOX"; else cat "$FEED"; fi
: > "$FEED"
EOF
  cat > "$T/bin/fraim-goal" <<'EOF'
#!/usr/bin/env bash
[ "$1" = start ] && [ "$2" = -- ] || exit 2
n=$(( $(wc -l < "$GOALS" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$3" >> "$GOALS"
echo "g$n"
EOF
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SENT"
EOF
  chmod +x "$T/bin/"* "$HOME/fraim/automations/_triggers/slack"
  export PATH="$T/bin:$PATH"
}

alert() { printf '[2026-11-09 10:05] :rotating_light: *Serverfout* `%s` / >%s\n' "$1" "${2:-boom}" >> "$FEED"; }

@test "one goal per error kind, grouped and counted" {
  alert cron.question_reminder.not_delivered "(geen melding)"
  alert cron.question_reminder.not_delivered "(geen melding)"
  alert payment.webhook_unknown_payment "unknown payment id"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$GOALS")" -eq 2 ]
  grep -q 'cron.question_reminder.not_delivered. Alert: "Serverfout  (geen melding)" (seen 2 times' "$GOALS" \
    || grep -q 'cron.question_reminder.not_delivered.*seen 2 times' "$GOALS"
  grep -q 'payment.webhook_unknown_payment.*seen 1 times' "$GOALS"
  grep -q 'draft pull request' "$GOALS"
  [[ "$output" == *"cron.question_reminder.not_delivered: goal g1"* ]]
}

@test "a repeat within a day starts nothing" {
  alert a.event
  "$CHECK"
  alert a.event
  run "$CHECK"
  [ "$(wc -l < "$GOALS")" -eq 1 ]
  [ -z "$output" ]
}

@test "at most 3 goals a run; the rest start in the next run, even without new alerts" {
  for e in e1 e2 e3 e4 e5; do alert "$e"; done
  run "$CHECK"
  [ "$(wc -l < "$GOALS")" -eq 3 ]
  run "$CHECK"
  [ "$(wc -l < "$GOALS")" -eq 5 ]
  grep -q 'e4' "$GOALS"
  grep -q 'e5' "$GOALS"
}

@test "alerts already in the inbox from a run that stopped are not lost" {
  mkdir -p "$HOME/.local/state/fraim/production-errors/errors"
  printf '[2026-11-09 10:01] *Serverfout* `left.over` / >x\n' > "$HOME/.local/state/fraim/production-errors/errors/inbox"
  run "$CHECK"
  grep -q 'left.over' "$GOALS"
  [ ! -s "$HOME/.local/state/fraim/production-errors/errors/inbox" ]
}

@test "lines without an error event are ignored" {
  printf '[2026-11-09 10:05] the deploy finished\n' >> "$FEED"
  run "$CHECK"
  [ ! -s "$GOALS" ]
}

@test "alert text never reaches a shell" {
  alert 'x.event$(touch hacked)' 'msg $(touch "$HOME/pwned") `touch also`'
  run "$CHECK"
  [ ! -e "$HOME/pwned" ]
  [ ! -e hacked ]
  [ "$(wc -l < "$GOALS")" -eq 1 ]
  # The event name keeps only safe characters; the message is kept as plain text.
  grep -q 'error in mijnlevensverhalen: x.event.touchhacked\|error in mijnlevensverhalen: x.eventtouchhacked' "$GOALS"
}

@test "when Slack cannot be read, the owner hears it once a day" {
  touch "$FEED.down"
  run "$CHECK"
  [ "$status" -eq 1 ]
  run "$CHECK"
  [ "$(grep -c 'cannot read Slack channel mlv-alerts' "$SENT")" -eq 1 ]
  grep -q not_in_channel "$SENT"
}
