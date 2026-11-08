#!/usr/bin/env bats
# workspace/bin/fraim-goal with a fake fraim-claude, fraim-gateway and fraim-notify:
# ids, the background run, the result message, failures and stop.

setup() {
  GOAL="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-goal"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim"
  export HOME="$T/home" FRAIM_GOALS_DIR="$T/home/fraim/goals" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args"
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
[ -z "${FAKE_FAIL:-}" ] || { echo "usage limit reached" >&2; exit 1; }
echo "Booked nothing, made a list in ~/fraim/goals/g1/flights.md"
EOF
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf 'gateway %s\n' "$3" >> "$SENT"
EOF
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >> "$SENT"
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

@test "start prints g1, then g2, and runs in the background" {
  run "$GOAL" start -- find flights
  [ "$status" -eq 0 ]
  [ "$output" = g1 ]
  run "$GOAL" start "second goal"
  [ "$output" = g2 ]
  wait_state g1 done
  wait_state g2 done
  [ "$(cat "$FRAIM_GOALS_DIR/g1/goal.md")" = "find flights" ]
}

@test "the result goes to the WhatsApp chat the goal came from" {
  run "$GOAL" start --chat 316@s.whatsapp.net -- find flights
  wait_state g1 done
  for _ in $(seq 20); do [ -s "$SENT" ] && break; sleep 0.1; done
  grep -q '"chat_id":"316@s.whatsapp.net"' "$SENT"
  grep -q 'Goal g1 done' "$SENT"
  grep -q 'flights.md' "$FRAIM_GOALS_DIR/g1/result.md"
}

@test "without a chat the owner gets the result through fraim-notify" {
  "$GOAL" start -- tidy up
  wait_state g1 done
  for _ in $(seq 20); do [ -s "$SENT" ] && break; sleep 0.1; done
  grep -q '^notify Goal g1 done' "$SENT"
}

@test "the goal text reaches Claude inside the prompt, with acceptEdits and the tools" {
  "$GOAL" start -- 'text with $(danger) and "quotes"'
  wait_state g1 done
  grep -qF 'text with $(danger) and "quotes"' "$CLAUDE_ARGS"
  grep -qx -- '--permission-mode' "$CLAUDE_ARGS"
  grep -qx 'acceptEdits' "$CLAUDE_ARGS"
  grep -qx 'Read,Glob,Grep,Edit,Write,WebSearch,Bash,mcp__browser' "$CLAUDE_ARGS"
}

@test "the result lands in the review queue with queue.json and media; the brain rules reach the prompt" {
  export PATH="$T/bin:$BATS_TEST_DIRNAME/../../workspace/bin:$PATH" FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_BRAIN_DIR="$T/home/fraim/brain"
  mkdir -p "$FRAIM_BRAIN_DIR"
  printf '# How the owner wants things\n- Short summaries.\n' > "$FRAIM_BRAIN_DIR/rules.md"
  # The fake run writes what a real goal writes: queue.json and a screenshot.
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
mkdir -p "$FRAIM_GOALS_DIR/g1/media"
printf 'png' > "$FRAIM_GOALS_DIR/g1/media/after.png"
printf '{"title":"New login page","priority":1,"kind":"review","links":["https://example.com/pr/1"],"on_approve":"merge PR #1"}' > "$FRAIM_GOALS_DIR/g1/queue.json"
echo "Built the login page."
EOF
  "$GOAL" start --lead web -- build the login page
  wait_state g1 done
  grep -q 'Short summaries.' "$CLAUDE_ARGS"
  item="$FRAIM_QUEUE_DIR/q1/item.json"
  for _ in $(seq 20); do [ -s "$item" ] && break; sleep 0.1; done
  [ "$(jq -r .title "$item")" = "New login page" ]
  [ "$(jq -r .priority "$item")" = 1 ]
  [ "$(jq -r .goal "$item")" = g1 ]
  [ "$(jq -r .lead "$item")" = web ]
  [ "$(jq -r .on_approve "$item")" = "merge PR #1" ]
  [ "$(jq -c .media "$item")" = '["after.png"]' ]
  [ "$(jq -c .links "$item")" = '["https://example.com/pr/1"]' ]
  for _ in $(seq 20); do [ -s "$SENT" ] && break; sleep 0.1; done
  grep -q 'ok q1' "$SENT"
}

@test "a failed goal becomes a priority 1 item" {
  export PATH="$T/bin:$BATS_TEST_DIRNAME/../../workspace/bin:$PATH" FRAIM_QUEUE_DIR="$T/home/fraim/queue"
  FAKE_FAIL=1 "$GOAL" start -- x
  wait_state g1 failed
  item="$FRAIM_QUEUE_DIR/q1/item.json"
  for _ in $(seq 20); do [ -s "$item" ] && break; sleep 0.1; done
  [ "$(jq -r .kind "$item")" = failed ]
  [ "$(jq -r .priority "$item")" = 1 ]
  [[ "$(jq -r .title "$item")" == "Failed: x" ]]
}

@test "a tools file replaces the default tools" {
  mkdir -p "$FRAIM_GOALS_DIR"
  printf '# comment\nRead\n\nWebFetch(domain:example.com)\n' > "$FRAIM_GOALS_DIR/tools"
  "$GOAL" start -- x
  wait_state g1 done
  grep -qx 'Read,WebFetch(domain:example.com)' "$CLAUDE_ARGS"
}

@test "a failed run says why" {
  FAKE_FAIL=1 "$GOAL" start -- x
  wait_state g1 failed
  grep -q 'usage limit' "$FRAIM_GOALS_DIR/g1/state"
  for _ in $(seq 20); do [ -s "$SENT" ] && break; sleep 0.1; done
  grep -q 'Goal g1 failed' "$SENT"
}

@test "list and show" {
  "$GOAL" start -- first goal
  wait_state g1 done
  run "$GOAL" list
  [[ "$output" == "g1  done "*"first goal" ]]
  run "$GOAL" show g1
  [[ "$output" == *"first goal"* ]]
  [[ "$output" == *"Result:"* ]]
}

@test "stop ends a running goal and sends nothing" {
  FAKE_SLEEP=30 "$GOAL" start -- slow
  wait_state g1 running
  for _ in $(seq 20); do [ -s "$CLAUDE_ARGS" ] && break; sleep 0.1; done
  run "$GOAL" stop g1
  [ "$output" = "Goal g1 stopped." ]
  wait_state g1 stopped
  sleep 0.5
  [ ! -s "$SENT" ]
}

@test "bad input is a usage error" {
  run "$GOAL" start
  [ "$status" -eq 2 ]
  run "$GOAL" show ../etc
  [ "$status" -eq 2 ]
  run "$GOAL" show g9
  [ "$status" -eq 1 ]
  run "$GOAL" list
  [ "$output" = "No goals yet." ]
}
