#!/usr/bin/env bats
# A repo's .fraim folder on the server (workspace/bin/fraim-project) with a real git origin and
# the real fraim-lead and fraim-auto, and the laptop command (fraim project) over the fake ssh.

load helper

setup() {
  setup_isolated
  use_public_target
  BIN="$REPO/workspace/bin"
  T="$BATS_TEST_TMPDIR"
  export FRAIM_LEADS_DIR="$HOME/fraim/leads" FRAIM_AUTOMATIONS_DIR="$HOME/fraim/automations" FRAIM_FILES_DIR="$HOME/fraim"
  export FRAIM_PROJECTS_DIR="$HOME/fraim/projects" FRAIM_GOALS_DIR="$HOME/fraim/goals"
  export FRAIM_AUTO_STATE_DIR="$HOME/.local/state/fraim/automations" FRAIM_AUTO_CRONTAB="$HOME/.local/state/fraim/automations.crontab"
  export FRAIM_AUTO_KIT_DIR="$REPO/workspace/automation-kit" FRAIM_RUNTIME_ENV="$T/runtime.env"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  printf 'FRAIM_MODULES=scheduler\n' > "$T/runtime.env"
  mkdir -p "$HOME/code" "$HOME/fraim/jobs"
  export PATH="$BIN:$PATH"
  P="$BIN/fraim-project"
  git init -q -b main --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/work" 2>/dev/null
  mkdir -p "$T/work/.fraim/leads" "$T/work/.fraim/automations/nightly"
  write_lead "Original brief."
  cat > "$T/work/.fraim/automations/nightly/automation.md" <<'EOF'
---
description: Nightly check
schedule: "0 2 * * *"
output: none
---
Check the app.
EOF
  printf '#!/usr/bin/env bash\necho hi\n' > "$T/work/.fraim/automations/nightly/check.sh"
  chmod +x "$T/work/.fraim/automations/nightly/check.sh"
  push_work
  git clone -q "$T/origin.git" "$HOME/code/app" 2>/dev/null
}

write_lead() {
  cat > "$T/work/.fraim/leads/web.md" <<EOF
---
role: lead
schedule: "20 5 * * *"
budget: 4
---
# Lead: web

## Area
The web app.

## Limits
$1
EOF
}

push_work() {
  git -C "$T/work" add -A
  git -C "$T/work" commit -q -m change
  git -C "$T/work" push -q origin main 2>/dev/null
  COMMIT="$(git -C "$T/work" rev-parse HEAD)"
}

@test "a new lead and automation arrive switched off and out of the schedule" {
  run "$P" plan app "$COMMIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"new      lead web, arrives switched off: The web app."* ]]
  [[ "$output" == *"new      automation nightly, arrives switched off: Nightly check (runs the script check.sh)"* ]]
  [ ! -e "$FRAIM_LEADS_DIR/web" ]
  run "$P" apply app "$COMMIT"
  [ "$status" -eq 0 ]
  [ -f "$FRAIM_LEADS_DIR/web/paused" ]
  [ "$(cat "$FRAIM_LEADS_DIR/web/budget")" = 4 ]
  grep -q '^schedule: "20 5 \* \* \*"' "$FRAIM_AUTOMATIONS_DIR/web/automation.md"
  ! grep -q '^schedule' "$FRAIM_LEADS_DIR/web/lead.md"
  grep -q '^enabled: false' "$FRAIM_AUTOMATIONS_DIR/nightly/automation.md"
  [ -x "$FRAIM_AUTOMATIONS_DIR/nightly/check.sh" ]
  ! grep -q 'fraim-auto fire nightly' "$FRAIM_AUTO_CRONTAB"
}

