#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2086
# Tests for bin/fraim-desktop. Every test gets a fresh temporary HOME and fake
# fraim, brew and cmux programs, so nothing on this Mac is touched.
# Usage: tests/desktop.sh [test-name ...]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$REPO/bin/fraim-desktop"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fraim-desktop-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

JQ="$(command -v jq)" || { echo "tests need jq"; exit 1; }
PASS=0; FAIL=0
OUT=""; CODE=0

ok()  { PASS=$((PASS + 1)); printf 'PASS %s\n' "$T"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s: %s\n' "$T" "$*"; [ -f "$OUT" ] && sed 's/^/    | /' "$OUT"; }

# fresh: a new HOME with fakes on PATH. Sets HOME, DOCK, CALLS, FAKEBIN.
fresh() {
  local dir="$ROOT/$T"
  mkdir -p "$dir/home/.config/cmux" "$dir/bin" "$dir/app/cmux.app"
  export HOME="$dir/home"
  DOCK="$HOME/.config/cmux/dock.json"
  CALLS="$dir/calls.log"; : > "$CALLS"
  FAKEBIN="$dir/bin"
  ln -s "$JQ" "$FAKEBIN/jq"
  export PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export FRAIM_BIN="$FAKEBIN/fraim"
  export FRAIM_CMUX_APP="$dir/app/cmux.app"
  export FRAIM_CMUX_BIN="$FAKEBIN/cmux"
  export FAKE_BROWSER_URL="http://100.64.0.1:6080/vnc.html"
  cat > "$FAKEBIN/fraim" <<'EOF'
#!/bin/sh
echo "fraim $*" >> "$CALLS"
if [ "$1 $2" = "browser --print-url" ]; then
  [ -n "$FAKE_BROWSER_URL" ] || { echo "no fraim target" >&2; exit 2; }
  echo "$FAKE_BROWSER_URL"
fi
EOF
  chmod +x "$FAKEBIN/fraim"
  export CALLS
}

# run <cmd...>: no terminal, 10 s limit. Sets OUT and CODE (124 = timeout).
run() {
  OUT="$ROOT/$T.out"
  "$@" </dev/null >"$OUT" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 100 ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; CODE=124; return; fi
    sleep 0.1; waited=$((waited + 1))
  done
  wait "$pid"; CODE=$?
}

ids() { jq -r '.controls[].id' "$DOCK" | tr '\n' ' ' | sed 's/ $//'; }

USER_DOCK='{"controls":[{"id":"git","title":"Git","command":"lazygit"}]}'

# --- Task 1: dock and uninstall ---

test_dock_fresh() {
  fresh; run "$DESKTOP" dock
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ "$(ids)" = "fraim-agent fraim-status fraim-browser" ] || { bad "ids: $(ids)"; return; }
  [ "$(jq -r '.controls[2].url' "$DOCK")" = "$FAKE_BROWSER_URL" ] || { bad "browser url"; return; }
  [ "$(jq -r '.controls[2].chrome' "$DOCK")" = false ] || { bad "browser chrome"; return; }
  ok
}

test_dock_merge() {
  fresh; printf '%s\n' "$USER_DOCK" > "$DOCK"; cp "$DOCK" "$ROOT/$T.orig"
  run "$DESKTOP" dock
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ "$(ids)" = "git fraim-agent fraim-status fraim-browser" ] || { bad "ids: $(ids)"; return; }
  [ "$(jq -c '.controls[0]' "$DOCK")" = "$(jq -c '.controls[0]' "$ROOT/$T.orig")" ] || { bad "user control changed"; return; }
  cmp -s "$DOCK.fraim-backup" "$ROOT/$T.orig" || { bad "backup differs from the old file"; return; }
  ok
}

test_dock_idempotent() {
  fresh; printf '%s\n' "$USER_DOCK" > "$DOCK"
  run "$DESKTOP" dock; run "$DESKTOP" dock
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ "$(jq '[.controls[]|select(.id|startswith("fraim-"))]|length' "$DOCK")" = 3 ] || { bad "ids: $(ids)"; return; }
  [ "$(ids)" = "git fraim-agent fraim-status fraim-browser" ] || { bad "ids: $(ids)"; return; }
  ok
}

