#!/usr/bin/env bats
# workspace/bin/fraim-goal with a fake hc (herdr-core), fraim-gateway and fraim-notify:
# ids, the live session, the result message, follow-up messages, failures, stop, reconcile.

setup() {
  GOAL="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-goal"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim"
  export HOME="$T/home" FRAIM_GOALS_DIR="$T/home/fraim/goals" SENT="$T/sent" HC_FAKE="$T/hc"
  export FAKE_REPLY="Booked nothing, made a list in ~/fraim/goals/g1/flights.md"
  export FRAIM_GOAL_POLL=0.1 FRAIM_GOAL_KEEP=0 FRAIM_GOAL_READY=1
  cp "$BATS_TEST_DIRNAME/fakes/hc" "$T/bin/hc"
  ln -s "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-herdr" "$T/bin/fraim-herdr"
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf 'gateway %s\n' "$3" >> "$SENT"
EOF
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
printf 'notify%s %s\n' "${FRAIM_NOTIFY_CHAT:+ to $FRAIM_NOTIFY_CHAT}" "$*" >> "$SENT"
EOF
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=whatsapp,scheduler\n' > "$T/runtime.env"
  export PATH="$T/bin:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
}

wait_state() {
  for _ in $(seq 50); do
    grep -q "^$2" "$FRAIM_GOALS_DIR/$1/state" 2>/dev/null && return 0
    sleep 0.1
  done
  cat "$FRAIM_GOALS_DIR/$1/state" >&2
  return 1
}

wait_sent() {
  for _ in $(seq 50); do grep -q "$1" "$SENT" 2>/dev/null && return 0; sleep 0.1; done
  cat "$SENT" >&2 2>/dev/null
  return 1
}

wait_gone() {
  for _ in $(seq 50); do [ ! -f "$HC_FAKE/t-$1.json" ] && return 0; sleep 0.1; done
  return 1
}

@test "start prints g1, then g2, and each runs in its own terminal" {
  run "$GOAL" start -- find flights
  [ "$status" -eq 0 ]
  [ "$output" = g1 ]
  run "$GOAL" start "second goal"
  [ "$output" = g2 ]
  wait_state g1 done
  wait_state g2 done
  [ "$(cat "$FRAIM_GOALS_DIR/g1/goal.md")" = "find flights" ]
  grep -q 'find flights' "$HC_FAKE/g1.sent"
  grep -q 'second goal' "$HC_FAKE/g2.sent"
}

@test "the terminal runs headless Claude with acceptEdits, the tools and its own session id" {
  "$GOAL" start -- 'text with $(danger) and "quotes"'
  wait_state g1 done
  argv="$HC_FAKE/g1.argv"
  [ "$(head -3 "$argv" | paste -sd' ' -)" = "env FRAIM_HEADLESS=1 FRAIM_GOAL=g1" ]
  grep -qx fraim-claude "$argv"
  grep -qx -- '--session-id' "$argv"
  grep -qx "$(cat "$FRAIM_GOALS_DIR/g1/session-id")" "$argv"
  grep -qx acceptEdits "$argv"
  grep -qx 'Read,Glob,Grep,Edit,Write,WebSearch,Bash,mcp__browser' "$argv"
  grep -qF 'text with $(danger) and "quotes"' "$HC_FAKE/g1.sent"
  grep -q 'run --bg --name g1 --cwd .*/fraim --label fraim=goal' "$HC_FAKE/calls"
}

@test "the result goes through fraim-notify to the chat the goal came from, without reply codes" {
  run "$GOAL" start --chat 316@s.whatsapp.net -- find flights
  wait_state g1 done
  wait_sent 'Goal g1 done'
  grep -q '^notify to 316@s.whatsapp.net Goal g1 done' "$SENT"
  run grep -q 'g1: <message>' "$SENT"
  [ "$status" -eq 1 ]
  grep -q 'flights.md' "$FRAIM_GOALS_DIR/g1/result.md"
}

@test "without a chat the owner gets the result through fraim-notify" {
  "$GOAL" start -- tidy up
  wait_state g1 done
  wait_sent '^notify Goal g1 done'
}

@test "after the keep time the terminal closes; the goal stays done" {
  "$GOAL" start -- tidy up
  wait_state g1 done
  wait_gone g1
  wait_state g1 done
}