@test "on switches items on, only for the owner, and only items of the project" {
  "$P" apply app "$COMMIT"
  run env FRAIM_HEADLESS=1 "$P" on app --all
  [ "$status" -eq 1 ]
  run "$P" on app other
  [ "$status" -eq 1 ]
  run "$P" on app nightly web
  [ "$status" -eq 0 ]
  [ ! -f "$FRAIM_LEADS_DIR/web/paused" ]
  ! grep -q '^enabled' "$FRAIM_AUTOMATIONS_DIR/nightly/automation.md"
  grep -q 'fraim-auto fire nightly' "$FRAIM_AUTO_CRONTAB"
  run "$P" list
  [[ "$output" == *"lead web  on"* ]]
}

@test "a headless run cannot apply" {
  run env FRAIM_HEADLESS=1 "$P" apply app "$COMMIT"
  [ "$status" -eq 1 ]
  [ ! -e "$FRAIM_LEADS_DIR/web" ]
}

@test "an update shows a diff, keeps notes, and keeps the on or off state" {
  "$P" apply app "$COMMIT"
  "$P" on app web
  echo "my notes" > "$FRAIM_LEADS_DIR/web/state.md"
  write_lead "New brief."
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"update   lead web"* ]]
  [[ "$output" == *"+New brief."* ]]
  run "$P" apply app "$COMMIT"
  [ "$status" -eq 0 ]
  grep -q 'New brief.' "$FRAIM_LEADS_DIR/web/lead.md"
  [ "$(cat "$FRAIM_LEADS_DIR/web/state.md")" = "my notes" ]
  [ ! -f "$FRAIM_LEADS_DIR/web/paused" ]
}

@test "an update of a switched-off automation stays off" {
  "$P" apply app "$COMMIT"
  printf -- '---\ndescription: Nightly check\nschedule: "0 3 * * *"\noutput: none\n---\nCheck more.\n' > "$T/work/.fraim/automations/nightly/automation.md"
  push_work
  "$P" apply app "$COMMIT"
  grep -q 'Check more' "$FRAIM_AUTOMATIONS_DIR/nightly/automation.md"
  grep -q '^enabled: false' "$FRAIM_AUTOMATIONS_DIR/nightly/automation.md"
}

@test "an edit on the server is kept when the repo changes" {
  "$P" apply app "$COMMIT"
  echo "owner line" >> "$FRAIM_LEADS_DIR/web/lead.md"
  write_lead "New brief."
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"keep     lead web"* ]]
  "$P" apply app "$COMMIT"
  grep -q 'owner line' "$FRAIM_LEADS_DIR/web/lead.md"
  ! grep -q 'New brief.' "$FRAIM_LEADS_DIR/web/lead.md"
}

@test "a different item with the same name is left alone" {
  fraim-lead new web --area "Mine" >/dev/null
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"skip     lead web"* ]]
  "$P" apply app "$COMMIT"
  grep -q 'Mine' "$FRAIM_LEADS_DIR/web/lead.md"
  ! grep -q '^lead' "$FRAIM_PROJECTS_DIR/app/installed.tsv"
}

@test "export gives files that install as the same items, so a live lead is adopted" {
  fraim-lead new live --area "Live area" --at "1 2 * * *" --budget 7 >/dev/null
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/job"
  printf -- '---\ndescription: Job\nenabled: false\noutput: none\n---\nDo it.\n' > "$FRAIM_AUTOMATIONS_DIR/job/automation.md"
  mkdir -p "$T/x"
  "$P" export live job | tar -xf - -C "$T/x"
  grep -q '^schedule: "1 2 \* \* \*"' "$T/x/leads/live.md"
  grep -q '^budget: 7' "$T/x/leads/live.md"
  cp "$T/x/leads/live.md" "$T/work/.fraim/leads/"
  cp -R "$T/x/automations/job" "$T/work/.fraim/automations/"
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"adopt    lead live"* ]]
  [[ "$output" == *"adopt    automation job"* ]]
  "$P" apply app "$COMMIT"
  [ ! -f "$FRAIM_LEADS_DIR/live/paused" ]
  grep -q '^enabled: false' "$FRAIM_AUTOMATIONS_DIR/job/automation.md"
}

