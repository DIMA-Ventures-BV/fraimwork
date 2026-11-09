#!/usr/bin/env bats
# workspace/bin/fraim-lead (and its brain rules) with a fake fraim-claude and fraim-notify, and
# the lead budget in fraim-goal.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/jobs"
  export HOME="$T/home" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args" FRAIM_QUEUE_QUIET=1
  export FRAIM_LEADS_DIR="$T/home/fraim/leads" FRAIM_CRONTAB="$T/home/fraim/jobs/crontab"
  export FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_GOALS_DIR="$T/home/fraim/goals" FRAIM_BRAIN_DIR="$T/home/fraim/brain"
  export FRAIM_AUTOMATIONS_DIR="$T/home/fraim/automations" FRAIM_FILES_DIR="$T/home/fraim"
  export FRAIM_AUTO_STATE_DIR="$T/home/.local/state/fraim/automations" FRAIM_AUTO_CRONTAB="$T/home/.local/state/fraim/automations.crontab"
  export FRAIM_AUTO_KIT_DIR="$BATS_TEST_DIRNAME/../../workspace/automation-kit"
  # The fake Claude records its arguments and runs FAKE_ACTION, to act like a lead would.
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
[ -z "${FAKE_ACTION:-}" ] || eval "$FAKE_ACTION"
[ -z "${FAKE_FAIL:-}" ] || { echo "usage limit reached" >&2; exit 1; }
echo "${FAKE_OUTPUT:-Checked the area.}"
EOF
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >> "$SENT"
EOF
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=scheduler\n' > "$T/runtime.env"
  export PATH="$T/bin:$BIN:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
}

@test "new writes the brief, the budget and an automation that runs it" {
  run fraim-lead new web --area "the mijnlevensverhalen web app" --at "0 6 * * 1-5"
  [ "$status" -eq 0 ]
  grep -q 'the mijnlevensverhalen web app' "$FRAIM_LEADS_DIR/web/lead.md"
  [ "$(cat "$FRAIM_LEADS_DIR/web/budget")" = 3 ]
  grep -qx 'lead: web' "$FRAIM_AUTOMATIONS_DIR/web/automation.md"
  grep -q 'description: Lead web: the mijnlevensverhalen web app' "$FRAIM_AUTOMATIONS_DIR/web/automation.md"
  grep -qx '0 6 \* \* 1-5 fraim-auto fire web' "$FRAIM_AUTO_CRONTAB"
  [ ! -e "$FRAIM_CRONTAB" ]
  run fraim-auto check web
  [ "$status" -eq 0 ]
  run fraim-auto list
  [[ "$output" == *"web (lead)  [on]  schedule 0 6 * * 1-5"* ]]
  run fraim-lead list
  [[ "$output" == *"web  lead  0 6 * * 1-5"* ]]
  run fraim-lead new web
  [ "$status" -eq 1 ]
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/report"
  run fraim-lead new report
  [ "$status" -eq 1 ]
  [[ "$output" == *"automation is already called report"* ]]
}

