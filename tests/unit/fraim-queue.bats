#!/usr/bin/env bats
# workspace/bin/fraim-queue with a fake fraim-goal and fraim-notify: adding, ranking,
# decisions, rework goals and the brain log.

setup() {
  Q="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-queue"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim"
  export HOME="$T/home" FRAIM_RUNTIME_ENV=/dev/null SENT="$T/sent" GOAL_ARGS="$T/goal.args"
  export FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_BRAIN_DIR="$T/home/fraim/brain" FRAIM_GOALS_DIR="$T/home/fraim/goals"
  cat > "$T/bin/fraim-goal" <<'EOF'
#!/usr/bin/env bash
{ printf 'env FRAIM_GOAL_FROM_QUEUE=%s\n' "${FRAIM_GOAL_FROM_QUEUE:-}"; printf '%s\n' "$@"; } > "$GOAL_ARGS"
echo g7
EOF
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >> "$SENT"
EOF
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"
}

@test "add prints q1, then q2, and tells the owner unless quiet" {
  run "$Q" add --title "First"
  [ "$status" -eq 0 ]
  [ "$output" = q1 ]
  grep -q '^notify First' "$SENT"
  run "$Q" add --title "Second" --quiet
  [ "$output" = q2 ]
  [ "$(grep -c '^notify' "$SENT")" = 1 ]
}

@test "list ranks open items by priority, then age, and hides closed ones" {
  "$Q" add --quiet --title low --priority 3
  "$Q" add --quiet --title urgent --priority 1
  "$Q" add --quiet --title normal
  "$Q" add --quiet --title done
  "$Q" dismiss q4
  run "$Q" list
  [ "${lines[0]%%  *}" = q2 ]
  [ "${lines[1]%%  *}" = q3 ]
  [ "${lines[2]%%  *}" = q1 ]
  [ "${#lines[@]}" = 3 ]
  run "$Q" list --all
  [ "${#lines[@]}" = 4 ]
}

@test "bad input is a usage error" {
  run "$Q" add --summary x
  [ "$status" -eq 2 ]
  run "$Q" add --title x --priority 5
  [ "$status" -eq 2 ]
  run "$Q" add --title x --kind party
  [ "$status" -eq 2 ]
  run "$Q" show ../etc
  [ "$status" -eq 2 ]
  run "$Q" show q99
  [ "$status" -eq 1 ]
  run "$Q" add --title x --advise maybe
  [ "$status" -eq 2 ]
}

@test "an item carries the question, the advice and at most 3 reasons, shown before the details" {
  run "$Q" add --quiet --title "Meta ads" --ask "May I read the orders?" --advise send-back \
    --why "one" --why "two" --why "three" --why "four" --summary "All the numbers."
  [ "$status" -eq 0 ]
  run "$Q" show q1 --json
  [ "$(printf '%s' "$output" | jq -r '.ask')" = "May I read the orders?" ]
  [ "$(printf '%s' "$output" | jq -r '.advise')" = reject ]
  [ "$(printf '%s' "$output" | jq -c '.why')" = '["one","two","three"]' ]
  run "$Q" show q1
  [[ "$output" == *"Question: May I read the orders?"*"Advice: Send back"*"- one"*"Details:"*"All the numbers."* ]]
}

@test "an item says why it is needed and what yes and no change, in the message and in show" {
  "$Q" add --title "PDF tool update" --ask "Merge the PDF tool update?" --advise approve \
    --need "It closes security holes on the live site." --if-yes "Safer site; check one PDF book first." \
    --if-no "The holes stay open." --why "Tests pass"
  grep -q '^notify PDF tool update' "$SENT"
  grep -q 'Why: It closes security holes on the live site.' "$SENT"
  grep -q 'If you say yes: Safer site; check one PDF book first.' "$SENT"
  grep -q 'If you say no: The holes stay open.' "$SENT"
  grep -q 'My advice: Approve' "$SENT"
  grep -q 'Answer here: yes or no' "$SENT"
  grep -q 'No answer in 72 hours counts as no' "$SENT"
  ! grep -q 'q1' "$SENT"
  run "$Q" show q1
  [[ "$output" == *"Question: Merge the PDF tool update?"*"Why it is needed: It closes"*"If you approve: Safer"*"If you say no: The holes"*"Advice: Approve"* ]]
}

