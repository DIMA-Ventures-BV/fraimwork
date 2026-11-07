#!/usr/bin/env bats
# Spaces (work, personal, ...): separate fraims on one server, and the commands that give a
# space access to repos, hosts and MCP servers. A fake server sits behind ssh.

load helper

setup() {
  setup_isolated
  use_public_target
}

# A fake server with one space "work" (index 1) next to main. Remote commands are matched
# on their text, like the real ssh would run them.
fake_server_with_work() {
  ssh_handler '
case "$REMOTE" in
  *"ls -1 .env.space-"*) echo work ;;
  *".env.space-work"*"grep -E"*|*"grep -E"*".env.space-work"*)
    printf "SSH_PORT=2223\nVNC_PORT=6081\nPREVIEW_PORTS=3110-3119\nMOSH_PORTS=60020-60030\nSPACE_INDEX=1\nCOMPOSE_PROFILES=browser,scheduler\nBROWSER_IP=172.29.50.10\n" ;;
  *"fraim-doctor --json"*) echo "{\"ok\":true,\"checks\":[]}" ;;
esac'
}

# --- the --space flag --------------------------------------------------------------

@test "--space with an invalid name exits 2" {
  run "$FRAIM" status --space 'Bad Name'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--space must be"* ]]
}

@test "--space for a space that does not exist exits 2 with a next step" {
  run "$FRAIM" status --space nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"no space 'nope'"* ]]
  [[ "$output" == *"fraim space list"* ]]
}

@test "--space routes the workspace to the space's SSH port and compose project" {
  fake_server_with_work
  run "$FRAIM" status --space work --json
  grep -q -- '-p 2223 .*claude@test.invalid' "$SSH_LOG"
  grep -q 'docker compose -p fraimwork-work --env-file .env.space-work ps' "$SSH_LOG"
}

@test "--space after -- belongs to the remote command" {
  fake_server_with_work
  run "$FRAIM" exec --space work -- echo --space main
  [ "$status" -eq 0 ]
  grep -q -- '-p 2223 .*echo --space main' "$SSH_LOG"
}

@test "main space commands keep the plain compose project" {
  run "$FRAIM" restart workspace
  grep -q 'cd /opt/fraimwork && docker compose restart workspace' "$SSH_LOG"
  ! grep -q 'fraimwork-' "$SSH_LOG"
}

# --- space env files -----------------------------------------------------------------

@test "space_env_text gives space n its own ports and subnets" {
  # shellcheck source=/dev/null
  source "$FRAIM"
  set +e
  text="$(printf 'SSH_PORT=2222\nACCESS_MODE=tailscale\nFRAIM_HOSTNAME=fraim-m\nBIND_IP=100.1.2.3\nPRIVATE_BIND_IP=100.1.2.3\nFRAIM_VERSION=v1\n' | space_env_text personal 2 browser,scheduler "")"
  get() { printf '%s\n' "$text" | grep -E "^$1=" | cut -d= -f2-; }
  [ "$(get SSH_PORT)" = 2224 ]
  [ "$(get VNC_PORT)" = 6082 ]
  [ "$(get MOSH_PORTS)" = 60040-60050 ]
  [ "$(get PREVIEW_PORTS)" = 3120-3129 ]
  [ "$(get SYNC_PORT)" = 22002 ]
  [ "$(get FRAIM_SUBNET)" = 172.29.100.0/24 ]
  [ "$(get BROWSER_IP)" = 172.29.100.10 ]
  [ "$(get FRAIM_SUBNET_SECRETS_OUT)" = 172.29.104.0/24 ]
  [ "$(get BIND_IP)" = 100.1.2.3 ]
  [ "$(get BROWSER_VIEW_URL)" = http://fraim-m:6082/vnc.html ]
  [ "$(get SYNC_DEVICE_NAME)" = fraim-m-personal ]
  [ "$(get FRAIM_VERSION)" = v1 ]
  [ "$(get CLAUDEAI_CONNECTORS)" = on ]
  [ "$(get SECRETS_TOKEN | wc -c | tr -d ' ')" = 65 ]
}

@test "space_env_text never reuses the main space's tokens" {
  # shellcheck source=/dev/null
  source "$FRAIM"
  set +e
  a="$(printf 'SECRETS_TOKEN=aaaa\n' | space_env_text work 1 browser "" | grep '^SECRETS_TOKEN=')"
  b="$(printf 'SECRETS_TOKEN=aaaa\n' | space_env_text work 1 browser "" | grep '^SECRETS_TOKEN=')"
  [ "$a" != SECRETS_TOKEN=aaaa ]
  [ "$a" != "$b" ]
}

@test "subnets of every space and local instance stay apart" {
  # shellcheck source=/dev/null
  source "$FRAIM"
  set +e
  all=""
  for k in 0 1 9; do
    for n in 1 2 3 4; do
      all="$all
$(printf 'PORT_OFFSET=%s\n' "$((k * 100))" | space_env_text s "$n" browser "" | grep '^FRAIM_SUBNET' | cut -d= -f2)"
    done
  done
  [ "$(printf '%s\n' "$all" | grep -c .)" = 60 ]
  [ -z "$(printf '%s\n' "$all" | grep . | sort | uniq -d)" ]
}

# --- fraim space ---------------------------------------------------------------------

@test "space add writes the env file over stdin and starts it with install.sh" {
  ssh_handler '
case "$REMOTE" in
  *"ls -1 .env.space-"*) ;;
  *"grep -E"*"FRAIM_HOSTNAME"*) printf "SSH_PORT=2222\nACCESS_MODE=public\nFRAIM_HOSTNAME=fraim\n" ;;
  *"grep -E"*".env.space-work"*) printf "SSH_PORT=2223\n" ;;
