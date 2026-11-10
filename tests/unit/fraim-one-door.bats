#!/usr/bin/env bats
# No shell without the owner's yes: who may start a goal, and what happens to code that a
# run nobody watches wrote.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/home/fraim/leads" "$T/home/fraim/automations" "$T/bin" "$T/state" "$T/kit/triggers" "$T/kit/outputs" "$T/kit/sources"
  export HOME="$T/home" FRAIM_RUNTIME_ENV=/dev/null PATH="$T/bin:$BIN:$PATH" LOG="$T/log"
  export FRAIM_LEADS_DIR="$HOME/fraim/leads" FRAIM_GOALS_DIR="$HOME/fraim/goals" FRAIM_QUEUE_DIR="$HOME/fraim/queue" FRAIM_BRAIN_DIR="$HOME/fraim/brain"
  export FRAIM_AUTOMATIONS_DIR="$HOME/fraim/automations" FRAIM_AUTO_STATE_DIR="$T/state" FRAIM_AUTO_KIT_DIR="$T/kit"
  unset FRAIM_HEADLESS FRAIM_GOAL FRAIM_BUILDS_OFF FRAIM_LEAD_NAME FRAIM_AUTHORITY_DIR
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/fraim-notify"
  chmod +x "$T/bin/"*
  U="$HOME/.config/fraim/authority/unreviewed"
  Q="$BIN/fraim-queue"
  A="$BIN/fraim-auto"
  G="$BIN/fraim-goal"
}

lead() { mkdir -p "$FRAIM_LEADS_DIR/$1"; printf -- '---\nrole: %s\n---\n' "$2" > "$FRAIM_LEADS_DIR/$1/lead.md"; }
state() { jq -r .state "$FRAIM_QUEUE_DIR/$1/item.json"; }

# --- starting a goal

@test "a lead cannot start a goal on its own" {
  lead web lead
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=web run "$G" start --lead web -- do something
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs the owner's yes"* ]]
  [ ! -d "$FRAIM_GOALS_DIR/g1" ]
}

@test "the chief cannot start a goal without a yes" {
  lead winston chief
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=winston run "$G" start --lead winston -- do something
  [ "$status" -eq 1 ]
}

@test "a request from the owner's chat covers one goal, for the chief only" {
  lead winston chief
  lead web lead
  "$Q" grant --title "Build the page" --note "doe maar" >/dev/null
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=web run "$Q" use-yes q1
  [ "$status" -ne 0 ]
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=winston run "$Q" use-yes q1
  [ "$status" -eq 0 ]
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=winston run "$Q" use-yes q1
  [ "$status" -ne 0 ]
}

@test "the chief cannot spend a yes that was given on a card" {
  lead winston chief
  "$Q" add --quiet --title "Some card" >/dev/null
  "$Q" approve q1 >/dev/null
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=winston run "$Q" use-yes q1
  [ "$status" -ne 0 ]
}

@test "no lead name, an old yes or an open card is refused" {
  lead winston chief
  "$Q" grant --title "Old" >/dev/null
  FRAIM_HEADLESS=1 run "$Q" use-yes q1
  [ "$status" -ne 0 ]
  jq '.decided = "2026-01-01T00:00:00Z"' "$FRAIM_QUEUE_DIR/q1/item.json" > "$T/i" && mv "$T/i" "$FRAIM_QUEUE_DIR/q1/item.json"
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=winston run "$Q" use-yes q1
  [ "$status" -ne 0 ]
  "$Q" add --quiet --title "open" >/dev/null
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=winston run "$Q" use-yes q2
  [ "$status" -ne 0 ]
}

@test "the tool lists give a lead no way to start a goal, and the chief only with a yes" {
  run grep -c 'fraim-goal start' "$BIN/../prompts/tools-lead.md"
  [ "$output" = 0 ]
  grep -qx 'Bash(fraim-goal start --lead {{name}} --approved-by:\*)' "$BIN/../prompts/tools-chief.md"
}

# --- code written by a run nobody watches

auto() {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/$1"
  printf -- '---\ndescription: test\nschedule: 0 7 * * *\noutput: none\n%s---\nDo it.\n' "${2:-}" > "$FRAIM_AUTOMATIONS_DIR/$1/automation.md"
}
fake_claude() {
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
echo ran >> "$LOG"
printf '{"type":"result","result":"done","is_error":false}\n'
EOF
  chmod +x "$T/bin/fraim-claude"
}