@test "media are copied in, other files are skipped" {
  printf 'png' > "$T/shot.png"
  printf 'x' > "$T/notes.txt"
  "$Q" add --quiet --title ui --media "$T/shot.png" --media "$T/notes.txt"
  [ -f "$FRAIM_QUEUE_DIR/q1/media/shot.png" ]
  [ ! -e "$FRAIM_QUEUE_DIR/q1/media/notes.txt" ]
  [ "$(jq -c .media "$FRAIM_QUEUE_DIR/q1/item.json")" = '["shot.png"]' ]
}

@test "reject needs a reason, reworks the goal behind the item and feeds the brain" {
  mkdir -p "$FRAIM_GOALS_DIR/g3"
  echo "Make the login page" > "$FRAIM_GOALS_DIR/g3/goal.md"
  echo "Made it blue" > "$FRAIM_GOALS_DIR/g3/result.md"
  "$Q" add --quiet --title "Login page" --goal g3 --lead web
  run "$Q" reject q1
  [ "$status" -eq 2 ]
  run "$Q" reject q1 --note "use the brand green, not blue"
  [ "$status" -eq 0 ]
  [[ "$output" == *"goal g7 started"* ]]
  grep -qx 'env FRAIM_GOAL_FROM_QUEUE=1' "$GOAL_ARGS"
  grep -qx -- '--lead' "$GOAL_ARGS"
  grep -qx 'web' "$GOAL_ARGS"
  grep -qx -- '--queue' "$GOAL_ARGS"
  grep -q 'Make the login page' "$GOAL_ARGS"
  grep -q 'Made it blue' "$GOAL_ARGS"
  grep -q 'use the brand green' "$GOAL_ARGS"
  grep -q 'rejected q1 "Login page" (lead web): use the brand green, not blue' "$FRAIM_BRAIN_DIR/log.md"
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q1/item.json")" = rejected ]
  [ "$(jq -r .follow_up "$FRAIM_QUEUE_DIR/q1/item.json")" = g7 ]
  run "$Q" approve q1
  [ "$status" -eq 1 ]
}

@test "a rejected idea only teaches the brain" {
  "$Q" add --quiet --title "Weekly report" --kind idea --lead ops
  run "$Q" reject q1 --note "not now"
  [ "$status" -eq 0 ]
  [ ! -f "$GOAL_ARGS" ]
  grep -q 'not now' "$FRAIM_BRAIN_DIR/log.md"
}

@test "approve starts the on-approve step; without one nothing runs" {
  "$Q" add --quiet --title "PR ready" --on-approve "merge PR #12"
  "$Q" add --quiet --title "FYI"
  run "$Q" approve q1 --note "looks good"
  [[ "$output" == *"goal g7 started"* ]]
  grep -q 'merge PR #12' "$GOAL_ARGS"
  rm -f "$GOAL_ARGS"
  run "$Q" approve q2
  [ "$status" -eq 0 ]
  [ ! -f "$GOAL_ARGS" ]
  grep -q 'approved q1 "PR ready": looks good' "$FRAIM_BRAIN_DIR/log.md"
}

@test "approve of a --switch-on item switches the automation on; reject and dismiss leave it off" {
  cat > "$T/bin/fraim-auto" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUTO_ARGS"
echo "$2 is on."
EOF
  chmod +x "$T/bin/fraim-auto"
  export AUTO_ARGS="$T/auto.args"
  "$Q" add --quiet --lead engineer --kind decision --title "Monday ad spend" --switch-on ad-spend
  "$Q" add --quiet --lead engineer --kind decision --title "Other" --switch-on other
  run "$Q" show q1
  [[ "$output" == *"On approve: switch on ad-spend"* ]]
  run "$Q" approve q1
  [ "$status" -eq 0 ]
  [[ "$output" == *"ad-spend is on."* ]]
  [ "$(cat "$AUTO_ARGS")" = "on ad-spend" ]
  [ ! -f "$GOAL_ARGS" ]
  "$Q" reject q2 --note "not yet"
  [ "$(wc -l < "$AUTO_ARGS" | tr -d ' ')" = 1 ]
  run "$Q" add --title x --switch-on "Bad Name"
  [ "$status" -eq 2 ]
}

@test "a headless run cannot approve a --switch-on item" {
  "$Q" add --quiet --title "Monday ad spend" --switch-on ad-spend
  FRAIM_HEADLESS=1 run "$Q" approve q1
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner decides"* ]]
}