@test "a lead's tools arrive with it, show in the plan, and an update shows the change" {
  sed -i.bak 's/^budget: 4/budget: 4\ntools: mcp__linear, Bash(git fetch:*)/' "$T/work/.fraim/leads/web.md"; rm "$T/work/.fraim/leads/web.md.bak"
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"may use: mcp__linear, Bash(git fetch:*)"* ]]
  "$P" apply app "$COMMIT"
  grep -qxF 'mcp__linear' "$FRAIM_LEADS_DIR/web/tools"
  grep -qxF 'Bash(git fetch:*)' "$FRAIM_LEADS_DIR/web/tools"
  ! grep -q '^tools' "$FRAIM_LEADS_DIR/web/lead.md"
  sed -i.bak 's/^tools: .*/tools: mcp__linear, mcp__posthog/' "$T/work/.fraim/leads/web.md"; rm "$T/work/.fraim/leads/web.md.bak"
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"update   lead web"* ]]
  [[ "$output" == *"+mcp__posthog"* ]]
  [[ "$output" == *"-Bash(git fetch:*)"* ]]
  "$P" apply app "$COMMIT"
  grep -qxF 'mcp__posthog' "$FRAIM_LEADS_DIR/web/tools"
  ! grep -qF 'git fetch' "$FRAIM_LEADS_DIR/web/tools"
}

@test "export carries a live lead's tools, so it is still adopted" {
  fraim-lead new live --area "Live area" >/dev/null
  printf 'mcp__linear\n# a note\nWebFetch\n' > "$FRAIM_LEADS_DIR/live/tools"
  mkdir -p "$T/x"
  "$P" export live | tar -xf - -C "$T/x"
  grep -q '^tools: mcp__linear,WebFetch' "$T/x/leads/live.md"
  cp "$T/x/leads/live.md" "$T/work/.fraim/leads/"
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"adopt    lead live"* ]]
}

@test "the plan names an MCP server that is neither connected nor in needs.mirror" {
  printf '#!/usr/bin/env bash\necho %s\n' "'[{\"name\":\"linear\"}]'" > "$STUBS/fraim-connect"
  chmod +x "$STUBS/fraim-connect"
  export PATH="$STUBS:$PATH"
  sed -i.bak 's/^budget: 4/budget: 4\ntools: mcp__linear, mcp__posthog, mcp__sentry__list, mcp__plugin_x_y/' "$T/work/.fraim/leads/web.md"; rm "$T/work/.fraim/leads/web.md.bak"
  printf 'connect posthog https://mcp.example.com oauth\n' > "$T/work/.fraim/needs.mirror"
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"missing  lead web needs sentry"* ]]
  [[ "$output" != *"needs linear"* ]]
  [[ "$output" != *"needs posthog"* ]]
  [[ "$output" != *"needs plugin"* ]]
}

@test "a tool name with a shell character is refused" {
  sed -i.bak 's/^budget: 4/budget: 4\ntools: $(reboot)/' "$T/work/.fraim/leads/web.md"; rm "$T/work/.fraim/leads/web.md.bak"
  push_work
  run "$P" plan app "$COMMIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tools holds a character"* ]]
}

@test "export refuses the chief and a lead's own automation" {
  fraim-lead new boss --chief >/dev/null
  run "$P" export boss
  [ "$status" -eq 1 ]
  fraim-lead new live --area x >/dev/null
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/own"
  printf -- '---\nlead: live\n---\nx\n' > "$FRAIM_AUTOMATIONS_DIR/own/automation.md"
  run "$P" export own
  [ "$status" -eq 1 ]
}

@test "a branch commit and an edit in the checkout do not reach the server" {
  git -C "$T/work" checkout -q -b evil
  write_lead "Evil brief."
  git -C "$T/work" add -A
  git -C "$T/work" commit -q -m evil
  git -C "$T/work" push -q origin evil 2>/dev/null
  EVIL="$(git -C "$T/work" rev-parse HEAD)"
  run "$P" apply app "$EVIL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not on the default branch"* ]]
  echo "Local change" >> "$HOME/code/app/.fraim/leads/web.md"
  "$P" apply app "$COMMIT"
  ! grep -q 'Local change' "$FRAIM_LEADS_DIR/web/lead.md"
}

