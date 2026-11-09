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
  chmod +x "$T/bin/"*
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

@test "new refuses folders outside home and unknown repos" {
  run "$SESSIONS" new ../../etc
  [ "$status" -eq 2 ]
  run "$SESSIONS" new /etc
  [ "$status" -eq 1 ]
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
