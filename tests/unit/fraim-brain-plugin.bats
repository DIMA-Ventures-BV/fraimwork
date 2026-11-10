#!/usr/bin/env bats
# The owner's own brain at ~/fraim/automations/_brain/brain replaces the default one, within
# the limits only the engine keeps: skills, owner-only changes and the one door.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/automations/_brain"
  export HOME="$T/home" FRAIM_QUEUE_QUIET=1 FRAIM_RUNTIME_ENV=/dev/null FRAIM_BRAIN_RETRY=0 CALLS="$T/calls"
  export FRAIM_QUEUE_DIR="$T/home/fraim/queue" FRAIM_GOALS_DIR="$T/home/fraim/goals" FRAIM_BRAIN_DIR="$T/home/fraim/brain"
  export FRAIM_SKILLS_DIR="$T/home/.claude/skills" FRAIM_AUTOMATIONS_DIR="$T/home/fraim/automations" FRAIM_AUTO_STATE_DIR="$T/state" FRAIM_CRONTAB="$T/crontab"
  unset FRAIM_HEADLESS FRAIM_BRAIN_BUILTIN FRAIM_AUTHORITY_DIR
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/fraim-notify"
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$BIN:$PATH"
  P="$FRAIM_AUTOMATIONS_DIR/_brain/brain"
  U="$HOME/.config/fraim/authority/unreviewed"
}

plugin() {
  cat > "$P" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  show) echo "plugin rules for: $*" ;;
  note) cat ;;
  *) echo "no such action" >&2; exit 2 ;;
esac
EOF
  chmod +x "$P"
}

mark() { mkdir -p "$U"; : > "$U/_brain.brain"; }

@test "without a plug-in the default brain runs" {
  rm -rf "$FRAIM_AUTOMATIONS_DIR/_brain"
  run fraim-brain note "Write in Dutch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rule r1 added"* ]]
}

@test "a plug-in gets the same arguments, the same stdio and decides the exit code" {
  plugin
  run fraim-brain show --for web --all --plain
  [ "$status" -eq 0 ]
  [ "$output" = "plugin rules for: show --for web --all --plain" ]
  run bash -c 'echo from-stdin | fraim-brain note "a rule"'
  [ "$status" -eq 0 ]
  [ "$output" = "from-stdin" ]
  [ ! -e "$FRAIM_BRAIN_DIR/rules.md" ]
  run fraim-brain whatever
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such action"* ]]
}

@test "FRAIM_AUTOMATIONS_DIR says where the plug-in lives" {
  plugin
  mkdir -p "$T/elsewhere/_brain"
  mv "$P" "$T/elsewhere/_brain/brain"
  FRAIM_AUTOMATIONS_DIR="$T/elsewhere" run fraim-brain show --for web
  [[ "$output" == *"plugin rules"* ]]
  run fraim-brain show --plain
  [ "$output" = "" ]
}

@test "FRAIM_BRAIN_BUILTIN=1 skips the plug-in" {
  plugin
  fraim-brain show --for web
  FRAIM_BRAIN_BUILTIN=1 run fraim-brain show
  [[ "$output" == *"No rules yet"* ]]
  [ "$(wc -l < "$CALLS" | tr -d ' ')" = 1 ]
}

@test "a plug-in that calls fraim-brain reaches the default, not itself" {
  cat > "$P" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$CALLS"
echo "wrapped:"
fraim-brain "$@"
EOF
  chmod +x "$P"
  FRAIM_BRAIN_BUILTIN=1 fraim-brain note "Write in Dutch"
  run fraim-brain show --for web
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrapped:"* && "$output" == *"Write in Dutch"* ]]
  [ "$(wc -l < "$CALLS" | tr -d ' ')" = 1 ]
}

@test "skill commands never reach the plug-in" {
  plugin
  run fraim-brain skill list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No skills from the brain yet"* ]]
  FRAIM_HEADLESS=1 run fraim-brain skill install s1
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
  [ ! -e "$CALLS" ]
}

