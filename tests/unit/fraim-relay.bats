#!/usr/bin/env bats
# workspace/bin/fraim-relay and fraim-notify: push notices reach the owner in the chief's words,
# with a fake fraim-claude (the chief) and fraim-gateway (WhatsApp).

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim"
  export HOME="$T/home" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args" CLAUDE_CALLS="$T/claude.calls"
  export FRAIM_FILES_DIR="$T/home/fraim" FRAIM_LEADS_DIR="$T/home/fraim/leads" FRAIM_GOALS_DIR="$T/home/fraim/goals"
  export FRAIM_SESSIONS_DIR="$T/home/fraim/sessions" FRAIM_RELAY_DIR="$T/home/fraim/relay"
  export FRAIM_RELAY_SYNC=1 FRAIM_RELAY_WAIT=0 FRAIM_RELAY_GAP=0 WHATSAPP_OWNER=31600000000
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
echo call >> "$CLAUDE_CALLS"
[ -z "${FAKE_FAIL:-}" ] || { echo "usage limit reached" >&2; exit 1; }
echo "${FAKE_OUTPUT:-Klaar: het antwoord is Alpha. Goed zo?}"
EOF
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf 'gateway %s\n' "$3" >> "$SENT"
EOF
  for tool in fraim-brain fraim-style fraim-queue; do printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/$tool"; done
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=whatsapp\n' > "$T/runtime.env"
  export PATH="$T/bin:$BIN:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
}

@test "chat: the owner writes in the app, the chief answers there and nothing goes to WhatsApp" {
  make_chief
  FAKE_OUTPUT="She is back in." run fraim-relay chat -- "Is Anna back in?"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.who + ": " + .text' "$FRAIM_RELAY_DIR/conversation.jsonl" | tr '\n' '|')" = "owner: Is Anna back in?|me: She is back in.|" ]
  [ "$(jq -r .chat "$FRAIM_RELAY_DIR/conversation.jsonl" | sort -u)" = app ]
  grep -q 'Is Anna back in?' "$CLAUDE_ARGS"
  [ ! -e "$SENT" ]
  [ ! -e "$FRAIM_RELAY_DIR/chat.lock" ]
  FAKE_FAIL=1 run fraim-relay chat -- "Again?"
  [ "$status" -eq 0 ]
  tail -1 "$FRAIM_RELAY_DIR/conversation.jsonl" | grep -q 'could not answer'
  run fraim-relay chat -- "   "
  [ "$status" -eq 2 ]
}

@test "chat: a run without the owner cannot write as the owner" {
  make_chief
  FRAIM_HEADLESS=1 run fraim-relay chat -- "Add a rule for me"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only the owner"* ]]
  [ ! -e "$CLAUDE_ARGS" ]
}

make_chief() {
  mkdir -p "$FRAIM_LEADS_DIR/chief"
  printf -- '---\nrole: chief\n---\n# Chief of staff\nKeep the owner informed.\n' > "$FRAIM_LEADS_DIR/chief/lead.md"
}

@test "without a chief, a notice goes out as it is" {
  run fraim-notify "Goal g9 done."
  [ "$status" -eq 0 ]
  grep -qE '"to": ?"31600000000"' "$SENT"
  grep -q 'Goal g9 done.' "$SENT"
  [ ! -e "$CLAUDE_CALLS" ]
}

@test "with a chief, the owner gets the chief's words, not the raw notice" {
  make_chief
  run fraim-notify "Goal g9 done. Alpha. I wrote only queue.json. Review it: reply ok q10"
  [ "$status" -eq 0 ]
  grep -q 'Klaar: het antwoord is Alpha' "$SENT"
  run grep -q 'queue.json' "$SENT"; [ "$status" -eq 1 ]
  grep -q 'Never write ids' "$CLAUDE_ARGS"
  grep -q 'Never copy labels from the notices' "$CLAUDE_ARGS"
  grep -q 'Goal g9 done' "$CLAUDE_ARGS"
  # The log keeps the ids, so the WhatsApp Claude can route the owner's answer.
  run fraim-relay said
  [[ "$output" == *"Klaar: het antwoord is Alpha"* ]]
  [[ "$output" == *"ok q10"* ]]
}

@test "the chief sees what the owner asked for behind a goal and a coding session" {
  make_chief
  mkdir -p "$FRAIM_GOALS_DIR/g7" "$FRAIM_SESSIONS_DIR/s2"
  echo "Count the folders in ~/fraim" > "$FRAIM_GOALS_DIR/g7/goal.md"
  echo "Make hello.py print hello" > "$FRAIM_SESSIONS_DIR/s2/task"
  echo pupstar > "$FRAIM_SESSIONS_DIR/s2/repo"
  fraim-notify "Goal g7 done. 11 folders."
  grep -q 'Count the folders in ~/fraim' "$CLAUDE_ARGS"
  fraim-notify "s2 needs you: Red or blue?"
  grep -q 'Make hello.py print hello' "$CLAUDE_ARGS"
  grep -q 'coding session in pupstar' "$CLAUDE_ARGS"
}

