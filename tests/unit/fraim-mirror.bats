#!/usr/bin/env bats
# fraim mirror (a space set up from one file), fraim host add --like (the same SSH host as
# this computer, with its trusted host keys) and fraim-hosts known_hosts pinning.

load helper

setup() {
  setup_isolated
  use_public_target
  HOSTS="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-hosts"
  ENVTOOL="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-env"
  MIRROR="$BATS_TEST_TMPDIR/setup.mirror"
}

# This computer's `ssh -G prod-app` and its known_hosts entry for the host key alias.
# `ssh -F /dev/null -G` (no config files) gives other values, so the alias is configured.
laptop_knows_prod_app() {
  mkdir -p "$HOME/.ssh"
  printf '203.0.113.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEHOSTKEY\n' > "$HOME/.ssh/known_hosts"
  ssh_handler '
if [ "$1" = -F ]; then printf "user me\nhostname prod-app\nport 22\n"; exit 0; fi
if [ "$1" = -G ]; then
  printf "user deploy\nhostname 100.84.1.2\nport ${LAPTOP_PORT:-22}\nhostkeyalias 203.0.113.9\nuserknownhostsfile %s/.ssh/known_hosts\n" "$HOME"
  exit 0
fi
case "$REMOTE" in
  *"fraim-hosts add prod-app"*) echo "ssh-ed25519 AAAAC3Nza fraim-main-prod-app" ;;
  *"fraim-hosts test prod-app"*) exit "${HOST_TEST_RC:-0}" ;;
esac'
}

# --- fraim host add --like -------------------------------------------------------------

@test "host add --like copies address, user, host key alias and host keys from this computer" {
  laptop_knows_prod_app
  run "$FRAIM" host add prod-app --like prod-app
  [ "$status" -eq 0 ]
  grep -qF 'fraim-hosts add prod-app --address 100.84.1.2 --user deploy --port 22 --host-key-alias 203.0.113.9 --known-hosts-stdin' "$SSH_LOG"
  grep -qF '203.0.113.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEHOSTKEY' "$SSH_STDIN_LOG"
  # The new key is authorized through the same alias on this computer.
  grep -qE '^.*prod-app k=no-agent-forwarding' "$SSH_LOG"
}

@test "host add --like finds the host keys of a HostKeyAlias on another port" {
  laptop_knows_prod_app
  export LAPTOP_PORT=2200
  run "$FRAIM" host add prod-app --like prod-app
  [ "$status" -eq 0 ]
  grep -qF -- '--port 2200 --host-key-alias 203.0.113.9 --known-hosts-stdin' "$SSH_LOG"
  [[ "$output" != *"no known host key"* ]]
}

@test "host add on a Tailscale address that the server cannot reach points at tailscale reach" {
  laptop_knows_prod_app
  export HOST_TEST_RC=1
  run "$FRAIM" host add prod-app --like prod-app --authorize-via none-needed
  [ "$status" -eq 3 ]
  [[ "$output" == *"fraim tailscale reach"* ]]
}

@test "host add --like stops before touching the space when this computer has no such alias" {
  ssh_handler '
case "$1" in -G|-F) printf "user someone\nhostname prod-app\nport 22\n"; exit 0 ;; esac'
  run "$FRAIM" host add prod-app --like prod-app
  [ "$status" -eq 1 ]
  [[ "$output" == *"no host prod-app in ~/.ssh/config"* ]]
  ! grep -q fraim-hosts "$SSH_LOG"
}

@test "host add --like takes an alias that only sets the user" {
  ssh_handler '
case "$1" in
  -F) printf "user me\nhostname prod-app\nport 22\n"; exit 0 ;;
  -G) printf "user Deploy.Bot\nhostname prod-app\nport 22\n"; exit 0 ;;
esac
case "$REMOTE" in *"fraim-hosts add"*) echo "ssh-ed25519 AAAAC3Nza fraim-main-prod-app" ;; esac'
  run "$FRAIM" host add prod-app --like prod-app
  [ "$status" -eq 0 ]
  grep -qF -- '--address prod-app --user Deploy.Bot' "$SSH_LOG"
  [[ "$output" == *"no known host key"* ]]
}

@test "host add --like refuses an alias that looks like an option" {
  run "$FRAIM" host add prod-app --like=-oProxyCommand=x
  [ "$status" -eq 2 ]
}

# --- fraim-hosts known_hosts -----------------------------------------------------------

@test "fraim-hosts pins the given host keys instead of trusting the first one" {
  printf '203.0.113.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEHOSTKEY\n# a comment\n' \
    | "$HOSTS" add prod-app --address 100.84.1.2 --user deploy --host-key-alias 203.0.113.9 --known-hosts-stdin >/dev/null
  config="$HOME/.ssh/config"
  grep -q 'HostKeyAlias 203.0.113.9' "$config"
  grep -q 'StrictHostKeyChecking yes' "$config"
  grep -q "UserKnownHostsFile $HOME/.ssh/fraim-hosts/prod-app.known" "$config"
  [ "$(cat "$HOME/.ssh/fraim-hosts/prod-app.known")" = '203.0.113.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEHOSTKEY' ]
  # Added again without host keys: back to trust on first use, and the old pin is gone.
  "$HOSTS" add prod-app --address 100.84.1.2 < /dev/null >/dev/null
  grep -q 'StrictHostKeyChecking accept-new' "$config"
  [ ! -e "$HOME/.ssh/fraim-hosts/prod-app.known" ]
}

