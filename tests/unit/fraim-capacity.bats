#!/usr/bin/env bats
# workspace/bin/fraim-capacity with a fake /proc/meminfo, cgroup and fraim-herdr: room for a
# Claude, admission with reservations, closing idle terminals (never working or recently used
# ones), and the fraim-claude gate.

setup() {
  CAP="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-capacity"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/fraim/goals/g1" "$T/home/fraim/goals/g2" "$T/home/fraim/sessions/s3"
  export FRAIM_CGROUP_DIR="$T/none" HOME="$T/home" FRAIM_MEMINFO="$T/meminfo" KILLS="$T/kills" \
    FRAIM_RUNTIME_ENV=/dev/null FRAIM_CAPACITY_POLL=1 FRAIM_RECLAIM_QUIET=0
  echo "done 2026-11-09 10:00" > "$HOME/fraim/goals/g1/state"
  echo "running 2026-11-09 10:00" > "$HOME/fraim/goals/g2/state"
  # Each kill frees 600 MB, so a test can watch reclaim stop once there is room.
  cat > "$T/bin/fraim-herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "ls --json") cat "$LIST" ;;
  "status "*) jq -r --arg n "$2" '.[] | select(.name == $n) | .status' "$LIST" ;;
  "hc kill")
    [ "${FRAIM_HEADLESS:-}" != 1 ] || [[ "$3" == g* ]] || exit 1
    echo "$3" >> "$KILLS"
    mb=$(( $(awk '/^MemAvailable:/ {print $2}' "$FRAIM_MEMINFO") + 614400 ))
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
  mem 1000
  run "$CAP" check
  [ "$status" -eq 0 ]
  mem 800
  run "$CAP" check
  [ "$status" -eq 1 ]
  run "$CAP" status --json
  [ "$(jq -r .needed_mb <<<"$output")" = 900 ]
  [ "$(jq -r .room <<<"$output")" = false ]
  [ "$(jq -r .claude_processes <<<"$output")" -ge 0 ]
}

@test "the container's own cap counts, without file cache the kernel can drop" {
  mem 4000
  mkdir -p "$T/cg"
  echo $(( 2000 * 1048576 )) > "$T/cg/memory.max"
  echo $(( 1900 * 1048576 )) > "$T/cg/memory.current"
  printf 'anon 1\ninactive_file %s\n' $(( 400 * 1048576 )) > "$T/cg/memory.stat"
  FRAIM_CGROUP_DIR="$T/cg" run "$CAP" status --json
  [ "$(jq -r .available_mb <<<"$output")" = 500 ]
  echo max > "$T/cg/memory.max"
  FRAIM_CGROUP_DIR="$T/cg" run "$CAP" status --json
  [ "$(jq -r .available_mb <<<"$output")" = 4000 ]
}

@test "admission reserves memory: runs that start together cannot all get in" {
  mem 2000
  run "$CAP" admit
  [ "$status" -eq 0 ]
  run "$CAP" admit
  [ "$status" -eq 0 ]
  # 2000 - 2 x 550 = 900: exactly room for one more, then none.
  run "$CAP" admit
  [ "$status" -eq 0 ]
  run "$CAP" admit
  [ "$status" -eq 1 ]
  # Reservations run out once the started Claudes would show in the real numbers.
  FRAIM_CAPACITY_HOLD=0 run "$CAP" admit
  [ "$status" -eq 0 ]
}

@test "admission under parallel starts lets in only what fits" {
  mem 2000
  for i in 1 2 3 4 5 6; do ( "$CAP" admit && echo in >> "$T/admitted" ) & done
  wait
  [ "$(wc -l < "$T/admitted")" -le 3 ]
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

@test "reclaim leaves a terminal alone that got a message or reported done just now" {
  mem 100
  touch "$HOME/fraim/goals/g1/last-send" "$HOME/fraim/sessions/s3/notified"
  FRAIM_RECLAIM_QUIET=300 run "$CAP" reclaim
  [ "$status" -eq 1 ]
  [ ! -s "$KILLS" ]
}

@test "reclaim checks again right before closing: a session that started working stays" {
  mem 100
  # The list says done; by the time of the close the terminal works again.
  jq '(.[] | select(.name == "s3") | .status) = "done"' "$LIST" > "$T/l" && mv "$T/l" "$LIST"
  cp "$T/bin/fraim-herdr" "$T/bin/fraim-herdr.orig"
  cat > "$T/bin/fraim-herdr" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "status s3" ]; then echo working; exit 0; fi
exec "$(dirname "$0")/fraim-herdr.orig" "$@"
EOF
  chmod +x "$T/bin/fraim-herdr"
  run "$CAP" reclaim
  [ "$(cat "$KILLS")" = g1 ]
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
  FRAIM_NO_CAPACITY_WAIT=1 run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-claude" -p "a message for the owner"
  [ "$status" -eq 0 ]
  mem 2000
  run "$BATS_TEST_DIRNAME/../../workspace/bin/fraim-claude" -p "hello"
  [ "$status" -eq 0 ]
}
