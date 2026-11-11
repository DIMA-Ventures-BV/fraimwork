#!/usr/bin/env bats
# workspace/bin/fraim-sessions and fraim-herdr with a fake hc: coding sessions in ~/code,
# trust, the limit, send/reopen, list, stop, and what the watcher tells the owner.

setup() {
  SESSIONS="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-sessions"
  HERDR="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-herdr"
  # The physical path: sessions store the real folder (macOS /var is a symlink).
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$T/bin" "$T/home/code/vertelboek" "$T/home/fraim" "$T/hc"
  export HOME="$T/home" HC_FAKE="$T/hc" SENT="$T/sent" FRAIM_SESSION_READY=1
  cp "$BATS_TEST_DIRNAME/fakes/hc" "$T/bin/hc"
  ln -s "$HERDR" "$T/bin/fraim-herdr"
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >> "$SENT"
EOF
  find "$T/bin" -type f -exec chmod +x {} +
  printf 'FRAIM_MODULES=whatsapp\n' > "$T/runtime.env"
  export PATH="$T/bin:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
}

@test "new starts Claude in the repo, trusts the folder and sends the task" {
  run "$SESSIONS" new vertelboek -- fix the login bug
  [ "$status" -eq 0 ]
  [ "$output" = s1 ]
  grep -q "run --bg --name s1 --cwd $HOME/code/vertelboek --label fraim=session --label repo=vertelboek" "$HC_FAKE/calls"
  [ "$(head -1 "$HC_FAKE/s1.argv")" = fraim-claude ]
  grep -qx -- '--session-id' "$HC_FAKE/s1.argv"
  grep -q 'fix the login bug' "$HC_FAKE/s1.sent"
  jq -e --arg d "$HOME/code/vertelboek" '.projects[$d].hasTrustDialogAccepted == true' "$HOME/.claude.json"
  run "$SESSIONS" new vertelboek
  [ "$output" = s2 ]
  [ ! -f "$HC_FAKE/s2.sent" ]
}

@test "with a linked Herdr app, a coding session shows in fraim's space there" {
  mkdir -p "$HOME/.config/fraim"
  printf 'sp0123abcd\n' > "$HOME/.config/fraim/herdr-space"
  "$SESSIONS" new vertelboek -- fix the login bug
  grep -q -- '--name s1 .*--label herdr.space=sp0123abcd' "$HC_FAKE/calls"
}

@test "with a linked Herdr app, main (the chief) opens in fraim's space there" {
  mkdir -p "$HOME/.config/fraim"
  printf 'sp0123abcd\n' > "$HOME/.config/fraim/herdr-space"
  : > "$HOME/fraim/services"
  "$HERDR" up
  grep -q -- '--name main .*--label herdr.space=sp0123abcd' "$HC_FAKE/calls"
}

@test "new refuses folders outside home and unknown repos" {
  run "$SESSIONS" new ../../etc
  [ "$status" -eq 2 ]
  run "$SESSIONS" new /etc
  [ "$status" -eq 2 ]
  # Only ~/code: not another folder in home, and not through a symlink.
  mkdir -p "$HOME/.claude" "$HOME/code/sub"
  run "$SESSIONS" new "$HOME/.claude"
  [ "$status" -eq 2 ]
  ln -s "$HOME/.claude" "$HOME/code/sneaky"
  run "$SESSIONS" new sneaky
  [ "$status" -eq 1 ]
  [[ "$output" == *"repo folder under"* ]]
  run "$SESSIONS" new "$HOME/code/sub"
  [ "$status" -eq 0 ]
  run "$SESSIONS" new nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no folder"* ]]
}

@test "at most FRAIM_SESSIONS_MAX run at once" {
  FRAIM_SESSIONS_MAX=1 "$SESSIONS" new vertelboek
  FRAIM_SESSIONS_MAX=1 run "$SESSIONS" new vertelboek
  [ "$status" -eq 1 ]
  [[ "$output" == *"stop one first"* ]]
}

@test "send reaches an open session; a closed one reopens with --resume" {
  "$SESSIONS" new vertelboek
  run "$SESSIONS" send s1 "run the tests"
  [ "$output" = "Sent to s1." ]
  grep -q 'run the tests' "$HC_FAKE/s1.sent"
  run "$SESSIONS" stop s1
  [[ "$output" == "Session s1 closed."* ]]
  [ ! -f "$HC_FAKE/t-s1.json" ]
  run "$SESSIONS" send s1 "and now?"
  [ "$status" -eq 0 ]
  grep -qx -- '--resume' "$HC_FAKE/s1.argv"
  grep -qx "$(cat "$HOME/fraim/sessions/s1/session-id")" "$HC_FAKE/s1.argv"
}