@test "fraim-hosts --known-hosts-stdin without host keys exits 2" {
  run "$HOSTS" add prod-app --address 100.84.1.2 --known-hosts-stdin <<<"# nothing"
  [ "$status" -eq 2 ]
}

@test "fraim-env says Unchanged when the value or file is already there" {
  printf 'v1' | "$ENVTOOL" set ONE
  run "$ENVTOOL" set ONE <<<"v1"
  [ "$output" = "Unchanged ONE." ]
  run "$ENVTOOL" set ONE <<<"v2"
  [ "$output" = "Set ONE." ]
  printf 'a' | "$ENVTOOL" file .config/t/c.json >/dev/null
  run "$ENVTOOL" file .config/t/c.json <<<"a"
  [ "$output" = "Wrote ~/.config/t/c.json." ]
  run "$ENVTOOL" file .config/t/c.json <<<"a"
  [ "$output" = "Unchanged ~/.config/t/c.json." ]
}

# --- fraim mirror: the file ---------------------------------------------------------------

@test "mirror checks every line before it runs anything" {
  printf 'repo acme/app\ntool npm:left-pad@1.3.0\nenv lower_case\nconnect x http://insecure.example key K\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"line 3: env lower_case"* ]]
  [[ "$output" == *"line 4: connect x http://insecure.example key K"* ]]
  [ ! -s "$SSH_LOG" ]
}

@test "mirror refuses option-like words, odd headers and formats, and protected files" {
  for l in \
    'connect x https://h.example/mcp key K --command=x;curl|sh' \
    'connect x https://h.example/mcp key K X-Key --url=https://evil.example' \
    'connect x https://h.example/mcp key K Bad:Header' \
    'connect x https://h.example/mcp key K X-Key nopercent' \
    'connect x https://h.example/mcp key K X-Key -%s' \
    'connect x https://h.example/mcp oauth --redirect' \
    'host prod -oProxyCommand=x' \
    'file .ssh/id_ed25519' 'file .ssh' 'file .claude/settings.json' 'file .claude.json' \
    'file .config/fraim/secrets.env' 'file .bashrc' 'file .gitconfig' 'file .local/bin/claude'; do
    printf '%s\n' "$l" > "$MIRROR"
    run "$FRAIM" mirror "$MIRROR" --yes
    [ "$status" -eq 2 ] || { echo "accepted: $l"; return 1; }
  done
  [ ! -s "$SSH_LOG" ]
  printf 'connect x https://h.example/mcp key K X-Api-Key Token_%%s\nfile .config/tool/creds.json\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --dry-run
  [ "$status" -eq 0 ]
}

@test "mirror reads a file with Windows line endings" {
  printf 'repo acme/app\r\ntool npm:left-pad@1.3.0 \r\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo    clone or fetch acme/app"* ]]
  [[ "$output" == *"tool    install npm:left-pad@1.3.0"* ]]
}

@test "mirror without --yes shows where every key goes and runs nothing" {
  printf 'env META_TOKEN\nconnect ph https://mcp-eu.posthog.com/mcp key PH_KEY\nhost prod-app\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --only env,connect,host
  [ "$status" -eq 3 ]
  [[ "$output" == *'copy $META_TOKEN from this computer'* ]]
  [[ "$output" == *'the key in $PH_KEY goes to mcp-eu.posthog.com'* ]]
  [[ "$output" == *"adds a key to its authorized_keys"* ]]
  [[ "$output" == *"HUMAN STEP:"*"fraim mirror $MIRROR --yes --only env,connect,host"* ]]
  [ ! -s "$SSH_LOG" ]
}

@test "mirror --dry-run shows the plan of the chosen kinds only and exits 0" {
  printf '# DAMI\nrepo acme/app\ntool npm:left-pad@1.3.0  # pinned\nenv META_TOKEN\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --dry-run --only repo,env
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
  [[ "$output" != *tool* ]]
  [ ! -s "$SSH_LOG" ]
}

@test "mirror works on macOS's own bash 3.2 with an empty file and an empty selection" {
  [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' || skip "no bash 3 here"
  printf '# only comments\n' > "$MIRROR"
  run /bin/bash "$FRAIM" mirror "$MIRROR" --dry-run
  [ "$status" -eq 0 ]
  printf 'repo acme/app\n' > "$MIRROR"
  run /bin/bash "$FRAIM" mirror "$MIRROR" --only connect --yes
  [ "$status" -eq 0 ]
  [ "$output" = "Nothing to do." ]
  ssh_handler '
case "$REMOTE" in
  "fraim-connect list --json") echo "[]" ;;
esac'
  printf 'connect posthog https://mcp.example.com/mcp key PH_KEY\n' > "$MIRROR"
  PH_KEY=ph-SECRET run /bin/bash "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"done    connect posthog"* ]]
}

