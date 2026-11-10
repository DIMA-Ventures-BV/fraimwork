#!/usr/bin/env bats
# workspace/bin/fraim-prompt: every instruction is a file the owner can change.

bats_require_minimum_version 1.5.0

setup() {
  T="$BATS_TEST_TMPDIR"
  BIN="$BATS_TEST_DIRNAME/../../workspace/bin"
  export HOME="$T/home" FRAIM_FILES_DIR="$T/home/fraim" FRAIM_LEADS_DIR="$T/home/fraim/leads"
  export FRAIM_PROMPT_DEFAULTS="$T/defaults" PATH="$BIN:$PATH"
  unset FRAIM_HEADLESS FRAIM_PROMPTS_DIR
  mkdir -p "$T/defaults" "$FRAIM_FILES_DIR/prompts" "$FRAIM_LEADS_DIR/chief/prompts"
  printf 'Hello {{who}}.\n' > "$T/defaults/greet.md"
}

@test "the default is used until the owner has their own" {
  run fraim-prompt render greet --set who=Sam
  [ "$output" = "Hello Sam." ]
  run fraim-prompt list
  [[ "$output" == *"greet"*"default"* ]]
}

@test "the owner's file wins, and one agent's file wins only for that agent" {
  printf 'Hi {{who}}.\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  run fraim-prompt render greet --set who=Sam
  [ "$output" = "Hi Sam." ]
  printf 'Yo {{who}}.\n' > "$FRAIM_LEADS_DIR/chief/prompts/greet.md"
  run fraim-prompt render greet --lead chief --set who=Sam
  [ "$output" = "Yo Sam." ]
  run fraim-prompt render greet --lead shop --set who=Sam
  [ "$output" = "Hi Sam." ]
}

@test "sections show on a value, and a section tag leaves no empty line" {
  printf 'A\n{{#x}}\nhas {{x}}\n{{/x}}\n{{^x}}\nnone\n{{/x}}\nB\n' > "$T/defaults/s.md"
  run fraim-prompt render s --set x=1
  [ "$output" = $'A\nhas 1\nB' ]
  run fraim-prompt render s
  [ "$output" = $'A\nnone\nB' ]
}

@test "a value is never read as a template, and multi-line values stay whole" {
  run fraim-prompt render greet --set 'who={{#x}}{{> greet}}{{/nope}}'
  [ "$status" -eq 0 ]
  [ "$output" = 'Hello {{#x}}{{> greet}}{{/nope}}.' ]
  run fraim-prompt render greet --set $'who=a\nb=c'
  [ "$output" = $'Hello a\nb=c.' ]
}

@test "a prompt can include another; a loop stops with the default" {
  printf '[{{> greet}}]' > "$T/defaults/wrap.md"
  run fraim-prompt render wrap --set who=Sam
  [ "$output" = $'[Hello Sam.\n]' ]
  printf '{{> loop}}' > "$FRAIM_FILES_DIR/prompts/loop.md"
  printf 'safe\n' > "$T/defaults/loop.md"
  run --separate-stderr fraim-prompt render loop
  [ "$status" -eq 0 ]
  [ "$output" = "safe" ]
  [[ "$stderr" == *"too deep"* ]]
}

@test "a mistake in the owner's file falls back to the default and is named" {
  printf '{{#open}} never closed\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  run --separate-stderr fraim-prompt render greet --set who=Sam
  [ "$status" -eq 0 ]
  [ "$output" = "Hello Sam." ]
  [[ "$stderr" == *"never closed"* ]]
  run fraim-prompt check greet
  [ "$status" -eq 1 ]
  [[ "$output" == *"never closed"* ]]
}

@test "check names a value the prompt does not get" {
  printf 'Hi {{whom}}\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  run fraim-prompt check greet
  [ "$status" -eq 1 ]
  [[ "$output" == *'"whom" is not a value'* ]]
}

@test "own copies the default once; reset keeps the old text" {
  run fraim-prompt own greet
  [ "$output" = "$FRAIM_FILES_DIR/prompts/greet.md" ]
  printf 'Mine {{who}}\n' > "$output"
  run fraim-prompt own greet
  run fraim-prompt show greet
  [ "$output" = "Mine {{who}}" ]
  run fraim-prompt diff greet
  [[ "$output" == *"+ Mine {{who}}"* ]]
  run fraim-prompt reset greet
  [ "$status" -eq 0 ]
  run fraim-prompt show greet
  [ "$output" = "Hello {{who}}." ]
  grep -q Mine "$FRAIM_FILES_DIR"/prompts/.history/greet.*.md
}

