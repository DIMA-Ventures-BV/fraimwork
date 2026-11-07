#!/usr/bin/env bash
# Sets up a fresh Ubuntu 24.04 server for fraimwork. Safe to run again.
# Usage (as root, from the repo folder on the server): ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'install.sh: warning: %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# ENV_FILE: .env (the main space) or .env.space-NAME (another space, see docs/spaces.md).
ENV_FILE=.env
get_env() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
set_env() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
has_module() { case ",$(get_env COMPOSE_PROFILES)," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
# Runs `docker compose` for the space in ENV_FILE.
space_compose() {
  if [ "$ENV_FILE" = .env ]; then
    docker compose "$@"
  else
    docker compose -p "fraimwork-${ENV_FILE#.env.space-}" --env-file "$ENV_FILE" "$@"
  fi
}

# Sets a fresh Syncthing GUI password, so the GUI is never open without one.
secure_syncthing() {
  for _ in $(seq 30); do
    space_compose exec -T syncthing test -s /var/syncthing/config/config.xml 2>/dev/null && break
    sleep 2
  done
  # shellcheck disable=SC2016
  space_compose exec -T -e PW="$(get_env SYNCTHING_GUI_PASSWORD)" syncthing sh -c '
    key=$(sed -n "s:.*<apikey>\(.*\)</apikey>.*:\1:p" /var/syncthing/config/config.xml)
    # Changing a GUI setting restarts the GUI listener, so the next call can briefly get
    # "connection refused": retry each call for up to about 20 seconds.
    st() {
      i=0
      until syncthing cli --gui-address=127.0.0.1:8384 --gui-apikey="$key" "$@" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -lt 20 ] || return 1; sleep 1
      done
    }
    st config gui user set fraim && st config gui password set "$PW"
  ' || die "could not set the Syncthing GUI password of $ENV_FILE; the GUI must not stay open without one. Run install.sh again."
}

# Brings one extra space in line with the main .env (access mode, Tailscale address,
# version) and starts it. Usage: start_space NAME
start_space() {
  local name="$1" key
  ENV_FILE=".env.space-$name"
  [ -f "$ENV_FILE" ] || die "no space $name ($ENV_FILE is missing); create it with: fraim space add $name"
  chmod 600 "$ENV_FILE"
  for key in ACCESS_MODE BIND_IP PRIVATE_BIND_IP FRAIM_HOSTNAME FRAIM_VERSION FRAIM_COMMIT FRAIM_RELEASES_REPO; do
    local value
    value="$(ENV_FILE=.env get_env "$key")"
    [ -z "$value" ] || set_env "$key" "$value"
  done
  if [ "$(get_env ACCESS_MODE)" = tailscale ]; then
    set_env BROWSER_VIEW_URL "http://$(get_env FRAIM_HOSTNAME):$(get_env VNC_PORT)/vnc.html"
  fi
  [ -n "$(get_env GATEWAY_TOKEN)" ] || set_env GATEWAY_TOKEN "$(openssl rand -hex 24)"
  [ -n "$(get_env VNC_PASSWORD)" ] || set_env VNC_PASSWORD "$(openssl rand -hex 4)"
  [ -n "$(get_env SYNCTHING_GUI_PASSWORD)" ] || set_env SYNCTHING_GUI_PASSWORD "$(openssl rand -hex 12)"
  [ -n "$(get_env SECRETS_TOKEN)" ] || set_env SECRETS_TOKEN "$(openssl rand -hex 32)"
  if has_module whatsapp && [ -z "$(get_env WHATSAPP_OWNER)" ]; then
    die "space $name has the whatsapp module but no WHATSAPP_OWNER"
  fi
  # `fraim space rm` (without --wipe) stops a space until `fraim space up`, also across updates.
  if [ "$(get_env STOPPED)" = 1 ]; then
    say "Space $name is stopped (fraim space up $name starts it)"
    ENV_FILE=.env
    return 0
  fi
  say "Starting space $name"
  space_compose up -d --build --remove-orphans
  if has_module sync; then secure_syncthing; fi
  ENV_FILE=.env
}

