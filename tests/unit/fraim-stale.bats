#!/usr/bin/env bats
# fraim-prompt stale and restore, fraim-ui restore, fraim-style own: an owner's copy survives
# updates, the owner hears once when a default moved on, and a reset can be undone.

bats_require_minimum_version 1.5.0

setup() {
  T="$BATS_TEST_TMPDIR"
  REPO="$BATS_TEST_DIRNAME/../.."
  BIN="$REPO/workspace/bin"
  mkdir -p "$T/fake" "$T/defaults" "$T/ui-defaults"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/sent"\n' "$T" > "$T/fake/fraim-notify"
  chmod +x "$T/fake/fraim-notify"
  export HOME="$T/home" FRAIM_FILES_DIR="$T/home/fraim" FRAIM_LEADS_DIR="$T/home/fraim/leads"
  export FRAIM_PROMPT_DEFAULTS="$T/defaults" FRAIM_UI_DEFAULTS="$T/ui-defaults"
  export PATH="$T/fake:$BIN:$PATH"
  unset FRAIM_HEADLESS FRAIM_PROMPTS_DIR FRAIM_UI_DIR FRAIM_STYLE_DIR FRAIM_GOAL
  mkdir -p "$FRAIM_FILES_DIR/prompts" "$FRAIM_FILES_DIR/styles" "$FRAIM_FILES_DIR/ui" "$FRAIM_LEADS_DIR/chief/prompts"
  cp "$REPO/workspace/prompts/stale-card.md" "$T/defaults/stale-card.md"
  printf 'Hello {{who}}.\n' > "$T/defaults/greet.md"
  printf 'Server rules.\n' > "$T/defaults/server.md"
  printf 'Be short.\n' > "$T/defaults/style-adhd.md"
  printf '<html>one</html>\n' > "$T/ui-defaults/inbox.html"
}

cards() { fraim-queue list --json | jq 'length'; }
card() { fraim-queue list --json | jq -r ".[$1].$2"; }

@test "nothing is reported while the owner has no copies, or copies of unchanged defaults" {
  run fraim-prompt stale
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing is out of date"* ]]
  fraim-prompt own greet
  fraim-ui own inbox
  fraim-style own adhd
  run fraim-prompt stale --json
  [ "$(jq -c . <<<"$output")" = '{"stale":[],"unknown":[]}' ]
}

@test "a copy of a prompt, a page and a style is stale once its default changed" {
  fraim-prompt own greet
  fraim-ui own inbox
  fraim-style own adhd
  printf 'Hello again {{who}}.\n' > "$T/defaults/greet.md"
  printf '<html>two</html>\n' > "$T/ui-defaults/inbox.html"
  printf 'Be shorter.\n' > "$T/defaults/style-adhd.md"
  run fraim-prompt stale --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stale | map(.kind + ":" + .name) | sort | join(" ")' <<<"$output")" = "page:inbox prompt:greet style:adhd" ]
  [ "$(jq -r '.unknown | length' <<<"$output")" = 0 ]
  run fraim-prompt stale
  [[ "$output" == *"prompt"*"greet"* ]]
  [[ "$output" == *"page"*"inbox"* ]]
  [[ "$output" == *"style"*"adhd"* ]]
}

@test "one agent's copy is reported with that agent's name" {
  fraim-prompt own greet --lead chief
  printf 'Changed\n' > "$T/defaults/greet.md"
  run fraim-prompt stale --json
  [ "$(jq -r '.stale[0].lead' <<<"$output")" = chief ]
  [ "$(jq -r '.stale[0].file' <<<"$output")" = "$FRAIM_LEADS_DIR/chief/prompts/greet.md" ]
}

@test "a hand-written copy with no base is unknown, reported apart from stale" {
  printf 'By hand\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  printf '<html>by hand</html>\n' > "$FRAIM_FILES_DIR/ui/inbox.html"
  printf 'By hand\n' > "$FRAIM_FILES_DIR/styles/adhd.md"
  run fraim-prompt stale --json
  [ "$(jq -r '.stale | length' <<<"$output")" = 0 ]
  [ "$(jq -r '.unknown | map(.kind) | sort | join(" ")' <<<"$output")" = "page prompt style" ]
  run fraim-prompt stale
  [[ "$output" == *"Not known"*"greet"* ]]
  [[ "$output" != *"Out of date"* ]]
}

