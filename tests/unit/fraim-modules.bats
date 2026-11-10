#!/usr/bin/env bats
# Module manifests: fraim-doctor runs the checks of the modules that are on, and a new
# module adds a health check without an engine change.

load helper

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  FAKE="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME/fraim" "$HOME/.claude" "$FAKE"
  echo '{}' > "$HOME/.claude/.credentials.json"
  export PATH="$FAKE:$REPO/workspace/bin:$PATH"
  export FRAIM_DOCTOR_RETRY=0
  export FRAIM_RUNTIME_ENV="$BATS_TEST_TMPDIR/runtime.env"
  echo 'BROWSER_CDP_URL=http://cdp.test:9223' > "$FRAIM_RUNTIME_ENV"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export GATEWAY_STATUS='{"connected":true,"listeners":1}'
  cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit 0
EOF
  cat > "$FAKE/fraim-gateway" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$GATEWAY_STATUS"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/fraim-channels"
  chmod +x "$FAKE/curl" "$FAKE/fraim-gateway" "$FAKE/fraim-channels"
  MODS="$BATS_TEST_TMPDIR/modules"
  mkdir -p "$MODS"
  DOCTOR="$REPO/workspace/bin/fraim-doctor"
}

# One line per check: "name true" or "name false", from the JSON on stdout.
doctor_json() { "$DOCTOR" --json 2>/dev/null | jq -r '.checks[] | "\(.name) \(.ok)"'; }

manifest() {  # NAME BODY
  printf '%s\n' "$2" > "$MODS/$1.manifest"
}

MODULE_CHECKS='server-browser|syncthing|whatsapp-connected|whatsapp-reaches-claude'

@test "the shipped manifests give exactly today's check names" {
  export FRAIM_MODULES_DIR="$REPO/modules" FRAIM_MODULES=whatsapp,browser,sync,scheduler,google
  run bash -c "$(declare -f doctor_json); DOCTOR='$DOCTOR' doctor_json | grep -E -v '^(claude-|disk-|memory-|sessions-|queue-page|instructions-watch|jobs-ok|plugins-ok)' | sort"
  [ "$status" -eq 0 ]
  [ "$output" = "mail-watch true
server-browser true
syncthing true
whatsapp-connected true
whatsapp-reaches-claude true" ]
}

@test "the browser check reaches the address from runtime.env" {
  export FRAIM_MODULES_DIR="$REPO/modules" FRAIM_MODULES=browser
  run doctor_json
  [[ "$output" == *"server-browser true"* ]]
  grep -q 'http://cdp.test:9223/json/version' "$CURL_LOG"
}

@test "a module that is off has no checks" {
  export FRAIM_MODULES_DIR="$REPO/modules" FRAIM_MODULES=scheduler
  run doctor_json
  ! grep -Eq "$MODULE_CHECKS" <<<"$output"
}

@test "a new manifest adds a check with no engine change" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax
  manifest fax 'id: fax
profile: fax
check: fax-line test -d "$HOME/fraim"'
  run doctor_json
  [[ "$output" == *"fax-line true"* ]]
}

@test "the module is matched on its profile, not its file name" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=print
  manifest fax 'id: fax
profile: print
check: fax-line true'
  run doctor_json
  [[ "$output" == *"fax-line true"* ]]
}

@test "a failing module check fails the doctor" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax
  manifest fax 'id: fax
profile: fax
check: fax-line false'
  run --separate-stderr "$DOCTOR" --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.checks[] | select(.name == "fax-line") | .ok' <<<"$output")" = false ]
}

@test "a check that reads stdin does not eat the rest of the manifest" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax
  manifest fax 'id: fax
profile: fax
check: first cat
check: second true'
  run doctor_json
  [[ "$output" == *"first true"* ]]
  [[ "$output" == *"second true"* ]]
}

@test "a command may hold several words and pipes" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax
  manifest fax 'id: fax
profile: fax
check: fax-pipe printf "a b" | grep -q "a b"'
  run doctor_json
  [[ "$output" == *"fax-pipe true"* ]]
}

@test "a manifest needing a newer fraimwork is skipped with a warning on stderr" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax FRAIM_VERSION=v0.1.0
  manifest fax 'id: fax
min_fraim_version: 99.0.0
profile: fax
check: fax-line true'
  run --separate-stderr "$DOCTOR" --json
  jq -e . <<<"$output" >/dev/null
  [ "$(jq '[.checks[] | select(.name == "fax-line")] | length' <<<"$output")" = 0 ]
  [[ "$stderr" == *"fax"*"99.0.0"* ]]
}

@test "a manifest for this or an older fraimwork runs" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax
  manifest fax 'id: fax
min_fraim_version: 0.2.0
profile: fax
check: fax-line true'
  for v in v0.2.0 v0.10.0 v0.2.0-12-gabc1234; do
    FRAIM_VERSION="$v" run doctor_json
    [[ "$output" == *"fax-line true"* ]]
  done
}

@test "a build without a version number runs every manifest" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax
  manifest fax 'id: fax
min_fraim_version: 99.0.0
profile: fax
check: fax-line true'
  for v in dev abc1234; do
    FRAIM_VERSION="$v" run doctor_json
    [[ "$output" == *"fax-line true"* ]]
  done
}

@test "a broken check line is skipped with a warning" {
  export FRAIM_MODULES_DIR="$MODS" FRAIM_MODULES=fax
  manifest fax 'id: fax
profile: fax
check: nothing-to-run'
  run --separate-stderr "$DOCTOR" --json
  [ "$(jq '[.checks[] | select(.name == "nothing-to-run")] | length' <<<"$output")" = 0 ]
  [[ "$stderr" == *"nothing-to-run"* ]]
}

@test "modules on but no manifests found is a warning, not silence" {
  export FRAIM_MODULES_DIR="$BATS_TEST_TMPDIR/missing" FRAIM_MODULES=whatsapp
  run --separate-stderr "$DOCTOR" --json
  [[ "$stderr" == *"no module manifests"* ]]
}

@test "whatsapp-reaches-claude fails when no Claude listens" {
  export FRAIM_MODULES_DIR="$REPO/modules" FRAIM_MODULES=whatsapp
  export GATEWAY_STATUS='{"connected":true,"listeners":0}'
  run doctor_json
  [[ "$output" == *"whatsapp-reaches-claude false"* ]]
}

@test "whatsapp-reaches-claude passes before anyone has logged in" {
  export FRAIM_MODULES_DIR="$REPO/modules" FRAIM_MODULES=whatsapp
  export GATEWAY_STATUS='{"connected":true,"listeners":0}'
  rm "$HOME/.claude/.credentials.json"
  run doctor_json
  [[ "$output" == *"whatsapp-reaches-claude true"* ]]
}

@test "every shipped manifest declares the required keys and matches its file name" {
  local id f key
  for id in whatsapp browser sync scheduler google; do
    f="$REPO/modules/$id.manifest"
    [ -f "$f" ]
    for key in id version min_fraim_version description profile; do
      grep -q "^$key:" "$f"
    done
    grep -q "^id: $id$" "$f"
  done
}

@test "the workspace and the scheduler both see the manifests" {
  [ "$(grep -c '\./modules:/etc/fraim/modules:ro' "$REPO/compose.yaml")" = 2 ]
  grep -q '/etc/fraim/modules' "$DOCTOR"
}