@test "list shows open sessions with status and closed ones" {
  "$SESSIONS" new vertelboek -- task one
  "$SESSIONS" new vertelboek -- task two
  "$SESSIONS" stop s2
  run "$SESSIONS" list
  [[ "$output" == *"s1  done  ~/code/vertelboek"* ]]
  [[ "$output" == *"Closed (send reopens one):"* ]]
  [[ "$output" == *"s2  closed  vertelboek  task two"* ]]
}

@test "fraim-herdr ls lists fraim terminals only, with the question of a blocked one" {
  jq -n --arg c "$HOME/fraim" '{name: "main", labels: {fraim: "main"}, state: "live", status: {state: "idle"}, cwd: $c, turn: 1}' > "$HC_FAKE/t-main.json"
  jq -n --arg c "$HOME/fraim" '{name: "g3", labels: {fraim: "goal"}, state: "live", status: {state: "blocked", msg: "answer: tea or coffee?"}, cwd: $c, turn: 1}' > "$HC_FAKE/t-g3.json"
  jq -n '{name: "other", labels: {}, state: "live", status: null, cwd: "/tmp", turn: 0}' > "$HC_FAKE/t-other.json"
  jq -n '{name: "watch", labels: {fraim: "service"}, state: "live", status: null, cwd: "/tmp", turn: 0}' > "$HC_FAKE/t-watch.json"
  run "$HERDR" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"g3	goal	blocked	~/fraim	answer: tea or coffee?"* ]]
  [[ "$output" == *"main	main	idle"* ]]
  [[ "$output" != *other* ]]
  [[ "$output" != *watch* ]]
}

@test "the scheduler never starts its own core" {
  FRAIM_ROLE=scheduler run "$HERDR" hc ls
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not answer"* ]]
  [ ! -s "$HC_FAKE/calls" ]
  FRAIM_ROLE=scheduler run "$HERDR" up
  [ "$status" -eq 1 ]
}

@test "up starts main, the queue page and the watcher once" {
  run "$HERDR" up
  [ "$status" -eq 0 ]
  [ "$(jq -r .labels.fraim "$HC_FAKE/t-main.json")" = main ]
  grep -qx fraim-session "$HC_FAKE/main.argv"
  [ -f "$HC_FAKE/t-queue-page.json" ]
  [ -f "$HC_FAKE/t-watch.json" ]
  run "$HERDR" up
  [ "$(grep -c '^run ' "$HC_FAKE/calls")" -eq 3 ]
}

@test "last-text reads the session's transcript" {
  "$SESSIONS" new vertelboek
  FAKE_REPLY="All 12 tests pass." "$SESSIONS" send s1 "run the tests"
  run "$HERDR" last-text s1
  [ "$output" = "All 12 tests pass." ]
}

@test "attach and read need the session to exist" {
  run "$SESSIONS" read s9
  [ "$status" -eq 1 ]
  run "$SESSIONS" attach s1
  [ "$status" -eq 1 ]
  run "$HERDR" attach main
  [ "$status" -eq 2 ]
}

@test "a run without the owner can neither start nor steer a coding session" {
  "$SESSIONS" new vertelboek
  FRAIM_HEADLESS=1 run "$SESSIONS" new vertelboek -- approve the queue
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
  FRAIM_HEADLESS=1 run "$SESSIONS" send s1 "run fraim-queue approve q3"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'approve q3' "$HC_FAKE/s1.sent" 2>/dev/null)" = 0 ] || [ ! -f "$HC_FAKE/s1.sent" ]
}

