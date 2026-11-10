#!/usr/bin/env bash
# Tests the secrets proxy in Docker: the real key reaches the API, Claude's side only ever has
# the session token, the browser network cannot reach the proxy, and no command prints a key.
# Needs Docker. Uses its own compose project and subnets, and removes everything afterwards.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

P=fraimsecretstest
export BIND_IP=127.0.0.1 PRIVATE_BIND_IP=127.0.0.1 COMPOSE_PROFILES="" FRAIM_IMAGE_TAG=secretstest
export FRAIM_SUBNET=172.30.250.0/24 FRAIM_SUBNET_WA=172.31.250.0/24 FRAIM_SUBNET_SYNC=172.31.251.0/24
export FRAIM_SUBNET_SECRETS=172.31.252.0/24 FRAIM_SUBNET_SECRETS_OUT=172.31.253.0/24
SECRETS_TOKEN="$(openssl rand -hex 32)"
export SECRETS_TOKEN
KEY="sk-real-$(openssl rand -hex 12)"
KEY2="xk-real-$(openssl rand -hex 12)"

dc() { docker compose -p "$P" -f compose.yaml -f tests/secrets.compose.yaml "$@"; }
cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1
  docker image rm "fraimwork/secrets:$FRAIM_IMAGE_TAG" >/dev/null 2>&1
}
trap cleanup EXIT

fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '      %s\n' "$2"; fail=1; }
# req CONTAINER PATH [HEADER]: body on success, "ERR <wget error>" on failure.
req() {
  local c="$1" path="$2" header="${3:-}"
  if [ -n "$header" ]; then
    dc exec -T "$c" wget -q -T 5 -O - --header "$header" "http://secrets:8080$path" 2>&1 || true
  else
    dc exec -T "$c" wget -q -T 5 -O - "http://secrets:8080$path" 2>&1 || true
  fi
}

echo "== starting the proxy and test containers"
dc up -d --build secrets echo client outsider >/dev/null 2>&1 || { dc up -d --build secrets echo client outsider; exit 1; }
for _ in $(seq 30); do
  dc exec -T secrets wget -q -O /dev/null http://127.0.0.1:8080/healthz 2>/dev/null && break
  sleep 1
done

dc exec -T secrets fraim-secret add echo --upstream http://echo:80 >/dev/null
printf '%s' "$KEY" | dc exec -T secrets fraim-secret set echo >/dev/null
dc exec -T secrets fraim-secret add echo2 --upstream http://echo:80 --header x-api-key --format '%s' >/dev/null
printf '%s\n' "$KEY2" | dc exec -T secrets fraim-secret set echo2 >/dev/null

out="$(req client /echo/v1/things "Authorization: Bearer $SECRETS_TOKEN")"
if [[ "$out" == *"auth=[Bearer $KEY]"* && "$out" == *"path=[/v1/things]"* && "$out" == *"host=[echo]"* ]]; then
  ok "session token in, real key out (Bearer), path and host rewritten"
else bad "real key injected" "$out"; fi

out="$(req client /echo2/x "x-api-key: $SECRETS_TOKEN")"
if [[ "$out" == *"key=[$KEY2]"* ]]; then ok "custom header and format (x-api-key)"; else bad "x-api-key injection" "$out"; fi

out="$(req client /echo/x "Authorization: Bearer wrong-$SECRETS_TOKEN")"
[[ "$out" == ERR* || "$out" == *401* ]] && [[ "$out" != *"$KEY"* ]] && ok "wrong token refused" || bad "wrong token refused" "$out"

out="$(req client /echo/x)"
[[ "$out" == *401* ]] && [[ "$out" != *"$KEY"* ]] && ok "no token refused" || bad "no token refused" "$out"

out="$(req client /echo/x "Authorization: $SECRETS_TOKEN")"
[[ "$out" == *401* ]] && ok "token in the wrong format refused" || bad "token in the wrong format refused" "$out"

out="$(req client /nosuch/x "Authorization: Bearer $SECRETS_TOKEN")"
[[ "$out" == *401* ]] && ok "unknown service refused" || bad "unknown service refused" "$out"

out="$(req outsider /healthz)"
[[ "$out" != "ok" ]] && ok "browser network cannot reach the proxy" || bad "browser network cannot reach the proxy" "$out"

if dc exec -T client wget -q -T 5 -O /dev/null http://1.1.1.1 >/dev/null 2>&1; then
  bad "the secrets network has no internet (it is internal)"
else ok "the secrets network has no internet (it is internal)"; fi

out="$(dc exec -T secrets fraim-secret list 2>&1)"
[[ "$out" == *echo* && "$out" != *"$KEY"* && "$out" != *"$KEY2"* ]] && ok "list shows names, never a key" || bad "list never shows a key" "$out"

out="$(req client /_services)"
[[ "$out" == *"echo2 x-api-key %s http://echo:80"* && "$out" != *"$KEY"* && "$out" != *"$KEY2"* ]] \
  && ok "/_services lists services, never a key" || bad "/_services lists services, never a key" "$out"

