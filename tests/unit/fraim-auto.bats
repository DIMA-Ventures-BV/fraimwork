#!/usr/bin/env bats
# workspace/bin/fraim-auto with a fake fraim-claude (stream-json), fraim-notify and
# fraim-gateway: the file format, checks, runs, outputs, failures, the crontab and migration,
# and the plugins: the built-in ones in workspace/automation-kit and the owner's own.

setup() {
  AUTO="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-auto"
  JOB="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-job"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/automations"
  export HOME="$T/home" SENT="$T/sent" CLAUDE_ARGS="$T/claude.args"
  export FRAIM_AUTOMATIONS_DIR="$HOME/fraim/automations" FRAIM_FILES_DIR="$HOME/fraim"
  export FRAIM_AUTO_STATE_DIR="$HOME/.local/state/fraim/automations"
  export FRAIM_AUTO_CRONTAB="$HOME/.local/state/fraim/automations.crontab"
  export FRAIM_AUTO_KIT_DIR="$BATS_TEST_DIRNAME/../../workspace/automation-kit"
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGS"
[ -z "${FAKE_FAIL:-}" ] || { echo "usage limit reached" >&2; exit 1; }
[ -z "${FAKE_BUSY:-}" ] || { echo "fraim: the server had no free memory" >&2; exit 75; }
answer="${FAKE_ANSWER:-Two mails need an answer.}"
echo '{"type":"system","subtype":"init"}'
jq -cn --arg r "$answer" '{type: "result", subtype: "success", is_error: false, result: $r, total_cost_usd: 0.01, num_turns: 2, duration_ms: 900}'
EOF
  cat > "$T/bin/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf 'gateway %s\n' "$3" >> "$SENT"
EOF
  cat > "$T/bin/fraim-notify" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FRAIM_NOTIFY_NO_ALERT:-}" ]; then printf 'result %s\n' "$*" >> "$SENT"; else printf 'alert %s\n' "$*" >> "$SENT"; fi
EOF
  chmod +x "$T/bin/"*
  printf 'FRAIM_MODULES=whatsapp,scheduler\n' > "$T/runtime.env"
  export PATH="$T/bin:$(dirname "$AUTO"):$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
}