@test "its automation runs the lead: one history, one alert and a queue item on failure" {
  fraim-lead new web
  FAKE_OUTPUT="Checked the web app." run fraim-auto run web
  [ "$status" -eq 0 ]
  grep -q 'Checked the web app.' "$FRAIM_AUTOMATIONS_DIR"/web/runs/*/output.md
  run fraim-auto run web --dry
  [[ "$output" == *"no dry run"* ]]
  rm -f "$SENT"
  FAKE_FAIL=1 run fraim-auto run web
  [ "$(grep -c 'failed' "$SENT")" -eq 1 ]
  grep -q "Automation web failed: the Claude plan's usage limit was reached" "$SENT"
  run fraim-queue list --json
  [[ "$output" == *'"kind":"failed"'* ]]
  [[ "$output" == *"Automation web failed"* ]]
  [[ "$output" != *"on_approve\":\"The automation"* ]]
}

@test "migrate moves old crontab lines of leads into automations, paused stays paused" {
  mkdir -p "$FRAIM_LEADS_DIR/web" "$FRAIM_LEADS_DIR/ops"
  printf -- '---\nrole: lead\n---\n# Lead: web\n\n## Area\nThe shop.\n' > "$FRAIM_LEADS_DIR/web/lead.md"
  printf -- '---\nrole: lead\n---\n# Lead: ops\n' > "$FRAIM_LEADS_DIR/ops/lead.md"
  touch "$FRAIM_LEADS_DIR/ops/paused"
  printf '0 5 * * * fraim-lead run web\n20 5 * * 1-5 fraim-lead run ops\n0 9 * * * fraim-lead run gone\n' > "$FRAIM_CRONTAB"
  run fraim-auto migrate
  [ "$status" -eq 0 ]
  grep -q 'description: Lead web: The shop.' "$FRAIM_AUTOMATIONS_DIR/web/automation.md"
  grep -qx 'schedule: "20 5 \* \* 1-5"' "$FRAIM_AUTOMATIONS_DIR/ops/automation.md"
  grep -qx '# moved to ~/fraim/automations/web: 0 5 \* \* \* fraim-lead run web' "$FRAIM_CRONTAB"
  grep -qx '0 9 \* \* \* fraim-lead run gone' "$FRAIM_CRONTAB"
  run fraim-auto list
  [[ "$output" == *"ops (lead)  [paused]"* ]]
}

@test "new refuses bad names and bad cron times" {
  run fraim-lead new "Web App"
  [ "$status" -eq 2 ]
  run fraim-lead new web --at "every day"
  [ "$status" -eq 2 ]
  run fraim-lead new web --at '0 7 * * 1; rm -rf ~'
  [ "$status" -eq 2 ]
  [ ! -e "$FRAIM_CRONTAB" ]
}

@test "the chief gets budget 2, its own brief and an events automation" {
  fraim-lead new chief --chief
  [ "$(cat "$FRAIM_LEADS_DIR/chief/budget")" = 2 ]
  grep -q '^role: chief' "$FRAIM_LEADS_DIR/chief/lead.md"
  run fraim-lead list
  [[ "$output" == *"chief  chief  30 7 * * *"* ]]
  grep -qx 'trigger: queue: events' "$FRAIM_AUTOMATIONS_DIR/chief-events/automation.md"
  grep -qx 'lead: chief' "$FRAIM_AUTOMATIONS_DIR/chief-events/automation.md"
  run fraim-auto check chief-events
  [ "$status" -eq 0 ]
  grep -qx '\*/15 \* \* \* \* fraim-auto poll chief-events' "$FRAIM_AUTO_CRONTAB"
  fraim-lead pause chief
  run fraim-auto list
  [[ "$output" == *"chief-events (lead)  [paused]"* ]]
  fraim-lead resume chief
  run fraim-lead events chief --off
  [ ! -e "$FRAIM_AUTOMATIONS_DIR/chief-events" ]
  run fraim-lead events chief --every 30m
  [ "$status" -eq 0 ]
  grep -qx 'every: 30m' "$FRAIM_AUTOMATIONS_DIR/chief-events/automation.md"
}

@test "run gives the lead its brief, notes, brain rules and queue history, with narrow tools" {
  fraim-lead new web --area "the web app"
  mkdir -p "$FRAIM_BRAIN_DIR"
  printf '# How the owner wants things\n- Dutch UI copy, informal je.\n' > "$FRAIM_BRAIN_DIR/rules.md"
  fraim-queue add --quiet --lead web --kind idea --title "Old idea" >/dev/null
  fraim-queue reject q1 --note "we tried that in May" >/dev/null
  run fraim-lead run web
  [ "$status" -eq 0 ]
  grep -q 'the web app' "$CLAUDE_ARGS"
  grep -q 'informal je' "$CLAUDE_ARGS"
  grep -q 'q1 \[rejected\] p2 idea: Old idea | owner: we tried that in May' "$CLAUDE_ARGS"
  grep -q 'Goal budget: 0 of 3 used today' "$CLAUDE_ARGS"
  tools="$(grep -A1 -x -- '--allowedTools' "$CLAUDE_ARGS" | tail -1)"
  [[ "$tools" == *"Bash(fraim-goal start --lead web:*)"* ]]
  [[ "$tools" == *"Edit(~/fraim/leads/web/**)"* ]]
  [[ "$tools" != *"Bash,"* ]]
  [[ "$tools" != *"fraim-queue prio"* ]]
  grep -q '^ok ' "$FRAIM_LEADS_DIR/web/last"
  [ ! -s "$SENT" ]
  [ ! -e "$FRAIM_LEADS_DIR/web/.running" ]
  [[ "$output" != *"unbound variable"* ]]
}

