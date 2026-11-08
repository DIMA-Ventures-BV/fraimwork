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
  grep -q 'New in your queue: q1 First' "$SENT"
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
