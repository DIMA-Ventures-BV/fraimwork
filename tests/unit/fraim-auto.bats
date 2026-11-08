#!/usr/bin/env bats
# workspace/bin/fraim-auto with a fake fraim-claude (stream-json), fraim-notify and
# fraim-gateway: the file format, checks, runs, outputs, failures, the crontab and migration.

setup() {
  AUTO="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-auto"
  JOB="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-job"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/automations"
  export HOME="$T/home" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args"
  export FRAIM_AUTOMATIONS_DIR="$HOME/fraim/automations" FRAIM_FILES_DIR="$HOME/fraim"
  export FRAIM_AUTO_STATE_DIR="$HOME/.local/state/fraim/automations"
  export FRAIM_AUTO_CRONTAB="$HOME/.local/state/fraim/automations.crontab"
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
[ -z "${FAKE_FAIL:-}" ] || { echo "usage limit reached" >&2; exit 1; }
answer="${FAKE_ANSWER:-Two mails need an answer.}"
echo '{"type":"system","subtype":"init"}'
jq -cn --arg r "$answer" '{type: "result", subtype: "success", is_error: false, result: $r, total_cost_usd: 0.01, num_turns: 2, duration_ms: 900}'
EOF
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf 'gateway %s\n' "$3" >> "$SENT"
EOF
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FRAIM_NOTIFY_NO_ALERT:-}" ]; then printf 'result %s\n' "$*" >> "$SENT"; else printf 'alert %s\n' "$*" >> "$SENT"; fi
EOF
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=whatsapp,scheduler\n' > "$T/runtime.env"
  export PATH="$T/bin:$(dirname "$AUTO"):$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
}