# make NAME HEADER-LINES PROMPT
make_auto() {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/$1"
  printf -- '---\n%s\n---\n%s\n' "$2" "$3" > "$FRAIM_AUTOMATIONS_DIR/$1/automation.md"
}
last_run() { find "$FRAIM_AUTOMATIONS_DIR/$1/runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -1; }

@test "list says how to start when there are no automations" {
  run "$AUTO" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No automations yet"* ]]
}

@test "check names each mistake in plain words" {
  make_auto broken 'schedule: "every morning"
whatsapp: ^digest
output: whatsapp, email:me@example.com, file:../etc/x
colour: blue' 'Do it.'
  run "$AUTO" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a cron line"* ]]
  [[ "$output" == *"'whatsapp:' triggers are not available yet"* ]]
  [[ "$output" == *"output 'email' is not available yet"* ]]
  [[ "$output" == *"must be a path inside ~/fraim"* ]]
  [[ "$output" == *"unknown setting 'colour:'"* ]]
}

@test "a good automation passes check and list shows its trigger" {
  make_auto digest 'schedule: "0 8 * * 1-5"   # weekdays
hours: 07:00-22:00' 'Summarise.'
  run "$AUTO" check digest
  [ "$status" -eq 0 ]
  run "$AUTO" list
  [[ "$output" == *"digest  [on]  schedule 0 8 * * 1-5 (07:00-22:00)  last: never ran"* ]]
}

@test "run sends the answer to WhatsApp and the outbox, and keeps the run" {
  make_auto digest 'tools: Read, Grep, mcp__google__gmail_search
model: sonnet' 'Mail since {{since}}. Extra: {{input}}'
  run "$AUTO" run digest --input "only work mail"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Two mails need an answer."* ]]
  grep -q '^result digest:' "$SENT"
  grep -q 'Two mails need an answer.' "$HOME/fraim/outbox.md"
  r="$(last_run digest)"
  [ "$(cat "$r/status")" = ok ]
  [ "$(cat "$r/delivery")" = ok ]
  grep -q 'Mail since never (this is the first run). Extra: only work mail' "$r/prompt.md"
  [ "$(jq -r .cost_usd "$r/usage.json")" = 0.01 ]
  grep -qx 'Read,Grep,mcp__google__gmail_search' "$CLAUDE_ARGS"
  grep -qx 'sonnet' "$CLAUDE_ARGS"
  grep -q 'Edit(~/fraim/automations/\*\*)' "$CLAUDE_ARGS"
  run "$AUTO" run digest
  grep -q 'Mail since 20' "$(last_run digest)/prompt.md"
}

@test "SILENT delivers nothing" {
  make_auto quiet '' 'Anything new?'
  FAKE_ANSWER=SILENT run "$AUTO" run quiet
  [ "$status" -eq 0 ]
  [ ! -s "$SENT" ]
  [ "$(cat "$(last_run quiet)/status")" = silent ]
}

@test "an answer that explains itself and ends on SILENT delivers nothing; SILENT inside a report does not count" {
  make_auto quiet '' 'Anything new?'
  FAKE_ANSWER=$'I checked Linear. There are none, so I am answering SILENT.\n\n**SILENT**' run "$AUTO" run quiet
  [ "$status" -eq 0 ]
  [ ! -s "$SENT" ]
  [ "$(cat "$(last_run quiet)/status")" = silent ]
  FAKE_ANSWER=$'Two new issues.\nOne says the app went SILENT after login.' run "$AUTO" run quiet
  [ -s "$SENT" ]
}

@test "an empty check.sh skips the run without calling Claude" {
  make_auto poll 'every: 15m' 'New mail: {{check}}'
  printf 'exit 0\n' > "$FRAIM_AUTOMATIONS_DIR/poll/check.sh"
  run "$AUTO" run poll
  [[ "$output" == *skipped* ]]
  [ ! -f "$CLAUDE_ARGS" ]
  printf 'echo "invoice from mollie"\n' > "$FRAIM_AUTOMATIONS_DIR/poll/check.sh"
  run "$AUTO" run poll
  grep -q 'New mail: invoice from mollie' "$(last_run poll)/prompt.md"
}

@test "script_only delivers the check output and never calls Claude" {
  make_auto disk 'script_only: true' ''
  printf 'echo "disk 91 percent"\n' > "$FRAIM_AUTOMATIONS_DIR/disk/check.sh"
  run "$AUTO" run disk
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_ARGS" ]
  grep -q 'disk 91 percent' "$SENT"
}

@test "file output writes under ~/fraim with the date filled in; none keeps it out of the outbox" {
  make_auto report 'output: file: reports/{name}-{date}.md, whatsapp:123@g.us' 'Report.'
  run "$AUTO" run report
  [ -f "$HOME/fraim/reports/report-$(date +%Y-%m-%d).md" ]
  grep -q '"chat_id":"123@g.us"' "$SENT"
  make_auto hidden 'output: none' 'Hidden.'
  rm -f "$HOME/fraim/outbox.md"
  run "$AUTO" run hidden
  [ ! -f "$HOME/fraim/outbox.md" ]
}

@test "a dry run shows the answer and delivers nothing" {
  make_auto digest '' 'Summarise.'
  run "$AUTO" run digest --dry
  [[ "$output" == *"dry run, nothing delivered"* ]]
  [ ! -s "$SENT" ]
  [ ! -f "$HOME/fraim/outbox.md" ]
}

@test "a run the server had no memory for is skipped: no alert, no failure streak, no pause" {
  make_auto busy 'schedule: "0 * * * *"' 'Try.'
  for _ in 1 2 3 4 5 6; do FAKE_BUSY=1 run "$AUTO" fire busy; done
  [ "$(grep -c '^alert' "$SENT" 2>/dev/null)" = 0 ] || [ ! -s "$SENT" ]
  run "$AUTO" list
  [[ "$output" != *"[paused]"* ]]
  run "$AUTO" run busy
  grep -q 'Two mails' "$HOME/fraim/outbox.md"
}

@test "failures alert once, pause after five, and resume clears it" {
  make_auto flaky 'schedule: "0 * * * *"' 'Try.'
  for _ in 1 2 3 4; do FAKE_FAIL=1 run "$AUTO" fire flaky; done
  [ "$(grep -c '^alert' "$SENT")" -eq 1 ]
  grep -q "usage limit was reached" "$SENT"
  FAKE_FAIL=1 run "$AUTO" fire flaky
  [ "$(grep -c '^alert' "$SENT")" -eq 2 ]
  grep -q 'is paused' "$SENT"
  run "$AUTO" list
  [[ "$output" == *"[paused]"* ]]
  rm -f "$CLAUDE_ARGS"
  run "$AUTO" fire flaky
  [ ! -f "$CLAUDE_ARGS" ]
  run "$AUTO" resume flaky
  run "$AUTO" fire flaky
  [ -f "$CLAUDE_ARGS" ]
  grep -q 'works again' "$SENT"
}

@test "an expired sign-in is named as a sign-in problem, also when it only shows as a 401" {
  make_auto signin '' 'Try.'
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"result","is_error":true,"result":"API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"OAuth session expired and could not be refreshed\"}}"}'
exit 1
EOF
  run "$AUTO" run signin
  [ "$status" -eq 1 ]
  [[ "$output" == *"not signed in to Claude"* ]]
  grep -q '^alert .*not signed in to Claude' "$SENT"
}

