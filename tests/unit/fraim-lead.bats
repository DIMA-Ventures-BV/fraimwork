#!/usr/bin/env bats
# workspace/bin/fraim-lead and fraim-brain with a fake fraim-claude and fraim-notify, and
# the lead budget in fraim-goal.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/jobs"
  export HOME="$T/home" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args" FRAIM_QUEUE_QUIET=1
  export FRAIM_LEADS_DIR="$T/home/fraim/leads" FRAIM_CRONTAB="$T/home/fraim/jobs/crontab"
  export FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_GOALS_DIR="$T/home/fraim/goals" FRAIM_BRAIN_DIR="$T/home/fraim/brain"
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

@test "new writes the brief, the budget and a crontab line" {
  run fraim-lead new web --area "the mijnlevensverhalen web app" --at "0 6 * * 1-5"
  [ "$status" -eq 0 ]
  grep -q 'the mijnlevensverhalen web app' "$FRAIM_LEADS_DIR/web/lead.md"
  [ "$(cat "$FRAIM_LEADS_DIR/web/budget")" = 3 ]
  grep -qx '0 6 \* \* 1-5 fraim-lead run web' "$FRAIM_CRONTAB"
  run fraim-lead new web
  [ "$status" -eq 1 ]
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

@test "the chief gets budget 0 and its own brief" {
  fraim-lead new chief --chief
  [ "$(cat "$FRAIM_LEADS_DIR/chief/budget")" = 0 ]
  grep -q '^role: chief' "$FRAIM_LEADS_DIR/chief/lead.md"
  run fraim-lead list
  [[ "$output" == *"chief  chief  30 7 * * *"* ]]
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
  [[ "$tools" != *"fraim-goal start"* ]]
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
  fraim-lead resume web
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

@test "brain note and distill write the rules, and keep the old ones" {
  run fraim-brain distill
  [[ "$output" == *"nothing to distill"* ]]
  fraim-brain note "never use emoji"
  grep -q 'owner said: never use emoji' "$FRAIM_BRAIN_DIR/log.md"
  FAKE_OUTPUT=$'# How the owner wants things\n- Never use emoji.' run fraim-brain distill
  [ "$status" -eq 0 ]
  grep -qx -- '- Never use emoji.' "$FRAIM_BRAIN_DIR/rules.md"
  grep -q 'never use emoji' "$CLAUDE_ARGS"
  run fraim-brain distill --if-new
  [[ "$output" == *"No new feedback"* ]]
  FAKE_OUTPUT="sorry, I cannot" run fraim-brain distill
  [ "$status" -eq 1 ]
  grep -qx -- '- Never use emoji.' "$FRAIM_BRAIN_DIR/rules.md"
}