esac'
  run "$FRAIM" space add work
  [ "$status" -eq 0 ]
  grep -q '^FRAIM_SPACE=work$' "$SSH_STDIN_LOG"
  grep -q '^SSH_PORT=2223$' "$SSH_STDIN_LOG"
  grep -q 'cat > .env.space-work' "$SSH_LOG"
  grep -q 'install.sh --space work' "$SSH_LOG"
  [[ "$output" == *"Space work is running"* ]]
}

@test "space add refuses main, bad names and unknown modules" {
  run "$FRAIM" space add main
  [ "$status" -eq 2 ]
  run "$FRAIM" space add 'Work!'
  [ "$status" -eq 2 ]
  run "$FRAIM" space add work --modules browser,telepathy
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown module"* ]]
}

@test "space add with whatsapp needs an owner" {
  ssh_handler 'case "$REMOTE" in *"grep -E"*"FRAIM_HOSTNAME"*) echo SSH_PORT=2222 ;; esac'
  run "$FRAIM" space add personal --modules whatsapp
  [ "$status" -eq 2 ]
  [[ "$output" == *"--whatsapp-owner"* ]]
}

@test "space rm --wipe needs --yes and deletes nothing without it" {
  fake_server_with_work
  run "$FRAIM" space rm work --wipe
  [ "$status" -eq 2 ]
  [[ "$output" == *"--yes"* ]]
  ! grep -q 'down -v' "$SSH_LOG"
}

@test "space rm without --wipe stops the space and keeps it stopped through updates" {
  fake_server_with_work
  run "$FRAIM" space rm work
  [ "$status" -eq 0 ]
  grep -q 'k=STOPPED -v v=1' "$SSH_LOG"
  grep -q 'docker compose -p fraimwork-work --env-file .env.space-work down$' "$SSH_LOG"
}

@test "space up clears the stopped mark before starting" {
  fake_server_with_work
  run "$FRAIM" space up work
  grep -q 'k=STOPPED -v v=0' "$SSH_LOG"
  grep -q 'install.sh --space work' "$SSH_LOG"
}

@test "server-wide commands refuse --space" {
  for c in update deploy init lock use; do
    run "$FRAIM" "$c" --space work
    [ "$status" -eq 2 ] || { echo "$c exited $status"; return 1; }
    [[ "$output" == *"whole server"* ]]
  done
}

@test "connect refuses names fraim uses itself" {
  for n in github github-mcp browser whatsapp; do
    run "$FRAIM" connect "$n" --url https://example.com/mcp
    [ "$status" -eq 2 ] || { echo "$n accepted"; return 1; }
  done
}

@test "connect rm keeps a key that the MCP server did not use" {
  ssh_handler '
case "$REMOTE" in
  *"fraim-connect list --json"*) echo "[{\"name\":\"openai\",\"type\":\"http\",\"url\":\"https://api.example.com/mcp\"}]" ;;
  *"fraim-secret list"*) printf "openai\thttps://api.openai.com\tAuthorization\tkey set\n" ;;
esac'
  run "$FRAIM" connect rm openai
  [ "$status" -eq 0 ]
  ! grep -q 'fraim-secret rm' "$SSH_LOG"
}