@test "the result lands in the review queue with queue.json and media; the brain rules reach the prompt" {
  export PATH="$T/bin:$BATS_TEST_DIRNAME/../../workspace/bin:$PATH" FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_BRAIN_DIR="$T/home/fraim/brain"
  mkdir -p "$FRAIM_BRAIN_DIR"
  printf '# How the owner wants things\n- Short summaries.\n' > "$FRAIM_BRAIN_DIR/rules.md"
  # What a real run writes before it ends: queue.json and a screenshot.
  cat > "$T/bin/write-results" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$FRAIM_GOALS_DIR/g1/media"
printf 'png' > "$FRAIM_GOALS_DIR/g1/media/after.png"
printf '{"title":"New login page","priority":1,"kind":"review","links":["https://example.com/pr/1"],"on_approve":"merge PR #1"}' > "$FRAIM_GOALS_DIR/g1/queue.json"
EOF
  chmod +x "$T/bin/write-results"
  FAKE_SEND_HOOK="$T/bin/write-results" FAKE_REPLY="Built the login page." "$GOAL" start --lead web -- build the login page
  wait_state g1 done
  grep -q 'Short summaries.' "$HC_FAKE/g1.sent"
  item="$FRAIM_QUEUE_DIR/q1/item.json"
  for _ in $(seq 20); do [ -s "$item" ] && break; sleep 0.1; done
  [ "$(jq -r .title "$item")" = "New login page" ]
  [ "$(jq -r .priority "$item")" = 1 ]
  [ "$(jq -r .goal "$item")" = g1 ]
  [ "$(jq -r .lead "$item")" = web ]
  [ "$(jq -r .on_approve "$item")" = "merge PR #1" ]
  [ "$(jq -c .media "$item")" = '["after.png"]' ]
  [ "$(jq -c .links "$item")" = '["https://example.com/pr/1"]' ]
  wait_sent 'Tell me what you think of it in your own words'
}

@test "each extra question becomes its own decision, and the prompt asks for plain words" {
  export PATH="$T/bin:$BATS_TEST_DIRNAME/../../workspace/bin:$PATH" FRAIM_QUEUE_DIR="$T/home/fraim/queue"
  cat > "$T/bin/write-results" <<'EOF'
#!/usr/bin/env bash
printf '{"title":"Check the orders? I advise yes","kind":"decision","on_approve":"check the orders","more":["Count checkout at payment? I advise yes"]}' > "$FRAIM_GOALS_DIR/g1/queue.json"
EOF
  chmod +x "$T/bin/write-results"
  FAKE_SEND_HOOK="$T/bin/write-results" "$GOAL" start --lead perf -- check meta
  wait_state g1 done
  grep -q 'no internal names' "$HC_FAKE/g1.sent"
  for _ in $(seq 20); do [ -s "$FRAIM_QUEUE_DIR/q2/item.json" ] && break; sleep 0.1; done
  [ "$(jq -r .on_approve "$FRAIM_QUEUE_DIR/q1/item.json")" = "check the orders" ]
  [ "$(jq -r .ask "$FRAIM_QUEUE_DIR/q2/item.json")" = "Count checkout at payment? I advise yes" ]
  [ "$(jq -r .kind "$FRAIM_QUEUE_DIR/q2/item.json")" = decision ]
  [ "$(jq -r .lead "$FRAIM_QUEUE_DIR/q2/item.json")" = perf ]
  [[ "$(jq -r .on_approve "$FRAIM_QUEUE_DIR/q2/item.json")" == *"Count checkout at payment"* ]]
}

@test "a run that ends on a usage limit fails, says why and becomes a priority 1 item" {
  export PATH="$T/bin:$BATS_TEST_DIRNAME/../../workspace/bin:$PATH" FRAIM_QUEUE_DIR="$T/home/fraim/queue"
  FAKE_REPLY="You've hit your usage limit" "$GOAL" start -- x
  wait_state g1 failed
  grep -q 'usage limit' "$FRAIM_GOALS_DIR/g1/state"
  wait_sent 'Goal g1 failed'
  item="$FRAIM_QUEUE_DIR/q1/item.json"
  for _ in $(seq 20); do [ -s "$item" ] && break; sleep 0.1; done
  [ "$(jq -r .kind "$item")" = failed ]
  [[ "$(jq -r .title "$item")" == "Failed: x" ]]
}

@test "a session that does not start fails the goal" {
  FAKE_RUN_FAIL=1 "$GOAL" start -- x
  wait_state g1 failed
  grep -q 'did not start' "$FRAIM_GOALS_DIR/g1/state"
}

@test "a tools file replaces the default tools" {
  mkdir -p "$FRAIM_GOALS_DIR"
  printf '# comment\nRead\n\nWebFetch(domain:example.com)\n' > "$FRAIM_GOALS_DIR/tools"
  "$GOAL" start -- x
  wait_state g1 done
  grep -qx 'Read,WebFetch(domain:example.com)' "$HC_FAKE/g1.argv"
}

