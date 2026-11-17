#!/usr/bin/env bash
# End-to-end deploy test on a real local VM that behaves like a fresh cloud server:
# cloud image, cloud-init, systemd, a sudo user (not root), the user's SSH key.
#
#   tests/vm-deploy.sh [debian-12|ubuntu-24.04]    (macOS with Lima: brew install lima)
#
# Steps: create a Lima VM (2 CPU, 4 GB, 30 GB, like a Hetzner cx23), run the real
# `fraim deploy USER@IP` from a throwaway copy of this repo, check the server, delete the VM.
# KEEP=1 keeps the VM. Takes 15 to 25 minutes (first image build).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
distro="${1:-debian-12}"
name="fraim-e2e-${distro//./-}"
key=""
for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do [ -f "$k.pub" ] && { key="$k"; break; }; done
[ -n "$key" ] || { echo "no SSH key in ~/.ssh"; exit 1; }
command -v limactl >/dev/null || { echo "install Lima: brew install lima"; exit 1; }
work="$(mktemp -d)"
cleanup() {
  [ -n "${KEEP:-}" ] || limactl delete -f "$name" >/dev/null 2>&1
  [ -z "${ip:-}" ] || { ssh-keygen -R "$ip" >/dev/null 2>&1; ssh-keygen -R "[$ip]:2222" >/dev/null 2>&1; }
  rm -rf "$work"
}
trap cleanup EXIT

# vzNAT gives the VM its own IP; ignoring all port forwards keeps it off this Mac's ports.
cat > "$work/vm.yaml" <<EOF
base: template:$distro
vmType: vz
cpus: 2
memory: 4GiB
disk: 30GiB
mounts: []
containerd: {system: false, user: false}
networks:
  - vzNAT: true
portForwards:
  - guestIP: "0.0.0.0"
    guestPortRange: [1, 65535]
    ignore: true
provision:
  - mode: user
    script: |
      #!/bin/sh
      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      grep -qF '$(cut -d' ' -f2 "$key.pub")' ~/.ssh/authorized_keys 2>/dev/null || echo '$(cat "$key.pub")' >> ~/.ssh/authorized_keys
      chmod 600 ~/.ssh/authorized_keys
EOF
limactl delete -f "$name" >/dev/null 2>&1
echo "== creating VM $name ($distro)"
limactl start --name "$name" --tty=false "$work/vm.yaml" >"$work/lima.log" 2>&1 || { tail -20 "$work/lima.log"; exit 1; }
ip="$(limactl shell "$name" ip -4 -o addr show lima0 | awk '{print $4}' | cut -d/ -f1)"
user="$(limactl shell "$name" whoami)"
[ -n "$ip" ] || { echo "VM has no lima0 address"; exit 1; }
ssh-keygen -R "$ip" >/dev/null 2>&1; ssh-keygen -R "[$ip]:2222" >/dev/null 2>&1

mkdir -p "$work/repo" "$work/xdg"
tar --exclude .git --exclude node_modules --exclude './.env' --exclude './.env.local' -cf - . | tar -xf - -C "$work/repo"
cat > "$work/repo/.env" <<'EOF'
FRAIM_HOSTNAME=fraim-e2e
ACCESS_MODE=public
TS_AUTHKEY=
COMPOSE_PROFILES=browser,scheduler,sync,whatsapp
TZ=Europe/Amsterdam
SSH_PORT=2222
WHATSAPP_OWNER=31600000000
WHATSAPP_ALLOW=
GATEWAY_TOKEN=
VNC_PASSWORD=
SYNCTHING_GUI_PASSWORD=
BIND_IP=
PRIVATE_BIND_IP=
BROWSER_VIEW_URL=
EOF
chmod 600 "$work/repo/.env"
mkdir -p "$work/repo/config" && cp "$key.pub" "$work/repo/config/authorized_keys"

echo "== fraim deploy $user@$ip"
if ! (cd "$work/repo" && XDG_CONFIG_HOME="$work/xdg" FRAIM_SSH_KEY="$key" bin/fraim deploy "$user@$ip" </dev/null) >"$work/deploy.log" 2>&1; then
  tail -30 "$work/deploy.log"; echo "FAIL  deploy"; exit 1
fi
grep '^install.sh: warning' "$work/deploy.log" || true

O=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i "$key" -o ConnectTimeout=10)
fail=0
chk() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi; }
root() { ssh "${O[@]}" "root@$ip" "$@"; }
chk "install.sh printed no warnings" sh -c "! grep -q '^install.sh: warning' '$work/deploy.log'"
chk "5 services running" root 'cd /opt/fraimwork && [ "$(docker compose ps --status running --services | wc -l)" -ge 5 ]'
chk "sshd: passwords off" root 'mkdir -p /run/sshd && sshd -T | grep -qx "passwordauthentication no"'
chk "sshd: root key-only" root 'sshd -T | grep -qx "permitrootlogin without-password"'
chk "ufw active" root 'ufw status | grep -q "Status: active"'
chk "swap on (4 GB server)" root 'swapon --show | grep -q swapfile'
chk ".env mode 600" root '[ "$(stat -c %a /opt/fraimwork/.env)" = 600 ]'
chk "syncthing GUI has a password" root 'cd /opt/fraimwork && docker compose exec -T syncthing grep -q "<password>" /var/syncthing/config/config.xml'
for _ in $(seq 20); do ssh "${O[@]}" -p 2222 "claude@$ip" true 2>/dev/null && break; sleep 3; done
chk "workspace SSH as claude" ssh "${O[@]}" -p 2222 "claude@$ip" 'command -v claude && tmux has-session -t main'
chk "SSH password login refused" sh -c "! ssh -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password -o ConnectTimeout=5 root@$ip true"
if root 'cd /opt/fraimwork && ./install.sh' >"$work/rerun.log" 2>&1; then echo "ok    install.sh runs again"
else echo "FAIL  install.sh runs again"; tail -25 "$work/rerun.log"; fail=1; fi
exit "$fail"