@test "connect rm deletes the key of a proxied MCP server" {
  ssh_handler '
case "$REMOTE" in
  *"fraim-connect list --json"*) echo "[{\"name\":\"posthog\",\"type\":\"http\",\"url\":\"http://secrets:8080/posthog/mcp\"}]" ;;
  *"fraim-secret list"*) printf "posthog\thttps://mcp-eu.posthog.com\tAuthorization\tkey set\n" ;;
esac'
  run "$FRAIM" connect rm posthog
  [ "$status" -eq 0 ]
  grep -q 'fraim-secret rm posthog' "$SSH_LOG"
}

@test "space policy writes the deny list to the space's env file and restarts it" {
  fake_server_with_work
  run "$FRAIM" space policy work --deny 'claude.ai Gmail,linear' --claudeai off
  grep -qF 'k=MCP_DENY -v v=claude.ai\ Gmail\,linear' "$SSH_LOG"
  grep -q 'k=CLAUDEAI_CONNECTORS -v v=off' "$SSH_LOG"
  grep -q 'umask 077 && t=$(mktemp .fraim-put-env.XXXXXX)' "$SSH_LOG"
  grep -q '.env.space-work > "$t"' "$SSH_LOG"
  grep -q 'install.sh --space work' "$SSH_LOG"
}

@test "space commands take the name as an argument, not --space" {
  run "$FRAIM" space list --space work
  [ "$status" -eq 2 ]
}

@test "space list shows main and every extra space" {
  fake_server_with_work
  run "$FRAIM" space list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'map(.name) | join(",")')" = main,work ]
  [ "$(printf '%s' "$output" | jq -r '.[1].ssh_port')" = 2223 ]
}

# --- keys never pass through arguments ---------------------------------------------------

@test "repo token without a terminal is a human step and stores nothing" {
  run "$FRAIM" repo token --space main
  [ "$status" -eq 3 ]
  [[ "$output" == HUMAN\ STEP:*"fraim repo token"* ]]
  ! grep -q 'fraim-secret set' "$SSH_LOG"
}

@test "repo token from stdin stores git, API and MCP keys through stdin only" {
  run "$FRAIM" repo token --stdin <<<"github_pat_EXAMPLE123"
  [ "$status" -eq 0 ]
  ! grep -q 'github_pat_EXAMPLE123' "$SSH_LOG"
  grep -q 'github_pat_EXAMPLE123' "$SSH_STDIN_LOG"
  grep -q "$(printf 'x-access-token:github_pat_EXAMPLE123' | base64)" "$SSH_STDIN_LOG"
  grep -q "fraim-secret add github --upstream https://github.com --header Authorization --format Basic\\\\ %s" "$SSH_LOG"
}

@test "repo token rejects something that is not a GitHub token" {
  run "$FRAIM" repo token --stdin <<<"hunter2"
  [ "$status" -eq 2 ]
  ! grep -q 'fraim-secret set' "$SSH_LOG"
}

@test "connect --key without a terminal is a human step naming the same command" {
  run "$FRAIM" connect posthog --url https://mcp-eu.posthog.com/mcp --key --space main
  [ "$status" -eq 3 ]
  [[ "$output" == *"fraim connect posthog --url https://mcp-eu.posthog.com/mcp --key"* ]]
}

@test "connect --key with stdin keeps the key out of every argument" {
  ssh_handler 'case "$REMOTE" in *"fraim-secret list"*) printf "posthog\thttps://mcp-eu.posthog.com\tAuthorization\tkey set\n" ;; esac'
  run "$FRAIM" connect posthog --url https://mcp-eu.posthog.com/mcp --key --stdin <<<"phx_SECRET"
  [ "$status" -eq 0 ]
  ! grep -q phx_SECRET "$SSH_LOG"
  grep -q phx_SECRET "$SSH_STDIN_LOG"
  grep -q 'fraim-connect proxied posthog /mcp' "$SSH_LOG"
}

@test "connect rejects a non-https URL and odd names" {
  run "$FRAIM" connect posthog --url http://example.com/mcp
  [ "$status" -eq 2 ]
  run "$FRAIM" connect 'Bad;name' --url https://example.com/mcp
  [ "$status" -eq 2 ]
}

@test "connect --oauth hands the human the sign-in link" {
  ssh_handler 'case "$REMOTE" in *"fraim-connect login"*) echo "https://sentry.example/authorize?x=1" ;; esac'
  run "$FRAIM" connect sentry --url https://mcp.sentry.dev/mcp --oauth
  [ "$status" -eq 3 ]
  [[ "$output" == *"https://sentry.example/authorize?x=1"* ]]
  [[ "$output" == *"fraim connect sentry --redirect"* ]]
}

