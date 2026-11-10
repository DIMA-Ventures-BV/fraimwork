#!/usr/bin/env bats
# Hiring an employee: the trial run (fraim-lead try), the queue's refusal without one, and the
# hiring rules in the chief's and the engineer's instructions. Claude is a fake.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/jobs"
  export HOME="$T/home" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args" FRAIM_QUEUE_QUIET=1 T_MARK="$T/trial-env"
  export FRAIM_LEADS_DIR="$T/home/fraim/leads"
  export FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_GOALS_DIR="$T/home/fraim/goals" FRAIM_BRAIN_DIR="$T/home/fraim/brain"
  export FRAIM_AUTOMATIONS_DIR="$T/home/fraim/automations" FRAIM_FILES_DIR="$T/home/fraim"
  export FRAIM_AUTO_STATE_DIR="$T/home/.local/state/fraim/automations" FRAIM_AUTO_CRONTAB="$T/home/.local/state/fraim/automations.crontab"
  export FRAIM_AUTO_KIT_DIR="$BATS_TEST_DIRNAME/../../workspace/automation-kit"
  export FRAIM_PROMPT_DEFAULTS="$BATS_TEST_DIRNAME/../../workspace/prompts"
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
[ -z "${FAKE_ACTION:-}" ] || eval "$FAKE_ACTION"
[ -z "${FAKE_FAIL:-}" ] || { echo "usage limit reached" >&2; exit 1; }
echo "${FAKE_OUTPUT:-Checked the area.}"
EOF
  printf '#!/usr/bin/env bash\nprintf "notify %%s\\n" "$*" >> "$SENT"\n' > "$T/bin/fraim-notify"
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=scheduler\n' > "$T/runtime.env"
  export PATH="$T/bin:$BIN:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env" FRAIM_LEAD_NO_WAKE=1
}

trial_output() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}\n'
  jq -cn --arg r "$1" '{type:"result",is_error:false,result:$r,permission_denials:[{tool_name:"Bash",tool_input:{command:"fraim-queue add --title x"}}]}'
}
allowed_tools() { grep -x -A1 -- '--allowedTools' "$CLAUDE_ARGS" | tail -1; }

@test "try runs a switched-off employee with only reading tools and changes nothing" {
  fraim-lead new ads --area "ads of the shop" --off
  printf 'mcp__shop__get_orders\nmcp__shop__send_invoice\nBash(curl:*)\n' > "$FRAIM_LEADS_DIR/ads/tools"
  FAKE_ACTION='printenv FRAIM_TRIAL > "$T_MARK"' FAKE_OUTPUT="$(trial_output $'Found 3 campaigns.\nTRIAL OK')" run fraim-lead try ads
  [ "$status" -eq 0 ]
  [[ "$output" == *"Trial of ads: passed"* ]]
  [[ "$output" == *"Refused during the trial"* ]]
  [ "$(cat "$T_MARK")" = 1 ]
  grep -q 'This run is a trial' "$CLAUDE_ARGS"
  tools="$(allowed_tools)"
  [[ "$tools" == *"mcp__shop__get_orders"* ]]
  [[ "$tools" == *"Bash(fraim-api:*)"* ]]
  [[ "$tools" == *"Bash(git log:*)"* ]]
  [[ "$tools" != *"send_invoice"* ]]
  [[ "$tools" != *"Bash(curl"* ]]
  [[ "$tools" != *"fraim-queue add"* ]]
  [[ "$tools" != *"fraim-goal start"* ]]
  [[ "$tools" != *"fraim-lead tell"* ]]
  [[ "$tools" != *"Edit("* ]]
  [[ "$tools" != *"Write("* ]]
  [ -f "$FRAIM_LEADS_DIR/ads/paused" ]
  [ ! -f "$FRAIM_LEADS_DIR/ads/last" ]
  run fraim-lead try ads --status
  [ "$status" -eq 0 ]
}

@test "try fails when the employee is blocked, looked at nothing, or the run breaks" {
  fraim-lead new ads --off
  FAKE_OUTPUT="$(trial_output $'No access to the shop.\nTRIAL BLOCKED: the shop login')" run fraim-lead try ads
  [ "$status" -eq 1 ]
  [[ "$output" == *"TRIAL BLOCKED: the shop login"* ]]
  run fraim-lead try ads --status
  [ "$status" -eq 1 ]
  [[ "$output" == *"the shop login"* ]]
  FAKE_OUTPUT='{"type":"result","is_error":false,"result":"TRIAL OK"}' run fraim-lead try ads
  [ "$status" -eq 1 ]
  [[ "$output" == *"looked at nothing"* ]]
  FAKE_FAIL=1 run fraim-lead try ads
  [ "$status" -eq 1 ]
  [[ "$output" == *"stopped with an error"* ]]
}

@test "the queue refuses a hire without a passed trial of the current brief and tools" {
  fraim-lead new ads --off
  run fraim-queue add --quiet --lead engineer --kind decision --title "Hire ads" --switch-on ads
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be hired yet"* ]]
  FAKE_OUTPUT="$(trial_output 'TRIAL OK')" run fraim-lead try ads
  [ "$status" -eq 0 ]
  run fraim-queue add --quiet --lead engineer --kind decision --title "Hire ads" --switch-on ads
  [ "$status" -eq 0 ]
  printf 'mcp__shop__get_orders\n' > "$FRAIM_LEADS_DIR/ads/tools"
  run fraim-queue add --quiet --lead engineer --kind decision --title "Hire ads" --switch-on ads
  [ "$status" -ne 0 ]
  [[ "$output" == *"changed after the trial"* ]]
}

@test "try is only for new employees" {
  fraim-lead new chief --chief
  run fraim-lead try chief
  [ "$status" -eq 1 ]
  [[ "$output" == *"only a new employee"* ]]
}

@test "the hiring rules reach the chief and the engineer, and the engineer can try and ask back" {
  fraim-lead new chief --chief
  fraim-lead new engineer --engineer
  FAKE_OUTPUT=SILENT run fraim-lead run engineer
  grep -q 'Hiring rules' "$CLAUDE_ARGS"
  grep -q 'Question for the owner about the hire' "$CLAUDE_ARGS"
  [[ "$(allowed_tools)" == *"Bash(fraim-lead try:*)"* ]]
  FAKE_OUTPUT=SILENT run fraim-lead run chief
  grep -q 'Hiring rules' "$CLAUDE_ARGS"
  grep -q 'your final answer to the owner is your questions' "$CLAUDE_ARGS"
}

@test "fraim-api in a trial refuses calls that change something" {
  export FRAIM_SECRETS_URL=http://proxy FRAIM_SECRETS_TOKEN=tok
  printf '#!/usr/bin/env bash\necho "shop X-Key %%s https://api"\n' > "$T/bin/curl"
  chmod +x "$T/bin/curl"
  for bad in "-X POST" "-sXDELETE" "-d @body.json" "--data-raw x" "--json {}"; do
    # shellcheck disable=SC2086
    FRAIM_TRIAL=1 run fraim-api shop /orders $bad
    [ "$status" -eq 1 ]
    [[ "$output" == *"this is a trial"* ]]
  done
  FRAIM_TRIAL=1 run fraim-api shop /orders -H 'Accept: application/json'
  [[ "$output" != *"this is a trial"* ]]
}
