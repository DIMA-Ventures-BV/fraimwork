#!/usr/bin/env bash
# End-to-end test of spaces on a throwaway local stack: a main space and a "work" space,
# their separation (files, secrets tokens, networks), the per-space MCP policy, previews,
# MCP servers, hosts, the GitHub setup and the full-login sign-in link.
#
# Runs fraim the way Claude does: no terminal. Uses its own instance (FRAIM_INSTANCE=spaces)
# and config dirs, so a running local stack is not touched.
#
# Usage: tests/e2e-spaces.sh [--keep]     (--keep leaves the stacks up for inspection)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FRAIM="$REPO/bin/fraim"
KEEP=0; [ "${1:-}" = --keep ] && KEEP=1

export FRAIM_INSTANCE="${FRAIM_INSTANCE:-spaces}"
export FRAIM_TARGET="$FRAIM_INSTANCE"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fraim-spaces.XXXXXX")"
export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
export XDG_CONFIG_HOME="$WORK/xdg"
mkdir -p "$XDG_CONFIG_HOME"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | tail -8 | sed 's/^/      | /'; }
# fx ARGS...: fraim without a terminal; output in $OUT, exit code in $CODE.
fx() { OUT="$("$FRAIM" "$@" </dev/null 2>&1)"; CODE=$?; }
# in_space SPACE CMD: a shell command inside that space's workspace, as user claude.
in_space() { "$FRAIM" exec --space "$1" -- bash -c "$2" </dev/null 2>&1; }

cleanup() {
  if [ "$KEEP" = 1 ]; then
    echo "Kept: FRAIM_INSTANCE=$FRAIM_INSTANCE XDG_CONFIG_HOME=$XDG_CONFIG_HOME $FRAIM local down --wipe"
    return
  fi
  "$FRAIM" local down --wipe </dev/null >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== starting main space (instance $FRAIM_INSTANCE)"
fx local up --modules browser,scheduler
[ "$CODE" = 0 ] && ok "local up" || { bad "local up" "$OUT"; exit 1; }

echo "== adding space work"
fx space add work --modules scheduler
[ "$CODE" = 0 ] && ok "space add work" || { bad "space add work" "$OUT"; exit 1; }
fx space add work
[ "$CODE" = 0 ] && [[ "$OUT" == *"already exists"* ]] && ok "space add is safe to run again" || bad "space add twice" "$OUT"

fx space list --json
names="$(printf '%s' "$OUT" | jq -r 'map(.name) | join(",")' 2>/dev/null)"
ports="$(printf '%s' "$OUT" | jq -r 'map(.ssh_port) | unique | length' 2>/dev/null)"
[ "$names" = main,work ] && [ "$ports" = 2 ] && ok "space list: main and work on their own ports" || bad "space list" "$OUT"

echo "== separation"
[ "$(in_space work '. /etc/fraim/runtime.env; echo $FRAIM_SPACE')" = work ] && ok "work workspace knows its space" || bad "FRAIM_SPACE in work"
t_main="$(in_space main '. /etc/fraim/runtime.env; echo $FRAIM_SECRETS_TOKEN')"
t_work="$(in_space work '. /etc/fraim/runtime.env; echo $FRAIM_SECRETS_TOKEN')"
[ -n "$t_main" ] && [ -n "$t_work" ] && [ "$t_main" != "$t_work" ] && ok "each space has its own secrets token" || bad "secrets tokens" "main=$t_main work=$t_work"

in_space main 'echo private > ~/fraim/main-only.txt' >/dev/null
[ "$(in_space work 'test -e ~/fraim/main-only.txt && echo seen || echo absent')" = absent ] && ok "files of main are not in work" || bad "file separation"

main_secrets_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "fraim$FRAIM_INSTANCE-secrets-1" 2>/dev/null | awk '{print $1}')"
reach="$(in_space work "curl -s -o /dev/null -m 5 -w '%{http_code}' http://$main_secrets_ip:8080/healthz || echo unreachable")"
[ -n "$main_secrets_ip" ] && [[ "$reach" == *unreachable* || "$reach" == 000* ]] && ok "work cannot reach main's secrets proxy ($main_secrets_ip)" || bad "secrets proxy isolation" "ip=$main_secrets_ip answer=$reach"
own="$(in_space work "curl -s -m 5 http://secrets:8080/healthz")"
[ "$own" = ok ] && ok "work reaches its own secrets proxy" || bad "own secrets proxy" "$own"

echo "== MCP policy per space"
fx space policy work --deny 'claude.ai Gmail' --claudeai off
policy="$(in_space work 'cat /etc/claude-code/managed-settings.d/50-fraim-space.json')"
[ "$CODE" = 0 ] && printf '%s' "$policy" | jq -e '.disableClaudeAiConnectors == true and .deniedMcpServers == [{serverName: "claude.ai Gmail"}]' >/dev/null \
  && ok "space policy lands as a root-owned managed settings drop-in" || bad "space policy" "$OUT
$policy"
[ "$(in_space work 'stat -c %U /etc/claude-code/managed-settings.d/50-fraim-space.json')" = root ] && ok "the policy file is owned by root" || bad "policy owner"
mainpolicy="$(in_space main 'cat /etc/claude-code/managed-settings.d/50-fraim-space.json')"
printf '%s' "$mainpolicy" | jq -e '.deniedMcpServers == [] and (has("disableClaudeAiConnectors") | not)' >/dev/null \
  && ok "main space keeps its own (open) policy" || bad "main policy" "$mainpolicy"

