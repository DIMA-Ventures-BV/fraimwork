#!/usr/bin/env bash
# Tests `fraim cloud prepare` against local containers that act like cloud images:
#   ubuntu: AWS style, login as ubuntu, root key line blocked with command="Please login as..."
#   debian: login as admin, no rsync installed
# Needs Docker and an SSH key in ~/.ssh. Removes its containers when done.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
key=""
for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do [ -f "$k.pub" ] && { key="$k"; break; }; done
[ -n "$key" ] || { echo "no SSH key"; exit 1; }
pub="$(cat "$key.pub")"
fail=0

image_for() {
  local base="$1" user="$2" tag="fraim-prepare-test-$1"
  docker build -q -t "$tag" - >/dev/null <<EOF
FROM $base:latest
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q openssh-server sudo >/dev/null \
 && apt-get remove -y -q rsync >/dev/null 2>&1; rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd && (id $user >/dev/null 2>&1 || useradd -m -s /bin/bash $user) \
 && echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cloud \
 && install -d -m 700 -o $user -g $user /home/$user/.ssh \
 && echo '$pub' > /home/$user/.ssh/authorized_keys && chown $user /home/$user/.ssh/authorized_keys \
 && install -d -m 700 /root/.ssh \
 && echo 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="echo Please login as the user $user rather than root;sleep 10;exit 142" $pub' > /root/.ssh/authorized_keys
CMD ["/usr/sbin/sshd", "-D", "-e"]
EOF
  printf '%s' "$tag"
}

check() {
  local base="$1" user="$2" port="$3" login="$4" tag name out rc=0
  tag="$(image_for "$base" "$user")" || { echo "FAIL  build $base"; fail=1; return; }
  name="fraim-prepare-test-$base"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" -p "127.0.0.1:$port:22" "$tag" >/dev/null
  sleep 2
  export FRAIM_CLOUD_SSH_OPTS="-o Port=$port -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $key"
  out="$(bin/fraim-cloud prepare "$login" 2>&1)" || rc=$?
  # shellcheck disable=SC2086
  if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "root@127.0.0.1" ] \
     && ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o IdentitiesOnly=yes $FRAIM_CLOUD_SSH_OPTS root@127.0.0.1 'command -v rsync && test "$(id -u)" = 0' >/dev/null; then
    printf 'ok    %s: prepare %s gives root with rsync\n' "$base" "$login"
  else
    printf 'FAIL  %s: prepare %s (exit %s)\n%s\n' "$base" "$login" "$rc" "$out"; fail=1
  fi
  rc=0; out="$(bin/fraim-cloud prepare "root@127.0.0.1" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then printf 'ok    %s: second run is a no-op\n' "$base"; else printf 'FAIL  %s: rerun\n%s\n' "$base" "$out"; fail=1; fi
  docker rm -f "$name" >/dev/null
}

check ubuntu ubuntu 2391 ubuntu@127.0.0.1
check debian admin 2392 root@127.0.0.1
exit "$fail"
