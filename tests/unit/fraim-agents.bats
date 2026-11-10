#!/usr/bin/env bats
# The engine knows agents, capabilities and a default contact: fraim-authority holds them, and
# the chief and engineer are only the defaults of a fresh install.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/leads"
  export HOME="$T/home" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args" CLAUDE_CALLS="$T/claude.calls"
  export FRAIM_FILES_DIR="$T/home/fraim" FRAIM_LEADS_DIR="$T/home/fraim/leads" FRAIM_GOALS_DIR="$T/home/fraim/goals"
  export FRAIM_SESSIONS_DIR="$T/home/fraim/sessions" FRAIM_RELAY_DIR="$T/home/fraim/relay"
  export FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_BRAIN_DIR="$T/home/fraim/brain"
  export FRAIM_AUTOMATIONS_DIR="$T/home/fraim/automations" FRAIM_CRONTAB="$T/home/fraim/jobs/crontab"
  export FRAIM_AUTO_STATE_DIR="$T/home/.local/state/fraim/automations" FRAIM_AUTO_CRONTAB="$T/home/.local/state/fraim/automations.crontab"
  export FRAIM_AUTO_KIT_DIR="$BATS_TEST_DIRNAME/../../workspace/automation-kit"
  export FRAIM_RELAY_SYNC=1 FRAIM_RELAY_WAIT=0 FRAIM_RELAY_GAP=0 WHATSAPP_OWNER=31600000000
  export FRAIM_LEAD_NO_WAKE=1 FRAIM_QUEUE_QUIET=1
  unset FRAIM_HEADLESS FRAIM_GOAL FRAIM_BUILDS_OFF FRAIM_LEAD_NAME FRAIM_AUTHORITY_DIR FRAIM_OWNER_CHAT
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
echo call >> "$CLAUDE_CALLS"
env > "$CLAUDE_ARGS.env"
[ -z "${FAKE_ACTION:-}" ] || eval "$FAKE_ACTION"
echo "${FAKE_OUTPUT:-Written by the agent.}"
EOF
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf 'gateway %s\n' "$3" >> "$SENT"
EOF
  for tool in fraim-style; do printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/$tool"; done
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=whatsapp,scheduler\n' > "$T/runtime.env"
  export PATH="$T/bin:$BIN:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
  A="$BIN/fraim-authority"
  SETTINGS="$HOME/.config/fraim/authority/settings"
}

agent() {
  mkdir -p "$FRAIM_LEADS_DIR/$1/runs"
  printf '# brief of %s\n' "$1" > "$FRAIM_LEADS_DIR/$1/lead.md"
  printf 'notes\n' > "$FRAIM_LEADS_DIR/$1/state.md"
  echo 3 > "$FRAIM_LEADS_DIR/$1/budget"
}

defaults() {
  fraim-lead new chief --chief >/dev/null
  fraim-lead new engineer --engineer >/dev/null
}

conversation() { jq -r '.who + ": " + .text' "$FRAIM_RELAY_DIR/conversation.jsonl"; }
fake_claude_runner() {
  mkdir -p "$T/fc"
  cp "$BIN/fraim-claude" "$T/fc/"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$T/fc/claude"
  chmod +x "$T/fc/"*
}

# --- migration: a server with roles and no settings keeps working the same

@test "migration: with no settings, everything comes from the chief and engineer roles" {
  agent winston
  agent bob
  "$A" set-role chief winston
  "$A" set-role engineer bob
  [ "$("$A" get contact)" = winston ]
  [ "$("$A" get fixer)" = bob ]
  [ "$("$A" get chat)" = winston ]
  [ "$("$A" cap winston queue)" = all ]
  [ "$("$A" cap winston rules)" = all ]
  [ "$("$A" cap winston output)" = direct ]
  [ "$("$A" cap winston source_tools)" = 1 ]
  [ "$("$A" cap winston template)" = chief ]
  [ "$("$A" cap bob builds_off)" = 1 ]
  [ "$("$A" cap bob template)" = engineer ]
  [ "$("$A" cap bob queue)" = own ]
  [ ! -e "$SETTINGS" ]
}