@test "a run nobody watches cannot change the rules through a plug-in" {
  plugin
  for args in "note x" "forget r1" "undo" "apply p1" "discard p1"; do
    FRAIM_HEADLESS=1 run fraim-brain $args
    [ "$status" -eq 1 ]
    [[ "$output" == *"only the owner"* ]]
  done
  [ ! -e "$CALLS" ]
  FRAIM_HEADLESS=1 run fraim-brain show --for web
  [[ "$output" == *"plugin rules"* ]]
}

@test "the default brain still refuses those runs" {
  rm -rf "$FRAIM_AUTOMATIONS_DIR/_brain"
  FRAIM_HEADLESS=1 run fraim-brain note x
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
}

@test "a plug-in that waits for the owner's yes is ignored" {
  plugin
  mark
  run fraim-brain show
  [[ "$output" == *"No rules yet"* ]]
  [ ! -e "$CALLS" ]
}

@test "FRAIM_AUTHORITY_DIR says where the mark lives" {
  plugin
  mkdir -p "$T/authority/unreviewed"
  : > "$T/authority/unreviewed/_brain.brain"
  FRAIM_AUTHORITY_DIR="$T/authority" run fraim-brain show
  [[ "$output" == *"No rules yet"* ]]
  [ ! -e "$CALLS" ]
}

@test "a tool edit by a run nobody watches marks the brain, for any file in its folder" {
  plugin
  input() { jq -cn --arg p "$1" '{session_id:"s",tool_name:"Write",tool_input:{file_path:$p}}'; }
  input "$P" | FRAIM_HEADLESS=1 "$BIN/fraim-audit"
  [ -f "$U/_brain.brain" ]
  rm "$U/_brain.brain"
  input "$FRAIM_AUTOMATIONS_DIR/_brain/lib/helper.sh" | FRAIM_HEADLESS=1 "$BIN/fraim-audit"
  [ -f "$U/_brain.brain" ]
  run fraim-brain show
  [[ "$output" == *"No rules yet"* ]]
}

@test "an edit by the owner marks nothing and goes live at once" {
  plugin
  jq -cn --arg p "$P" '{tool_name:"Edit",tool_input:{file_path:$p}}' | "$BIN/fraim-audit"
  [ ! -e "$U/_brain.brain" ]
  run fraim-brain show
  [[ "$output" == *"plugin rules"* ]]
}

@test "the owner's yes clears the mark, a run nobody watches cannot" {
  plugin
  mark
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/report"
  printf -- '---\ndescription: test\nschedule: 0 7 * * *\noutput: none\n---\nDo it.\n' > "$FRAIM_AUTOMATIONS_DIR/report/automation.md"
  FRAIM_HEADLESS=1 run "$BIN/fraim-auto" on report
  [ -f "$U/_brain.brain" ]
  run "$BIN/fraim-auto" on report
  [ "$status" -eq 0 ]
  [ ! -e "$U/_brain.brain" ]
  run fraim-brain show
  [[ "$output" == *"plugin rules"* ]]
}

@test "apply and discard the plug-in does not have go to the default, so a waiting card can close" {
  plugin
  run fraim-brain apply p1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no proposal p1"* ]]
  run fraim-brain discard p1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no proposal p1"* ]]
  run fraim-brain forget r1
  [ "$status" -eq 2 ]
  [[ "$output" != *"no rule"* ]]
}

@test "a crash on show prints nothing on stdout and does not stop the caller" {
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 7\n' > "$P"
  chmod +x "$P"
  run bash -c 'set -uo pipefail; rules="$(fraim-brain show --for web 2>/dev/null)"; echo "rules=[$rules] status=$?"'
  [ "$status" -eq 0 ]
  [ "$output" = "rules=[] status=7" ]
}

@test "a plug-in that cannot run is an error, not a silent switch to the default" {
  printf 'not executable\n' > "$P"
  chmod -x "$P"
  run fraim-brain note "Write in Dutch"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plug-in"* ]]
  [ ! -e "$FRAIM_BRAIN_DIR/rules.md" ]
}