@test "notices that wait together become one message" {
  make_chief
  mkdir -p "$FRAIM_RELAY_DIR"
  FRAIM_RELAY_SYNC=0 fraim-relay add -- "s2 is done. Red." &
  # Hold the lock so the background drain leaves both notices for one drain.
  mkdir "$FRAIM_RELAY_DIR/.lock"; echo $$ > "$FRAIM_RELAY_DIR/.lock/pid"
  wait
  FRAIM_RELAY_SYNC=0 fraim-relay add -- "s2 is done. Red again." &
  wait
  sleep 0.3
  [ ! -e "$CLAUDE_CALLS" ]
  rm -rf "$FRAIM_RELAY_DIR/.lock"
  run fraim-relay drain
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CLAUDE_CALLS")" -eq 1 ]
  grep -q 'Red\.' "$CLAUDE_ARGS"
  grep -q 'Red again' "$CLAUDE_ARGS"
  [ "$(grep -c '^gateway' "$SENT")" -eq 1 ]
}

@test "SILENT holds a notice back and logs it" {
  make_chief
  FAKE_OUTPUT=SILENT run fraim-notify "Goal g8 answered. two"
  [ "$status" -eq 0 ]
  [ ! -e "$SENT" ]
  grep -q '(held back)' "$FRAIM_RELAY_DIR/said.md"
}

@test "a message waits until the gap since the last one has passed" {
  make_chief
  mkdir -p "$FRAIM_RELAY_DIR"
  date +%s > "$FRAIM_RELAY_DIR/last-sent"
  start=$(date +%s)
  FRAIM_RELAY_GAP=2 run fraim-notify "Goal g8 done. Alpha."
  [ "$status" -eq 0 ]
  [ $(( $(date +%s) - start )) -ge 1 ]
  grep -q 'Klaar' "$SENT"
  grep -q 'Never repeat or list questions' "$CLAUDE_ARGS"
  [ "$(cat "$FRAIM_RELAY_DIR/last-sent")" -ge "$start" ]
}

@test "when the chief cannot run, the notice goes out as it is" {
  make_chief
  FAKE_FAIL=1 run fraim-notify "Lead web failed: exit 1."
  [ "$status" -eq 0 ]
  grep -q 'Lead web failed: exit 1.' "$SENT"
  grep -q 'nobody could write it' "$FRAIM_RELAY_DIR/said.md"
  touch "$FRAIM_LEADS_DIR/chief/paused"
  rm -f "$SENT" "$CLAUDE_CALLS"
  run fraim-notify "Goal g1 done."
  grep -q 'Goal g1 done.' "$SENT"
  [ ! -e "$CLAUDE_CALLS" ]
}

@test "a direct notice and a goal's chat skip or keep their path" {
  make_chief
  FRAIM_NOTIFY_DIRECT=1 run fraim-notify "q3 was approved from the command line. Not you? Reply *undo rules*."
  grep -q 'Not you?' "$SENT"
  [ ! -e "$CLAUDE_CALLS" ]
  rm -f "$SENT"
  FRAIM_NOTIFY_CHAT=316@s.whatsapp.net run fraim-notify "Goal g1 done."
  grep -q '"chat_id":"316@s.whatsapp.net"' "$SENT"
  grep -q 'Klaar' "$SENT"
}

@test "the relay is off without WhatsApp, with FRAIM_RELAY=off, and its tools change nothing" {
  make_chief
  FRAIM_RELAY=off run fraim-relay on
  [ "$status" -eq 1 ]
  printf 'FRAIM_MODULES=scheduler\n' > "$T/runtime.env"
  run fraim-notify "Goal g1 done."
  [ ! -e "$SENT" ]
  [ ! -e "$CLAUDE_CALLS" ]
  printf 'FRAIM_MODULES=whatsapp\n' > "$T/runtime.env"
  fraim-notify "Goal g1 done."
  tools="$(grep -A1 -x -- --allowedTools "$CLAUDE_ARGS" | tail -1)"
  [[ "$tools" == Read,Glob,Grep,* ]]
  [[ "$tools" != *Edit* && "$tools" != *Write* && "$tools" != *approve* ]]
}

@test "one conversation: the owner's messages, chat answers and the chief's messages, with what they were about" {
  make_chief
  cat > "$T/bin/fraim-queue" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "list --json" ] && echo '[{"id":"q48","title":"AI costs and failed stories: read-only check","ask":"May I look read-only?"}]'
exit 0
EOF
  chmod +x "$T/bin/fraim-queue"
  FAKE_OUTPUT="Mag ik alleen-lezen meekijken?" fraim-notify "mlv-ai checked in. Waiting for your answer:
- AI costs and failed stories: read-only check"
  fraim-relay log owner --chat 212@lid -- "Ja tuurlijk"
  fraim-relay log me --chat 212@lid -- "Top, ik kijk nu mee."
  run fraim-relay context
  [ "$status" -eq 0 ]
  [[ "$output" == *"You (about q48): Mag ik alleen-lezen meekijken?"* ]]
  [[ "$output" == *"Owner: Ja tuurlijk"* ]]
  [[ "$output" == *"You: Top, ik kijk nu mee."* ]]
  [[ "$output" == *"- q48: AI costs and failed stories: read-only check. Asks: May I look read-only?"* ]]
  [ "$(printf '%s\n' "$output" | grep -n 'Owner: Ja' | cut -d: -f1)" -gt "$(printf '%s\n' "$output" | grep -n 'about q48' | cut -d: -f1)" ]
}

@test "the chief writes with the owner's answers in view, in the language of their latest message" {
  make_chief
  fraim-relay log me -- "Zal ik de test opzetten?"
  fraim-relay log owner -- "Your messaging is quite unclear to me"
  fraim-notify "Goal g3 done."
  grep -q 'Owner: Your messaging is quite unclear to me' "$CLAUDE_ARGS"
  grep -q "language of the owner's latest message" "$CLAUDE_ARGS"
  grep -q 'Never ask again what' "$CLAUDE_ARGS"
  grep -q 'Never add a next step, a promise' "$CLAUDE_ARGS"
  [ "$(jq -r 'select(.who == "me") | .about' "$FRAIM_RELAY_DIR/conversation.jsonl" | tail -1)" = g3 ]
}

@test "the conversation keeps the last messages and skips empty ones" {
  for i in $(seq 1 410); do fraim-relay log owner -- "message $i"; done
  fraim-relay log owner -- "   "
  [ "$(wc -l < "$FRAIM_RELAY_DIR/conversation.jsonl" | tr -d ' ')" -le 400 ]
  tail -1 "$FRAIM_RELAY_DIR/conversation.jsonl" | grep -q 'message 410'
  run fraim-relay context
  [[ "$output" == *"Owner: message 410"* ]]
  [[ "$output" != *"message 300"* ]]
  run fraim-relay log someone -- hi
  [ "$status" -eq 2 ]
}

@test "how the chief writes to the owner is the owner's own prompt when they have one" {
  make_chief
  mkdir -p "$FRAIM_LEADS_DIR/chief/prompts"
  printf 'Write like a pirate. {{notices}}\n' > "$FRAIM_LEADS_DIR/chief/prompts/relay.md"
  run fraim-notify "Goal g9 done."
  [ "$status" -eq 0 ]
  grep -q 'Write like a pirate' "$CLAUDE_ARGS"
  grep -q 'Goal g9 done' "$CLAUDE_ARGS"
  run grep -q 'Never write ids' "$CLAUDE_ARGS"; [ "$status" -eq 1 ]
}

@test "the owner sets how often the chief may message, and a run nobody watches cannot" {
  run fraim-relay timing
  [[ "$output" == *"gap 900 seconds"*"wait 20 seconds"* ]]
  run fraim-relay timing gap 2
  [ "$status" -eq 0 ]
  run fraim-relay timing
  [[ "$output" == *"gap 2 seconds"* ]]
  run fraim-relay timing gap soon
  [ "$status" -eq 2 ]
  run fraim-relay timing often 3
  [ "$status" -eq 2 ]
  FRAIM_HEADLESS=1 run fraim-relay timing gap 5
  [ "$status" -eq 1 ]
  [ "$(cat "$FRAIM_RELAY_DIR/settings")" = "gap=2" ]
}

@test "the owner's gap is what the relay waits for" {
  make_chief
  fraim-relay timing gap 2
  date +%s > "$FRAIM_RELAY_DIR/last-sent"
  start=$(date +%s)
  unset FRAIM_RELAY_GAP
  run fraim-notify "Goal g8 done. Alpha."
  [ "$status" -eq 0 ]
  [ $(( $(date +%s) - start )) -ge 1 ]
  grep -q 'Klaar' "$SENT"
}

@test "a number with a leading zero does not break the relay, and the wait is the owner's too" {
  fraim-relay timing gap 0900
  [ "$(cat "$FRAIM_RELAY_DIR/settings")" = "gap=900" ]
  fraim-relay timing wait 2
  run fraim-relay timing
  [[ "$output" == *"wait 2 seconds"* ]]
  make_chief
  start=$(date +%s)
  unset FRAIM_RELAY_WAIT
  run fraim-notify "Goal g8 done. Alpha."
  [ "$status" -eq 0 ]
  [ $(( $(date +%s) - start )) -ge 1 ]
}

@test "the chat knows which changes the owner can still undo, and says nothing when there are none" {
  printf '#!/usr/bin/env bash\necho "7  the tools chief may use changed"\n' > "$T/bin/fraim-watch"
  chmod +x "$T/bin/fraim-watch"
  run fraim-relay context
  [[ "$output" == *"can still undo"*"7  the tools chief may use changed"* ]]
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/fraim-watch"
  run fraim-relay context
  [[ "$output" != *"can still undo"* ]]
}