@test "files with no default are the owner's own, not copies" {
  printf 'Mine\n' > "$FRAIM_FILES_DIR/prompts/mine.md"
  fraim-ui new mypage
  printf 'Mine\n' > "$FRAIM_FILES_DIR/styles/mine.md"
  printf -- '- Call me Sam\n' > "$FRAIM_FILES_DIR/styles/voice.md"
  run fraim-prompt stale --json
  [ "$(jq -c . <<<"$output")" = '{"stale":[],"unknown":[]}' ]
}

@test "a copy that already matches the new default is not out of date" {
  fraim-prompt own greet
  printf 'New\n' > "$T/defaults/greet.md"
  printf 'New\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  run fraim-prompt stale --json
  [ "$(jq -r '.stale | length' <<<"$output")" = 0 ]
}

@test "stale takes only its own options" {
  run fraim-prompt stale --nonsense
  [ "$status" -eq 2 ]
}

@test "the owner hears once for one set of changes, in one card" {
  fraim-prompt own greet
  fraim-ui own inbox
  printf 'Changed\n' > "$T/defaults/greet.md"
  printf '<html>two</html>\n' > "$T/ui-defaults/inbox.html"
  run fraim-prompt stale --notify
  [ "$status" -eq 0 ]
  [ "$(cards)" = 1 ]
  [ "$(card 0 kind)" = info ]
  [[ "$(card 0 summary)" == *"greet"*"inbox"* ]]
  for _ in $(seq 1 50); do [ -s "$T/sent" ] && break; sleep 0.1; done
  [ "$(grep -cF "$(card 0 title)" "$T/sent")" -eq 1 ]
  run fraim-prompt stale --notify
  [ "$status" -eq 0 ]
  [ "$(cards)" = 1 ]
  [ "$(grep -cF "$(card 0 title)" "$T/sent")" -eq 1 ]
}

@test "the default changing again is news; a copy being fixed is not" {
  fraim-prompt own greet
  fraim-ui own inbox
  printf 'Changed\n' > "$T/defaults/greet.md"
  printf '<html>two</html>\n' > "$T/ui-defaults/inbox.html"
  fraim-prompt stale --notify
  [ "$(cards)" = 1 ]
  fraim-prompt reset greet
  fraim-prompt stale --notify
  [ "$(cards)" = 1 ]
  printf '<html>three</html>\n' > "$T/ui-defaults/inbox.html"
  fraim-prompt stale --notify
  [ "$(cards)" = 2 ]
}

@test "no card without a stale copy; unknown copies alone do not make one" {
  printf 'By hand\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  run fraim-prompt stale --notify
  [ "$status" -eq 0 ]
  [ "$(cards)" = 0 ]
}

@test "a card that went out names the unknown copies too" {
  fraim-prompt own greet
  printf 'By hand\n' > "$FRAIM_FILES_DIR/styles/adhd.md"
  printf 'Changed\n' > "$T/defaults/greet.md"
  fraim-prompt stale --notify
  [[ "$(card 0 summary)" == *"greet"*"adhd"* ]]
}

@test "a stale copy of the server rules is said more strongly" {
  fraim-prompt own greet
  printf 'Changed\n' > "$T/defaults/greet.md"
  fraim-prompt stale --notify
  [ "$(card 0 priority)" = 2 ]
  [[ "$(card 0 summary)" != *"safety rules"* ]]
  fraim-prompt own server
  printf 'New rules.\n' > "$T/defaults/server.md"
  fraim-prompt stale --notify
  [ "$(cards)" = 2 ]
  [ "$(card 0 priority)" = 1 ]
  [[ "$(card 0 title)" == *"afety"* ]]
  [[ "$(card 0 summary)" == *"safety rules"* ]]
}

@test "the card text is the owner's to change" {
  printf 'My words: {{stale}}\n' > "$FRAIM_FILES_DIR/prompts/stale-card.md"
  fraim-prompt own greet
  printf 'Changed\n' > "$T/defaults/greet.md"
  fraim-prompt stale --notify
  [[ "$(card 0 summary)" == "My words: "*"greet"* ]]
}

@test "a card that could not be added is tried again" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$T/fake/fraim-queue"
  chmod +x "$T/fake/fraim-queue"
  fraim-prompt own greet
  printf 'Changed\n' > "$T/defaults/greet.md"
  run fraim-prompt stale --notify
  [ "$status" -eq 1 ]
  rm "$T/fake/fraim-queue"
  run fraim-prompt stale --notify
  [ "$status" -eq 0 ]
  [ "$(cards)" = 1 ]
}

@test "the check runs every day" {
  grep -Eq '^[0-9]+ [0-9]+ \* \* \* fraim-prompt stale --notify$' "$REPO/workspace/system.crontab"
}