@test "login --full hands the human the sign-in link and the code command for the space" {
  ssh_handler '
case "$REMOTE" in
  *"test -s ~/.claude/.credentials.json"*) exit 1 ;;
  *"fraim-tty start login"*) echo "https://claude.ai/oauth/authorize?code=true" ;;
  *"grep -E"*".env.space-work"*) printf "SSH_PORT=2223\n" ;;
esac'
  run "$FRAIM" login --full --space work
  [ "$status" -eq 3 ]
  [[ "$output" == *"https://claude.ai/oauth/authorize?code=true"* ]]
  [[ "$output" == *"fraim login --code --space work"* ]]
}

# --- hosts ------------------------------------------------------------------------------

@test "host add with --authorize-via installs a restricted key line on the host" {
  ssh_handler '
case "$REMOTE" in
  *"fraim-hosts add devbox"*) echo "ssh-ed25519 AAAAC3Nza fraim-main-devbox" ;;
  *"fraim-hosts test devbox"*) exit 0 ;;
esac'
  run "$FRAIM" host add devbox --address 198.51.100.4 --user dev --authorize-via devbox-laptop-alias
  [ "$status" -eq 0 ]
  grep -q 'devbox-laptop-alias' "$SSH_LOG"
  grep -qF 'devbox-laptop-alias k=no-agent-forwarding\,no-X11-forwarding\ ssh-ed25519' "$SSH_LOG"
  [[ "$output" == *"reaches devbox"* ]]
}

@test "host add without --authorize-via asks the human to add the key line" {
  ssh_handler '
case "$REMOTE" in
  *"fraim-hosts add devbox"*) echo "ssh-ed25519 AAAAC3Nza fraim-main-devbox" ;;
  *"fraim-hosts test devbox"*) exit 1 ;;
esac'
  run "$FRAIM" host add devbox --address 198.51.100.4 --user dev
  [ "$status" -eq 3 ]
  [[ "$output" == *"no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3Nza"* ]]
}

@test "help lists the space commands" {
  run "$FRAIM" help
  for c in space repo host connect preview; do
    [[ "$output" == *"fraim $c"* ]] || { echo "help misses: $c"; return 1; }
  done
  [[ "$output" == *"--space NAME"* ]]
}

# --- reaching a space before the tailnet policy allows its port --------------------------

@test "use_space_jump goes through the admin login to the space's Tailscale address" {
  # shellcheck source=/dev/null
  source "$FRAIM"
  set +e
  FRAIM_ACCESS=tailscale FRAIM_SPACE=work FRAIM_TARGET=default FRAIM_ADMIN=root@fraim-test
  FRAIM_HOST=fraim-test FRAIM_SSH_PORT=2223 FRAIM_SSH_KEY="" KNOWN_HOSTS="$HOME/kh"
  port_open() { return 1; }
  space_get() { echo 100.64.0.9; }
  use_space_jump
  [ -n "$SPACE_JUMP_CONFIG" ]
  grep -q 'ProxyCommand ssh .*-W 100.64.0.9:%p root@fraim-test' "$SPACE_JUMP_CONFIG"
  [[ "$(ssh_opts)" == *"-F $SPACE_JUMP_CONFIG"* ]]
}

@test "use_space_jump stays direct when the space port answers, and for main" {
  # shellcheck source=/dev/null
  source "$FRAIM"
  set +e
  FRAIM_ACCESS=tailscale FRAIM_SPACE=work FRAIM_SSH_PORT=2223 FRAIM_HOST=fraim-test SPACE_JUMP_CONFIG=""
  port_open() { return 0; }
  use_space_jump
  [ -z "$SPACE_JUMP_CONFIG" ]
  FRAIM_SPACE=main
  port_open() { return 1; }
  use_space_jump
  [ -z "$SPACE_JUMP_CONFIG" ]
}

@test "login --from-space copies the token container to container on the server" {
  ssh_handler 'case "$REMOTE" in *"grep -E"*".env.space-personal"*) printf "SSH_PORT=2224\n" ;; esac'
  run "$FRAIM" login --space personal --from-space main
  [ "$status" -eq 0 ]
  grep -qF "exec -T -u claude workspace sh -c 'test -s ~/.config/fraim/claude-token && cat ~/.config/fraim/claude-token' | docker compose -p fraimwork-personal --env-file .env.space-personal exec -T -u claude workspace" "$SSH_LOG"
  ! grep -q 'sk-ant' "$SSH_LOG"
}

@test "login --from-space refuses the same space" {
  run "$FRAIM" login --from-space main
  [ "$status" -eq 2 ]
}
