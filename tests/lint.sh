#!/usr/bin/env bash
# Static checks for the whole repo. Fast, no Docker daemon, no network.
# A missing optional tool (hadolint, actionlint, claude) is a skip locally and a failure in CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FAIL=0
step() { printf '\n== %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
skip() {
  if [ -n "${CI:-}" ]; then fail "$1 is not installed"; else printf 'skip: %s is not installed\n' "$1"; fi
}

# Every tracked or new file, without ignored ones (node_modules, .env).
files() { git ls-files --cached --others --exclude-standard "$@"; }

shell_scripts() {
  files | while read -r f; do
    [ -f "$f" ] || continue
    case "$f" in *.sh|*.bash|*.bats) printf '%s\n' "$f"; continue ;; esac
    if head -1 "$f" | grep -qE '^#!.*\b(ba)?sh\b'; then printf '%s\n' "$f"; fi
  done
}

step "shellcheck (warnings and errors)"
if command -v shellcheck >/dev/null; then
  n=0
  while read -r f; do
    n=$((n + 1))
    shellcheck -S warning -x "$f" || fail "shellcheck $f"
  done < <(shell_scripts | grep -v '\.bats$')
  echo "$n scripts"
  [ "$n" -ge 15 ] || fail "found only $n shell scripts; the file search is broken"
else skip shellcheck; fi

step "node syntax"
for f in $(files '*.mjs' '*.js') workspace/bin/fraim-preview workspace/bin/fraim-queue workspace/bin/fraim-brain workspace/bin/fraim-channels; do node --check "$f" || fail "node --check $f"; done

step "JSON files parse"
for f in $(files '*.json'); do jq empty "$f" 2>/dev/null || fail "invalid JSON: $f"; done

step "compose file, every profile"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  BIND_IP=127.0.0.1 COMPOSE_PROFILES=sync,browser,whatsapp,scheduler,google \
    docker compose --env-file .env.example -f compose.yaml config -q || fail "compose config"
else skip "docker compose"; fi

step "Dockerfiles"
if command -v hadolint >/dev/null; then
  files '*Dockerfile' | xargs hadolint || fail hadolint
else skip hadolint; fi

step "GitHub workflows"
if [ -d .github/workflows ]; then
  if command -v actionlint >/dev/null; then actionlint || fail actionlint; else skip actionlint; fi
fi

step "Claude plugin manifests"
if command -v claude >/dev/null; then
  claude plugin validate . </dev/null >/dev/null || fail "claude plugin validate"
else printf 'skip: claude is not installed\n'; fi
for f in $(files '*SKILL.md'); do
  head -1 "$f" | grep -qx -- '---' || { fail "$f has no frontmatter"; continue; }
  name="$(sed -n '2,/^---$/s/^name: *//p' "$f")"
  [ "$name" = "$(basename "$(dirname "$f")")" ] || fail "$f: name '$name' does not match its folder"
  sed -n '2,/^---$/p' "$f" | grep -q '^description: .\{20,\}' || fail "$f: description is missing or too short"
done

echo
if [ "$FAIL" = 0 ]; then echo "lint: all checks passed"; else echo "lint: FAILED"; fi
exit "$FAIL"