@test "one yes: what is built for an approved item switches on at once, also from a headless run" {
  cat > "$T/bin/fraim-auto" <<'EOF'
#!/usr/bin/env bash
[ "${FRAIM_HEADLESS:-}" != 1 ] || { echo "only the owner switches an automation on" >&2; exit 1; }
printf '%s\n' "$*" >> "$AUTO_ARGS"
echo "$2 is on."
EOF
  chmod +x "$T/bin/fraim-auto"
  export AUTO_ARGS="$T/auto.args"
  "$Q" add --quiet --lead mlv-ai --kind decision --title "AI costs: read-only check"
  "$Q" approve q1 --note "ja tuurlijk"
  rm -f "$SENT"
  FRAIM_HEADLESS=1 FRAIM_BUILDS_OFF=1 run "$Q" add --quiet --lead engineer --kind decision --title "Daily AI cost report" --if-yes "Every morning you see what stories cost." --switch-on ai-costs --approved-by q1
  [ "$status" -eq 0 ]
  [ "$output" = q2 ]
  [ "$(cat "$AUTO_ARGS")" = "on ai-costs" ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q2/item.json")" = approved ]
  [ "$(jq -r .via "$FRAIM_QUEUE_DIR/q2/item.json")" = grant ]
  [ "$(jq -r '.used_by[0]' "$FRAIM_QUEUE_DIR/q1/item.json")" = q2 ]
  # The owner hears it runs, with no question.
  grep -q 'already said yes to "AI costs: read-only check": Daily AI cost report' "$SENT"
  run grep -q 'Answer here' "$SENT"; [ "$status" -eq 1 ]
}

@test "a yes cannot be borrowed: no open, rejected, brain or chained item; the item then waits as a question" {
  cat > "$T/bin/fraim-auto" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUTO_ARGS"
EOF
  chmod +x "$T/bin/fraim-auto"
  export AUTO_ARGS="$T/auto.args"
  "$Q" add --quiet --title "still open"
  "$Q" add --quiet --title "said no"
  "$Q" reject q2 --note "no"
  "$Q" add --quiet --title "said yes"
  "$Q" approve q3
  for grant in q1 q2; do
    run "$Q" add --quiet --title "built" --switch-on thing --approved-by "$grant"
    [ "$status" -eq 0 ]
    [[ "$output" == *"waits in the queue as a normal question"* ]]
  done
  "$Q" add --quiet --title "granted" --switch-on thing --approved-by q3
  # A yes given by a grant is not the owner's yes; it cannot grant further.
  run "$Q" add --quiet --title "chained" --switch-on other --approved-by q6
  [[ "$output" == *"not a yes from the owner"* ]]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q7/item.json")" = open ]
  [ "$(grep -c . "$AUTO_ARGS")" = 1 ]
  run "$Q" add --title x --approved-by nope
  [ "$status" -eq 2 ]
  # An old yes does not count.
  jq '.decided = "2026-01-01T00:00:00Z"' "$FRAIM_QUEUE_DIR/q3/item.json" > "$T/i" && mv "$T/i" "$FRAIM_QUEUE_DIR/q3/item.json"
  run "$Q" add --quiet --title "late" --switch-on late --approved-by q3
  [[ "$output" == *"older than 14 days"* ]]
}

@test "grant records a request from the chat as the owner's yes; a headless run cannot" {
  run "$Q" grant --title "Daily security check" --note "doe maar elke dag" --via whatsapp
  [ "$status" -eq 0 ]
  [ "$output" = q1 ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q1/item.json")" = approved ]
  [ "$(jq -r .via "$FRAIM_QUEUE_DIR/q1/item.json")" = whatsapp ]
  [ ! -e "$SENT" ]
  FRAIM_HEADLESS=1 run "$Q" grant --title "sneaky"
  [ "$status" -eq 1 ]
  run "$Q" grant
  [ "$status" -eq 2 ]
}