@test "migration: a server from before the roles file still finds its chief" {
  mkdir -p "$FRAIM_LEADS_DIR/winston"
  printf -- '---\nrole: chief\n---\n# Chief\n' > "$FRAIM_LEADS_DIR/winston/lead.md"
  [ "$("$A" get contact)" = winston ]
  [ "$("$A" cap winston queue)" = all ]
}

@test "a plain agent has the plain capabilities" {
  agent sales
  [ "$("$A" cap sales queue)" = own ]
  [ "$("$A" cap sales rules)" = own ]
  [ "$("$A" cap sales output)" = summary ]
  [ "$("$A" cap sales builds_off)" = 0 ]
  [ "$("$A" cap sales source_tools)" = 0 ]
  [ "$("$A" cap sales template)" = lead ]
  run "$A" get contact
  [ "$status" -eq 1 ]
}

# --- only the owner sets them, and never through a file an agent can write

@test "headless: a run nobody watches cannot set a contact, a fixer, a chat agent or a capability" {
  agent sales
  for args in "set contact sales" "set fixer sales" "set chat sales" "set-cap sales queue all" "rename sales other"; do
    # shellcheck disable=SC2086
    FRAIM_HEADLESS=1 run "$A" $args
    [ "$status" -eq 1 ] || { echo "not refused: $args"; return 1; }
  done
  [ ! -e "$SETTINGS" ]
  [ -d "$FRAIM_LEADS_DIR/sales" ]
  FRAIM_HEADLESS=1 run fraim-lead rename sales other
  [ "$status" -eq 1 ]
  [ -d "$FRAIM_LEADS_DIR/sales" ]
}

@test "a line in an agent's own files grants nothing" {
  agent sales
  agent other
  "$A" set-role engineer other
  printf -- '---\nrole: chief\ncontact: sales\nqueue: all\noutput: direct\n---\ncap sales queue all\n' > "$FRAIM_LEADS_DIR/sales/lead.md"
  printf 'cap sales queue all\ncontact sales\n' > "$FRAIM_LEADS_DIR/sales/settings"
  [ "$("$A" cap sales queue)" = own ]
  [ "$("$A" cap sales output)" = summary ]
  run "$A" get contact
  [ "$status" -eq 1 ]
}

