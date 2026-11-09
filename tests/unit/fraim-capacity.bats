#!/usr/bin/env bats
# workspace/bin/fraim-capacity with a fake /proc/meminfo and a fake fraim-herdr: room for a
# Claude, waiting, closing idle terminals (never working ones), and the fraim-claude gate.

setup() {
  CAP="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-capacity"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/goals/g1" "$T/home/fraim/goals/g2"
  export HOME="$T/home" FRAIM_MEMINFO="$T/meminfo" KILLS="$T/kills" FRAIM_RUNTIME_ENV=/dev/null FRAIM_CAPACITY_POLL=1
  echo "done 2026-11-09 10:00" > "$HOME/fraim/goals/g1/state"
  echo "running 2026-11-09 10:00" > "$HOME/fraim/goals/g2/state"
  # Each kill frees 500 MB, so a test can watch reclaim stop once there is room.
  cat > "$T/bin/fraim-herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "ls --json") cat "$LIST" ;;
  "hc kill")
    [ "${FRAIM_HEADLESS:-}" != 1 ] || [[ "$3" == g* ]] || exit 1
    echo "$3" >> "$KILLS"
    mb=$(( $(awk '/^MemAvailable:/ {print $2}' "$FRAIM_MEMINFO") + 512000 ))
    printf 'MemAvailable: %s kB\n' "$mb" > "$FRAIM_MEMINFO" ;;
  "hc rm") ;;
esac
EOF
  chmod +x "$T/bin/fraim-herdr"
  export PATH="$T/bin:$PATH" LIST="$T/list"
  jq -n '[
    {name: "main", kind: "main", status: "idle"},
    {name: "g1", kind: "goal", status: "idle"},
    {name: "g2", kind: "goal", status: "working"},
    {name: "s1", kind: "session", status: "working"},
    {name: "s2", kind: "session", status: "blocked"},
    {name: "s3", kind: "session", status: "done"}
  ]' > "$LIST"
}

mem() { printf 'MemAvailable: %s kB\n' "$(( $1 * 1024 ))" > "$FRAIM_MEMINFO"; }

@test "room means free memory for one Claude plus the reserve" {
  mem 900
  run "$CAP" check
  [ "$status" -eq 0 ]
  mem 700
  run "$CAP" check
  [ "$status" -eq 1 ]
  run "$CAP" status --json
  [ "$(jq -r .needed_mb <<<"$output")" = 800 ]
  [ "$(jq -r .room <<<"$output")" = false ]
}

@test "reclaim closes a finished goal first, then an idle session, and stops when there is room" {
  mem 100
  run "$CAP" reclaim
  [ "$status" -eq 0 ]
  [ "$(cat "$KILLS")" = "$(printf 'g1\ns3')" ]
}

@test "reclaim never closes main, a working goal, or a session that works or asks something" {
  mem 100
  jq '[.[] | select(.name != "g1" and .name != "s3")]' "$LIST" > "$T/l" && mv "$T/l" "$LIST"
  run "$CAP" reclaim
  [ "$status" -eq 1 ]
  [ ! -s "$KILLS" ]
}

@test "a run without the owner only closes goals" {
  mem 100
  FRAIM_HEADLESS=1 run "$CAP" reclaim
  [ "$(cat "$KILLS")" = g1 ]
}

@test "wait gives up after its time when nothing can be freed" {
  mem 100
  echo '[]' > "$LIST"
  run "$CAP" wait --max 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"waiting for free memory"* ]]
}

@test "fraim-claude: a headless run waits for room and is not started without it; main never waits" {
  ln -s "$CAP" "$T/bin/fraim-capacity"
  printf '#!/usr/bin/env bash\necho started "$@"\n' > "$T/bin/claude"
  chmod +x "$T/bin/claude"
  mem 100
  echo '[]' > "$LIST"
  FRAIM_CAPACITY_WAIT=1 run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-claude" -p "hello"
  [ "$status" -eq 75 ]
  [[ "$output" == *"no free memory"* ]]
  run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-claude" --continue
  [ "$status" -eq 0 ]
  [[ "$output" == *"started"* ]]
  mem 2000
  run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-claude" -p "hello"
  [ "$status" -eq 0 ]
}