@test "a lead gets read-only git per repo in ~/code, and the code folder" {
  fraim-lead new web --area "the web app"
  mkdir -p "$HOME/code/shop/.git" "$HOME/code/notes"
  run fraim-lead run web
  [ "$status" -eq 0 ]
  tools="$(grep -A1 -x -- '--allowedTools' "$CLAUDE_ARGS" | tail -1)"
  [[ "$tools" == *"Bash(git -C $HOME/code/shop fetch:*)"* ]]
  [[ "$tools" == *"Bash(git -C $HOME/code/shop log:*)"* ]]
  [[ "$tools" != *"code/notes"* ]]
  [[ "$tools" != *"push"* ]]
  [ "$(grep -A1 -x -- '--add-dir' "$CLAUDE_ARGS" | tail -1)" = "$HOME/code" ]
  grep -q -- "- $HOME/code/shop" "$CLAUDE_ARGS"
  grep -q 'A cd before git is refused' "$CLAUDE_ARGS"
}

@test "a lead without ~/code gets no repo rules and no extra folder" {
  fraim-lead new web --area "the web app"
  run fraim-lead run web
  [ "$status" -eq 0 ]
  ! grep -q -- '--add-dir' "$CLAUDE_ARGS"
  ! grep -q 'Code on this server' "$CLAUDE_ARGS"
}

@test "a run that adds to the queue sends one message" {
  fraim-lead new web
  FAKE_ACTION='fraim-queue add --quiet --lead web --kind idea --title A >/dev/null; fraim-queue add --quiet --lead web --kind idea --title B >/dev/null' \
    run fraim-lead run web
  [ "$status" -eq 0 ]
  [ "$(grep -c '^notify' "$SENT")" = 1 ]
  grep -q 'Lead web: 2 new in your queue, 0 goal(s) started' "$SENT"
}

@test "the chief's answer is the digest, SILENT sends nothing" {
  fraim-lead new chief --chief
  FAKE_OUTPUT="Two things today." run fraim-lead run chief
  grep -q 'Chief of staff:' "$SENT"
  grep -q 'Two things today.' "$SENT"
  tools="$(grep -A1 -x -- '--allowedTools' "$CLAUDE_ARGS" | tail -1)"
  [[ "$tools" == *"Bash(fraim-queue prio:*)"* ]]
  [[ "$tools" == *"Bash(fraim-auto show:*)"* ]]
  [[ "$tools" == *"Bash(fraim-goal start --lead chief:*)"* ]]
  [[ "$tools" == *"Bash(fraim-lead tell:*)"* ]]
  [[ "$tools" != *"Bash,"* ]]
  grep -q 'Goal budget: 0 of 2 used today' "$CLAUDE_ARGS"
  grep -q 'daily digest' "$CLAUDE_ARGS"
  grep -q 'chief (lead)  \[on\]' "$CLAUDE_ARGS"
  rm -f "$SENT"
  FAKE_OUTPUT=SILENT run fraim-lead run chief
  [ ! -s "$SENT" ]
}

@test "a failed run tells the owner why" {
  fraim-lead new web
  FAKE_FAIL=1 run fraim-lead run web
  [ "$status" -eq 1 ]
  grep -q "Lead web failed: the Claude plan's usage limit was reached" "$SENT"
  grep -q '^failed ' "$FRAIM_LEADS_DIR/web/last"
}

@test "a paused lead does not run" {
  fraim-lead new web
  fraim-lead pause web
  run fraim-lead run web
  [[ "$output" == *paused* ]]
  [ ! -f "$CLAUDE_ARGS" ]
  run fraim-auto list
  [[ "$output" == *"web (lead)  [paused]"* ]]
  fraim-lead resume web
  run fraim-auto list
  [[ "$output" == *"web (lead)  [on]"* ]]
  run fraim-lead run web
  [ -f "$CLAUDE_ARGS" ]
}

@test "fraim-goal enforces the lead budget, but not for the owner's follow-ups" {
  mkdir -p "$FRAIM_LEADS_DIR/web"
  echo 2 > "$FRAIM_LEADS_DIR/web/budget"
  FAKE_SLEEP=2 fraim-goal start --lead web -- one
  fraim-goal start --lead web -- two
  run fraim-goal start --lead web -- three
  [ "$status" -eq 1 ]
  [[ "$output" == *"already started 2 of its 2 goals today"* ]]
  run fraim-goal start --lead web --queue q1 -- sneaky
  [ "$status" -eq 1 ]
  FRAIM_GOAL_FROM_QUEUE=1 run fraim-goal start --lead web --queue q1 -- rework
  [ "$status" -eq 0 ]
  [ -f "$FRAIM_GOALS_DIR/g3/by-owner" ]
}

