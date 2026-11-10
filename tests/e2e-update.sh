#!/usr/bin/env bash
# Proves self-updating on a real Ubuntu machine with real Docker: starts a Lima VM and runs
# tests/e2e-update-vm.sh in it as root. About 40 minutes the first time.
# KEEP_VM=1 leaves the VM running afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
vm=fraim-update-test
free_gb="$(df -g . | awk 'NR == 2 { print $4 }')"
[ "$free_gb" -ge 30 ] || { echo "only ${free_gb} GB free; this test needs 30" >&2; exit 1; }
if ! limactl list -q | grep -qx "$vm"; then
  limactl start -y --name="$vm" --cpus=4 --memory=8 --disk=40 template:ubuntu-24.04
fi
code=0
limactl shell --workdir / "$vm" sudo bash "$PWD/tests/e2e-update-vm.sh" "$PWD" || code=$?
[ -n "${KEEP_VM:-}" ] || limactl delete -f "$vm"
exit "$code"