# Containers have their own networks per space, but every port the server publishes on its
# own address (another space's previews, browser view, Syncthing GUI, SSH) would still be
# reachable from any container through that address. These rules drop container traffic to
# the server's own fraim ports. A systemd unit puts them back after a reboot or Docker restart.
isolate_spaces() {
  command -v iptables >/dev/null || return 1
  cat > /usr/local/sbin/fraim-isolation <<'EOF'
#!/bin/sh
# Installed by fraimwork install.sh: containers may not reach the server's own fraim ports.
for _ in $(seq 60); do iptables -L DOCKER-USER -n >/dev/null 2>&1 && break; sleep 1; done
rule() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
for src in 172.29.0.0/16 172.30.0.0/16 172.31.0.0/16; do
  rule INPUT -s "$src" -m addrtype --dst-type LOCAL -p tcp -m multiport --dports 22,2222:2226,3100:3149,6080:6084,8384:8388,22000:22004 -j DROP
  rule INPUT -s "$src" -m addrtype --dst-type LOCAL -p udp -m multiport --dports 22000:22004,60000:60090 -j DROP
  # Published ports reached by DNAT pass FORWARD, where Docker lets DOCKER-USER decide first.
  if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    rule DOCKER-USER -s "$src" -m conntrack --ctstate DNAT -j DROP
  fi
done
EOF
  chmod 0755 /usr/local/sbin/fraim-isolation
  cat > /etc/systemd/system/fraim-isolation.service <<'EOF'
[Unit]
Description=fraimwork: keep spaces from reaching each other's published ports
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fraim-isolation

[Install]
WantedBy=multi-user.target docker.service
EOF
  systemctl daemon-reload
  systemctl enable fraim-isolation.service >/dev/null 2>&1 || true
  /usr/local/sbin/fraim-isolation
}

[ "$(id -u)" = 0 ] || die "run as root"

if [ "${1:-}" != --lock-public-ssh ] && [ "${1:-}" != --space ] && [ -d .update-lock ] && [ "${FRAIM_LOCK_HELD:-}" != 1 ]; then
  die "an update is running or did not finish ($(cat .update-lock/info 2>/dev/null)); run 'fraim update --recover' from the laptop"
fi

# Second stage, run by `fraim deploy` only after the laptop reached the server over Tailscale.
if [ "${1:-}" = --lock-public-ssh ]; then
  ufw delete allow OpenSSH >/dev/null 2>&1 || true
  touch .public-ssh-locked
  echo "Public SSH closed. The server is reachable over Tailscale only."
  exit 0
fi

# `fraim space add/up/policy`: start one extra space with the host as it is.
if [ "${1:-}" = --space ]; then
  [ -n "${2:-}" ] || die "usage: install.sh --space NAME"
  [ -f .env ] || die "no .env found; deploy the main space first"
  [ ! -d .update-lock ] || [ "${FRAIM_LOCK_HELD:-}" = 1 ] || die "an update is running or did not finish ($(cat .update-lock/info 2>/dev/null)); try again after it"
  printf '%s' "$2" | grep -Eq '^[a-z][a-z0-9-]{0,15}$' || die "invalid space name $2"
  start_space "$2"
  isolate_spaces || warn "could not add the firewall rules that keep spaces apart"
  echo "Space $2 is running."
  exit 0
fi
# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "Ubuntu 24.04 or newer is required (found ${ID:-unknown})"
[ -f .env ] || die "no .env found; run 'fraim init' on your laptop and deploy again"
[ -s config/authorized_keys ] || die "config/authorized_keys is empty; add at least one SSH public key"
chmod 600 .env

mode="$(get_env ACCESS_MODE)"
case "$mode" in tailscale|public) ;; *) die "ACCESS_MODE must be tailscale or public" ;; esac
if has_module whatsapp && [ -z "$(get_env WHATSAPP_OWNER)" ]; then
  die "the whatsapp module needs WHATSAPP_OWNER in .env"
fi

