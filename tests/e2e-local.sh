#!/usr/bin/env bash
# record() always returns 0, so "A && ok || bad" is a safe if/else here.
# shellcheck disable=SC2015,SC2016
# End-to-end test of the agent-facing fraim CLI on a throwaway local stack.
#
# Runs every command the way Claude runs it: no terminal on stdin or stdout, with a time limit.
# A hidden prompt shows up as a timeout, a human-only step as exit 3 plus a "HUMAN STEP:" line.
# Uses its own instance, ports and config dirs (FRAIM_INSTANCE=e2e), so a running local stack is not touched.
# It uses your normal SSH key, like fraim does.
#
# Usage: tests/e2e-local.sh [--keep]     (--keep leaves the stack up for inspection)
# Optional: FRAIM_TEST_TOKEN=<claude setup-token output> also tests login and `fraim ask`.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FRAIM="$REPO/bin/fraim"
CLAUDE="${FRAIM_CLAUDE_BIN:-$(command -v claude)}"
export FRAIM_CLAUDE_BIN="$CLAUDE"
KEEP=0; [ "${1:-}" = --keep ] && KEEP=1

export FRAIM_INSTANCE="${FRAIM_INSTANCE:-e2e}"
export FRAIM_TARGET="$FRAIM_INSTANCE"
PORT_OFFSET="${FRAIM_PORT_OFFSET:-100}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fraim-e2e.XXXXXX")"
export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
export XDG_CONFIG_HOME="$WORK/xdg"
export CLAUDE_CONFIG_DIR="$WORK/claude"
export FRAIM_DIR="$WORK/fraim"
mkdir -p "$XDG_CONFIG_HOME" "$CLAUDE_CONFIG_DIR" "$FRAIM_DIR" "$WORK/out"

PASS=0; FAIL=0; SKIP=0; N=0
RESULTS="$WORK/results.tsv"
OUT=""; CODE=0

# run <seconds> <cmd...>: no TTY, killed after <seconds>. Sets OUT (file) and CODE (124 = timeout).
run() {
  local limit="$1"; shift
  N=$((N + 1)); OUT="$WORK/out/$N.log"
  "$@" </dev/null >"$OUT" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      CODE=124; return
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"; CODE=$?
}

record() { # record <PASS|FAIL|SKIP> <name> <detail>
  case "$1" in PASS) PASS=$((PASS + 1)) ;; FAIL) FAIL=$((FAIL + 1)) ;; SKIP) SKIP=$((SKIP + 1)) ;; esac
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"
  printf '%-4s  %-44s %s\n' "$1" "$2" "$3"
  if [ "$1" = FAIL ] && [ -n "$OUT" ] && [ -f "$OUT" ]; then sed 's/^/        | /' "$OUT" | tail -6; fi
}

# check <name> <expected exit> <seconds> <cmd...> ; then optional assertions on $OUT
check() {
  local name="$1" want="$2" limit="$3"; shift 3
  run "$limit" "$@"
  if [ "$CODE" = 124 ]; then record FAIL "$name" "timed out after ${limit}s (prompt or blocking call?)"; return 1; fi
  if [ "$CODE" != "$want" ]; then record FAIL "$name" "exit $CODE, expected $want"; return 1; fi
  return 0
}
ok() { record PASS "$1" "${2:-}"; }
bad() { record FAIL "$1" "$2"; }
has() { grep -qE "$1" "$OUT"; }

echo "fraim e2e: instance $FRAIM_INSTANCE, work dir $WORK"
echo

# --- 1. Before setup: clear errors, no hangs -------------------------------------
check "help" 0 10 "$FRAIM" help && { has 'Exit codes' && ok "help" || bad "help" "no exit-code contract in help"; }
check "status before setup fails clearly" 2 15 "$FRAIM" status --json || true
[ "$CODE" = 2 ] && ok "status before setup fails clearly"
check "unknown command" 2 10 "$FRAIM" no-such-command && ok "unknown command"
run 20 "$FRAIM" local --help
if docker compose ls --format json 2>/dev/null | jq -e --arg p "fraim$FRAIM_INSTANCE" 'any(.[]; .Name == $p)' >/dev/null; then
  bad "local --help starts nothing" "a stack fraim$FRAIM_INSTANCE was created"
  "$FRAIM" local down --wipe </dev/null >/dev/null 2>&1
