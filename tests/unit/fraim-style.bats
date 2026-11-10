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

@test "the owner's voice: add, list, remove, and it wins in every place" {
  run fraim-style voice
  [[ "$output" == "No own rules yet"* ]]
  fraim-style voice add "Talk English to me"
  fraim-style voice add "Call me Michael"
  run fraim-style voice add "Talk English to me"
  [[ "$output" == "Already a rule"* ]]
  run fraim-style voice
  [ "$output" = "1. Talk English to me
2. Call me Michael" ]
  for place in whatsapp queue default; do
    run fraim-style prompt "$place"
    [[ "$output" == *"The owner's own rules for how you talk to them. They win over every rule above:"* ]]
    [[ "$output" == *"- Talk English to me"* ]]
  done
  fraim-style set whatsapp normal
  run fraim-style prompt whatsapp
  [[ "$output" == *"- Call me Michael"* ]]
  run fraim-style voice remove 1
  [ "$output" = "Removed: Talk English to me" ]
  run fraim-style voice
  [ "$output" = "1. Call me Michael" ]
  run fraim-style voice remove 5
  [ "$status" -eq 1 ]
  run fraim-style
  [[ "$output" == *"voice     1 own rules"* ]]
  fraim-style voice clear
  run fraim-style prompt whatsapp
  [[ "$output" != *"own rules"* ]]
}

@test "plain words name no internal parts, translate developer words, and say je" {
  run fraim-style prompt whatsapp
  [[ "$output" == *'"de bouwer"'* ]]
  [[ "$output" == *'merge/"gemerged" = "added to the code, not live yet"'* ]]
  [[ "$output" == *'never "u"'* ]]
  [[ "$output" == *"Never ask for a yes the owner already gave"* ]]
  [[ "$output" == *"do not ask which part"* ]]
}
