#!/usr/bin/env bats
# workspace/bin/fraim-authority, and the limits that lean on it: who holds a role, which
# yes covers which work, what fraim-api passes to curl.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/home/fraim/leads" "$T/bin"
  export HOME="$T/home" FRAIM_RUNTIME_ENV=/dev/null
  export FRAIM_LEADS_DIR="$T/home/fraim/leads" PATH="$T/bin:$BIN:$PATH"
  unset FRAIM_HEADLESS FRAIM_GOAL FRAIM_BUILDS_OFF FRAIM_AUTHORITY_DIR
  A="$BIN/fraim-authority"
  ROLES="$HOME/.config/fraim/authority/roles"
}

lead() { mkdir -p "$FRAIM_LEADS_DIR/$1"; printf -- '%b' "$2" > "$FRAIM_LEADS_DIR/$1/lead.md"; }

@test "the roles file decides, not a line in the agent's own file" {
  lead real '---\nrole: chief\n---\n# Chief\n'
  run "$A" role chief
  [ "$output" = real ]
  lead aaa '---\nrole: lead\n---\nrole: chief\n'
  run "$A" role chief
  [ "$output" = real ]
  run "$A" role-of aaa
  [ "$output" = lead ]
}

@test "a role line in the body is not a role, also on the first read" {
  lead aaa '---\nrole: lead\n---\nrole: chief\n'
  lead real '---\nrole: chief\n---\n'
  run "$A" role chief
  [ "$output" = real ]
}

@test "adding a header after the first read gives no role" {
  lead real '---\nrole: chief\n---\n'
  lead sneaky '---\nrole: lead\n---\n'
  "$A" role chief >/dev/null
  lead sneaky '---\nrole: engineer\n---\n'
  run "$A" role engineer
  [ "$status" -eq 1 ]
}

@test "two chiefs on the first read: one wins and there is a warning" {
  lead one '---\nrole: chief\n---\n'
  lead two '---\nrole: chief\n---\n'
  run "$A" role chief
  [[ "$output" == *one* ]]
  [ "$(grep -c '^chief ' "$ROLES")" = 1 ]
}

@test "set-role replaces the holder and keeps the other roles" {
  lead c1 '---\nrole: chief\n---\n'
  lead e1 '---\nrole: engineer\n---\n'
  lead c2 '# new\n'
  "$A" set-role chief c2
  [ "$("$A" role chief)" = c2 ]
  [ "$("$A" role engineer)" = e1 ]
  [ "$(grep -c '^chief ' "$ROLES")" = 1 ]
}

@test "a run nobody watches cannot set a role" {
  lead c1 '# x\n'
  FRAIM_HEADLESS=1 run "$A" set-role chief c1
  [ "$status" -eq 1 ]
  [ ! -e "$ROLES" ]
}

@test "a holder whose folder is gone is no holder" {
  lead c1 '---\nrole: chief\n---\n'
  "$A" role chief >/dev/null
  rm -rf "$FRAIM_LEADS_DIR/c1"
  run "$A" role chief
  [ "$status" -eq 1 ]
}

@test "bad input is a usage error" {
  run "$A" role boss
  [ "$status" -eq 2 ]
  run "$A" set-role chief '../x'
  [ "$status" -eq 2 ]
  run "$A"
  [ "$status" -eq 2 ]
}

# --- which yes covers which work

queue_setup() {
  export FRAIM_QUEUE_DIR="$HOME/fraim/queue" FRAIM_BRAIN_DIR="$HOME/fraim/brain" FRAIM_GOALS_DIR="$HOME/fraim/goals" AUTO_ARGS="$T/auto" GOAL_ARGS="$T/goal"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$AUTO_ARGS"\n' > "$T/bin/fraim-auto"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$GOAL_ARGS"\necho g9\n' > "$T/bin/fraim-goal"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/fraim-notify"
  chmod +x "$T/bin/"*
  Q="$BIN/fraim-queue"
  "$Q" add --quiet --title "Owner said yes to this" >/dev/null
  "$Q" approve q1 >/dev/null
}
state() { jq -r .state "$FRAIM_QUEUE_DIR/$1/item.json"; }

@test "a plain lead cannot spend an owner's yes" {
  queue_setup
  FRAIM_HEADLESS=1 run "$Q" add --quiet --lead sales --title "x" --switch-on thing --approved-by q1
  [ "$(state q2)" = open ]
  [ ! -e "$AUTO_ARGS" ]
}

@test "a plain lead cannot start a goal with an owner's yes" {
  queue_setup
  FRAIM_HEADLESS=1 run "$Q" add --quiet --lead sales --title "x" --on-approve "do anything" --approved-by q1
  [ "$(state q2)" = open ]
  [ ! -e "$GOAL_ARGS" ]
}

@test "the engineer can switch on what it built, but cannot start a goal" {
  queue_setup
  FRAIM_HEADLESS=1 FRAIM_BUILDS_OFF=1 run "$Q" add --quiet --lead e --title "x" --switch-on thing --approved-by q1
  [ "$(state q2)" = approved ]
  grep -qx 'on thing' "$AUTO_ARGS"
  FRAIM_HEADLESS=1 FRAIM_BUILDS_OFF=1 run "$Q" add --quiet --lead e --title "y" --on-approve "do anything" --approved-by q1
  [ "$(state q3)" = open ]
  [ ! -e "$GOAL_ARGS" ]
}