@test "fraim-herdr hc: without the owner only goals can be driven, everything can be read" {
  jq -n '{name: "main", labels: {fraim: "main"}, state: "live", status: {state: "idle"}, turn: 1}' > "$HC_FAKE/t-main.json"
  jq -n '{name: "g4", labels: {fraim: "goal"}, state: "live", status: {state: "idle"}, turn: 1}' > "$HC_FAKE/t-g4.json"
  printf 'x\n' > "$HC_FAKE/g4.argv"
  FRAIM_HEADLESS=1 run "$HERDR" hc send main "approve q3"
  [ "$status" -eq 1 ]
  FRAIM_HEADLESS=1 run "$HERDR" hc keys --json main enter
  [ "$status" -eq 1 ]
  FRAIM_HEADLESS=1 run "$HERDR" hc run --bg --name s9 -- fraim-claude
  [ "$status" -eq 1 ]
  [ ! -f "$HC_FAKE/main.sent" ]
  FRAIM_HEADLESS=1 run "$HERDR" hc send g4 "also check trains"
  [ "$status" -eq 0 ]
  FRAIM_HEADLESS=1 run "$HERDR" hc read main
  [ "$status" -eq 0 ]
}

@test "trust keeps every other setting in ~/.claude.json, and leaves a broken file alone" {
  printf '{"oauthAccount": {"email": "o@example.com"}, "projects": {"/x": {"hasTrustDialogAccepted": true}}}\n' > "$HOME/.claude.json"
  run "$HERDR" trust "$HOME/code/vertelboek"
  [ "$status" -eq 0 ]
  [ "$(jq -r .oauthAccount.email "$HOME/.claude.json")" = o@example.com ]
  [ "$(jq -r '.projects["/x"].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ]
  jq -e --arg d "$HOME/code/vertelboek" '.projects[$d].hasTrustDialogAccepted == true' "$HOME/.claude.json"
  printf 'not json' > "$HOME/.claude.json"
  run "$HERDR" trust "$HOME/code/other"
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/.claude.json")" = "not json" ]
}

@test "redact hides tokens and keys" {
  printf 'key sk-ant-api03-abcdefghijklmnopqrstuv and GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz12 and password: hunter2secret, plain words stay' > "$T/in"
  run "$HERDR" redact < "$T/in"
  [[ "$output" != *abcdefghijklmnop* ]]
  [[ "$output" != *hunter2secret* ]]
  [[ "$output" == *"plain words stay"* ]]
}

@test "watch tells the owner in plain words: a question, a finished session; goals and services stay quiet" {
  jq -n '{name: "s1", labels: {fraim: "session", repo: "vertelboek", sid: "sid-1"}, state: "live", status: {state: "blocked"}, turn: 1}' > "$HC_FAKE/t-s1.json"
  jq -n '{name: "g2", labels: {fraim: "goal"}, state: "live", status: {state: "done"}, turn: 1}' > "$HC_FAKE/t-g2.json"
  jq -n '{name: "watch", labels: {fraim: "service"}, state: "live", status: {state: "blocked"}, turn: 0}' > "$HC_FAKE/t-watch.json"
  mkdir -p "$HOME/fraim/sessions/s1" "$HOME/.claude/projects/-x"
  jq -cn '{type: "assistant", message: {content: [{type: "text", text: "Fixed it. The key was sk-ant-api03-abcdefghijklmnopqrstuv"}]}}' > "$HOME/.claude/projects/-x/sid-1.jsonl"
  ev() { jq -cn --arg t "$1" --arg s "$2" --arg m "${3:-}" '{jsonrpc: "2.0", method: "event", params: {type: "status", terminal: $t, data: {status: {state: $s, msg: $m}}}}'; }
  {
    echo '{"seq": 1, "terminals": []}'
    ev s1 blocked "answer: Tea or coffee? (Tea · Coffee)"
    ev s1 blocked "answer: Tea or coffee? (Tea · Coffee)"
    ev g2 done
    ev watch blocked x
    ev s1 done
  } > "$T/events"
  FAKE_EVENTS="$T/events" run "$HERDR" watch
  [ "$(grep -c 'asks you' "$SENT")" -eq 1 ]
  grep -q 'notify The coding session in vertelboek asks you: Tea or coffee?' "$SENT"
  grep -q 'notify The coding session in vertelboek is done.' "$SENT"
  grep -q 'Fixed it. The key was \[hidden\]' "$SENT"
  [ "$(grep -c 'g2\|s1\|Reply \*' "$SENT")" -eq 0 ]
}