test_dock_no_target() {
  fresh; export FAKE_BROWSER_URL=""
  run "$DESKTOP" dock
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ "$(ids)" = "fraim-agent fraim-status" ] || { bad "ids: $(ids)"; return; }
  ok
}

test_dock_invalid() {
  fresh; printf '{ // comment\n  "controls": []\n}\n' > "$DOCK"; cp "$DOCK" "$ROOT/$T.orig"
  run "$DESKTOP" dock
  [ "$CODE" = 1 ] || { bad "exit $CODE, wanted 1"; return; }
  grep -q 'dock.json is not plain JSON' "$OUT" || { bad "message missing"; return; }
  cmp -s "$DOCK" "$ROOT/$T.orig" || { bad "file changed"; return; }
  ok
}

test_uninstall_keeps_user() {
  fresh; printf '%s\n' "$USER_DOCK" > "$DOCK"
  run "$DESKTOP" dock; run "$DESKTOP" uninstall
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ "$(ids)" = "git" ] || { bad "ids: $(ids)"; return; }
  ok
}

test_uninstall_removes_ours() {
  fresh; run "$DESKTOP" dock; run "$DESKTOP" uninstall
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ ! -e "$DOCK" ] || { bad "dock.json still exists"; return; }
  ok
}

test_no_secrets() {
  fresh; run "$DESKTOP" dock
  [ -s "$DOCK" ] || { bad "no dock.json"; return; }
  ! grep -qi password "$DOCK" || { bad "dock.json mentions a password"; return; }
  ok
}

test_dock_commands_use_fraim_bin() {
  fresh; run "$DESKTOP" dock
  jq -r '.controls[0].command' "$DOCK" | grep -qF "$FRAIM_BIN" || { bad "agent command does not use FRAIM_BIN"; return; }
  ok
}

# --- Task 2: install ---

fake_brew() {
  cat > "$FAKEBIN/brew" <<'EOF'
#!/bin/sh
echo "$*" >> "$CALLS.brew"
[ "$*" = "install --cask cmux" ] && mkdir -p "$FRAIM_CMUX_APP"
exit 0
EOF
  chmod +x "$FAKEBIN/brew"
}

test_install_present() {
  fresh; fake_brew
  run "$DESKTOP" install
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ ! -e "$CALLS.brew" ] || { bad "brew was called"; return; }
  [ -s "$DOCK" ] || { bad "no dock.json"; return; }
  ok
}

test_install_brew() {
  fresh; fake_brew; rmdir "$FRAIM_CMUX_APP"
  run "$DESKTOP" install
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ "$(cat "$CALLS.brew")" = "install --cask cmux" ] || { bad "brew calls: $(cat "$CALLS.brew" 2>/dev/null)"; return; }
  [ -s "$DOCK" ] || { bad "no dock.json"; return; }
  ok
}

test_install_no_brew() {
  fresh; rmdir "$FRAIM_CMUX_APP"
  run "$DESKTOP" install
  [ "$CODE" = 3 ] || { bad "exit $CODE, wanted 3"; return; }
  [ "$(grep -c '^HUMAN STEP:' "$OUT")" = 1 ] || { bad "wanted one HUMAN STEP line"; return; }
  grep '^HUMAN STEP:' "$OUT" | grep -q 'https://cmux.com' || { bad "no cmux.com link"; return; }
  [ ! -e "$DOCK" ] || { bad "dock.json written"; return; }
  ok
}

test_install_brew_fails() {
  fresh; rmdir "$FRAIM_CMUX_APP"
  printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/brew"; chmod +x "$FAKEBIN/brew"
  run "$DESKTOP" install
  [ "$CODE" = 1 ] || { bad "exit $CODE, wanted 1"; return; }
  [ ! -e "$DOCK" ] || { bad "dock.json written"; return; }
  ok
}

test_install_no_tty() {
  fresh; fake_brew; rmdir "$FRAIM_CMUX_APP"
  run "$DESKTOP" install
  [ "$CODE" != 124 ] || { bad "timed out"; return; }
  ok
}

ALL=$(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//')
[ $# -gt 0 ] || set -- $ALL
for T in "$@"; do "test_$T"; done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
