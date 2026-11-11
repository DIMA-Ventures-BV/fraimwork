#!/usr/bin/env bats
# bin/fraim.d/herdr.sh: `fraim herdr` links the Herdr app on this computer to the server's
# terminals, with fakes for the installer, hc, herdr-app, open and ssh.

load helper

setup() {
  setup_isolated
  use_public_target
  export HERDR_LOG="$BATS_TEST_TMPDIR/herdr.log" FAKES="$BATS_TEST_TMPDIR/herdr-fakes"
  mkdir -p "$FAKES"
  cat > "$FAKES/hc" <<'EOF'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "machine ls") if [ -f "$FAKES/machine" ]; then echo '{"machines":[{"name":"fraim","state":"connected"}]}'; else echo '{"machines":[]}'; fi ;;
  "machine add") touch "$FAKES/machine"; echo '{"name":"fraim"}' ;;
  "machine rm") rm -f "$FAKES/machine"; echo '{"removed":"fraim"}' ;;
esac
EOF
  cat > "$FAKES/herdr-app" <<'EOF'
#!/usr/bin/env bash
printf 'herdr-app %s\n' "$*" >> "$HERDR_LOG"
case "$1 ${2:-}" in
  "ls ") if [ -f "$FAKES/space" ]; then echo '{"spaces":[{"id":"fraim/sp0123abcd","name":"fraim","machine":"fraim"}]}'; else echo '{"spaces":[]}'; fi ;;
  "do space.new") touch "$FAKES/space"; echo '{"space":"fraim/sp0123abcd","terminal":"fraim/t1"}' ;;
esac
EOF
  # The installer puts herdr-app and hc in ~/.local/bin, like the real one.
  cat > "$FAKES/install.sh" <<'EOF'
printf 'installer ran\n' >> "$HERDR_LOG"
mkdir -p "$HOME/.local/bin"
cp "$FAKES/hc" "$FAKES/herdr-app" "$HOME/.local/bin/"
EOF
  printf '#!/usr/bin/env bash\nprintf "open %%s\\n" "$*" >> "$HERDR_LOG"\n' > "$STUBS/open"
  chmod +x "$FAKES/hc" "$FAKES/herdr-app" "$STUBS/open"
  export FRAIM_HERDR_INSTALL_URL="file://$FAKES/install.sh" FRAIM_HERDR_WAIT=1
}

@test "link installs the app, adds the server as a machine, makes fraim's space and tells the server" {
  run "$FRAIM" herdr link
  [ "$status" -eq 0 ]
  grep -q 'installer ran' "$HERDR_LOG"
  grep -q 'hc machine add --name fraim --via ssh -p 2222 .*-o BatchMode=yes.* claude@test.invalid' "$HERDR_LOG"
  grep -q 'herdr-app do space.new --name fraim --machine fraim --folder /home/claude/fraim' "$HERDR_LOG"
  grep -q 'herdr-space' "$SSH_LOG"
  grep -qx 'sp0123abcd' "$SSH_STDIN_LOG"
  [[ "$output" == *"Herdr"* ]]
}

@test "link again changes nothing: one machine, one space, no second install" {
  "$FRAIM" herdr link
  run "$FRAIM" herdr link
  [ "$status" -eq 0 ]
  [ "$(grep -c 'installer ran' "$HERDR_LOG")" -eq 1 ]
  [ "$(grep -c 'machine add' "$HERDR_LOG")" -eq 1 ]
  [ "$(grep -c 'space.new' "$HERDR_LOG")" -eq 1 ]
}

@test "unlink forgets the machine here and the space on the server" {
  "$FRAIM" herdr link
  run "$FRAIM" herdr unlink
  [ "$status" -eq 0 ]
  grep -q 'hc machine rm fraim' "$HERDR_LOG"
  grep -q 'rm -f .*herdr-space' "$SSH_LOG"
}

@test "link installs fraim's look (layout and panel) and switches the window to it" {
  "$FRAIM" herdr link
  [ -f "$HOME/.config/herdr-app/mods/fraim/main.js" ]
  [ -f "$HOME/.config/herdr-app/mods/fraim/mod.json" ]
  jq -e '.. | objects | select(.id? == "chief-term") | .content.terminal == "fraim/main"' "$HOME/.config/herdr-app/layouts/fraim.json"
  grep -q 'herdr-app do layout.switch --name fraim' "$HERDR_LOG"
}

@test "link keeps the owner's own edits to fraim's layout aside before it replaces it" {
  mkdir -p "$HOME/.config/herdr-app/layouts"
  printf '{"mine":true}\n' > "$HOME/.config/herdr-app/layouts/fraim.json"
  "$FRAIM" herdr link
  grep -q mine "$HOME"/.config/herdr-app/layouts/fraim.json.old-*
  jq -e '.id == "root"' "$HOME/.config/herdr-app/layouts/fraim.json"
}

@test "herdr without a subcommand or with an unknown one explains itself" {
  run "$FRAIM" herdr nonsense
  [ "$status" -eq 2 ]
  [[ "$output" == *"fraim herdr link"* ]]
}