@test "a lead gets the general rules and its own, not another lead's" {
  fraim-brain note "Write in Dutch"
  fraim-brain note --lead ops "Check the backups first"
  fraim-brain note --lead web "Test on a phone screen"
  fraim-lead new web --area "the web app"
  fraim-lead run web
  grep -q 'Write in Dutch' "$CLAUDE_ARGS"
  grep -q 'phone screen' "$CLAUDE_ARGS"
  ! grep -q 'backups first' "$CLAUDE_ARGS"
}

@test "tell leaves a note the next run reads first; a good run clears it, a failed run keeps it" {
  fraim-lead new web
  run fraim-lead tell web --from chief -- "Customers ask for a PDF export"
  [ "$status" -eq 0 ]
  grep -q 'from chief: Customers ask for a PDF export' "$FRAIM_LEADS_DIR/web/inbox.md"
  FAKE_FAIL=1 run fraim-lead run web
  grep -q 'Customers ask for a PDF export' "$CLAUDE_ARGS"
  grep -q 'PDF export' "$FRAIM_LEADS_DIR/web/inbox.md"
  run fraim-lead run web
  [ "$status" -eq 0 ]
  grep -q 'Your inbox' "$CLAUDE_ARGS"
  [ ! -e "$FRAIM_LEADS_DIR/web/inbox.md" ]
  grep -q 'PDF export' "$FRAIM_LEADS_DIR"/web/runs/*.md
  run fraim-lead tell web -- "   "
  [ "$status" -eq 2 ]
  run fraim-lead tell nobody -- hi
  [ "$status" -eq 1 ]
}

@test "ask runs the chief now with the owner's message, and it always answers" {
  fraim-lead new chief --chief
  FAKE_OUTPUT="Started g1 for the export." run fraim-lead ask -- "customers want a PDF export"
  [ "$status" -eq 0 ]
  [[ "$output" == *"chief is on it"* ]]
  for _ in $(seq 50); do grep -q 'Started g1' "$SENT" 2>/dev/null && break; sleep 0.1; done
  grep -q 'The owner wrote: customers want a PDF export' "$CLAUDE_ARGS"
  grep -q 'Never answer SILENT' "$CLAUDE_ARGS"
  grep -q 'Chief of staff:' "$SENT"
  grep -q 'Started g1 for the export.' "$SENT"
  ls "$FRAIM_AUTOMATIONS_DIR"/chief/runs/*/trigger.json >/dev/null
}

@test "ask without a chief says how to make one" {
  run fraim-lead ask -- "hello"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no chief of staff"* ]]
}

@test "a queue event wakes the chief; it stays quiet unless the owner must act" {
  fraim-lead new chief --chief
  FRAIM_LEAD_TRIGGER=queue FRAIM_LEAD_INPUT="q4 p2 review from goal g2: Export done" FAKE_OUTPUT=SILENT run fraim-lead run chief
  [ "$status" -eq 0 ]
  grep -q 'q4 p2 review from goal g2: Export done' "$CLAUDE_ARGS"
  grep -q 'only when the owner must act today' "$CLAUDE_ARGS"
  [ ! -s "$SENT" ]
}

@test "the queue trigger reports goal results, failures, automation answers and urgent items, not ideas or the chief's own" {
  fraim-lead new chief --chief
  fraim-lead new web
  P="$BATS_TEST_DIRNAME/../../workspace/automation-kit/triggers/queue"
  export FRAIM_TRIGGER_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FRAIM_TRIGGER_STATE"
  fraim-queue add --quiet --title "Before" >/dev/null
  run bash "$P" events
  [ -z "$output" ]
  fraim-queue add --quiet --lead web --kind idea --title "Lead idea" >/dev/null
  fraim-queue add --quiet --lead web --kind idea --priority 1 --title "Urgent idea" >/dev/null
  fraim-queue add --quiet --lead web --goal g3 --kind review --title "Goal result" >/dev/null
  fraim-queue add --quiet --source "automation mail" --kind decision --title "Mail asks for export" >/dev/null
  fraim-queue add --quiet --lead chief --kind decision --title "Chief asks" >/dev/null
  run bash "$P" events
  [ "$status" -eq 0 ]
  [[ "$output" != *"Lead idea"* ]]
  [[ "$output" != *"Chief asks"* ]]
  [[ "$output" == *"q3 p1 idea from lead web: Urgent idea"* ]]
  [[ "$output" == *"Goal result"* ]]
  [[ "$output" == *"from automation mail: Mail asks for export"* ]]
  run bash "$P" events
  [ -z "$output" ]
  run bash "$P" --check events
  [ "$status" -eq 0 ]
  run bash "$P" --check sometimes
  [ "$status" -eq 1 ]
}
