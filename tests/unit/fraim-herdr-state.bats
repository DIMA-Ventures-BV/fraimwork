#!/usr/bin/env bats
# fraim-herdr state and ls with a fake hc: the scheduler never starts a core of its own, and
# services are not listed as agents.

setup() {
  HERDR="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-herdr"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home"
  cp "$BATS_TEST_DIRNAME/fakes/hc" "$T/bin/hc"
  export HOME="$T/home" HC_FAKE="$T/hc" FRAIM_RUNTIME_ENV=/dev/null HC_SOCKET="$T/none.sock"
  export PATH="$T/bin:$PATH"
  mkdir -p "$HC_FAKE"
  jq -n '{address: "g1", name: "g1", labels: {fraim: "goal"}, state: "live", status: {state: "working"}, turn: 1}' > "$HC_FAKE/t-g1.json"
  jq -n '{address: "watch", name: "watch", labels: {fraim: "service"}, state: "live", status: {state: "idle"}, turn: 0}' > "$HC_FAKE/t-watch.json"
}

@test "state asks the core in the workspace" {
  run "$HERDR" state g1
  [ "$output" = live ]
  run "$HERDR" state g9
  [ "$output" = gone ]
}

@test "state in the scheduler with no core answering is unknown and calls no hc" {
  FRAIM_ROLE=scheduler run "$HERDR" state g1
  [ "$output" = unknown ]
  [ ! -s "$HC_FAKE/calls" ]
}

@test "open replaces a finished terminal and labels it" {
  jq '.state = "finished"' "$HC_FAKE/t-g1.json" > "$T/g" && mv "$T/g" "$HC_FAKE/t-g1.json"
  run "$HERDR" open g1 goal /tmp --label repo=x -- echo hi
  [ "$status" -eq 0 ]
  [ "$(jq -r '"\(.state) \(.labels.fraim) \(.labels.repo) \(.cwd)"' "$HC_FAKE/t-g1.json")" = "live goal x /tmp" ]
  [ "$(cat "$HC_FAKE/g1.argv")" = "$(printf 'echo\nhi')" ]
}

@test "a run without the owner may open goals only" {
  FRAIM_HEADLESS=1 run "$HERDR" open g2 goal /tmp -- true
  [ "$status" -eq 0 ]
  FRAIM_HEADLESS=1 run "$HERDR" open main main /tmp -- true
  [ "$status" -eq 1 ]
  [ ! -e "$HC_FAKE/t-main.json" ]
}

@test "up starts the services of the owner's services file, which wins over the default" {
  mkdir -p "$HOME/fraim"
  printf '# mine\nmine-sync sleep 30\n\nBad_Name true\n' > "$HOME/fraim/services"
  run "$HERDR" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad service name 'Bad_Name'"* ]]
  [ "$(jq -r .labels.fraim "$HC_FAKE/t-mine-sync.json")" = service ]
  grep -q 'sleep 30 2>>' "$HC_FAKE/mine-sync.argv"
  [ ! -e "$HC_FAKE/t-queue-page.json" ]
  [ -e "$HC_FAKE/t-main.json" ]
}

@test "the shipped services file starts the queue page and the watcher" {
  run "$HERDR" up
  [ "$status" -eq 0 ]
  [ -e "$HC_FAKE/t-queue-page.json" ]
  grep -q 'fraim-queue serve' "$HC_FAKE/queue-page.argv"
}

@test "ls leaves services out" {
  run "$HERDR" ls --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.name) | join(",")' <<<"$output")" = g1 ]
}