# --- fraim mirror: running -------------------------------------------------------------

@test "mirror sends keys from this computer on stdin and skips what is missing or done" {
  ssh_handler '
case "$REMOTE" in
  "fraim-tools list") echo "npm:left-pad@1.3.0" ;;
  "fraim-connect list --json") echo "[{\"name\":\"linear\"}]" ;;
  "fraim-connect list") echo "linear: https://mcp.linear.app/mcp (HTTP) - ✔ Connected" ;;
esac'
  printf 'tool npm:left-pad@1.3.0\nenv META_TOKEN\nenv NOT_SET_HERE\nenv BLANK_HERE\nfile .config/tool/creds.json\nconnect linear https://mcp.linear.app/mcp oauth\n' > "$MIRROR"
  mkdir -p "$HOME/.config/tool"
  printf '{"refresh_token": "rt-SECRET"}\n' > "$HOME/.config/tool/creds.json"
  unset NOT_SET_HERE
  BLANK_HERE='   ' META_TOKEN=meta-SECRET run "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip    tool npm:left-pad@1.3.0 (installed)"* ]]
  [[ "$output" == *"done    env META_TOKEN"* ]]
  [[ "$output" == *"skip    env NOT_SET_HERE (not set on this computer)"* ]]
  [[ "$output" == *"skip    env BLANK_HERE (not set on this computer)"* ]]
  [[ "$output" == *"done    file .config/tool/creds.json"* ]]
  [[ "$output" == *"skip    connect linear https://mcp.linear.app/mcp oauth (signed in)"* ]]
  [[ "$output" == *"2 done, 4 skipped, 0 failed"* ]]
  ! grep -q 'SECRET' "$SSH_LOG"
  grep -q meta-SECRET "$SSH_STDIN_LOG"
  grep -q rt-SECRET "$SSH_STDIN_LOG"
  grep -q 'fraim-env set META_TOKEN' "$SSH_LOG"
  grep -q 'fraim-connect reload' "$SSH_LOG"
  ! grep -q 'npm' "$SSH_LOG"
}

@test "mirror run again with nothing new does not restart the space's Claude" {
  ssh_handler '
case "$REMOTE" in
  *"fraim-env set"*) echo "Unchanged META_TOKEN." ;;
  *"installed_plugins.json"*) echo "acme-config@acme" ;;
esac'
  printf 'env META_TOKEN\nplugin https://github.com/acme/config.git acme-config@acme\n' > "$MIRROR"
  META_TOKEN=meta-SECRET run "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip    env META_TOKEN (unchanged)"* ]]
  [[ "$output" == *"skip    plugin"*"(installed)"* ]]
  ! grep -q 'fraim-connect reload' "$SSH_LOG"
  ! grep -q 'plugin install' "$SSH_LOG"
}

@test "mirror signs in again to an OAuth server that is added but not signed in" {
  ssh_handler '
case "$REMOTE" in
  "fraim-connect list --json") echo "[{\"name\":\"linear\"}]" ;;
  "fraim-connect list") echo "linear: https://mcp.linear.app/mcp (HTTP) - ! Needs authentication" ;;
  *"fraim-connect login linear"*) echo "https://linear.app/oauth?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcb" ;;
esac'
  printf 'connect linear https://mcp.linear.app/mcp oauth\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"waiting connect linear"* ]]
}

@test "mirror counts a step whose key could not be stored as failed, not done" {
  ssh_handler '
case "$REMOTE" in
  "fraim-connect list --json") echo "[]" ;;
  *"fraim-secret set"*) exit 1 ;;
esac'
  printf 'connect ph https://mcp.example.com/mcp key PH_KEY\n' > "$MIRROR"
  PH_KEY=ph-SECRET run "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed  connect ph"* ]]
  ! grep -q 'fraim-connect proxied' "$SSH_LOG"
}

@test "mirror collects human steps with their text, runs the other lines and exits 3" {
  ssh_handler '
case "$REMOTE" in
  "fraim-connect list --json") echo "[]" ;;
  *"fraim-connect login linear"*) echo "https://linear.app/oauth?redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcb" ;;
esac'
  printf 'connect linear https://mcp.linear.app/mcp oauth\nrepo acme/app\ntool npm:left-pad@1.3.0\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"waiting connect linear"* ]]
  [[ "$output" == *"waiting repo acme/app"* ]]
  [[ "$output" == *"done    tool npm:left-pad@1.3.0"* ]]
  [[ "$output" == *"HUMAN STEP:"*"linear"* ]]
  # The repo step names what is missing: a GitHub token.
  [[ "$output" == *"- Space main has no GitHub token yet"* ]]
}

@test "mirror skips a host the space already reaches, so production is not touched again" {
  ssh_handler '
case "$REMOTE" in
  *"fraim-hosts test prod-app"*) exit 0 ;;
esac'
  printf 'host prod-app\n' > "$MIRROR"
  run "$FRAIM" mirror "$MIRROR" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip    host prod-app (reachable)"* ]]
  ! grep -q -- '-G' "$SSH_LOG"
}
