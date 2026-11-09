#!/usr/bin/env bats
# workspace/bin/fraim-style: one writing style per place, built-in and owner-written styles,
# and the prompt block that goals, leads, automations and WhatsApp get.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  export HOME="$BATS_TEST_TMPDIR/home" FRAIM_STYLE_DIR="$BATS_TEST_TMPDIR/home/fraim/styles"
  mkdir -p "$HOME"
  export PATH="$BIN:$PATH"
}

@test "every place writes adhd by default" {
  run fraim-style
  [ "$status" -eq 0 ]
  [[ "$output" == *"whatsapp  adhd"* ]]
  [[ "$output" == *"queue     adhd"* ]]
  run fraim-style prompt whatsapp
  [[ "$output" == "Writing style for whatsapp (adhd)."* ]]
  [[ "$output" == *"At most 5 short lines"* ]]
}

@test "set changes one place, all changes every place" {
  run fraim-style set queue detailed
  [ "$status" -eq 0 ]
  run fraim-style prompt queue
  [[ "$output" == *"(detailed)"* ]]
  run fraim-style prompt whatsapp
  [[ "$output" == *"(adhd)"* ]]
  fraim-style set all detailed
  fraim-style set queue adhd
  [ "$(grep -c '^queue=' "$FRAIM_STYLE_DIR/settings")" -eq 1 ]
  run fraim-style prompt whatsapp
  [[ "$output" == *"(detailed)"* ]]
}

@test "normal gives only the plain-words rules" {
  fraim-style set whatsapp normal
  run fraim-style prompt whatsapp
  [ "$status" -eq 0 ]
  [[ "$output" == "Plain words, always"* ]]
  [[ "$output" != *"Writing style"* ]]
}

@test "every style gets the plain-words rules: no ids, real cause, a question that names the action" {
  for s in adhd detailed; do
    fraim-style set whatsapp "$s"
    run fraim-style prompt whatsapp
    [[ "$output" == *"Never show ids"* ]]
    [[ "$output" == *"real cause"* ]]
    [[ "$output" == *'not "Retry g5?"'* ]]
  done
}

@test "an owner-written style is listed, usable, and overrides a built-in one" {
  mkdir -p "$FRAIM_STYLE_DIR"
  printf -- '- Answer like a pirate.\n' > "$FRAIM_STYLE_DIR/pirate.md"
  printf -- '- One line only.\n' > "$FRAIM_STYLE_DIR/adhd.md"
  run fraim-style list
  [[ "$output" == *pirate* ]]
  fraim-style set whatsapp pirate
  run fraim-style prompt whatsapp
  [[ "$output" == *"like a pirate"* ]]
  run fraim-style prompt queue
  [[ "$output" == *"One line only"* ]]
  [[ "$output" != *"At most 5"* ]]
}

@test "unknown style or place is refused; an unknown prompt place falls back to default" {
  run fraim-style set whatsapp shouty
  [ "$status" -eq 1 ]
  run fraim-style set phone adhd
  [ "$status" -eq 2 ]
  run fraim-style set whatsapp ../x
  [ "$status" -eq 1 ]
  fraim-style set default detailed
  run fraim-style prompt email
  [[ "$output" == *"default (detailed)"* ]]
}
