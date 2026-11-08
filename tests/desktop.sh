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

# macOS ships bash 3.2; test against it. FRAIM_TEST_BASH=... picks another bash.
TEST_BASH="${FRAIM_TEST_BASH:-/bin/bash}"
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
case "$1 $2" in
  "browser --url-only")
    [ -n "$FAKE_BROWSER_URL" ] || { echo "no fraim target" >&2; exit 2; }
    echo "$FAKE_BROWSER_URL" ;;
  "browser --print-url")
    echo "$FAKE_BROWSER_URL"; echo "vnc-password-s3cret" ;;
esac
EOF
  chmod +x "$FAKEBIN/fraim"
  export CALLS
}

# run <cmd...>: no terminal, 10 s limit. Sets OUT and CODE (124 = timeout).
run() {
  OUT="$ROOT/$T.out"
  [ "$1" = "$DESKTOP" ] && set -- "$TEST_BASH" "$@"
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
  ! grep -q s3cret "$DOCK" || { bad "dock.json holds the VNC password"; return; }
  ok
}

test_dock_no_tunnel() {
  fresh; run "$DESKTOP" dock
  grep -q 'browser --url-only' "$CALLS" || { bad "did not ask for the URL"; return; }
  ! grep -q 'browser --print-url' "$CALLS" || { bad "opened a tunnel and fetched the password"; return; }
  ok
}

test_dock_quote_apostrophe() {
  fresh
  local odd="$ROOT/$T/Michael's code/fraim bin"
  mkdir -p "$odd"; cp "$FAKEBIN/fraim" "$odd/fraim"; export FRAIM_BIN="$odd/fraim"
  run "$DESKTOP" dock
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  : > "$CALLS"
  "$TEST_BASH" -c "$(jq -r '.controls[0].command' "$DOCK")" </dev/null >/dev/null 2>&1
  grep -qx 'fraim shell' "$CALLS" || { bad "agent command did not run: $(jq -r '.controls[0].command' "$DOCK")"; return; }
  ok
}

test_dock_symlink_kept() {
  fresh
  mkdir -p "$HOME/dotfiles"; printf '%s\n' "$USER_DOCK" > "$HOME/dotfiles/dock.json"
  ln -s "$HOME/dotfiles/dock.json" "$DOCK"
  run "$DESKTOP" dock
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  [ -L "$DOCK" ] || { bad "dock.json is no longer a symlink"; return; }
  [ "$(jq -r '.controls|length' "$HOME/dotfiles/dock.json")" = 4 ] || { bad "link target not updated"; return; }
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

# --- Task 3: open ---

# fake_cmux: logs every call. Running when $STATE/running exists; with
# FAKE_CMUX_DENY=1 it runs but refuses callers from outside cmux.
fake_cmux() {
  STATE="$ROOT/$T.state"; mkdir -p "$STATE"; export STATE
  export FAKE_WS='{"workspaces":[{"ref":"workspace:1","title":"notes","custom_title":null}]}'
  export FRAIM_CMUX_WAIT=2
  cat > "$FAKEBIN/cmux" <<'EOF'
#!/bin/sh
echo "cmux $*" >> "$CALLS"
case "$1" in
  ping)
    [ -e "$STATE/running" ] || { echo "Error: cmux is not running" >&2; exit 1; }
    [ -z "$FAKE_CMUX_DENY" ] || { echo "Error: ERROR: Access denied - only processes started inside cmux can connect" >&2; exit 1; }
    echo PONG ;;
  workspace) [ "$2" = list ] && printf '%s\n' "$FAKE_WS" ;;
esac
exit 0
EOF
  cat > "$FAKEBIN/open" <<'EOF'
#!/bin/sh
echo "open $*" >> "$CALLS"
[ -n "$FAKE_OPEN_FAILS" ] && exit 1
touch "$STATE/running"
exit 0
EOF
  chmod +x "$FAKEBIN/cmux" "$FAKEBIN/open"
}

test_open_running() {
  fresh; fake_cmux; touch "$STATE/running"
  run "$DESKTOP" open
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  grep -qF "cmux new-workspace --name fraim --cwd $HOME/fraim --command '$FRAIM_BIN' shell" "$CALLS" || { bad "no new-workspace call"; cat "$CALLS"; return; }
  [ -d "$HOME/fraim" ] || { bad "no ~/fraim folder"; return; }
  ! grep -q '^open ' "$CALLS" || { bad "launched cmux while it ran"; return; }
  ok
}

test_open_not_running() {
  fresh; fake_cmux
  run "$DESKTOP" open
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  grep -qxF "open -a $FRAIM_CMUX_APP $HOME/fraim" "$CALLS" || { bad "cmux not opened on ~/fraim"; cat "$CALLS"; return; }
  ! grep -q new-workspace "$CALLS" || { bad "new-workspace called"; return; }
  ok
}

test_open_outside_cmux() {
  fresh; fake_cmux; touch "$STATE/running"; export FAKE_CMUX_DENY=1
  run "$DESKTOP" open
  unset FAKE_CMUX_DENY
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  grep -qxF "open -a $FRAIM_CMUX_APP $HOME/fraim" "$CALLS" || { bad "cmux not opened on ~/fraim"; cat "$CALLS"; return; }
  ! grep -q new-workspace "$CALLS" || { bad "new-workspace called"; return; }
  ok
}

test_open_launch_fails() {
  fresh; fake_cmux; export FAKE_OPEN_FAILS=1
  run "$DESKTOP" open
  unset FAKE_OPEN_FAILS
  [ "$CODE" = 1 ] || { bad "exit $CODE, wanted 1"; return; }
  ok
}

test_open_existing() {
  fresh; fake_cmux; touch "$STATE/running"
  export FAKE_WS='{"workspaces":[{"ref":"workspace:7","title":"fraim","custom_title":"fraim"}]}'
  run "$DESKTOP" open
  [ "$CODE" = 0 ] || { bad "exit $CODE"; return; }
  ! grep -q new-workspace "$CALLS" || { bad "new-workspace called"; return; }
  grep -qF "cmux select-workspace --workspace workspace:7" "$CALLS" || { bad "no select-workspace"; cat "$CALLS"; return; }
  ok
}

ALL=$(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//')
[ $# -gt 0 ] || set -- $ALL
for T in "$@"; do "test_$T"; done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