say "Generating secrets"
[ -n "$(get_env GATEWAY_TOKEN)" ] || set_env GATEWAY_TOKEN "$(openssl rand -hex 24)"
# VNC only uses the first 8 characters of a password.
[ -n "$(get_env VNC_PASSWORD)" ] || set_env VNC_PASSWORD "$(openssl rand -hex 4)"
[ -n "$(get_env SYNCTHING_GUI_PASSWORD)" ] || set_env SYNCTHING_GUI_PASSWORD "$(openssl rand -hex 12)"
# Session token between Claude's workspace and the secrets proxy (see docs/secrets.md).
[ -n "$(get_env SECRETS_TOKEN)" ] || set_env SECRETS_TOKEN "$(openssl rand -hex 32)"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
# Wait for Ubuntu's own apt runs (unattended-upgrades, apt-daily) instead of failing.
apt_wait() { apt-get -o DPkg::Lock::Timeout=900 "$@"; }
base_packages=(ca-certificates curl openssl jq ufw unattended-upgrades)
if dpkg -s "${base_packages[@]}" >/dev/null 2>&1; then
  say "System packages already installed"
else
  say "Installing system packages"
  apt_wait update -q
  apt_wait install -y -q "${base_packages[@]}"
fi
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_wait update -q
  apt_wait install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker >/dev/null

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
  # Public SSH stays open until `fraim deploy` has proven it can reach the server over
  # Tailscale; then it runs `install.sh --lock-public-ssh`. This prevents a lock-out.
  [ -f .public-ssh-locked ] || ufw allow OpenSSH >/dev/null
  ufw --force enable >/dev/null
else
  set_env BIND_IP "0.0.0.0"
  set_env PRIVATE_BIND_IP "127.0.0.1"
  set_env BROWSER_VIEW_URL "http://localhost:6080/vnc.html (run 'fraim browser' to open the tunnel)"

  # Note: ports Docker publishes on 0.0.0.0 bypass ufw. Only the workspace SSH, mosh and
  # Syncthing sync ports are published publicly (see compose.yaml); never trust ufw to
  # hide a Docker port. GUIs bind to 127.0.0.1 in this mode.
  say "Configuring the firewall: SSH keys only"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw --force enable >/dev/null
fi

say "Hardening SSH: keys only"
# sshd uses the first value it reads, and sshd_config.d is read first, so 00- wins over
# cloud-init's 50-cloud-init.conf.
cat > /etc/ssh/sshd_config.d/00-fraim.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t && { systemctl reload ssh || systemctl reload sshd || true; }

if ! swapon --show --noheadings | grep -q .; then
  # Cloud images ship without swap; on a 4 GB server Claude, a job and Chromium can hit the OOM killer.
  say "Adding 2 GB of swap"
  if fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    warn "could not add swap; the server works, but heavy browser use may run out of memory"
  fi
fi

say "Building and starting fraimwork (first build takes a few minutes)"
docker compose up -d --build --remove-orphans

if has_module sync; then
  say "Securing the Syncthing GUI"
  secure_syncthing
fi

# Every other space (work, personal, ...) runs the same code with its own env file. A space
# that fails to start is reported, but never stops the main space's install or update.
failed_spaces=""
for space_env in .env.space-*; do
  [ -f "$space_env" ] || continue
  space_name="${space_env#.env.space-}"
  if ! printf '%s' "$space_name" | grep -Eq '^[a-z][a-z0-9-]{0,15}$'; then
    warn "ignoring $space_env: not a valid space name"
    continue
  fi
  ( start_space "$space_name" ) || { warn "space $space_name did not start; see the lines above"; failed_spaces="$failed_spaces $space_name"; }
done

say "Isolating spaces from each other's published ports"
isolate_spaces || warn "could not add the firewall rules that keep spaces apart; spaces still have separate networks"

cat <<EOF

fraimwork is running ($(get_env FRAIM_HOSTNAME), $mode mode). Secrets are in $(pwd)/.env (root only).
Next steps are run from the laptop by Claude:
  fraim login                   store the Claude login token on the server
EOF
has_module whatsapp && echo "  fraim whatsapp link --number  link the agent's WhatsApp number with a pairing code"
has_module sync && echo "  fraim sync                    pair the laptop's Syncthing"
[ -z "$failed_spaces" ] || warn "these spaces did not start:$failed_spaces (the main space runs; fix them with fraim space up NAME)"
true
