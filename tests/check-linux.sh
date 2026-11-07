#!/usr/bin/env bash
# Runs `make check` on Ubuntu 24.04 in Docker, the way CI does, to catch GNU vs BSD differences
# before pushing. The checkout is mounted read-only at the same path (git worktrees need that).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"
mounts=(-v "$repo:$repo:ro")
case "$common" in "$repo"/*) ;; *) mounts+=(-v "$common:$common:ro") ;; esac

docker run --rm "${mounts[@]}" -w "$repo" ubuntu:24.04 sh -c '
  set -e
  apt-get update -q >/dev/null
  apt-get install -yq --no-install-recommends bats shellcheck jq git make ca-certificates curl >/dev/null 2>&1
  curl -fsSL https://deb.nodesource.com/setup_24.x | sh - >/dev/null 2>&1
  apt-get install -yq nodejs >/dev/null 2>&1
  useradd -m tester
  su tester -c "git config --global --add safe.directory \"*\" && make check"
'