@test "supersede closes only open failures of the same decision, and only for a goal that finished it" {
  for g in g1 g2 g3 g4 g5; do mkdir -p "$FRAIM_GOALS_DIR/$g"; done
  echo q9 > "$FRAIM_GOALS_DIR/g1/queue"; echo q9 > "$FRAIM_GOALS_DIR/g2/queue"; echo q8 > "$FRAIM_GOALS_DIR/g3/queue"
  echo q9 > "$FRAIM_GOALS_DIR/g4/queue"; echo q9 > "$FRAIM_GOALS_DIR/g5/queue"
  echo 'done 2026-11-09 10:00' > "$FRAIM_GOALS_DIR/g5/state"
  echo running > "$FRAIM_GOALS_DIR/g4/state"
  "$Q" add --quiet --goal g1 --kind failed --title "same decision"
  "$Q" add --quiet --goal g3 --kind failed --title "other decision"
  "$Q" add --quiet --goal g2 --title "same decision, a result"
  "$Q" add --quiet --goal g2 --kind failed --title "same decision, already decided"
  "$Q" dismiss q4
  run "$Q" supersede --origin q9 --by g4
  [ "$status" -ne 0 ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q1/item.json")" = open ]
  run "$Q" supersede --origin q9 --by g5
  [ "$status" -eq 0 ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q1/item.json")" = dismissed ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q2/item.json")" = open ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q3/item.json")" = open ]
  [ "$(jq -r .via "$FRAIM_QUEUE_DIR/q4/item.json")" != system ]
  run "$Q" supersede --origin ../x --by g5
  [ "$status" -eq 2 ]
}

@test "one job, one card: a follow-up result reopens the card with the new question and keeps the earlier step" {
  "$Q" add --quiet --goal g1 --title "Package updates" --ask "Merge?" --on-approve "merge" --summary "first report" >/dev/null
  "$Q" approve q1 --note "go" >/dev/null
  run "$Q" add --quiet --result --continues q1 --goal g7 --title "Other words" --ask "Deploy?" --on-approve "deploy" --summary "second report"
  [ "$status" -eq 0 ]
  [ "$output" = q1 ]
  [ ! -e "$FRAIM_QUEUE_DIR/q2" ]
  item="$FRAIM_QUEUE_DIR/q1/item.json"
  [ "$(jq -r .state "$item")" = open ]
  [ "$(jq -r .title "$item")" = "Package updates" ]
  [ "$(jq -r .ask "$item")" = "Deploy?" ]
  [ "$(jq -r .on_approve "$item")" = deploy ]
  [ "$(jq -r .goal "$item")" = g7 ]
  [ "$(jq -r .decided "$item")" = "" ]
  [ "$(jq -r '.history | length' "$item")" = 1 ]
  [ "$(jq -r '.history[0].ask' "$item")" = "Merge?" ]
  [ "$(jq -r '.history[0].state' "$item")" = approved ]
  [ "$(jq -r '.history[0].note' "$item")" = go ]
  [ "$(jq -r '.history[0].summary' "$item")" = "first report" ]
  run "$Q" show q1
  [[ "$output" == *"Earlier steps"* ]]
  [[ "$output" == *"Merge?"* ]]
}

@test "one job, one card: a follow-up with nothing to decide stays closed and prints no id" {
  "$Q" add --quiet --goal g1 --title "Job" --ask "Merge?" --on-approve "merge" --summary "first" >/dev/null
  "$Q" approve q1 >/dev/null
  run "$Q" add --quiet --result --continues q1 --goal g7 --title "Job" --summary "merged, all fine"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  item="$FRAIM_QUEUE_DIR/q1/item.json"
  [ "$(jq -r .state "$item")" = approved ]
  [ "$(jq -r .summary "$item")" = "merged, all fine" ]
  [ "$(jq -r .goal "$item")" = g7 ]
  [ "$(jq -r '.history | length' "$item")" = 1 ]
  [ ! -e "$FRAIM_QUEUE_DIR/q2" ]
}

@test "one job, one card: rework after a send-back and a failure always wait for the owner" {
  "$Q" add --quiet --goal g1 --title "Text" --ask "Good?" --summary "draft" >/dev/null
  "$Q" reject q1 --note "shorter" >/dev/null
  run "$Q" add --quiet --result --continues q1 --goal g7 --title "Text" --summary "shorter draft"
  [ "$output" = q1 ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q1/item.json")" = open ]
  "$Q" add --quiet --goal g2 --title "Job" --ask "Go?" --on-approve "go" >/dev/null
  "$Q" approve q2 >/dev/null
  run "$Q" add --quiet --result --continues q2 --goal g8 --kind failed --priority 1 --title "Failed: Job" --ask "Try this task again?" --summary "broke"
  [ "$output" = q2 ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q2/item.json")" = open ]
  [ "$(jq -r .kind "$FRAIM_QUEUE_DIR/q2/item.json")" = failed ]
  [ "$(jq -r .title "$FRAIM_QUEUE_DIR/q2/item.json")" = Job ]
}

