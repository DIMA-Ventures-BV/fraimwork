#!/usr/bin/env bats
# The name people see for an agent: fraim-lead display and the prompts that use it.

setup() {
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/home/fraim/leads/winston" "$T/home/fraim/leads/plain"
  export HOME="$T/home" FRAIM_FILES_DIR="$T/home/fraim" FRAIM_LEADS_DIR="$T/home/fraim/leads"
  export PATH="$BIN:$PATH"
  unset FRAIM_HEADLESS
  printf -- '---\nrole: chief\n---\n# Chief of staff\n' > "$FRAIM_LEADS_DIR/winston/lead.md"
  printf '# No header yet\n' > "$FRAIM_LEADS_DIR/plain/lead.md"
}

@test "the chief starts without a name, and setting one keeps the rest of its brief" {
  [ -z "$(fraim-lead display)" ]
  run fraim-lead display --chief -- "Winston de Boer"
  [ "$status" -eq 0 ]
  [ "$(fraim-lead display)" = "Winston de Boer" ]
  grep -qx 'role: chief' "$FRAIM_LEADS_DIR/winston/lead.md"
  grep -qx '# Chief of staff' "$FRAIM_LEADS_DIR/winston/lead.md"
}

@test "a new name replaces the old one, and clear brings the default back" {
  fraim-lead display --chief -- Sam
  fraim-lead display --chief -- Noor
  [ "$(grep -c '^display:' "$FRAIM_LEADS_DIR/winston/lead.md")" -eq 1 ]
  [ "$(fraim-lead display)" = Noor ]
  fraim-lead display --chief --clear
  [ -z "$(fraim-lead display)" ]
  grep -qx 'role: chief' "$FRAIM_LEADS_DIR/winston/lead.md"
}

@test "any agent can get a name, also one without a header" {
  fraim-lead display plain -- Platform
  [ "$(fraim-lead display plain)" = Platform ]
  grep -qx '# No header yet' "$FRAIM_LEADS_DIR/plain/lead.md"
  grep -q 'display: Platform' "$FRAIM_LEADS_DIR/plain/lead.md"
}

@test "a run with no owner watching cannot change a name" {
  FRAIM_HEADLESS=1 run fraim-lead display --chief -- Evil
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
  [ -z "$(fraim-lead display)" ]
}

@test "a name that could break a page or a prompt is refused" {
  for bad in '<b>x</b>' '{{x}}' 'a"b' "$(printf 'a%.0s' {1..41})"; do
    run fraim-lead display --chief -- "$bad"
    [ "$status" -eq 2 ]
  done
  [ -z "$(fraim-lead display)" ]
}

@test "the WhatsApp text is a prompt with the name and the login address in it" {
  run fraim-prompt render whatsapp --set view_url=http://view.example --set display=Winston
  [ "$status" -eq 0 ]
  [[ "$output" == *"You are Winston, the owner's chief of staff"* ]]
  [[ "$output" == *"log in at http://view.example and wait"* ]]
  [[ "$output" != *"\\'"* ]]
  [[ "$output" != *'${'* ]]
}

@test "without a name the prompts read normally" {
  for p in whatsapp relay chief-chat; do
    run fraim-prompt render "$p"
    [ "$status" -eq 0 ]
    [[ "$output" == *"You are the owner's chief of staff"* ]]
  done
  run fraim-prompt render server --set display=Winston
  [[ "$output" == *"chief of staff, and they call you Winston: one assistant"* ]]
}

@test "the owner can change the WhatsApp text" {
  mkdir -p "$FRAIM_FILES_DIR/prompts"
  printf 'Only say hello.\n' > "$FRAIM_FILES_DIR/prompts/whatsapp.md"
  [ "$(fraim-prompt render whatsapp)" = "Only say hello." ]
}