@test "send reaches a live goal and its answer comes back" {
  FRAIM_GOAL_KEEP=30 "$GOAL" start -- find flights
  wait_state g1 done
  wait_sent 'Goal g1 done'
  FAKE_REPLY="Also checked trains." run "$GOAL" send g1 "check trains too"
  [ "$status" -eq 0 ]
  [ "$output" = "Sent to g1." ]
  grep -q 'check trains too' "$HC_FAKE/g1.sent"
  wait_sent 'Goal g1 answered'
  wait_state g1 done
  grep -q 'Also checked trains' "$FRAIM_GOALS_DIR/g1/result.md"
  "$GOAL" stop g1
}

@test "send to a closed goal reopens the same conversation" {
  "$GOAL" start -- find flights
  wait_state g1 done
  wait_gone g1
  sid="$(cat "$FRAIM_GOALS_DIR/g1/session-id")"
  FAKE_REPLY="Reopened." run "$GOAL" send g1 "one more thing"
  [ "$status" -eq 0 ]
  grep -qx -- '--resume' "$HC_FAKE/g1.argv"
  grep -qx "$sid" "$HC_FAKE/g1.argv"
  wait_sent 'Goal g1 answered'
}

@test "a question on the screen is answered with send --force" {
  FAKE_SEND_STATE=blocked FRAIM_GOAL_KEEP=30 "$GOAL" start -- pick a drink
  for _ in $(seq 30); do grep -q '^send ' "$HC_FAKE/calls" && break; sleep 0.1; done
  sleep 0.3
  run "$GOAL" send g1 "tea"
  [ "$status" -eq 0 ]
  grep -q '^send --force g1 tea' "$HC_FAKE/calls"
  "$GOAL" stop g1
}

@test "list, show and read" {
  FRAIM_GOAL_KEEP=30 "$GOAL" start -- first goal
  wait_state g1 done
  run "$GOAL" list
  [[ "$output" == "g1  done "*"first goal"* ]]
  run "$GOAL" show g1
  [[ "$output" == *"first goal"* ]]
  [[ "$output" == *"Result:"* ]]
  FAKE_SCREEN="the screen" run "$GOAL" read g1
  [ "$output" = "the screen" ]
  "$GOAL" stop g1
  wait_gone g1 || true
}

@test "stop ends a running goal and sends nothing" {
  FAKE_SEND_STATE=working "$GOAL" start -- slow
  wait_state g1 running
  for _ in $(seq 30); do grep -q '^send ' "$HC_FAKE/calls" && break; sleep 0.1; done
  run "$GOAL" stop g1
  [ "$output" = "Goal g1 stopped." ]
  wait_state g1 stopped
  sleep 0.5
  [ ! -s "$SENT" ]
  [ "$(jq -r .state "$HC_FAKE/t-g1.json")" = finished ]
}

@test "reconcile gives a live goal without a watcher a new one, and fails a vanished one" {
  mkdir -p "$FRAIM_GOALS_DIR/g1" "$FRAIM_GOALS_DIR/g2"
  for g in g1 g2; do
    echo "goal $g" > "$FRAIM_GOALS_DIR/$g/goal.md"
    echo "running 2026-01-01 10:00" > "$FRAIM_GOALS_DIR/$g/state"
    echo "sid-$g" > "$FRAIM_GOALS_DIR/$g/session-id"
    touch -t 202601010000 "$FRAIM_GOALS_DIR/$g/heartbeat"
  done
  mkdir -p "$HC_FAKE"
  jq -n '{address: "g1", name: "g1", labels: {fraim: "goal"}, state: "live", status: {state: "working"}, turn: 0}' > "$HC_FAKE/t-g1.json"
  printf -- 'fraim-claude\n--session-id\nsid-g1\n' > "$HC_FAKE/g1.argv"
  run "$GOAL" reconcile
  [ "$status" -eq 0 ]
  wait_state g2 failed
  grep -q 'server restarted' "$FRAIM_GOALS_DIR/g2/state"
  for _ in $(seq 30); do [ -n "$(find "$FRAIM_GOALS_DIR/g1/heartbeat" -newer "$FRAIM_GOALS_DIR/g1/goal.md")" ] && break; sleep 0.1; done
  [ -n "$(find "$FRAIM_GOALS_DIR/g1/heartbeat" -newer "$FRAIM_GOALS_DIR/g1/goal.md")" ]
  "$GOAL" stop g1
}

@test "bad input is a usage error" {
  run "$GOAL" start
  [ "$status" -eq 2 ]
  run "$GOAL" show ../etc
  [ "$status" -eq 2 ]
  run "$GOAL" show g9
  [ "$status" -eq 1 ]
  run "$GOAL" send g1
  [ "$status" -eq 2 ]
  run "$GOAL" read g1 abc
  [ "$status" -eq 1 ]
  run "$GOAL" list
  [ "$output" = "No goals yet." ]
}