elif [ "$CODE" = 0 ] || [ "$CODE" = 2 ]; then ok "local --help starts nothing" "exit $CODE"
else bad "local --help starts nothing" "exit $CODE"; fi

# --- 2. Local up ----------------------------------------------------------------
if check "local up" 0 1200 "$FRAIM" local up --modules browser,scheduler --port-offset "$PORT_OFFSET"; then
  ok "local up" "$(tail -1 "$OUT")"
else
  echo "local up failed; the remaining steps need a stack. Stopping."
  "$FRAIM" local down --wipe </dev/null >/dev/null 2>&1
  exit 1
fi

# --- 3. Status JSON -------------------------------------------------------------
sleep 5
run 60 "$FRAIM" status --json
if [ "$CODE" = 124 ]; then bad "status --json" "timed out"
elif jq -e . "$OUT" >/dev/null 2>&1; then
  ok "status --json is valid JSON" "exit $CODE (non-zero is expected before login)"
  down="$(jq -r '[.services[]? | select(.state != "running" or ((.status // "") | test("unhealthy"))) | .service] | join(",")' "$OUT")"
  [ -z "$down" ] && ok "all services running" "$(jq -r '[.services[].service] | join(",")' "$OUT")" || bad "all services running" "not running: $down"
  unexpected="$(jq -r '[.health.checks[]? | select(.ok == false) | .name
    | select(. != "claude-login" and . != "claude-session-running")] | join(",")' "$OUT")"
  [ -z "$unexpected" ] && ok "health: only login checks fail before login" \
    || bad "health: only login checks fail before login" "also failing: $unexpected"
else
  bad "status --json is valid JSON" "exit $CODE: $(head -c 200 "$OUT")"
fi

# --- 4. Remote exec -------------------------------------------------------------
check "exec whoami" 0 30 "$FRAIM" exec -- whoami && { has '^claude$' && ok "exec whoami" || bad "exec whoami" "got: $(head -1 "$OUT")"; }
check "exec exit code passes through" 7 30 "$FRAIM" exec -- sh -c 'exit 7' && ok "exec exit code passes through"
check "server fraim-config present" 0 30 "$FRAIM" exec -- fraim-config status \
  && { has 'role +server' && has 'linked +fraim-core' && has 'linked +fraim-server' \
       && ok "server fraim-config present" "role server, core + server linked" \
       || bad "server fraim-config present" "$(tr '\n' ' ' < "$OUT" | head -c 200)"; }

check "claude cannot add SSH keys" 0 30 "$FRAIM" exec -- sh -c \
  'test ! -e ~/.ssh/authorized_keys && test ! -w /etc/ssh/authorized_keys/claude && ! touch /etc/ssh/authorized_keys/x 2>/dev/null && ! command -v sudo' \
  && ok "claude cannot add SSH keys" "no home key file, key dir read-only, no sudo"

# --- 5. Login --------------------------------------------------------------------
if [ -z "${FRAIM_TEST_TOKEN:-}" ]; then
  check "ask before login asks the human" 3 60 "$FRAIM" ask "ping" --json \
    && { has '^HUMAN STEP:' && ok "ask before login asks the human" || bad "ask before login asks the human" "exit 3 but no HUMAN STEP line"; }
fi
check "login without token asks the human" 3 15 "$FRAIM" login \
  && { has '^HUMAN STEP:' && ok "login without token asks the human" || bad "login without token asks the human" "exit 3 but no HUMAN STEP line"; }
if [ -n "${FRAIM_TEST_TOKEN:-}" ]; then
  N=$((N + 1)); OUT="$WORK/out/$N.log"
  printf '%s\n' "$FRAIM_TEST_TOKEN" | "$FRAIM" login --token-stdin >"$OUT" 2>&1; CODE=$?
  [ "$CODE" = 0 ] && ok "login --token-stdin" || bad "login --token-stdin" "exit $CODE"
  check "ask" 0 180 "$FRAIM" ask "Reply with the single word: pong" --json \
    && { jq -e . "$OUT" >/dev/null 2>&1 && grep -qi pong "$OUT" && ok "ask" || bad "ask" "no pong in JSON: $(head -c 200 "$OUT")"; }
