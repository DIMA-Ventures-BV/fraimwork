#!/usr/bin/env bash
# Checks fraim cloud without spending money: usage errors, the cost gate, login checks
# and a Hetzner dry run (needs a logged-in hcloud; it only reads).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

expect() {
  local want="$1" pattern="$2"; shift 2
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qE "$pattern"; then
    printf 'ok    %s\n' "$*"
  else
    printf 'FAIL  %s (exit %s, want %s)\n%s\n' "$*" "$rc" "$want" "$out"
    fail=1
  fi
}

expect 0 'fraim cloud create' bin/fraim help
expect 0 'prepare USER@IP' bin/fraim cloud help
expect 2 'provider hetzner' bin/fraim cloud create
expect 2 'hetzner, digitalocean or aws' bin/fraim cloud create --provider vultr --name t1
expect 2 'no server named' bin/fraim cloud destroy --name does-not-exist
expect 2 'fraim cloud prepare USER@IP' bin/fraim cloud prepare

if command -v doctl >/dev/null && doctl account get >/dev/null 2>&1; then
  expect 2 'costs money' bin/fraim cloud create --provider digitalocean --name t1
else
  expect 3 '^HUMAN STEP: .*(doctl|DigitalOcean)' bin/fraim cloud create --provider digitalocean --name t1
fi
if aws sts get-caller-identity >/dev/null 2>&1; then
  expect 2 'costs money' bin/fraim cloud create --provider aws --name t1
else
  expect 3 '^HUMAN STEP: .*aws login' bin/fraim cloud create --provider aws --name t1
fi
if hcloud server list >/dev/null 2>&1; then
  expect 2 'type cx23, region nbg1' bin/fraim cloud create --provider hetzner --name fraim-cli-test
  expect 0 'hcloud server create --name fraim-cli-test --type cax11 --image ubuntu-24.04 --location fsn1' \
    bin/fraim cloud create --provider hetzner --name fraim-cli-test --arch arm --dry-run
  expect 2 'no ARM droplets' bin/fraim cloud create --provider digitalocean --arch arm --name t1 --dry-run
fi

exit "$fail"