echo "== preview"
# docker exec -d: a background server started over ssh keeps the ssh session open.
in_space work 'mkdir -p /tmp/site && echo preview-ok > /tmp/site/index.html' >/dev/null
docker exec -d -u claude -w /tmp/site "fraim$FRAIM_INSTANCE-work-workspace-1" python3 -m http.server 8123 --bind 127.0.0.1
sleep 2
fx preview 8123 --space work
url="$(printf '%s' "$OUT" | awk -F'\t' '/^8123/ {print $2}')"
body="$(curl -s -m 5 "$url" 2>/dev/null)"
[ "$body" = preview-ok ] && ok "preview of a 127.0.0.1 dev server opens at $url" || bad "preview" "$OUT
url=$url body=$body"
fx preview stop all --space work

echo "== MCP servers and keys"
fx connect ctx --url https://mcp.context7.com/mcp --space work
fx connect list --json --space work
printf '%s' "$OUT" | jq -e 'map(select(.name == "ctx" and .url == "https://mcp.context7.com/mcp")) | length == 1' >/dev/null \
  && ok "connect adds an MCP server to the space" || bad "connect http" "$OUT"
fx connect list --json
printf '%s' "$OUT" | jq -e 'map(select(.name == "ctx")) | length == 0' >/dev/null && ok "the MCP server is not in main" || bad "connect leaked to main" "$OUT"
OUT="$(printf 'test-key-123' | "$FRAIM" connect demo --url https://example.com/mcp --key --stdin --space work 2>&1)"; CODE=$?
fx connect list --json --space work
printf '%s' "$OUT" | jq -e 'map(select(.name == "demo" and .url == "http://secrets:8080/demo/mcp")) | length == 1' >/dev/null \
  && ok "a key MCP server goes through the secrets proxy" || bad "connect --key" "$OUT"
cfg="$(in_space work 'cat ~/.claude.json')"
[[ "$cfg" != *test-key-123* ]] && ok "the real key is not in the space's Claude config" || bad "key leaked into ~/.claude.json"
fx connect rm demo --space work
fx secret list --space work
[[ "$OUT" != *demo* ]] && ok "connect rm removes the server and its key" || bad "connect rm" "$OUT"

fx space policy work --deny 'claude.ai Gmail,ctx'
listing="$(in_space work 'claude mcp list')"
[[ "$listing" != *"ctx:"* ]] && ok "Claude Code hides an MCP server the space policy denies" || bad "policy not enforced" "$listing"
fx space policy work --deny 'claude.ai Gmail'

echo "== hosts"
pub="$(in_space work 'fraim-hosts add devbox --address 192.0.2.10 --user dev')"
list="$(in_space work 'fraim-hosts list --json')"
[[ "$pub" == ssh-ed25519* ]] && printf '%s' "$list" | jq -e '.[0] == {name: "devbox", address: "192.0.2.10", user: "dev", port: 22}' >/dev/null \
  && ok "a host gets its own key and ssh alias" || bad "hosts" "$pub
$list"
[ "$(in_space main 'test -e ~/.ssh/fraim-hosts/devbox && echo seen || echo absent')" = absent ] && ok "the host key is not in main" || bad "host key leaked"

echo "== GitHub through the proxy"
OUT="$(printf 'github_pat_FAKE000' | "$FRAIM" repo token --stdin --space work 2>&1)"; CODE=$?
gitcfg="$(in_space work 'git config --global --list')"
[ "$CODE" = 0 ] && [[ "$gitcfg" == *"url.http://secrets:8080/github/.insteadof=https://github.com/"* ]] && [[ "$gitcfg" != *github_pat_FAKE000* ]] \
  && ok "repo token: git goes through the proxy and never holds the token" || bad "repo token" "$OUT
$gitcfg"
fx connect list --json --space work
printf '%s' "$OUT" | jq -e 'map(select(.name == "github-mcp")) | length == 1' >/dev/null && ok "repo token adds the GitHub MCP server" || bad "github-mcp" "$OUT"

echo "== full login link"
fx login --full --space work
[ "$CODE" = 3 ] && [[ "$OUT" == *"https://"* ]] && [[ "$OUT" == *"fraim login --code --space work"* ]] \
  && ok "login --full hands out a sign-in link" || bad "login --full" "$OUT"
in_space work 'fraim-tty stop login' >/dev/null

echo "== stopping and removing"
fx space rm work
[ "$CODE" = 0 ] && [ -z "$(docker ps -q --filter "label=com.docker.compose.project=fraim$FRAIM_INSTANCE-work")" ] && ok "space rm stops the space" || bad "space rm" "$OUT"
fx space up work
[ "$CODE" = 0 ] && [ "$(in_space work 'test -e ~/.ssh/fraim-hosts/devbox && echo kept')" = kept ] && ok "space up brings it back with its data" || bad "space up" "$OUT"
fx space rm work --wipe
[ "$CODE" = 2 ] && ok "wipe without --yes is refused" || bad "wipe without --yes" "$OUT"
fx space rm work --wipe --yes
[ "$CODE" = 0 ] && [ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=fraim$FRAIM_INSTANCE-work")" ] && ok "wipe removes the space and its volumes" || bad "wipe" "$OUT"

echo
echo "spaces e2e: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