@test "a first result with nothing to decide is on record but waits for nobody; a lost origin makes a normal card" {
  run "$Q" add --quiet --result --goal g1 --title "Check done" --summary "all fine"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q1/item.json")" = dismissed ]
  [ "$(jq -r .via "$FRAIM_QUEUE_DIR/q1/item.json")" = system ]
  run "$Q" add --quiet --result --continues q99 --goal g2 --title "Orphan" --ask "Go?" --on-approve "go"
  [ "$output" = q2 ]
  run "$Q" add --continues nonsense --title X
  [ "$status" -eq 2 ]
}

@test "a goal's own session cannot add a second card; the server and brain proposals can" {
  FRAIM_GOAL=g1 run "$Q" add --title "Twin" --ask "Merge?"
  [ "$status" -eq 2 ]
  [[ "$output" == *queue.json* ]]
  [ ! -e "$FRAIM_QUEUE_DIR/q1" ]
  FRAIM_GOAL=g1 run "$Q" add --quiet --result --goal g1 --title "Result" --ask "Merge?" --on-approve "merge"
  [ "$output" = q1 ]
  FRAIM_GOAL=g1 run "$Q" add --quiet --skill s1 --title "New skill" --ask "Install?"
  [ "$output" = q2 ]
}

@test "the owner's yes still counts after the card moved on to its next question" {
  "$Q" add --quiet --goal g1 --title "Job" --ask "Go?" --on-approve "go" >/dev/null
  "$Q" approve q1 >/dev/null
  "$Q" add --quiet --result --continues q1 --goal g7 --title "Job" --ask "Next?" --on-approve "next" >/dev/null
  run "$Q" add --quiet --title "Built for it" --approved-by q1
  [ "$status" -eq 0 ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q2/item.json")" = approved ]
  "$Q" reject q1 --note "no" >/dev/null
  "$Q" add --quiet --result --continues q1 --goal g8 --title "Job" --ask "Again?" --on-approve "again" >/dev/null
  run "$Q" add --quiet --title "Borrowed" --approved-by q1
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q3/item.json")" = open ]
}

@test "the queue trigger reports new cards and cards that moved on, each once" {
  export PATH="$T/bin:$(dirname "$Q"):$PATH" FRAIM_TRIGGER_STATE="$T/trigger" FRAIM_LEADS_DIR="$T/leads"
  TRIGGER="$BATS_TEST_DIRNAME/../../workspace/automation-kit/triggers/queue"
  mkdir -p "$T/trigger"
  "$Q" add --quiet --goal g1 --title "Job" --ask "Go?" --on-approve "go" >/dev/null
  run "$TRIGGER" events
  [ -z "$output" ]
  "$Q" approve q1 >/dev/null
  run "$TRIGGER" events
  [ -z "$output" ]
  "$Q" add --quiet --result --continues q1 --goal g7 --title "Job" --ask "Next?" --on-approve "next" >/dev/null
  run "$TRIGGER" events
  [[ "$output" == q1* ]]
  run "$TRIGGER" events
  [ -z "$output" ]
}

@test "dismiss closes without a goal or a brain note" {
  "$Q" add --quiet --title x --goal g1
  "$Q" dismiss q1
  [ ! -f "$GOAL_ARGS" ]
  [ ! -f "$FRAIM_BRAIN_DIR/log.md" ]
}

@test "prio changes the priority" {
  "$Q" add --quiet --title x
  "$Q" prio q1 1
  [ "$(jq -r .priority "$FRAIM_QUEUE_DIR/q1/item.json")" = 1 ]
  run "$Q" prio q1 9
  [ "$status" -eq 2 ]
}