@test "a repo cannot add a chief, a symbolic link, stray files or a lead automation" {
  sed -i.bak 's/^role: lead/role: chief/' "$T/work/.fraim/leads/web.md"; rm "$T/work/.fraim/leads/web.md.bak"
  push_work
  run "$P" plan app "$COMMIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"role: lead"* ]]
  write_lead "ok"
  ln -s /etc/passwd "$T/work/.fraim/automations/nightly/x.sh"
  push_work
  run "$P" plan app "$COMMIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symbolic link"* ]]
  rm "$T/work/.fraim/automations/nightly/x.sh"
  echo x > "$T/work/.fraim/automations/nightly/data.txt"
  push_work
  run "$P" plan app "$COMMIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"only automation.md"* ]]
  rm "$T/work/.fraim/automations/nightly/data.txt"
  printf -- '---\nlead: chief\n---\nx\n' > "$T/work/.fraim/automations/nightly/automation.md"
  push_work
  run "$P" plan app "$COMMIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lead: is not allowed"* ]]
}

@test "an item removed from the repo stays and is reported" {
  "$P" apply app "$COMMIT"
  git -C "$T/work" rm -q .fraim/leads/web.md
  push_work
  run "$P" plan app "$COMMIT"
  [[ "$output" == *"gone     lead web"* ]]
  "$P" apply app "$COMMIT"
  [ -f "$FRAIM_LEADS_DIR/web/lead.md" ]
}

@test "a commit without .fraim is an error" {
  git -C "$T/work" rm -rq .fraim
  push_work
  run "$P" plan app "$COMMIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no .fraim folder"* ]]
}

project_ssh() {
  ssh_handler '
case "$REMOTE" in
  *"fraim-project head app"*) echo abc1234 ;;
  *"fraim-project plan app abc1234"*) echo "PLAN SHOWN" ;;
  *"fraim-project needs app abc1234"*) printf "tool npm:thing@1.0.0\n" ;;
  *"fraim-project apply app abc1234"*) echo "APPLIED" ;;
  *"fraim-tools list"*) echo "npm:thing@1.0.0" ;;
esac'
}

@test "the laptop shows the plan with its commit and needs, and changes nothing" {
  project_ssh
  run "$FRAIM" project update app
  [ "$status" -eq 3 ]
  [[ "$output" == *"PLAN SHOWN"* ]]
  [[ "$output" == *"tool    install npm:thing@1.0.0"* ]]
  [[ "$output" == *"fraim project update app --yes --commit abc1234"* ]]
  ! grep -q 'fraim-project apply' "$SSH_LOG"
}

@test "the laptop installs only with --yes and the commit from the plan" {
  project_ssh
  run "$FRAIM" project update app --yes
  [ "$status" -eq 2 ]
  ! grep -q 'fraim-project apply' "$SSH_LOG"
  run "$FRAIM" project update app --yes --commit abc1234
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPLIED"* ]]
  [[ "$output" == *"skip    tool npm:thing@1.0.0"* ]]
}

@test "the laptop's dry run stops after the plan" {
  project_ssh
  run "$FRAIM" project update app --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN SHOWN"* ]]
  ! grep -q 'fraim-project apply' "$SSH_LOG"
}

@test "export unpacks into the folder the laptop names" {
  mkdir -p "$T/tar/leads"; echo brief > "$T/tar/leads/one.md"
  tar -C "$T/tar" -cf "$T/one.tar" .
  ssh_handler "case \"\$REMOTE\" in *'fraim-project export'*) cat '$T/one.tar' ;; esac"
  run "$FRAIM" project export one --to "$T/out/.fraim"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/out/.fraim/leads/one.md")" = brief ]
}