@test "a tool edit by a run nobody watches marks the automation or plug-in" {
  input() { jq -cn --arg p "$1" '{session_id:"s",tool_name:"Write",tool_input:{file_path:$p}}'; }
  input "$FRAIM_AUTOMATIONS_DIR/report/check.sh" | FRAIM_HEADLESS=1 "$BIN/fraim-audit"
  [ -f "$U/report" ]
  input "$FRAIM_AUTOMATIONS_DIR/_triggers/mine" | FRAIM_HEADLESS=1 "$BIN/fraim-audit"
  [ -f "$U/_triggers.mine" ]
  input "$HOME/fraim/notes.md" | FRAIM_HEADLESS=1 "$BIN/fraim-audit"
  [ "$(ls "$U" | wc -l | tr -d ' ')" = 2 ]
}

@test "an edit by the owner marks nothing" {
  jq -cn --arg p "$FRAIM_AUTOMATIONS_DIR/report/check.sh" '{tool_name:"Edit",tool_input:{file_path:$p}}' | "$BIN/fraim-audit"
  [ ! -e "$U" ]
}

@test "reading an automation marks nothing" {
  jq -cn --arg p "$FRAIM_AUTOMATIONS_DIR/report/check.sh" '{tool_name:"Read",tool_input:{file_path:$p}}' | FRAIM_HEADLESS=1 "$BIN/fraim-audit"
  [ ! -e "$U" ]
}

@test "a changed automation does not fire and asks the owner once" {
  fake_claude
  auto report
  mkdir -p "$U"; : > "$U/report"
  printf '#!/usr/bin/env bash\necho "$*" >> "$LOG.queue"\necho q1\n' > "$T/bin/fraim-queue"
  chmod +x "$T/bin/fraim-queue"
  run "$A" fire report
  [ "$status" -eq 0 ]
  ! grep -q ran "$LOG"
  grep -q -- '--switch-on report' "$LOG.queue"
  run "$A" fire report
  [ "$(grep -c -- '--switch-on report' "$LOG.queue")" = 1 ]
}

@test "the owner's yes clears the mark and it runs again" {
  fake_claude
  auto report
  mkdir -p "$U"; : > "$U/report"
  run "$A" on report
  [ "$status" -eq 0 ]
  [ ! -e "$U/report" ]
  run "$A" fire report
  grep -q ran "$LOG"
}

@test "a run nobody watches cannot clear the mark" {
  auto report
  mkdir -p "$U"; : > "$U/report"
  FRAIM_HEADLESS=1 run "$A" on report
  [ "$status" -ne 0 ]
  [ -f "$U/report" ]
}

@test "a test run of a marked automation is refused when it holds code or a shell" {
  fake_claude
  auto withcheck
  echo 'echo hi' > "$FRAIM_AUTOMATIONS_DIR/withcheck/check.sh"
  auto withbash 'tools: Read, Bash
'
  mkdir -p "$U"; : > "$U/withcheck"; : > "$U/withbash"
  FRAIM_HEADLESS=1 run "$A" run withcheck
  [ "$status" -ne 0 ]
  FRAIM_HEADLESS=1 run "$A" run withbash
  [ "$status" -ne 0 ]
  [ ! -e "$LOG" ]
}

@test "a test run of a marked automation with only a prompt is allowed" {
  fake_claude
  auto plain 'tools: Read
'
  mkdir -p "$U"; : > "$U/plain"
  FRAIM_HEADLESS=1 run "$A" run plain
  [ "$status" -eq 0 ]
  grep -q ran "$LOG"
}

@test "an automation the engineer creates starts marked" {
  FRAIM_HEADLESS=1 FRAIM_BUILDS_OFF=1 run "$A" new built
  [ "$status" -eq 0 ]
  [ -f "$U/built" ]
}

@test "one the owner creates does not" {
  run "$A" new mine
  [ "$status" -eq 0 ]
  [ ! -e "$U/mine" ]
}

@test "a marked plug-in of the owner is not used, the built-in still is" {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/_triggers" "$U"
  printf '#!/usr/bin/env bash\n# description: mine\n' > "$FRAIM_AUTOMATIONS_DIR/_triggers/custom"
  printf '#!/usr/bin/env bash\n# description: kit\n' > "$FRAIM_AUTO_KIT_DIR/triggers/both"
  cp "$FRAIM_AUTO_KIT_DIR/triggers/both" "$FRAIM_AUTOMATIONS_DIR/_triggers/both"
  : > "$U/_triggers.custom"
  : > "$U/_triggers.both"
  run "$A" catalog
  [[ "$output" != *"custom"* ]]
  [[ "$output" == *"both"* ]]
}
