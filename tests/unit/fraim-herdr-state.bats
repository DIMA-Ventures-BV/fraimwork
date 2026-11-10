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

@test "ls leaves services out" {
  run "$HERDR" ls --json
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.name) | join(",")' <<<"$output")" = g1 ]
}