# make NAME HEADER-LINES PROMPT
make_auto() {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/$1"
  printf -- '---\n%s\n---\n%s\n' "$2" "$3" > "$FRAIM_AUTOMATIONS_DIR/$1/automation.md"
}
last_run() { find "$FRAIM_AUTOMATIONS_DIR/$1/runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -1; }

@test "list says how to start when there are no automations" {
  run "$AUTO" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No automations yet"* ]]
}

@test "check names each mistake in plain words" {
  make_auto broken 'schedule: "every morning"
whatsapp: ^digest
output: whatsapp, email:me@example.com, file:../etc/x
colour: blue' 'Do it.'
  run "$AUTO" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a cron line"* ]]
  [[ "$output" == *"'whatsapp:' triggers are not available yet"* ]]
  [[ "$output" == *"output 'email' is not available yet"* ]]
  [[ "$output" == *"must be a path inside ~/fraim"* ]]
  [[ "$output" == *"unknown setting 'colour:'"* ]]
}

@test "a good automation passes check and list shows its trigger" {
  make_auto digest 'schedule: "0 8 * * 1-5"   # weekdays
hours: 07:00-22:00' 'Summarise.'
  run "$AUTO" check digest
  [ "$status" -eq 0 ]
  run "$AUTO" list
  [[ "$output" == *"digest  [on]  schedule 0 8 * * 1-5 (07:00-22:00)  last: never ran"* ]]
}

@test "run sends the answer to WhatsApp and the outbox, and keeps the run" {
  make_auto digest 'tools: Read, Grep, mcp__google__gmail_search
model: sonnet' 'Mail since {{since}}. Extra: {{input}}'
  run "$AUTO" run digest --input "only work mail"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Two mails need an answer."* ]]
  grep -q '^result digest:' "$SENT"
  grep -q 'Two mails need an answer.' "$HOME/fraim/outbox.md"
  r="$(last_run digest)"
  [ "$(cat "$r/status")" = ok ]
  [ "$(cat "$r/delivery")" = ok ]
  grep -q 'Mail since never (this is the first run). Extra: only work mail' "$r/prompt.md"
  [ "$(jq -r .cost_usd "$r/usage.json")" = 0.01 ]
  grep -qx 'Read,Grep,mcp__google__gmail_search' "$CLAUDE_ARGS"
  grep -qx 'sonnet' "$CLAUDE_ARGS"
  grep -q 'Edit(~/fraim/automations/\*\*)' "$CLAUDE_ARGS"
  run "$AUTO" run digest
  grep -q 'Mail since 20' "$(last_run digest)/prompt.md"
}

@test "SILENT delivers nothing" {
  make_auto quiet '' 'Anything new?'
  FAKE_ANSWER=SILENT run "$AUTO" run quiet
  [ "$status" -eq 0 ]
  [ ! -s "$SENT" ]
  [ "$(cat "$(last_run quiet)/status")" = silent ]
}

@test "an empty check.sh skips the run without calling Claude" {
  make_auto poll 'every: 15m' 'New mail: {{check}}'
  printf 'exit 0\n' > "$FRAIM_AUTOMATIONS_DIR/poll/check.sh"
  run "$AUTO" run poll
  [[ "$output" == *skipped* ]]
  [ ! -f "$CLAUDE_ARGS" ]
  printf 'echo "invoice from mollie"\n' > "$FRAIM_AUTOMATIONS_DIR/poll/check.sh"
  run "$AUTO" run poll
  grep -q 'New mail: invoice from mollie' "$(last_run poll)/prompt.md"
}

@test "script_only delivers the check output and never calls Claude" {
  make_auto disk 'script_only: true' ''
  printf 'echo "disk 91 percent"\n' > "$FRAIM_AUTOMATIONS_DIR/disk/check.sh"
  run "$AUTO" run disk
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_ARGS" ]
  grep -q 'disk 91 percent' "$SENT"
}

@test "file output writes under ~/fraim with the date filled in; none keeps it out of the outbox" {
  make_auto report 'output: file: reports/{name}-{date}.md, whatsapp:123@g.us' 'Report.'
  run "$AUTO" run report
  [ -f "$HOME/fraim/reports/report-$(date +%Y-%m-%d).md" ]
  grep -q '"chat_id":"123@g.us"' "$SENT"
  make_auto hidden 'output: none' 'Hidden.'
  rm -f "$HOME/fraim/outbox.md"
  run "$AUTO" run hidden
  [ ! -f "$HOME/fraim/outbox.md" ]
}

@test "a dry run shows the answer and delivers nothing" {
  make_auto digest '' 'Summarise.'
  run "$AUTO" run digest --dry
  [[ "$output" == *"dry run, nothing delivered"* ]]
  [ ! -s "$SENT" ]
  [ ! -f "$HOME/fraim/outbox.md" ]
}

@test "failures alert once, pause after five, and resume clears it" {
  make_auto flaky 'schedule: "0 * * * *"' 'Try.'
  for _ in 1 2 3 4; do FAKE_FAIL=1 run "$AUTO" fire flaky; done
  [ "$(grep -c '^alert' "$SENT")" -eq 1 ]
  grep -q "usage limit was reached" "$SENT"
  FAKE_FAIL=1 run "$AUTO" fire flaky
  [ "$(grep -c '^alert' "$SENT")" -eq 2 ]
  grep -q 'is paused' "$SENT"
  run "$AUTO" list
  [[ "$output" == *"[paused]"* ]]
  rm -f "$CLAUDE_ARGS"
  run "$AUTO" fire flaky
  [ ! -f "$CLAUDE_ARGS" ]
  run "$AUTO" resume flaky
  run "$AUTO" fire flaky
  [ -f "$CLAUDE_ARGS" ]
  grep -q 'works again' "$SENT"
}

@test "a scheduled run of an automation with a mistake is blocked with one alert" {
  make_auto bad 'output: telegram' 'Do.'
  run "$AUTO" fire bad
  [ "$status" -eq 1 ]
  run "$AUTO" fire bad
  [ "$(grep -c '^alert' "$SENT")" -eq 1 ]
  [ ! -f "$CLAUDE_ARGS" ]
}

@test "fire respects enabled: false and hours" {
  make_auto off 'enabled: false' 'Do.'
  run "$AUTO" fire off
  [ ! -f "$CLAUDE_ARGS" ]
  h="$(date +%H)"; next=$(( (10#$h + 1) % 24 )); after=$(( (10#$h + 2) % 24 ))
  make_auto later "$(printf 'hours: %02d:00-%02d:00' "$next" "$after")" 'Do.'
  run "$AUTO" fire later
  [ ! -f "$CLAUDE_ARGS" ]
  run "$AUTO" run later
  [ -f "$CLAUDE_ARGS" ]
}

@test "a second trigger during a run is queued, not run alongside" {
  make_auto busy '' 'Do.'
  sleep 30 & pid=$!
  mkdir -p "$FRAIM_AUTO_STATE_DIR/busy/lock"
  printf '%s %s\n' "$(hostname)" "$pid" > "$FRAIM_AUTO_STATE_DIR/busy/lock/owner"
  run "$AUTO" run busy
  kill "$pid"
  [[ "$output" == *"runs once more"* ]]
  [ -f "$FRAIM_AUTO_STATE_DIR/busy/queued" ]
  [ ! -f "$CLAUDE_ARGS" ]
}

@test "sync writes one crontab line per scheduled automation" {
  make_auto a 'schedule: "0 8 * * 1-5"' 'A.'
  make_auto b 'every: 30m' 'B.'
  make_auto c 'every: 2h' 'C.'
  make_auto d '' 'Manual only.'
  make_auto e 'schedule: "0 9 * * *"
enabled: false' 'Off.'
  run "$AUTO" sync
  [[ "$output" == *"3 scheduled"* ]]
  grep -qx '0 8 \* \* 1-5 fraim-auto fire a' "$FRAIM_AUTO_CRONTAB"
  grep -qx '\*/30 \* \* \* \* fraim-auto fire b' "$FRAIM_AUTO_CRONTAB"
  grep -qx '0 \*/2 \* \* \* fraim-auto fire c' "$FRAIM_AUTO_CRONTAB"
  ! grep -q 'fire [de]$' "$FRAIM_AUTO_CRONTAB"
  run "$AUTO" sync
  [[ "$output" == *"already up to date"* ]]
}

@test "migrate moves crontab jobs into automations once and fraim-job still works" {
  mkdir -p "$HOME/fraim/jobs"
  printf 'Check the weather.\n' > "$HOME/fraim/jobs/weather.md"
  printf 'Read\nWebFetch(domain:wttr.in)\n' > "$HOME/fraim/jobs/weather.tools"
  printf '# a comment\n0 7 * * *   fraim-job weather\n# 0 8 * * * fraim-job example\n' > "$HOME/fraim/jobs/crontab"
  run "$AUTO" migrate
  [[ "$output" == *"Moved 1 job"* ]]
  f="$FRAIM_AUTOMATIONS_DIR/weather/automation.md"
  grep -qx 'schedule: "0 7 \* \* \*"' "$f"
  grep -qx 'tools: Read, WebFetch(domain:wttr.in)' "$f"
  grep -qx 'Check the weather.' "$f"
  grep -q '^# moved to ~/fraim/automations/weather' "$HOME/fraim/jobs/crontab"
  grep -qx '# 0 8 \* \* \* fraim-job example' "$HOME/fraim/jobs/crontab"
  run "$AUTO" check weather
  [ "$status" -eq 0 ]
  run "$AUTO" migrate
  [ -z "$output" ]
  run "$JOB" weather
  [ "$status" -eq 0 ]
  grep -qx 'Read,WebFetch(domain:wttr.in)' "$CLAUDE_ARGS"
}

@test "names that could escape the folder are refused" {
  run "$AUTO" run ../etc
  [ "$status" -eq 2 ]
  run "$AUTO" show 'a b'
  [ "$status" -eq 2 ]
}