@test "own for one agent copies what that agent uses now" {
  printf 'Team {{who}}\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  run fraim-prompt own greet --lead chief
  [ "$output" = "$FRAIM_LEADS_DIR/chief/prompts/greet.md" ]
  grep -q Team "$output"
}

@test "list says when fraimwork changed a default the owner copied" {
  fraim-prompt own greet
  printf 'New default {{who}}\n' > "$T/defaults/greet.md"
  run fraim-prompt list
  [[ "$output" == *"changed its default"* ]]
}

@test "a run nobody watches cannot change prompts" {
  FRAIM_HEADLESS=1 run fraim-prompt own greet
  [ "$status" -eq 1 ]
  [[ "$output" == *"only the owner"* ]]
  FRAIM_HEADLESS=1 run fraim-prompt reset greet
  [ "$status" -eq 1 ]
}

@test "bad names and missing prompts are refused" {
  run fraim-prompt render ../secret
  [ "$status" -eq 2 ]
  run fraim-prompt show nothing
  [ "$status" -eq 1 ]
  run fraim-prompt list --lead ../x
  [ "$status" -eq 2 ]
}

@test "every shipped prompt parses and leaves no template syntax or shell in its text" {
  unset FRAIM_PROMPT_DEFAULTS
  run fraim-prompt list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 15 ]
  for name in $(fraim-prompt list | awk '{print $1}'); do
    out="$(fraim-prompt render "$name")"
    [[ "$out" != *"{{"* ]]
    [[ "$out" != *'$('* ]]
  done
}

@test "an empty file is skipped, so the agent keeps its instructions, and check names it" {
  printf '  \n\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  run fraim-prompt render greet --set who=Sam
  [ "$output" = "Hello Sam." ]
  printf '' > "$FRAIM_LEADS_DIR/chief/prompts/greet.md"
  run fraim-prompt render greet --lead chief --set who=Sam
  [ "$output" = "Hello Sam." ]
  run fraim-prompt check greet
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty"* ]]
}

@test "a broken file for one agent falls back to the owner's good file, not past it" {
  printf 'Hi {{who}}.\n' > "$FRAIM_FILES_DIR/prompts/greet.md"
  printf '{{#open}} never closed\n' > "$FRAIM_LEADS_DIR/chief/prompts/greet.md"
  run --separate-stderr fraim-prompt render greet --lead chief --set who=Sam
  [ "$status" -eq 0 ]
  [ "$output" = "Hi Sam." ]
  [[ "$stderr" == *"never closed"* ]]
}

@test "the shipped prompts say what the scripts used to say" {
  unset FRAIM_PROMPT_DEFAULTS
  out="$(fraim-prompt render goal --set id=g7 --set 'text=find flights' --set 'rules=- no emoji')"
  [[ "$out" == *"find flights"* ]]
  [[ "$out" == *"~/fraim/goals/g7/queue.json"* ]]
  [[ "$out" == *'e.g. \"Merge the new checkout text?\"'* ]]
  [[ "$out" == *"preferences, learned from earlier reviews"*"- no emoji"* ]]
  out="$(fraim-prompt render automation --set name=mail --set 'text=read mail' --set skill=inbox --set outs=whatsapp)"
  [[ "$out" == "Use the inbox skill"* ]]
  [[ "$out" == *"read mail"*'answer with exactly: SILENT'* ]]
  out="$(fraim-prompt render brain-distill --set 'log=e1 said' --set max_rule_chars=300)"
  [[ "$out" == *"e1 said"*"At most 300 characters"*'"ops"'* ]]
  out="$(fraim-prompt render brain-review --set 'chats=OWNER: hi' --set max_items=5)"
  [[ "$out" == *"OWNER: hi"*"Return at most 5 items"*'"items"'* ]]
  [[ "$(fraim-prompt render style-adhd)" == *"At most 5 short lines"* ]]
  [[ "$(fraim-prompt render style-detailed)" == *"Give the reasoning"* ]]
}