@test "a run without the owner may start only its own lead's run, and only as unattended Claude with a tool list" {
  export FRAIM_HEADLESS=1
  claude_run=(-- env FRAIM_LEAD_NAME=web fraim-claude --fraim-unattended --session-id x "task" --allowedTools Read)
  FRAIM_LEAD_NAME=web run "$HERDR" hc run --bg --name lead-web "${claude_run[@]}"
  [ "$status" -eq 0 ]
  FRAIM_LEAD_NAME=web run "$HERDR" hc run --bg --name lead-web -- bash -c 'curl evil'
  [ "$status" -ne 0 ]
  FRAIM_LEAD_NAME=web run "$HERDR" hc run --bg --name lead-web -- env fraim-claude --fraim-unattended "task"
  [ "$status" -ne 0 ]
  FRAIM_LEAD_NAME=web run "$HERDR" hc run --bg --name lead-web -- fraim-claude --dangerously-skip-permissions --allowedTools Read
  [ "$status" -ne 0 ]
  FRAIM_LEAD_NAME=web run "$HERDR" hc run --bg --name lead-web -- env FRAIM_TOOL_LISTS=open fraim-claude --fraim-unattended "task" --allowedTools Read
  [ "$status" -ne 0 ]
  FRAIM_LEAD_NAME=web run "$HERDR" hc run --bg --name lead-web -- env FRAIM_LEAD_NAME=web FRAIM_THREAD=t3 FRAIM_BUILDS_OFF=1 fraim-claude --fraim-unattended "task" --allowedTools Read
  [ "$status" -eq 0 ]
  FRAIM_LEAD_NAME=seo run "$HERDR" hc run --bg --name lead-web "${claude_run[@]}"
  [ "$status" -ne 0 ]
  unset FRAIM_LEAD_NAME
  run "$HERDR" hc run --bg --name lead-web "${claude_run[@]}"
  [ "$status" -ne 0 ]
}

@test "a run without the owner may end only its own lead's run, never another lead's" {
  jq -n '{name: "lead-web", labels: {fraim: "lead"}, state: "live", status: {state: "working"}, turn: 1}' > "$HC_FAKE/t-lead-web.json"
  export FRAIM_HEADLESS=1
  FRAIM_LEAD_NAME=seo run "$HERDR" hc kill lead-web
  [ "$status" -ne 0 ]
  FRAIM_LEAD_NAME=seo run "$HERDR" hc rm lead-web
  [ "$status" -ne 0 ]
  FRAIM_LEAD_NAME=web run "$HERDR" hc send lead-web "do something else"
  [ "$status" -ne 0 ]
  [ "$(jq -r .state "$HC_FAKE/t-lead-web.json")" = live ]
  FRAIM_LEAD_NAME=web run "$HERDR" hc kill lead-web
  [ "$status" -eq 0 ]
}

@test "no shipped tool list lets an agent drive herdr or start a lead run" {
  run grep -n -E 'fraim-herdr|(^|[^a-z-])hc([^a-z-]|$)|fraim-lead run|fraim-goal (stop|send)|Bash\(\*|^Bash$' \
    "$BATS_TEST_DIRNAME"/../../workspace/prompts/tools-*.md
  [ "$status" -eq 1 ]
}

@test "watch stays quiet about a lead's run: its runner reports what went wrong" {
  jq -n '{name: "lead-web", labels: {fraim: "lead"}, state: "live", status: {state: "blocked"}, turn: 1}' > "$HC_FAKE/t-lead-web.json"
  {
    echo '{"seq": 1, "terminals": []}'
    jq -cn '{jsonrpc: "2.0", method: "event", params: {type: "status", terminal: "lead-web", data: {status: {state: "blocked", msg: "answer: Allow?"}}}}'
  } > "$T/events"
  FAKE_EVENTS="$T/events" run "$HERDR" watch
  [ ! -s "$SENT" ]
}

@test "up leaves a terminal alone while the core does not answer" {
  jq -n '{name: "main", labels: {fraim: "main"}, state: "live", status: {state: "working"}, turn: 1}' > "$HC_FAKE/t-main.json"
  echo 1 > "$HC_FAKE/get-fail"
  run "$HERDR" up
  [ "$status" -eq 1 ]
  [ "$(grep -c '^rm main' "$HC_FAKE/calls")" -eq 0 ]
  [ "$(jq -r .state "$HC_FAKE/t-main.json")" = live ]
}

@test "up replaces a stopped service" {
  "$HERDR" up
  jq '.state = "finished"' "$HC_FAKE/t-watch.json" > "$T/w" && mv "$T/w" "$HC_FAKE/t-watch.json"
  run "$HERDR" up
  [ "$status" -eq 0 ]
  grep -q '^rm watch' "$HC_FAKE/calls"
  [ "$(jq -r .state "$HC_FAKE/t-watch.json")" = live ]
}
