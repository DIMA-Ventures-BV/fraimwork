#!/usr/bin/env bash
# Sets up a fresh Ubuntu 22.04+ or Debian 12+ server for fraimwork, on any provider. Safe to run again.
# Usage (as root, from the repo folder on the server): ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'install.sh: warning: %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

get_env() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- || true; }
set_env() {
  if grep -qE "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
has_module() { case ",$(get_env COMPOSE_PROFILES)," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

[ "$(id -u)" = 0 ] || die "run as root"
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Ubuntu 22.04+ or Debian 12+ is required (found ${ID:-unknown})" ;;
esac
[ -f .env ] || die "no .env found; run 'fraim init' on your laptop and deploy again"
[ -s config/authorized_keys ] || die "config/authorized_keys is empty; add at least one SSH public key"
chmod 600 .env

mode="$(get_env ACCESS_MODE)"
case "$mode" in tailscale|public) ;; *) die "ACCESS_MODE must be tailscale or public" ;; esac
if has_module whatsapp && [ -z "$(get_env WHATSAPP_OWNER)" ]; then
  die "the whatsapp module needs WHATSAPP_OWNER in .env"
fi

say "Installing system packages"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -q
apt-get install -y -q ca-certificates curl openssl jq ufw unattended-upgrades
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker >/dev/null

say "Generating secrets"
[ -n "$(get_env GATEWAY_TOKEN)" ] || set_env GATEWAY_TOKEN "$(openssl rand -hex 24)"
# VNC only uses the first 8 characters of a password.
[ -n "$(get_env VNC_PASSWORD)" ] || set_env VNC_PASSWORD "$(openssl rand -hex 4)"
[ -n "$(get_env SYNCTHING_GUI_PASSWORD)" ] || set_env SYNCTHING_GUI_PASSWORD "$(openssl rand -hex 12)"

# Small cloud servers (2 to 4 GB) have no swap. The image build and Chrome need headroom.
mem_mb="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
if [ "$mem_mb" -lt 3500 ]; then
  warn "this server has ${mem_mb} MB memory; 4 GB or more is recommended"
fi
if [ "$mem_mb" -lt 6000 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ] && [ ! -f /swapfile ]; then
  say "Adding a 2 GB swap file"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  # Container-based VPS hosts (LXC, OpenVZ) do not allow swap.
  if swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    warn "this host does not allow swap; continuing without it"
    rm -f /swapfile
  fi
fi
free_gb="$(df -BG --output=avail / | tail -1 | tr -dc 0-9)"
[ "$free_gb" -ge 12 ] || warn "only ${free_gb} GB free disk; the images need about 6 GB, 20 GB or more is recommended"

# Cloud images can enable passwords in sshd_config.d (for example 50-cloud-init.conf).
# The first value sshd reads wins, so this file sorts first.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-fraim.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

if [ "$mode" = tailscale ]; then
  say "Connecting to Tailscale"
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  if ! tailscale ip -4 >/dev/null 2>&1; then
    key="$(get_env TS_AUTHKEY)"
    [ -n "$key" ] || die "TS_AUTHKEY is empty; create a tagged one-time key in the Tailscale admin console"
    tailscale up --auth-key="$key" --hostname="$(get_env FRAIM_HOSTNAME)" --advertise-tags=tag:fraim --ssh
  fi
  set_env TS_AUTHKEY ""
  ts_ip="$(tailscale ip -4 | head -1)"
  set_env BIND_IP "$ts_ip"
  set_env PRIVATE_BIND_IP "$ts_ip"
  set_env BROWSER_VIEW_URL "http://$(get_env FRAIM_HOSTNAME):6080/vnc.html"

  # Docker binds ports to the Tailscale IP, so it must start after Tailscale has one.
  install -d /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/fraim-tailscale.conf <<'EOF'
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 60); do tailscale ip -4 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 0'
EOF
  systemctl daemon-reload

  say "Configuring the firewall: Tailscale only"
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow in on tailscale0 >/dev/null
  ufw allow 41641/udp comment 'tailscale direct connections' >/dev/null
  ufw --force enable >/dev/null
  warn "public SSH is now closed. Reach this server with: ssh root@$(get_env FRAIM_HOSTNAME) (Tailscale SSH)"
else
  set_env BIND_IP "0.0.0.0"
  set_env PRIVATE_BIND_IP "127.0.0.1"
  set_env BROWSER_VIEW_URL "http://localhost:6080/vnc.html (run 'fraim browser' to open the tunnel)"

  say "Configuring the firewall: SSH keys only"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp comment 'admin ssh' >/dev/null
  ufw allow "$(get_env SSH_PORT)/tcp" comment 'fraim workspace' >/dev/null
  ufw allow 60000:60010/udp comment 'mosh' >/dev/null
  ufw allow 22000 comment 'syncthing' >/dev/null
  ufw --force enable >/dev/null
fi

say "Building and starting fraimwork (first build takes a few minutes)"
docker compose up -d --build --remove-orphans

if has_module sync; then
  say "Securing the Syncthing GUI"
  for _ in $(seq 30); do
    docker compose exec -T syncthing test -s /var/syncthing/config/config.xml 2>/dev/null && break
    sleep 2
  done
  # shellcheck disable=SC2016
  docker compose exec -T -e PW="$(get_env SYNCTHING_GUI_PASSWORD)" syncthing sh -c '
    key=$(sed -n "s:.*<apikey>\(.*\)</apikey>.*:\1:p" /var/syncthing/config/config.xml)
    st() { syncthing cli --gui-address=127.0.0.1:8384 --gui-apikey="$key" "$@"; }
    # The API starts a few seconds after the config file appears, and each GUI change
    # restarts the listener. Retry every call until the API takes it.
    retry() { i=0; until "$@" 2>/dev/null; do i=$((i + 1)); [ "$i" -lt 60 ] || return 1; sleep 1; done; }
    retry st config gui user set fraim && retry st config gui password set "$PW" \
      && retry grep -q "<password>" /var/syncthing/config/config.xml
  ' || warn "could not set the Syncthing GUI password; set it in the GUI"
fi

host="$(get_env FRAIM_HOSTNAME)"
[ "$mode" = tailscale ] || host="$(curl -fsS https://api.ipify.org || hostname -I | cut -d' ' -f1)"

cat <<EOF

fraimwork is running.

  Terminal:        fraim shell            (ssh -p $(get_env SSH_PORT) claude@${host})
  First time:      log in to Claude inside that session (/login)
EOF
has_module browser && cat <<EOF
  Server browser:  fraim browser          (VNC password: $(get_env VNC_PASSWORD))
EOF
has_module sync && cat <<EOF
  File sync:       fraim sync             (GUI user: fraim, password: $(get_env SYNCTHING_GUI_PASSWORD))
EOF
has_module whatsapp && cat <<EOF
  WhatsApp:        fraim whatsapp         (scan the QR code with WhatsApp Business)
EOF
echo
echo "Secrets are stored in $(pwd)/.env (root only)."
