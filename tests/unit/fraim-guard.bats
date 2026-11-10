#!/usr/bin/env bats
# workspace/bin/fraim-guard: real commands through the hook, the way Claude Code calls it.

bats_require_minimum_version 1.5.0

setup() {
  export HOME=/home/claude
  GUARD="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-guard"
}

check() { jq -cn --arg c "$1" --arg d "${2:-/home/claude/fraim}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | node "$GUARD"; }

@test "every spelling of a force push is refused" {
  for c in 'git push --force origin main' 'git push -f origin main' 'git push origin main -f' 'git push origin main --force' \
    'git -C /home/claude/code/app push --force' 'git -c a=b push -uf origin x' 'git push origin +main' 'cd x && git push -f' \
    'bash -c "git push --force"' 'FOO=1 git push -f' '/usr/bin/git push -f' 'timeout 30 git push --force'; do
    run check "$c"
    [ "$status" -eq 2 ] || { echo "not refused: $c"; false; }
  done
}

@test "a normal push and other git commands run" {
  for c in 'git push origin main' 'git push -u origin feature' 'git push --force-with-lease origin feature' \
    'git log -f' 'git fetch --force' 'git commit -m "git push -f"' 'echo git push --force'; do
    run check "$c"
    [ "$status" -eq 0 ] || { echo "refused: $c"; false; }
  done
}

@test "every spelling of deleting the home folder is refused" {
  for c in 'rm -rf ~' 'rm -rf ~/' 'rm -rf $HOME' 'rm -rf "$HOME"' 'rm -rf ${HOME}/' 'rm -r -f ~' 'rm -fr /home/claude' 'rm -rf -- ~' \
    'rm -rf /' 'rm -rf /home' 'rm -rf ~/*' 'rm -rf ~/fraim' 'rm -rf ~/..' 'rm --recursive --force ~' 'bash -c "rm -rf ~"'; do
    run check "$c"
    [ "$status" -eq 2 ] || { echo "not refused: $c"; false; }
  done
  run check 'rm -rf .' /home/claude
  [ "$status" -eq 2 ]
  run check 'rm -rf *' /home/claude
  [ "$status" -eq 2 ]
}

@test "ordinary deletes run" {
  for c in 'rm -rf /tmp/build' 'rm -rf ~/code/app/node_modules' 'rm -rf ~/fraim/goals/g1/tmp' 'rm ~/notes.txt' 'rm -f ~/x' 'rm -rf build' 'echo rm -rf ~'; do
    run check "$c"
    [ "$status" -eq 0 ] || { echo "refused: $c"; false; }
  done
  run check 'rm -rf *' /home/claude/code/app/dist
  [ "$status" -eq 0 ]
}

@test "a refusal tells Claude why, and anything unexpected lets the command run" {
  run --separate-stderr check 'git push -f'
  [[ "$stderr" == *"force push"* ]]
  run node "$GUARD" <<<'not json'
  [ "$status" -eq 0 ]
  run node "$GUARD" <<<'{"tool_name":"Read","tool_input":{"file_path":"x"}}'
  [ "$status" -eq 0 ]
}

@test "text that only looks like a command is not refused" {
  run check "$(printf "cat > notes.md <<'EOF'\ngit push --force\nrm -rf ~\nEOF")"
  [ "$status" -eq 0 ]
  run check "$(printf 'cat <<-EOF > x\n\trm -rf ~\n\tEOF\necho done')"
  [ "$status" -eq 0 ]
  run check 'git push origin main # was -f'
  [ "$status" -eq 0 ]
  run check "rm -rf '\$HOME/build'"
  [ "$status" -eq 0 ]
  run check 'rm -rf "~/x"'
  [ "$status" -eq 0 ]
  run check 'cd ~/code/app && rm -rf .' /home/claude
  [ "$status" -eq 0 ]
}

@test "a real command after text, on two lines, or behind a keyword or wrapper is refused" {
  for c in "$(printf "cat <<'EOF'\ndon't\nEOF\ngit push -f")" "$(printf "# don't\ngit push -f")" "$(printf 'git push \\\n-f')" \
    "$(printf 'git push\\\n -f')" "$(printf 'rm -rf \\\n$HOME')" 'env -i git push --force' 'nice -n 10 git push -f' 'timeout -k 5 10 git push -f' \
    'if true; then git push -f; fi' 'for b in a; do git push -f; done' '! git push -f' '{ git push -f; }' 'eval "git push -f"'; do
    run check "$c"
    [ "$status" -eq 2 ] || { echo "not refused: $c"; false; }
  done
}

@test "a cd in the same command counts, and every glob of home is refused" {
  for c in 'cd ~ && rm -rf .' 'cd ~/fraim && rm -rf *' 'rm -rf ~/.*' 'rm -rf ~/fraim/*/' 'rm -rf /*'; do
    run check "$c" /tmp
    [ "$status" -eq 2 ] || { echo "not refused: $c"; false; }
  done
  run check 'rm -rf ~/code/app/*'
  [ "$status" -eq 0 ]
}