@test "url uses the space's last preview port and a token" {
  printf "FRAIM_ACCESS_MODE=tailscale\nFRAIM_HOSTNAME=fraim-x\nFRAIM_PREVIEW_PORTS=3110-3119\n" > "$T/runtime.env"
  FRAIM_RUNTIME_ENV="$T/runtime.env" run "$Q" url
  [[ "$output" =~ ^http://fraim-x:3119/\?t=[A-Za-z0-9_-]{20,}$ ]]
  [ "$(stat -c %a "$HOME/.config/fraim/queue-token" 2>/dev/null || stat -f %Lp "$HOME/.config/fraim/queue-token")" = 600 ]
}

age() { jq --arg c "$2" '.created = $c' "$FRAIM_QUEUE_DIR/$1/item.json" > "$T/i" && mv "$T/i" "$FRAIM_QUEUE_DIR/$1/item.json"; }

@test "expire closes questions older than 72 hours as a no, and tells the owner once" {
  "$Q" add --quiet --title "Old question" --ask "Do it?" --on-approve "do it"
  "$Q" add --quiet --title "Fresh question" --ask "Do it too?"
  "$Q" add --quiet --title "Old note without a question"
  age q1 2026-01-01T00:00:00Z
  age q3 2026-01-01T00:00:00Z
  run "$Q" expire
  [ "$status" -eq 0 ]
  [ "$output" = "closed q1" ]
  [ "$(jq -r '.state + " " + .via' "$FRAIM_QUEUE_DIR/q1/item.json")" = "dismissed expired" ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q2/item.json")" = open ]
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q3/item.json")" = open ]
  [ ! -e "$GOAL_ARGS" ]
  [ "$(grep -c 'No answer in 72 hours, so I took these as a no' "$SENT")" = 1 ]
  grep -q -- '- Old question' "$SENT"
}

@test "expire_hours in the queue settings changes the wait, and 0 never expires" {
  "$Q" add --quiet --title "Q" --ask "Do it?"
  age q1 "$(date -u -d '-3 hours' +%FT%TZ 2>/dev/null || date -u -v-3H +%FT%TZ)"
  run "$Q" expire --quiet
  [ "$output" = "nothing to close" ]
  echo expire_hours=2 > "$FRAIM_QUEUE_DIR/settings"
  run "$Q" expire --quiet
  [ "$output" = "closed q1" ]
  "$Q" add --quiet --title "Q2" --ask "Again?"
  age q2 2026-01-01T00:00:00Z
  echo expire_hours=0 > "$FRAIM_QUEUE_DIR/settings"
  run "$Q" expire --quiet
  [ "$output" = "nothing to close" ]
  [ ! -e "$SENT" ]
}

@test "always ID approves it and every same question from the same agent after it" {
  "$Q" add --quiet --title "Merge dependabot PR 12" --lead web --ask "Merge?" --on-approve "merge it"
  run "$Q" always q1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state + " " + .via' "$FRAIM_QUEUE_DIR/q1/item.json")" = "approved always" ]
  rm -f "$GOAL_ARGS"
  run "$Q" add --title "Merge Dependabot PR 47" --lead web --ask "Merge?" --on-approve "merge 47"
  [ "$(jq -r '.state + " " + .via' "$FRAIM_QUEUE_DIR/q2/item.json")" = "approved always" ]
  grep -q 'merge 47' "$GOAL_ARGS"
  grep -q 'Done without asking, because you always say yes to this: Merge Dependabot PR 47' "$SENT"
  "$Q" add --quiet --title "Merge dependabot PR 48" --lead shop --ask "Merge?" --on-approve "x"
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q3/item.json")" = open ]
  "$Q" add --quiet --title "Merge dependabot PR 49" --lead web --ask "Merge?" --switch-on nightly
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q4/item.json")" = open ]
  run "$Q" always list
  [[ "$output" == '1. "merge dependabot pr #" from web: start a task'* ]]
  run "$Q" always rm 1
  [ "$status" -eq 0 ]
  "$Q" add --quiet --title "Merge dependabot PR 50" --lead web --ask "Merge?" --on-approve "y"
  [ "$(jq -r .state "$FRAIM_QUEUE_DIR/q5/item.json")" = open ]
}

@test "only the owner gives a standing yes, and never for a brain change" {
  "$Q" add --quiet --title "T" --lead web --ask "Do it?"
  FRAIM_HEADLESS=1 run "$Q" always q1
  [ "$status" -ne 0 ]
  [[ "$output" == *"only the owner"* ]]
  [ ! -e "$FRAIM_QUEUE_DIR/always.json" ]
  "$Q" add --quiet --title "Rule change" --brain p1
  run "$Q" always q2
  [ "$status" -ne 0 ]
  [[ "$output" == *"asked every time"* ]]
}