else
  record SKIP "login --token-stdin + ask" "set FRAIM_TEST_TOKEN to test"
fi

# --- 6. Browser, chrome, logs, restart ------------------------------------------
if check "browser --print-url" 0 15 "$FRAIM" browser --print-url; then
  url="$(grep -oE 'https?://[^ ]+' "$OUT" | head -1)"
  if [ -n "$url" ] && curl -fsS -o /dev/null --max-time 10 "$url"; then ok "browser --print-url" "$url answers"
  else bad "browser --print-url" "url '$url' does not answer"; fi
fi
check "chrome status" 0 15 "$FRAIM" chrome status && ok "chrome status" "$(head -1 "$OUT")"
check "logs (bounded)" 0 30 "$FRAIM" logs workspace && ok "logs (bounded)" "$(wc -l < "$OUT" | tr -d ' ') lines"
check "restart scheduler" 0 90 "$FRAIM" restart scheduler && ok "restart scheduler"
run 15 "$FRAIM" whatsapp status
case "$CODE" in
  2) ok "whatsapp status without module" "exit 2: $(head -1 "$OUT")" ;;
  124) bad "whatsapp status without module" "timed out" ;;
  *) bad "whatsapp status without module" "exit $CODE, expected 2 (module off is missing input, not a human step)" ;;
esac

# --- 7. Claude config ------------------------------------------------------------
check "config init laptop" 0 120 "$FRAIM" config init --role laptop && ok "config init laptop"
check "config mcp add" 0 15 "$FRAIM" config mcp add e2e-test --url https://example.invalid/mcp --header 'Authorization: Bearer ${E2E_KEY}' && ok "config mcp add"
check "config status shows missing key" 0 15 "$FRAIM" config status \
  && { has 'missing +E2E_KEY' && ok "config status shows missing key" || bad "config status shows missing key" "no missing line"; }
check "config skill new" 0 15 "$FRAIM" config skill new e2e-checking && ok "config skill new"
check "config mcp remove" 0 15 "$FRAIM" config mcp remove e2e-test && ok "config mcp remove"
check "config uninstall" 0 15 "$FRAIM" config uninstall \
  && { [ ! -e "$CLAUDE_CONFIG_DIR/skills/fraim-core" ] && [ -d "$FRAIM_DIR/claude" ] \
       && ok "config uninstall" "links gone, files kept" || bad "config uninstall" "links or files wrong"; }

# --- 8. Plugin ------------------------------------------------------------------
check "plugin validate" 0 60 "$CLAUDE" plugin validate "$REPO" && ok "plugin validate"
check "plugin install" 0 120 sh -c "'$CLAUDE' plugin marketplace add '$REPO' && '$CLAUDE' plugin install fraim@fraimwork" && ok "plugin install"
check "plugin skills" 0 60 "$CLAUDE" plugin details fraim@fraimwork \
  && { has 'setting-up-fraim' && has 'operating-fraim' && has 'managing-fraim-config' && ok "plugin skills" "3 skills" || bad "plugin skills" "$(grep Skills "$OUT")"; }

# --- 9. Teardown -----------------------------------------------------------------
if [ "$KEEP" = 1 ]; then
  record SKIP "local down --wipe" "--keep: stack left running"
else
  check "local down --wipe" 0 180 "$FRAIM" local down --wipe && ok "local down --wipe"
  docker compose ls --format json 2>/dev/null | jq -e --arg p "fraim$FRAIM_INSTANCE" 'any(.[]; .Name == $p) | not' >/dev/null \
    && ok "no stack left behind" || bad "no stack left behind" "fraim$FRAIM_INSTANCE still listed"
fi

echo
echo "PASS $PASS  FAIL $FAIL  SKIP $SKIP   (logs: $WORK/out, table: $RESULTS)"
[ "$FAIL" = 0 ]