@test "a scheduled run of an automation with a mistake is blocked with one alert" {
  make_auto bad 'output: telegram' 'Do.'
  run "$AUTO" fire bad
  [ "$status" -eq 1 ]
  run "$AUTO" fire bad
  [ "$(grep -c '^alert' "$SENT")" -eq 1 ]
  [ ! -f "$CLAUDE_ARGS" ]
}

@test "fire respects enabled: false and hours" {
  make_auto off 'enabled: false' 'Do.'
  run "$AUTO" fire off
  [ ! -f "$CLAUDE_ARGS" ]
  h="$(date +%H)"; next=$(( (10#$h + 1) % 24 )); after=$(( (10#$h + 2) % 24 ))
  make_auto later "$(printf 'hours: %02d:00-%02d:00' "$next" "$after")" 'Do.'
  run "$AUTO" fire later
  [ ! -f "$CLAUDE_ARGS" ]
  run "$AUTO" run later
  [ -f "$CLAUDE_ARGS" ]
}

@test "a second trigger during a run is queued, not run alongside" {
  make_auto busy '' 'Do.'
  sleep 30 & pid=$!
  mkdir -p "$FRAIM_AUTO_STATE_DIR/busy/lock"
  printf '%s %s\n' "$(hostname)" "$pid" > "$FRAIM_AUTO_STATE_DIR/busy/lock/owner"
  run "$AUTO" run busy
  kill "$pid"
  [[ "$output" == *"runs once more"* ]]
  [ -f "$FRAIM_AUTO_STATE_DIR/busy/queued" ]
  [ ! -f "$CLAUDE_ARGS" ]
}

@test "a wake-up that waited keeps its hop count, the highest one when several waited" {
  make_auto busy '' 'Do.'
  export DEPTHS="$T/depths" ONCE="$T/once" AUTO
  cat > "$T/bin/fraim-claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FRAIM_LEAD_DEPTH:-none}" >> "$DEPTHS"
if [ ! -e "$ONCE" ]; then
  touch "$ONCE"
  FRAIM_LEAD_DEPTH=5 "$AUTO" run busy --input first >/dev/null
  FRAIM_LEAD_DEPTH=3 "$AUTO" run busy --input second >/dev/null
fi
echo '{"type":"system","subtype":"init"}'
jq -cn '{type: "result", subtype: "success", is_error: false, result: "Done.", num_turns: 1, duration_ms: 1}'
EOF
  run "$AUTO" run busy
  [ "$status" -eq 0 ]
  [ "$(paste -sd' ' - < "$DEPTHS")" = "none 5" ]
  [ ! -e "$FRAIM_AUTO_STATE_DIR/busy/queued.depth" ]
}

@test "sync writes one crontab line per scheduled automation" {
  make_auto a 'schedule: "0 8 * * 1-5"' 'A.'
  make_auto b 'every: 30m' 'B.'
  make_auto c 'every: 2h' 'C.'
  make_auto d '' 'Manual only.'
  make_auto e 'schedule: "0 9 * * *"
enabled: false' 'Off.'
  run "$AUTO" sync
  [[ "$output" == *"3 scheduled"* ]]
  grep -qx '0 8 \* \* 1-5 fraim-auto fire a' "$FRAIM_AUTO_CRONTAB"
  grep -qx '\*/30 \* \* \* \* fraim-auto fire b' "$FRAIM_AUTO_CRONTAB"
  grep -qx '0 \*/2 \* \* \* fraim-auto fire c' "$FRAIM_AUTO_CRONTAB"
  ! grep -q 'fire [de]$' "$FRAIM_AUTO_CRONTAB"
  run "$AUTO" sync
  [[ "$output" == *"already up to date"* ]]
}

@test "migrate moves crontab jobs into automations once and fraim-job still works" {
  mkdir -p "$HOME/fraim/jobs"
  printf 'Check the weather.\n' > "$HOME/fraim/jobs/weather.md"
  printf 'Read\nWebFetch(domain:wttr.in)\n' > "$HOME/fraim/jobs/weather.tools"
  printf '# a comment\n0 7 * * *   fraim-job weather\n# 0 8 * * * fraim-job example\n' > "$HOME/fraim/jobs/crontab"
  run "$AUTO" migrate
  [[ "$output" == *"Moved 1 job"* ]]
  f="$FRAIM_AUTOMATIONS_DIR/weather/automation.md"
  grep -qx 'schedule: "0 7 \* \* \*"' "$f"
  grep -qx 'tools: Read, WebFetch(domain:wttr.in)' "$f"
  grep -qx 'Check the weather.' "$f"
  grep -q '^# moved to ~/fraim/automations/weather' "$HOME/fraim/jobs/crontab"
  grep -qx '# 0 8 \* \* \* fraim-job example' "$HOME/fraim/jobs/crontab"
  run "$AUTO" check weather
  [ "$status" -eq 0 ]
  run "$AUTO" migrate
  [ -z "$output" ]
  run "$JOB" weather
  [ "$status" -eq 0 ]
  grep -qx 'Read,WebFetch(domain:wttr.in)' "$CLAUDE_ARGS"
}

@test "names that could escape the folder are refused" {
  run "$AUTO" run ../etc
  [ "$status" -eq 2 ]
  run "$AUTO" show 'a b'
  [ "$status" -eq 2 ]
}

@test "an output plugin of the owner is checked, gets the answer on stdin and shows in the catalog" {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/_outputs"
  cat > "$FRAIM_AUTOMATIONS_DIR/_outputs/slack" <<'EOF'
# usage: slack:CHANNEL
# description: A Slack channel.
if [ "$1" = --check ]; then case "$2" in '#'*) exit 0 ;; *) echo "a channel starts with #"; exit 1 ;; esac; fi
printf '%s|%s|' "$FRAIM_AUTOMATION" "$1" >> "$SENT"; cat >> "$SENT"
EOF
  make_auto team 'output: slack: general' 'Post.'
  run "$AUTO" check team
  [ "$status" -eq 1 ]
  [[ "$output" == *"output slack: a channel starts with #"* ]]
  make_auto team 'output: slack:#general' 'Post.'
  run "$AUTO" run team
  [ "$status" -eq 0 ]
  grep -q '^team|#general|Two mails need an answer.' "$SENT"
  [ "$(cat "$(last_run team)/delivery")" = ok ]
  run "$AUTO" catalog
  [[ "$output" == *"slack:CHANNEL"*"A Slack channel. (yours)"* ]]
  [[ "$output" == *"file:PATH"*"(built-in)"* ]]
  [[ "$output" == *"inbox-watch"* ]]
}

@test "a failing output plugin alerts once with the plugin's own reason" {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/_outputs"
  printf '[ "$1" = --check ] && exit 0\necho "the Slack token expired"\nexit 1\n' > "$FRAIM_AUTOMATIONS_DIR/_outputs/slack"
  make_auto team 'output: slack:#x' 'Post.'
  run "$AUTO" run team
  run "$AUTO" run team
  [ "$(grep -c '^alert' "$SENT")" -eq 1 ]
  grep -q 'did not arrive everywhere: slack:#x: the Slack token expired' "$SENT"
}

@test "check names a wrong trigger in plain words" {
  make_auto a 'trigger: telepathy: x' 'A.'
  make_auto b 'trigger: after: b' 'B.'
  make_auto c 'trigger: after: nobody' 'C.'
  make_auto d 'trigger: files: ../etc
schedule: "0 8 * * *"' 'D.'
  make_auto e 'file: inbox' 'E.'
  run "$AUTO" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown trigger 'telepathy' (available: after, files, mail, page"* ]]
  [[ "$output" == *"cannot run after itself"* ]]
  [[ "$output" == *"there is no automation 'nobody'"* ]]
  [[ "$output" == *"trigger files: '../etc' must be a folder inside ~/fraim"* ]]
  [[ "$output" == *"use schedule or trigger, not both"* ]]
  [[ "$output" == *"trigger: files: FOLDER"* ]]
}

@test "a files trigger is polled by the scheduler and runs once with the new files" {
  mkdir -p "$HOME/fraim/inbox"
  : > "$HOME/fraim/inbox/old.pdf"
  make_auto inbox 'trigger: files: inbox
every: 10m' 'New: {{input}}'
  run "$AUTO" sync
  grep -qx '\*/10 \* \* \* \* fraim-auto poll inbox' "$FRAIM_AUTO_CRONTAB"
  run "$AUTO" list
  [[ "$output" == *"files: inbox (checked every 10m)"* ]]
  run "$AUTO" poll inbox
  [ "$status" -eq 0 ]
  [ ! -f "$CLAUDE_ARGS" ]
  run "$AUTO" poll inbox
  [ ! -f "$CLAUDE_ARGS" ]
  : > "$HOME/fraim/inbox/invoice.pdf"
  : > "$HOME/fraim/inbox/.hidden"
  run "$AUTO" poll inbox
  [ -f "$CLAUDE_ARGS" ]
  p="$(last_run inbox)/prompt.md"
  grep -q 'New: new file: ~/fraim/inbox/invoice.pdf' "$p"
  ! grep -q 'old.pdf\|hidden' "$p"
  [ "$(jq -r .trigger "$(last_run inbox)/trigger.json")" = files ]
}

@test "what a trigger reported is kept when the server had no memory, and comes with the next check" {
  mkdir -p "$HOME/fraim/inbox"
  make_auto inbox 'trigger: files: inbox
every: 10m' 'New: {{input}}'
  run "$AUTO" poll inbox
  : > "$HOME/fraim/inbox/invoice.pdf"
  FAKE_BUSY=1 run "$AUTO" poll inbox
  [ "$status" -eq 0 ]
  # The files trigger already moved on; the next check has nothing new of its own.
  rm -f "$CLAUDE_ARGS"
  run "$AUTO" poll inbox
  [ -f "$CLAUDE_ARGS" ]
  grep -q 'New: new file: ~/fraim/inbox/invoice.pdf' "$(last_run inbox)/prompt.md"
}

@test "a run takes at most 50 trigger lines; the rest come with the next check, none twice" {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/_triggers"
  # Prints 60 lines once, then nothing.
  printf '[ "$1" = --check ] && exit 0\n[ -f "$FRAIM_TRIGGER_STATE/done" ] && exit 0\ntouch "$FRAIM_TRIGGER_STATE/done"\nseq 1 60 | sed "s/^/line /"\n' > "$FRAIM_AUTOMATIONS_DIR/_triggers/burst"
  make_auto burst 'trigger: burst: x' 'Got: {{input}}'
  run "$AUTO" poll burst
  p="$(last_run burst)/prompt.md"
  grep -qx 'line 50' "$p"
  ! grep -qx 'line 51' "$p"
  sleep 1
  run "$AUTO" poll burst
  p="$(last_run burst)/prompt.md"
  grep -q 'Got: line 51' "$p"
  grep -qx 'line 60' "$p"
  ! grep -qx 'line 50' "$p"
  [ ! -f "$HOME/.local/state/fraim/automations/burst/deferred" ]
}

@test "a manual or dry run the server had no memory for keeps nothing for later" {
  mkdir -p "$HOME/fraim/inbox"
  make_auto inbox 'trigger: files: inbox
every: 10m' 'New: {{input}}'
  FAKE_BUSY=1 run "$AUTO" run inbox --input "typed by hand"
  [ ! -f "$HOME/.local/state/fraim/automations/inbox/deferred" ]
}

@test "a failing trigger of the owner alerts once and says when it works again" {
  mkdir -p "$FRAIM_AUTOMATIONS_DIR/_triggers"
  printf '[ "$1" = --check ] && exit 0\n[ -f "$HOME/ok" ] && exit 0\necho "the shop API answered 503" >&2\nexit 1\n' > "$FRAIM_AUTOMATIONS_DIR/_triggers/shop"
  make_auto orders 'trigger: shop: orders' 'Orders: {{input}}'
  run "$AUTO" poll orders
  [ "$status" -eq 1 ]
  run "$AUTO" poll orders
  [ "$(grep -c '^alert' "$SENT")" -eq 1 ]
  grep -q 'the shop trigger failed: the shop API answered 503' "$SENT"
  : > "$HOME/ok"
  run "$AUTO" poll orders
  [ "$status" -eq 0 ]
  grep -q 'orders works again' "$SENT"
  [ ! -f "$CLAUDE_ARGS" ]
}

@test "after: runs the follower with the leader's answer, and not after SILENT" {
  make_auto leader '' 'Lead.'
  make_auto follower 'trigger: after: leader
output: file: notes/{name}.md' 'Earlier answer: {{input}}'
  run "$AUTO" sync
  ! grep -q 'follower' "$FRAIM_AUTO_CRONTAB"
  run "$AUTO" run leader
  [ "$status" -eq 0 ]
  grep -q 'Earlier answer: Two mails need an answer.' "$(last_run follower)/prompt.md"
  [ "$(jq -r .trigger "$(last_run follower)/trigger.json")" = after:leader ]
  [ -f "$HOME/fraim/notes/follower.md" ]
  rm -rf "$FRAIM_AUTOMATIONS_DIR/follower/runs"
  FAKE_ANSWER=SILENT run "$AUTO" run leader
  [ ! -d "$FRAIM_AUTOMATIONS_DIR/follower/runs" ]
}

@test "automations that follow each other run once each, not in a loop" {
  make_auto ping 'trigger: after: pong' 'Ping.'
  make_auto pong 'trigger: after: ping' 'Pong.'
  run "$AUTO" run ping
  [ "$status" -eq 0 ]
  [ "$(find "$FRAIM_AUTOMATIONS_DIR/ping/runs" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]
  [ "$(find "$FRAIM_AUTOMATIONS_DIR/pong/runs" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]
  [ ! -f "$FRAIM_AUTO_STATE_DIR/ping/queued" ]
}

@test "the webhook output posts JSON, and a missing variable is named" {
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s ' "${@: -1}" >> "$SENT"; cat >> "$SENT"; echo >> "$SENT"
EOF
  chmod +x "$T/bin/curl"
  make_auto hook 'output: webhook: https://hooks.example.com/x' 'Hook.'
  run "$AUTO" run hook
  grep -q '^curl https://hooks.example.com/x {"text":"Two mails need an answer.","automation":"hook"}' "$SENT"
  make_auto hook2 'output: webhook: SLACK_URL' 'Hook.'
  run "$AUTO" run hook2
  grep -q 'the variable SLACK_URL is not set' "$SENT"
  make_auto hook3 'output: webhook: http://plain' 'Hook.'
  run "$AUTO" check hook3
  [[ "$output" == *"must be an https:// URL"* ]]
}

@test "new starts an automation from every example, and each one passes check" {
  run "$AUTO" new mine
  [ "$status" -eq 0 ]
  run "$AUTO" check mine
  [ "$status" -eq 0 ]
  run "$AUTO" new mine
  [ "$status" -eq 1 ]
  for ex in "$FRAIM_AUTO_KIT_DIR"/examples/*/; do
    e="$(basename "$ex")"
    run "$AUTO" new "my-$e" --from "$e" --off
    [ "$status" -eq 0 ]
    run "$AUTO" check "my-$e"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'enabled: false' "$FRAIM_AUTOMATIONS_DIR/my-$e/automation.md"
  done
  [ -f "$FRAIM_AUTOMATIONS_DIR/my-disk-space/check.sh" ]
  run "$AUTO" new x --from nothing
  [ "$status" -eq 1 ]
}

@test "the page trigger reports new lines only after it changed" {
  printf '<html><script>var t=1;</script><p>Price 10</p></html>' > "$T/page.html"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$T/page.html" > "$T/bin/curl"
  chmod +x "$T/bin/curl"
  st="$T/st"; mkdir -p "$st"
  run env FRAIM_TRIGGER_STATE="$st" "$FRAIM_AUTO_KIT_DIR/triggers/page" https://shop.example.com
  [ -z "$output" ]
  printf '<html><script>var t=2;</script><p>Price 10</p></html>' > "$T/page.html"
  run env FRAIM_TRIGGER_STATE="$st" "$FRAIM_AUTO_KIT_DIR/triggers/page" https://shop.example.com
  [ -z "$output" ]
  printf '<html><p>Price 12</p></html>' > "$T/page.html"
  run env FRAIM_TRIGGER_STATE="$st" "$FRAIM_AUTO_KIT_DIR/triggers/page" https://shop.example.com
  [[ "$output" == *"changed: https://shop.example.com"*"Price 12"* ]]
}

@test "the queue output puts the answer in the review queue, with the first line as title" {
  export FRAIM_QUEUE_DIR="$HOME/fraim/queue" FRAIM_QUEUE_QUIET=1
  make_auto ads 'output: queue:decision' 'Report.'
  FAKE_ANSWER="**Ad spend doubled**
Meta spent 400 euro this week for 3 orders." run "$AUTO" run ads
  [ "$status" -eq 0 ]
  [ "$(cat "$(last_run ads)/delivery")" = ok ]
  run fraim-queue list --json
  [[ "$output" == *'"title":"Ad spend doubled"'* ]]
  [[ "$output" == *"automation ads"* ]]
  [[ "$output" == *'"kind":"decision"'* ]]
  make_auto bad 'output: queue:urgent' 'Report.'
  run "$AUTO" check bad
  [[ "$output" == *"'urgent' is not a queue kind"* ]]
}

@test "the owner's learned rules go into every automation's prompt" {
  FRAIM_QUEUE_QUIET=1 fraim-brain note "Never mail customers on Sunday."
  make_auto digest 'output: none' 'Report.'
  run "$AUTO" run digest
  grep -q 'Never mail customers on Sunday.' "$(last_run digest)/prompt.md"
}

@test "a failed automation waits in the queue once, and approving it starts a fix" {
  export FRAIM_QUEUE_DIR="$HOME/fraim/queue" FRAIM_QUEUE_QUIET=1
  make_auto digest 'output: whatsapp' 'Report.'
  printf '#!/usr/bin/env bash\necho boom >&2; exit 3\n' > "$T/bin/fraim-claude"
  run "$AUTO" run digest
  run "$AUTO" run digest
  run fraim-queue list --json
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [[ "$output" == *"Automation digest failed"* ]]
  [[ "$output" == *"building-automations skill"* ]]
}

@test "on switches on an automation made off, only outside a headless run" {
  run fraim-auto new report --off
  [[ "$output" == *"switched off"* ]]
  printf -- '---\nenabled: false\ndescription: r\nschedule: "0 8 * * *"\noutput: none\n---\nSay hi.\n' > "$FRAIM_AUTOMATIONS_DIR/report/automation.md"
  fraim-auto sync
  ! grep -q 'report' "$FRAIM_AUTO_CRONTAB"
  FRAIM_HEADLESS=1 run fraim-auto on report
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner switches"* ]]
  grep -qx 'enabled: false' "$FRAIM_AUTOMATIONS_DIR/report/automation.md"
  run fraim-auto on report
  [ "$status" -eq 0 ]
  ! grep -q 'enabled' "$FRAIM_AUTOMATIONS_DIR/report/automation.md"
  grep -qx 'Say hi.' "$FRAIM_AUTOMATIONS_DIR/report/automation.md"
  grep -qx '0 8 \* \* \* fraim-auto fire report' "$FRAIM_AUTO_CRONTAB"
  FRAIM_LEAD_ROLE=engineer fraim-auto new other >/dev/null
  grep -qx 'enabled: false' "$FRAIM_AUTOMATIONS_DIR/other/automation.md"
}

@test "a good run closes the failure card of that automation only" {
  export FRAIM_QUEUE_DIR="$HOME/fraim/queue" FRAIM_QUEUE_QUIET=1
  make_auto flaky 'schedule: "0 8 * * *"' 'Do it.'
  FAKE_FAIL=1 run "$AUTO" fire flaky
  fraim-queue add --quiet --source "automation other" --kind failed --title "Automation other failed" >/dev/null
  [ "$(fraim-queue list --json | jq 'length')" = 2 ]
  run "$AUTO" fire flaky
  [ "$status" -eq 0 ]
  [ "$(fraim-queue list --json | jq -r '.[].title')" = "Automation other failed" ]
  [ "$(fraim-queue show q1 --json | jq -r .note)" = "Solved: the automation works again" ]
}

@test "an automation that names a skill may use it, and one without keeps its list" {
  make_auto withskill 'tools: Read
skill: inbox-rules' 'Sort the mail.'
  run "$AUTO" run withskill
  [ "$status" -eq 0 ]
  grep -qx 'Read,Skill' "$CLAUDE_ARGS"
  make_auto noskill 'tools: Read' 'Sort the mail.'
  run "$AUTO" run noskill
  [ "$status" -eq 0 ]
  grep -qx 'Read' "$CLAUDE_ARGS"
}