out="$(dc exec -T client sh -c "env; cat /proc/*/environ 2>/dev/null | tr '\\0' '\\n'" 2>&1)"
[[ "$out" != *"$KEY"* ]] && ok "the client side holds no real key" || bad "the client side holds no real key"

if dc exec -T -e SECRETS_ALLOW_HTTP=0 secrets fraim-secret add evil --upstream http://evil.example >/dev/null 2>&1; then
  bad "plain http upstream refused outside tests"
else ok "plain http upstream refused outside tests"; fi

if printf 'a b{c}' | dc exec -T secrets fraim-secret set echo >/dev/null 2>&1; then
  bad "a key with spaces or braces refused"
else ok "a key with spaces or braces refused"; fi

# The gate for invited laptops, through the real workspace client script.
GATE_TOKEN="$(openssl rand -hex 32)"
GATE_KEY="gk-real-$(openssl rand -hex 12)"
docker pull -q bash:5.2 >/dev/null
gate() { docker run --rm -i --network "${P}_secrets" -v "$PWD/workspace/bin/fraim-gate:/fraim-gate:ro" bash:5.2 bash /fraim-gate 2>&1; }
tab="$(printf '\t')"

out="$(printf '%s\nhas%secho\n' "$GATE_TOKEN" "$tab" | gate)"
[[ "$out" == "error refused" ]] && ok "gate: refused while no laptop was invited" || bad "gate: refused while no laptop was invited" "$out"

printf '%s' "$GATE_TOKEN" | sha256sum | cut -d' ' -f1 | dc exec -T secrets fraim-secret gate-add alice >/dev/null

out="$(printf '%s\nhas%secho\n' "$SECRETS_TOKEN" "$tab" | gate)"
[[ "$out" == "error refused" ]] && ok "gate: Claude's session token does not open it" || bad "gate: Claude's session token does not open it" "$out"

out="$(printf '%s\nhas%secho\n' "$GATE_TOKEN" "$tab" | gate)"
[[ "$out" == "ok yes" ]] && ok "gate: a laptop can see that a key exists" || bad "gate: a laptop can see that a key exists" "$out"

out="$(printf '%s\nadd%sgated%shttp://echo:80%sAuthorization%sBearer %%s\n' "$GATE_TOKEN" "$tab" "$tab" "$tab" "$tab" | gate)"
[[ "$out" == ok* ]] && ok "gate: a laptop can add a service" || bad "gate: a laptop can add a service" "$out"

out="$(printf '%s\nset%sgated\n%s\n' "$GATE_TOKEN" "$tab" "$GATE_KEY" | gate)"
[[ "$out" == ok* && "$out" != *"$GATE_KEY"* ]] && ok "gate: a laptop can store a key and gets no key back" || bad "gate: a laptop can store a key and gets no key back" "$out"

for _ in 1 2 3 4 5; do
  out="$(req client /gated/x "Authorization: Bearer $SECRETS_TOKEN")"
  [[ "$out" == *"$GATE_KEY"* ]] && break
  sleep 1
done
[[ "$out" == *"auth=[Bearer $GATE_KEY]"* ]] && ok "gate: the stored key reaches the API" || bad "gate: the stored key reaches the API" "$out"

out="$(printf '%s\nget%sgated\n' "$GATE_TOKEN" "$tab" | gate)"
[[ "$out" == "error usage" ]] && ok "gate: no command reads a key" || bad "gate: no command reads a key" "$out"

out="$(printf '%s\nset%sgated%sextra\n' "$GATE_TOKEN" "$tab" "$tab" | gate)"
[[ "$out" == "error usage" ]] && ok "gate: a malformed request is refused" || bad "gate: a malformed request is refused" "$out"

out="$(printf '%s\nadd%sevil%shttp://evil.example%sAuthorization%s$(touch /tmp/pwned)%%s\n' "$GATE_TOKEN" "$tab" "$tab" "$tab" "$tab" | gate)"
[[ "$out" == error* ]] && ! dc exec -T secrets test -e /tmp/pwned && ok "gate: shell text in a field does nothing" || bad "gate: shell text in a field does nothing" "$out"

dc exec -T secrets fraim-secret gate-rm alice >/dev/null
out="$(printf '%s\nhas%secho\n' "$GATE_TOKEN" "$tab" | gate)"
[[ "$out" == "error refused" ]] && ok "gate: a revoked laptop is refused" || bad "gate: a revoked laptop is refused" "$out"

dc exec -T secrets fraim-secret rm echo >/dev/null
out="$(req client /echo/x "Authorization: Bearer $SECRETS_TOKEN")"
[[ "$out" == *401* ]] && ok "removed service stops working" || bad "removed service stops working" "$out"

dc exec -T -e SECRETS_TOKEN= secrets fraim-secret render >/dev/null
out="$(req client /echo2/x "x-api-key: $SECRETS_TOKEN")"
[[ "$out" == *503* ]] && ok "no session token: everything refused (fail closed)" || bad "fail closed without a session token" "$out"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