@test "restore puts back the newest copy that reset kept" {
  fraim-prompt own greet
  printf 'First\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  fraim-prompt reset greet
  mv "$FRAIM_FILES_DIR"/prompts/.history/greet.*.md "$FRAIM_FILES_DIR/prompts/.history/greet.20260101T000000.md"
  fraim-prompt own greet
  printf 'Second\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  fraim-prompt reset greet
  run fraim-prompt restore greet
  [ "$status" -eq 0 ]
  [ "$(fraim-prompt show greet)" = "Second" ]
}

@test "restore keeps what it replaces" {
  fraim-prompt own greet
  printf 'Old\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  fraim-prompt reset greet
  mv "$FRAIM_FILES_DIR"/prompts/.history/greet.*.md "$FRAIM_FILES_DIR/prompts/.history/greet.20260101T000000.md"
  printf 'Current\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  fraim-prompt restore greet
  [ "$(fraim-prompt show greet)" = "Old" ]
  grep -q Current "$FRAIM_FILES_DIR"/prompts/.history/greet.*.md
}

@test "a restored copy still knows which default it came from" {
  fraim-prompt own greet
  printf 'Changed\n' > "$T/defaults/greet.md"
  fraim-prompt reset greet
  fraim-prompt restore greet
  run fraim-prompt stale --json
  [ "$(jq -r '.stale[0].name' <<<"$output")" = greet ]
}

@test "restore works for one agent's copy only" {
  fraim-prompt own greet --lead chief
  printf 'For chief\n' > "$FRAIM_LEADS_DIR/chief/prompts/greet.md"
  fraim-prompt reset greet --lead chief
  run fraim-prompt restore greet
  [ "$status" -eq 1 ]
  run fraim-prompt restore greet --lead chief
  [ "$status" -eq 0 ]
  [ "$(fraim-prompt show greet --lead chief)" = "For chief" ]
}

@test "restore without history says so, bad names are refused, and only the owner restores" {
  run fraim-prompt restore greet
  [ "$status" -eq 1 ]
  [[ "$output" == *"no earlier copy"* ]]
  run fraim-prompt restore ../secret
  [ "$status" -eq 2 ]
  FRAIM_HEADLESS=1 run fraim-prompt restore greet
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
}

@test "fraim-ui restore puts back the newest page, keeps the replaced one and its base" {
  fraim-ui own inbox
  printf '<html>mine</html>\n' > "$FRAIM_FILES_DIR/ui/inbox.html"
  printf '<html>two</html>\n' > "$T/ui-defaults/inbox.html"
  fraim-ui reset inbox
  mv "$FRAIM_FILES_DIR"/ui/.history/inbox.*.html "$FRAIM_FILES_DIR/ui/.history/inbox.20260101T000000.html"
  mv "$FRAIM_FILES_DIR"/ui/.history/.base/inbox.*.html "$FRAIM_FILES_DIR/ui/.history/.base/inbox.20260101T000000.html"
  printf '<html>current</html>\n' > "$FRAIM_FILES_DIR/ui/inbox.html"
  run fraim-ui restore inbox
  [ "$status" -eq 0 ]
  grep -q mine "$FRAIM_FILES_DIR/ui/inbox.html"
  grep -q current "$FRAIM_FILES_DIR"/ui/.history/inbox.*.html
  run fraim-prompt stale --json
  [ "$(jq -r '.stale[0].name' <<<"$output")" = inbox ]
}

@test "fraim-ui restore without history says so, and only the owner restores" {
  run fraim-ui restore inbox
  [ "$status" -eq 1 ]
  [[ "$output" == *"no earlier copy"* ]]
  run fraim-ui restore ../secret
  [ "$status" -eq 2 ]
  FRAIM_HEADLESS=1 run fraim-ui restore inbox
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
}

@test "fraim-style own copies a shipped style once and refuses what has no default" {
  run fraim-style own adhd
  [ "$output" = "$FRAIM_FILES_DIR/styles/adhd.md" ]
  grep -q 'Be short' "$FRAIM_FILES_DIR/styles/adhd.md"
  printf 'Mine\n' > "$FRAIM_FILES_DIR/styles/adhd.md"
  fraim-style own adhd
  grep -q Mine "$FRAIM_FILES_DIR/styles/adhd.md"
  run fraim-style own nonsense
  [ "$status" -eq 1 ]
  FRAIM_HEADLESS=1 run fraim-style own detailed
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
}
