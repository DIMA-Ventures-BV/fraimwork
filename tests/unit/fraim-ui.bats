#!/usr/bin/env bats
# workspace/bin/fraim-ui: the pages are files the owner can change.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/defaults" "$T/home"
  printf '<html>default inbox</html>\n' > "$T/defaults/inbox.html"
  printf '<html>default team</html>\n' > "$T/defaults/team.html"
  export HOME="$T/home" FRAIM_FILES_DIR="$T/home/fraim" FRAIM_UI_DEFAULTS="$T/defaults"
  export PATH="$BIN:$PATH"
  unset FRAIM_HEADLESS FRAIM_UI_DIR
  OWN="$T/home/fraim/ui"
}

@test "the shipped pages exist and are complete" {
  unset FRAIM_UI_DEFAULTS
  run fraim-ui list
  [[ "$output" == *"inbox"*"default"* ]]
  [[ "$output" == *"team"*"default"* ]]
  grep -qi '</html>' "$BIN/../ui/inbox.html"
  grep -qi '</html>' "$BIN/../ui/team.html"
  grep -qi '</html>' "$BIN/../ui/settings.html"
}

@test "own copies the default once, and keeps later edits" {
  run fraim-ui own inbox
  [ "$output" = "$OWN/inbox.html" ]
  echo '<html>mine</html>' > "$OWN/inbox.html"
  fraim-ui own inbox
  grep -q mine "$OWN/inbox.html"
  [ "$(fraim-ui path inbox)" = "$OWN/inbox.html" ]
  [[ "$(fraim-ui list)" == *"inbox"*"yours"* ]]
}

@test "list says when the default changed after the copy" {
  fraim-ui own inbox
  printf '<html>new default</html>\n' > "$FRAIM_UI_DEFAULTS/inbox.html"
  [[ "$(fraim-ui list)" == *"changed its default"* ]]
}

@test "reset goes back to the default and keeps the old page" {
  fraim-ui own inbox
  run fraim-ui reset inbox
  [ "$status" -eq 0 ]
  [ ! -e "$OWN/inbox.html" ]
  ls "$OWN/.history" | grep -q '^inbox\.'
  [ "$(fraim-ui path inbox)" = "$FRAIM_UI_DEFAULTS/inbox.html" ]
}

@test "new makes a page of the owner's and does not replace anything" {
  run fraim-ui new orders
  [ "$status" -eq 0 ]
  [ -s "$OWN/orders.html" ]
  run fraim-ui new orders
  [ "$status" -eq 2 ]
  run fraim-ui new inbox
  [ "$status" -eq 2 ]
}

@test "check names a page that is cut off" {
  fraim-ui own inbox
  run fraim-ui check
  [ "$status" -eq 0 ]
  printf '<html><body>half' > "$OWN/inbox.html"
  run fraim-ui check inbox
  [ "$status" -eq 1 ]
  [[ "$output" == *"stops before"* ]]
}

@test "a run nobody watches cannot change a page" {
  for action in "own inbox" "new orders" "reset inbox"; do
    # shellcheck disable=SC2086
    FRAIM_HEADLESS=1 run fraim-ui $action
    [ "$status" -eq 1 ]
    [[ "$output" == *"only the owner"* ]]
  done
  [ ! -e "$OWN/inbox.html" ]
}

@test "the chat with the owner can change a page" {
  run fraim-ui own inbox
  [ "$status" -eq 0 ]
  [ -f "$OWN/inbox.html" ]
}

@test "a bad page name is refused" {
  for bad in '../x' 'A' '.hidden'; do
    run fraim-ui path "$bad"
    [ "$status" -eq 2 ]
  done
}