@test "a goal can only use the yes it was started from" {
  queue_setup
  "$Q" add --quiet --title "Another yes" >/dev/null
  "$Q" approve q2 >/dev/null
  mkdir -p "$FRAIM_GOALS_DIR/g5"
  echo q2 > "$FRAIM_GOALS_DIR/g5/queue"
  FRAIM_HEADLESS=1 FRAIM_GOAL=g5 run "$Q" add --quiet --title "x" --switch-on a --approved-by q1
  [ "$(state q3)" = open ]
  FRAIM_HEADLESS=1 FRAIM_GOAL=g5 run "$Q" add --quiet --title "y" --switch-on b --approved-by q2
  [ "$(state q4)" = approved ]
}

@test "the owner's own session still spends a yes" {
  queue_setup
  run "$Q" add --quiet --title "x" --on-approve "go" --approved-by q1
  [ "$(state q2)" = approved ]
}

# --- what fraim-api passes to curl

api_setup() {
  export FRAIM_SECRETS_URL=http://secrets:8080 FRAIM_SECRETS_TOKEN=tok CURL_LOG="$T/curl"
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *_services*) echo 'openai Authorization Bearer %s https://api.openai.com' ;;
  *) cat >/dev/null; printf '%s\n' "$@" >> "$CURL_LOG" ;;
esac
EOF
  chmod +x "$T/bin/curl"
}

@test "normal API options pass" {
  api_setup
  run "$BIN/fraim-api" openai /v1/x -X POST -H 'Content-Type: application/json' -d @body.json -sS --max-time 30 -G --data-urlencode 'a=b'
  [ "$status" -eq 0 ]
  grep -qx 'POST' "$CURL_LOG"
  grep -qx '@body.json' "$CURL_LOG"
}

@test "a body from the owner's folder or tmp passes" {
  api_setup
  run "$BIN/fraim-api" openai /v1/x -d "@$HOME/fraim/body.json"
  [ "$status" -eq 0 ]
  run "$BIN/fraim-api" openai /v1/x -d @/tmp/body.json
  [ "$status" -eq 0 ]
}

@test "options that write files, change the target or read config are refused" {
  api_setup
  for bad in "-o /tmp/x" "-O" "--output /tmp/x" "-T /tmp/x" "-K /tmp/c" "--config /tmp/c" "--url http://evil" "-x http://evil" "--proxy http://evil" "-L" "--location" "http://evil.example/" "-w @/tmp/f" "-F a=@/tmp/f" "--next" "-H @/tmp/h" "-d @/etc/passwd" "-d @../../secret"; do
    # shellcheck disable=SC2086
    run "$BIN/fraim-api" openai /v1/x $bad
    [ "$status" -eq 2 ] || { echo "not refused: $bad"; return 1; }
  done
  [ ! -e "$CURL_LOG" ]
}

# --- what unattended runs may edit

@test "an unattended run cannot edit budgets or the chief's brief" {
  mkdir -p "$T/fc"
  cp "$BIN/fraim-claude" "$T/fc/"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$T/fc/claude"
  chmod +x "$T/fc/"*
  lead winston '---\nrole: chief\n---\n'
  PATH="$T/fc:$T/bin:$BIN:/usr/bin:/bin" run "$T/fc/fraim-claude" -p hi
  [[ "$output" == *'Edit(~/fraim/leads/*/budget)'* ]]
  [[ "$output" == *'Edit(~/fraim/leads/winston/lead.md)'* ]]
  [[ "$output" != *'Write(~/fraim/leads/winston/lead.md)'* ]]
}

@test "the owner's chat is not limited by those rules" {
  mkdir -p "$T/fc"
  cp "$BIN/fraim-claude" "$T/fc/"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$T/fc/claude"
  chmod +x "$T/fc/"*
  FRAIM_OWNER_CHAT=1 PATH="$T/fc:$T/bin:$BIN:/usr/bin:/bin" run "$T/fc/fraim-claude" -p hi
  [[ "$output" != *'budget'* ]]
}

# --- an agent cannot speak as someone else

@test "a lead run cannot write a note as the owner or as another lead" {
  export FRAIM_LEAD_NO_WAKE=1
  lead sales '# x\n'
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=ops run "$BIN/fraim-lead" tell sales -- hello
  grep -q 'from ops: hello' "$FRAIM_LEADS_DIR/sales/inbox.md"
  FRAIM_HEADLESS=1 FRAIM_LEAD_NAME=ops run "$BIN/fraim-lead" tell sales --from owner -- hi2
  grep -q 'from ops: hi2' "$FRAIM_LEADS_DIR/sales/inbox.md"
  FRAIM_HEADLESS=1 FRAIM_GOAL=g3 run "$BIN/fraim-lead" tell sales -- hi3
  grep -q 'from g3: hi3' "$FRAIM_LEADS_DIR/sales/inbox.md"
  run "$BIN/fraim-lead" tell sales -- hi4
  grep -q 'from owner: hi4' "$FRAIM_LEADS_DIR/sales/inbox.md"
}
