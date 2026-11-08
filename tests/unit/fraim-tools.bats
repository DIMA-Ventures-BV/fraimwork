#!/usr/bin/env bats
# Extra tools and tool keys for a space: fraim-tools and fraim-env run in the workspace,
# fraim tool and fraim secret env/file call them over ssh.

load helper

setup() {
  setup_isolated
  use_public_target
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  TOOLS="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-tools"
  ENVTOOL="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-env"
  NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  export NPM_LOG
  cat > "$STUBS/npm" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$NPM_LOG"
EOF
  chmod +x "$STUBS/npm"
}

# --- fraim-env -----------------------------------------------------------------------

@test "fraim-env set writes NAME=value mode 600 and replaces an old value" {
  printf 'old' | "$ENVTOOL" set META_ACCESS_TOKEN
  printf 'new\n' | "$ENVTOOL" set META_ACCESS_TOKEN
  [ "$(cat "$HOME/.config/fraim/secrets.env")" = "META_ACCESS_TOKEN=new" ]
  [ "$(stat -c %a "$HOME/.config/fraim/secrets.env" 2>/dev/null || stat -f %Lp "$HOME/.config/fraim/secrets.env")" = 600 ]
}

@test "fraim-env list shows names only, rm removes one" {
  printf 'a-secret' | "$ENVTOOL" set ONE
  printf 'b-secret' | "$ENVTOOL" set TWO
  run "$ENVTOOL" list
  [ "$output" = "$(printf 'ONE\nTWO')" ]
  "$ENVTOOL" rm ONE
  run "$ENVTOOL" list
  [ "$output" = TWO ]
}

@test "fraim-env refuses odd names and an empty value" {
  run "$ENVTOOL" set 'bad name' <<<"x"
  [ "$status" -eq 2 ]
  run "$ENVTOOL" set GOOD < /dev/null
  [ "$status" -eq 1 ]
}

@test "fraim-env file writes inside home only, mode 600" {
  printf '{"a": "b c"}\n' | "$ENVTOOL" file .config/tool/credentials.json
  [ "$(cat "$HOME/.config/tool/credentials.json")" = '{"a": "b c"}' ]
  run "$ENVTOOL" file ../escape.json <<<"x"
  [ "$status" -eq 2 ]
  run "$ENVTOOL" file /etc/passwd <<<"x"
  [ "$status" -eq 2 ]
}

# --- fraim-tools ---------------------------------------------------------------------

@test "fraim-tools add installs an npm tool into home and remembers it once" {
  "$TOOLS" add npm:tiktok-ads-cli@1.0.4
  "$TOOLS" add npm:tiktok-ads-cli@1.0.5
  grep -q -- "install -g --prefix $HOME/.local .*tiktok-ads-cli@1.0.4" "$NPM_LOG"
  [ "$(cat "$HOME/.config/fraim/tools")" = "npm:tiktok-ads-cli@1.0.5" ]
}

@test "fraim-tools add takes scoped npm packages and refuses specs without a version" {
  run "$TOOLS" add npm:@owntag/gtm-cli@1.5.8
  [ "$status" -eq 0 ]
  run "$TOOLS" add npm:tiktok-ads-cli
  [ "$status" -eq 2 ]
  run "$TOOLS" add 'npm:x@1;rm -rf ~'
  [ "$status" -eq 2 ]
  run "$TOOLS" add pip:requests@2.0.0
  [ "$status" -eq 2 ]
}

@test "fraim-tools rm by short name uninstalls and forgets" {
  "$TOOLS" add npm:@owntag/gtm-cli@1.5.8 npm:tiktok-ads-cli@1.0.4
  "$TOOLS" rm gtm-cli
  grep -q 'uninstall -g .*@owntag/gtm-cli' "$NPM_LOG"
  [ "$(cat "$HOME/.config/fraim/tools")" = "npm:tiktok-ads-cli@1.0.4" ]
}

# --- laptop commands -------------------------------------------------------------------

@test "fraim tool add checks every spec before calling the server" {
  run "$FRAIM" tool add npm:tiktok-ads-cli@1.0.4 npm:no-version
  [ "$status" -eq 2 ]
  ! grep -q fraim-tools "$SSH_LOG"
  run "$FRAIM" tool add npm:tiktok-ads-cli@1.0.4 uv:meta-ads@1.0.1
  [ "$status" -eq 0 ]
  grep -q 'fraim-tools add npm:tiktok-ads-cli@1.0.4 uv:meta-ads@1.0.1' "$SSH_LOG"
}

@test "fraim secret env keeps the value out of every argument and restarts Claude" {
  run "$FRAIM" secret env TIKTOK_ADS_ACCESS_TOKEN --stdin <<<"tt-SECRET"
  [ "$status" -eq 0 ]
  ! grep -q tt-SECRET "$SSH_LOG"
  grep -q tt-SECRET "$SSH_STDIN_LOG"
  grep -q 'fraim-env set TIKTOK_ADS_ACCESS_TOKEN' "$SSH_LOG"
  grep -q 'fraim-connect reload' "$SSH_LOG"
}

@test "fraim secret file needs --stdin and sends the content on stdin" {
  run "$FRAIM" secret file .config/google-ads-open-cli/credentials.json
  [ "$status" -eq 2 ]
  run "$FRAIM" secret file .config/google-ads-open-cli/credentials.json --stdin <<<'{"refresh_token": "rt-SECRET"}'
  [ "$status" -eq 0 ]
  ! grep -q rt-SECRET "$SSH_LOG"
  grep -q rt-SECRET "$SSH_STDIN_LOG"
}