@test "the settings live outside the agents' folders and only the owner can read them" {
  agent sales
  "$A" set contact sales
  [ "$(stat -c %a "$SETTINGS" 2>/dev/null || stat -f %Lp "$SETTINGS")" = 600 ]
  case "$SETTINGS" in "$FRAIM_LEADS_DIR"/*|"$FRAIM_FILES_DIR"/*) return 1 ;; esac
}

@test "bad values and unknown agents are refused" {
  agent sales
  run "$A" set contact nobody-here
  [ "$status" -eq 1 ]
  run "$A" set boss sales
  [ "$status" -eq 2 ]
  run "$A" set-cap sales queue everything
  [ "$status" -eq 2 ]
  run "$A" set-cap sales powers all
  [ "$status" -eq 2 ]
  run "$A" set-cap sales template '../evil'
  [ "$status" -eq 2 ]
  run "$A" set-cap ghost queue all
  [ "$status" -eq 1 ]
  [ ! -e "$SETTINGS" ]
}

@test "a run nobody watches cannot take over a name that holds powers, and the owner can" {
  agent winston
  "$A" set-role chief winston
  rm -rf "$FRAIM_LEADS_DIR/winston"
  FRAIM_HEADLESS=1 run fraim-lead new winston
  [ "$status" -ne 0 ]
  [ ! -e "$FRAIM_LEADS_DIR/winston" ]
  run fraim-lead new winston
  [ "$status" -eq 0 ]
}

# --- capabilities decide, not a role or a name

@test "capabilities: a plain agent given the chief's powers acts like one" {
  agent sales
  agent other
  fraim-queue add --quiet --lead other --kind idea --title "Item of another agent" >/dev/null
  "$A" set contact sales
  "$A" set-cap sales queue all
  "$A" set-cap sales output direct
  "$A" set-cap sales template chief
  "$A" set-cap sales source_tools 1
  FAKE_OUTPUT="The digest." run fraim-lead run sales
  [ "$status" -eq 0 ]
  grep -q 'Item of another agent' "$CLAUDE_ARGS"
  grep -q 'Bash(fraim-queue prio:\*)' "$CLAUDE_ARGS"
  grep -q 'The digest.' "$SENT"
  ! grep -q 'checked in' "$SENT"
}

@test "capabilities: without them the same run sees only its own items and sends a summary" {
  agent sales
  agent other
  fraim-queue add --quiet --lead other --kind idea --title "Item of another agent" >/dev/null
  FAKE_OUTPUT="All fine." FAKE_ACTION='fraim-queue add --quiet --lead sales --kind idea --title "My idea" >/dev/null' run fraim-lead run sales
  [ "$status" -eq 0 ]
  ! grep -q 'Item of another agent' "$CLAUDE_ARGS"
  ! grep -q 'Bash(fraim-queue prio:\*)' "$CLAUDE_ARGS"
  grep -q 'sales checked in' "$SENT"
}

@test "capabilities: builds_off is what makes new things start switched off" {
  agent builder
  "$A" set-cap builder builds_off 1
  run fraim-lead run builder
  [ "$status" -eq 0 ]
  grep -qx 'FRAIM_BUILDS_OFF=1' "$CLAUDE_ARGS.env"
  FRAIM_BUILDS_OFF=1 fraim-auto new made >/dev/null
  grep -q '^enabled: false' "$FRAIM_AUTOMATIONS_DIR/made/automation.md"
  FRAIM_BUILDS_OFF=1 fraim-lead new hired >/dev/null
  [ -f "$FRAIM_LEADS_DIR/hired/paused" ]
  agent plain
  run fraim-lead run plain
  ! grep -q 'FRAIM_BUILDS_OFF' "$CLAUDE_ARGS.env"
}

@test "failures go to the fixer setting, whoever that is" {
  agent mechanic
  agent broken
  "$A" set fixer mechanic
  printf -- '---\nschedule: "0 7 * * *"\noutput: none\n---\nDo it.\n' > "$T/auto.md"
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/job" && cp "$T/auto.md" "$FRAIM_AUTOMATIONS_DIR/job/automation.md"
  FAKE_ACTION='exit 3' run fraim-auto run job
  grep -q 'The automation job failed' "$FRAIM_LEADS_DIR/mechanic/inbox.md"
  ! grep -q 'tell  ' "$FRAIM_LEADS_DIR/mechanic/inbox.md"
}

@test "with fixer none, a failure becomes a question for the owner" {
  agent mechanic
  "$A" set-role engineer mechanic
  "$A" set fixer none
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/job"
  printf -- '---\nschedule: "0 7 * * *"\noutput: none\n---\nDo it.\n' > "$FRAIM_AUTOMATIONS_DIR/job/automation.md"
  FAKE_ACTION='exit 3' run fraim-auto run job
  [ ! -e "$FRAIM_LEADS_DIR/mechanic/inbox.md" ]
  fraim-queue list --json | jq -r '.[0].ask' | grep -q 'find out why job failed'
}

# --- rename and replace

@test "rename: the chief under another name keeps everything" {
  defaults
  "$A" set chat chief
  run fraim-lead rename chief anna
  [ "$status" -eq 0 ]
  [ ! -e "$FRAIM_LEADS_DIR/chief" ]
  [ -f "$FRAIM_LEADS_DIR/anna/lead.md" ]
  [ "$("$A" get contact)" = anna ]
  [ "$("$A" get chat)" = anna ]
  [ "$("$A" role-of anna)" = chief ]
  [ "$("$A" cap anna queue)" = all ]
  grep -qx 'lead: anna' "$FRAIM_AUTOMATIONS_DIR/anna/automation.md"
  grep -qx 'lead: anna' "$FRAIM_AUTOMATIONS_DIR/anna-events/automation.md"
  [ ! -e "$FRAIM_AUTOMATIONS_DIR/chief" ]
  [ ! -e "$FRAIM_AUTOMATIONS_DIR/chief-events" ]
  grep -q 'fraim-auto fire anna$' "$FRAIM_AUTO_CRONTAB"
  ! grep -q ' chief' "$FRAIM_AUTO_CRONTAB"
  run fraim-auto check
  [ "$status" -eq 0 ]
  run fraim-lead run anna
  [ "$status" -eq 0 ]
  grep -q 'Bash(fraim-queue prio:\*)' "$CLAUDE_ARGS"
  run fraim-relay chat -- "Hello"
  [ "$status" -eq 0 ]
  grep -q 'fraim-lead tell anna' "$CLAUDE_ARGS"
  run fraim-notify "Goal g3 done."
  grep -q 'Written by the agent' "$SENT"
}

@test "rename: refused for a name that is taken, and while the agent runs" {
  agent one
  agent two
  run fraim-lead rename one two
  [ "$status" -eq 1 ]
  [ -f "$FRAIM_LEADS_DIR/one/lead.md" ]
  mkdir "$FRAIM_LEADS_DIR/one/.running"
  run fraim-lead rename one three
  [ "$status" -eq 1 ]
  [ -f "$FRAIM_LEADS_DIR/one/lead.md" ]
  [ ! -e "$FRAIM_LEADS_DIR/three" ]
}

@test "replace: giving the role to another agent moves the contact and the powers" {
  defaults
  agent anna
  "$A" set-role chief anna
  [ "$("$A" get contact)" = anna ]
  [ "$("$A" get chat)" = anna ]
  [ "$("$A" cap anna template)" = chief ]
  [ "$("$A" cap chief queue)" = own ]
  [ "$("$A" get fixer)" = engineer ]
  run fraim-lead ask -- "Do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"anna is on it"* ]]
}

@test "replace: an owner-picked contact stays when the role moves" {
  defaults
  agent anna
  agent sam
  "$A" set contact sam
  "$A" set-role chief anna
  [ "$("$A" get contact)" = sam ]
}

# --- deletion: no chief, or contact=none

no_contact() {
  rm -rf "$FRAIM_AUTOMATIONS_DIR" "$FRAIM_AUTO_STATE_DIR"
  case "$1" in
    deleted) defaults; rm -rf "$FRAIM_LEADS_DIR/chief" ;;
    none) defaults; "$A" set contact none ;;
    never) ;;
  esac
}

@test "no contact: notices go out as they are, batched and at the normal gap" {
  for how in deleted none never; do
    rm -rf "$FRAIM_LEADS_DIR" "$HOME/.config/fraim/authority" "$FRAIM_RELAY_DIR" "$CLAUDE_CALLS" "$SENT"
    mkdir -p "$FRAIM_LEADS_DIR" "$FRAIM_RELAY_DIR"
    no_contact "$how"
    date +%s > "$FRAIM_RELAY_DIR/last-sent"
    start=$(date +%s)
    FRAIM_RELAY_GAP=2 run fraim-notify "Goal g8 done."
    [ "$status" -eq 0 ] || { echo "$how: $output"; return 1; }
    [ $(( $(date +%s) - start )) -ge 1 ] || { echo "$how: did not wait for the gap"; return 1; }
    grep -q 'Goal g8 done.' "$SENT" || { echo "$how: nothing sent"; return 1; }
    [ ! -e "$CLAUDE_CALLS" ] || { echo "$how: an agent wrote it"; return 1; }
  done
}

@test "no contact: the relay stays on, so the gap holds; FRAIM_RELAY=off still turns it off" {
  run fraim-relay on
  [ "$status" -eq 0 ]
  FRAIM_RELAY=off run fraim-relay on
  [ "$status" -eq 1 ]
}

@test "a paused contact is like no contact: raw notices, still at the gap" {
  defaults
  touch "$FRAIM_LEADS_DIR/chief/paused"
  run fraim-notify "Goal g2 done."
  [ "$status" -eq 0 ]
  grep -q 'Goal g2 done.' "$SENT"
  [ ! -e "$CLAUDE_CALLS" ]
}

@test "no contact: the WhatsApp prompt tells it to answer itself, not to run commands that die" {
  out="$(fraim-prompt render whatsapp --set view_url=x --set contact=)"
  [[ "$out" != *"fraim-lead ask"* ]]
  [[ "$out" != *"fraim-lead tell <chief>"* ]]
  [[ "$out" != *"fraim-lead tell  "* ]]
  [[ "$out" == *"Answer every message yourself"* ]]
  out="$(fraim-prompt render whatsapp --set view_url=x --set contact=anna)"
  [[ "$out" == *"fraim-lead ask -- "* ]]
  [[ "$out" == *"fraim-lead tell anna --later"* ]]
  [[ "$out" != *"Answer every message yourself"* ]]
}

@test "no contact: the server prompt does not send work to fraim-lead ask" {
  out="$(fraim-prompt render server --set contact=)"
  [[ "$out" != *"fraim-lead ask --"* ]]
  out="$(fraim-prompt render server --set contact=anna)"
  [[ "$out" == *"fraim-lead ask --"* ]]
}

@test "no contact: the app chat says so clearly and keeps the owner's words" {
  for how in deleted none never; do
    rm -rf "$FRAIM_LEADS_DIR" "$HOME/.config/fraim/authority" "$FRAIM_RELAY_DIR" "$CLAUDE_CALLS"
    mkdir -p "$FRAIM_LEADS_DIR"
    no_contact "$how"
    run fraim-relay chat -- "Is Anna back in?"
    [ "$status" -eq 0 ] || { echo "$how: $output"; return 1; }
    conversation | grep -qx 'owner: Is Anna back in?' || { echo "$how: the owner's text is gone"; return 1; }
    conversation | tail -1 | grep -q 'Nobody is set up to answer' || { echo "$how: no clear answer"; return 1; }
    [ ! -e "$CLAUDE_CALLS" ] || { echo "$how: an agent ran"; return 1; }
    [ ! -e "$FRAIM_RELAY_DIR/chat.lock" ]
  done
}

@test "the chat setting takes the chat also with contact none" {
  defaults
  agent anna
  "$A" set contact none
  "$A" set chat anna
  FAKE_OUTPUT="Yes she is." run fraim-relay chat -- "Is Anna back in?"
  [ "$status" -eq 0 ]
  conversation | tail -1 | grep -qx 'me: Yes she is.'
}

@test "no contact: fraim-lead ask says what to do instead, fraim-lead display is empty" {
  run fraim-lead ask -- "hello"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no default contact"* ]]
  run fraim-lead display
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no contact: leads get no instruction to tell someone who is not there" {
  agent sales
  run fraim-lead run sales
  [ "$status" -eq 0 ]
  ! grep -q 'fraim-lead tell chief' "$CLAUDE_ARGS"
  ! grep -q 'fraim-lead tell  --from' "$CLAUDE_ARGS"
  grep -q 'fraim-lead tell <lead>' "$CLAUDE_ARGS"
  agent anna
  "$A" set contact anna
  run fraim-lead run sales
  grep -q 'fraim-lead tell anna --from sales' "$CLAUDE_ARGS"
}

@test "no contact: the fixer's task names nobody to tell" {
  agent mechanic
  "$A" set fixer mechanic
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/job"
  printf -- '---\nschedule: "0 7 * * *"\noutput: none\n---\nDo it.\n' > "$FRAIM_AUTOMATIONS_DIR/job/automation.md"
  FAKE_ACTION='exit 3' run fraim-auto run job
  grep -q 'Find the cause and fix it' "$FRAIM_LEADS_DIR/mechanic/inbox.md"
  ! grep -q 'tell the chief' "$FRAIM_LEADS_DIR/mechanic/inbox.md"
  ! grep -q 'then tell ' "$FRAIM_LEADS_DIR/mechanic/inbox.md"
}

@test "deleted: leftover automations stay quiet and leave the schedule" {
  defaults
  fraim-auto sync --quiet
  grep -q 'fire chief$' "$FRAIM_AUTO_CRONTAB"
  rm -rf "$FRAIM_LEADS_DIR/chief"
  for _ in 1 2 3; do
    run fraim-auto fire chief
    [ "$status" -eq 0 ]
    run fraim-auto poll chief-events
    [ "$status" -eq 0 ]
  done
  [ ! -e "$SENT" ]
  [ ! -s "$HOME/fraim/alerts.md" ]
  [ ! -e "$CLAUDE_CALLS" ]
  fraim-auto sync --quiet
  ! grep -q 'chief' "$FRAIM_AUTO_CRONTAB"
  grep -q 'fire engineer$' "$FRAIM_AUTO_CRONTAB"
}

@test "deleted: a hand run of a leftover automation still says what is wrong" {
  defaults
  rm -rf "$FRAIM_LEADS_DIR/chief"
  run fraim-auto run chief
  [ "$status" -eq 1 ]
  [[ "$output" == *"there is no lead"* ]]
}

# --- the owner's chat: an engine capability, not something an agent can claim

@test "only the chat agent's brief goes into the owner's chat" {
  agent sam
  agent anna
  printf 'brief of the contact agent\n' > "$FRAIM_LEADS_DIR/sam/lead.md"
  printf 'brief of the chat agent\n' > "$FRAIM_LEADS_DIR/anna/lead.md"
  "$A" set contact sam
  "$A" set chat anna
  run fraim-relay chat -- "Hi"
  [ "$status" -eq 0 ]
  grep -q 'brief of the chat agent' "$CLAUDE_ARGS"
  ! grep -q 'brief of the contact agent' "$CLAUDE_ARGS"
  grep -qx 'FRAIM_OWNER_CHAT=1' "$CLAUDE_ARGS.env"
}

@test "fraim-lead brief without a name is the contact's, with a name that agent's" {
  agent sam
  agent anna
  "$A" set contact sam
  run fraim-lead brief
  [[ "$output" == *"# brief of sam"* ]]
  [[ "$output" != *"# brief of anna"*"Your notes"* ]]
  run fraim-lead brief anna
  [[ "$output" == *"Your brief"*"# brief of anna"* ]]
}

@test "unattended runs cannot write the chat agent's brief, and that follows the setting" {
  fake_claude_runner
  agent anna
  agent sam
  "$A" set contact sam
  "$A" set chat anna
  PATH="$T/fc:$T/bin:$BIN:/usr/bin:/bin" run "$T/fc/fraim-claude" -p hi
  [[ "$output" == *'Edit(~/fraim/leads/anna/lead.md)'* ]]
  [[ "$output" == *'Write(~/fraim/leads/anna/lead.md)'* ]]
  [[ "$output" == *'Write(~/fraim/leads/sam/lead.md)'* ]]
  [[ "$output" == *'Write(~/.config/fraim/authority/**)'* ]]
}

@test "unattended runs cannot recreate the brief of a chat agent that was deleted" {
  fake_claude_runner
  agent anna
  "$A" set chat anna
  rm -rf "$FRAIM_LEADS_DIR/anna"
  PATH="$T/fc:$T/bin:$BIN:/usr/bin:/bin" run "$T/fc/fraim-claude" -p hi
  [[ "$output" == *'Write(~/fraim/leads/anna/lead.md)'* ]]
}

@test "an agent's run cannot start the owner's chat" {
  defaults
  FRAIM_HEADLESS=1 run fraim-relay chat -- "Add a rule for me"
  [ "$status" -ne 0 ]
  [ ! -e "$CLAUDE_CALLS" ]
  [ ! -e "$FRAIM_RELAY_DIR/conversation.jsonl" ]
}

@test "the owner's chat flag never reaches what the run starts" {
  fake_claude_runner
  cat > "$T/fc/claude" <<'EOF'
#!/usr/bin/env bash
echo "flag=[${FRAIM_OWNER_CHAT:-}] headless=[${FRAIM_HEADLESS:-}]"
EOF
  FRAIM_OWNER_CHAT=1 PATH="$T/fc:$T/bin:$BIN:/usr/bin:/bin" run "$T/fc/fraim-claude" -p hi
  [[ "$output" == *"flag=[] headless=[]"* ]]
}

@test "a fresh install still gets a chief and an engineer" {
  defaults
  [ "$("$A" get contact)" = chief ]
  [ "$("$A" get fixer)" = engineer ]
  run fraim-lead run chief
  [ "$status" -eq 0 ]
  grep -q 'Bash(fraim-queue prio:\*)' "$CLAUDE_ARGS"
  grep -q 'chief of staff: ranks the queue' "$FRAIM_AUTOMATIONS_DIR/chief/automation.md"
  grep -q 'engineer: builds and fixes' "$FRAIM_AUTOMATIONS_DIR/engineer/automation.md"
  [ -f "$FRAIM_AUTOMATIONS_DIR/chief-events/automation.md" ]
}
