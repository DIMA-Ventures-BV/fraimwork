#!/usr/bin/env bash
# Runs install.sh (public mode) inside a systemd container that acts like a fresh cloud VM,
# with Docker inside it. Then checks that the stack is up and that SSH to the workspace works.
# Usage: tests/install-distro.sh ubuntu:24.04|debian:12 [ssh-port]
# Needs Docker with privileged containers. Takes 5 to 15 minutes per distro (image builds).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
base="${1:?usage: tests/install-distro.sh ubuntu:24.04|debian:12 [port]}"
port="${2:-2401}"
slug="$(printf '%s' "$base" | tr ':.' '--')"
name="fraim-install-test-$slug"
key=""
for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do [ -f "$k.pub" ] && { key="$k"; break; }; done
[ -n "$key" ] || { echo "no SSH key"; exit 1; }

docker build -q -t "$name" - >/dev/null <<EOF || { echo "FAIL build $base"; exit 1; }
FROM $base
ENV container=docker
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
      systemd systemd-sysv dbus openssh-server sudo iproute2 iptables kmod >/dev/null \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF

docker rm -f "$name" >/dev/null 2>&1
docker volume rm -f "$name-docker" "$name-containerd" >/dev/null 2>&1
docker run -d --name "$name" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "$name-docker:/var/lib/docker" -v "$name-containerd:/var/lib/containerd" -p "127.0.0.1:$port:2222" "$name" >/dev/null
sleep 3

stage="$(mktemp -d)"
mkdir -p "$stage/fraimwork"
tar --exclude .git --exclude node_modules --exclude '.env*' -cf - . | tar -xf - -C "$stage/fraimwork"
cat > "$stage/fraimwork/.env" <<EOF
FRAIM_HOSTNAME=fraim-test
ACCESS_MODE=public
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
mkdir -p "$stage/fraimwork/config"
cp "$key.pub" "$stage/fraimwork/config/authorized_keys"
docker cp "$stage/fraimwork" "$name:/opt/fraimwork" >/dev/null
rm -rf "$stage"

echo "== install.sh on $base"
if ! docker exec "$name" bash -c 'cd /opt/fraimwork && ./install.sh' > "/tmp/$name.log" 2>&1; then
  tail -30 "/tmp/$name.log"
  [ -n "${KEEP:-}" ] || { docker rm -f "$name" >/dev/null; docker volume rm -f "$name-docker" "$name-containerd" >/dev/null; }
  echo "FAIL install.sh on $base (full log: /tmp/$name.log)"
  exit 1
fi
tail -15 "/tmp/$name.log"

fail=0
check() { if "$@" >/dev/null 2>&1; then echo "ok    $base: $label"; else echo "FAIL  $base: $label"; fail=1; fi; }
label="all services running"
check docker exec "$name" bash -c 'cd /opt/fraimwork && [ "$(docker compose ps --status running --services | wc -l)" -ge 5 ]'
label="sshd drop-in disables passwords"
# Ubuntu 24.04 starts sshd by socket, so /run/sshd only exists after the first login.
check docker exec "$name" bash -c 'mkdir -p /run/sshd && sshd -T | grep -qx "passwordauthentication no"'
label=".env is mode 600 with generated secrets"
check docker exec "$name" bash -c 'cd /opt/fraimwork && [ "$(stat -c %a .env)" = 600 ] && grep -qE "^GATEWAY_TOKEN=.{48}$" .env'
label="workspace SSH works as claude"
for _ in $(seq 20); do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o IdentitiesOnly=yes -i "$key" -p "$port" claude@127.0.0.1 true 2>/dev/null && break
  sleep 3
done
check ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o IdentitiesOnly=yes -i "$key" -p "$port" claude@127.0.0.1 'command -v claude && tmux has-session -t main'
label="install.sh runs again without errors"
check docker exec "$name" bash -c 'cd /opt/fraimwork && ./install.sh'

[ -n "${KEEP:-}" ] || { docker rm -f "$name" >/dev/null; docker volume rm -f "$name-docker" "$name-containerd" >/dev/null; }
exit "$fail"
