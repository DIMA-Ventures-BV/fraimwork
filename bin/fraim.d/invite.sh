# shellcheck shell=bash disable=SC2034,SC2154
load_group secret

# --- invite and attach: a laptop joins a server that someone else runs ----------------------
# The operator runs `fraim invite NAME`. It makes a login key for this one person and a token
# for the secrets gate, and writes both to a file. On the person's laptop `fraim attach` reads
# that file. The laptop reaches the workspace only: no root on the server. See docs/invite.md.
INVITE_PREFIX=fraim-invite-v1:
BOOTSTRAP_URL=https://raw.githubusercontent.com/DIMA-Ventures-BV/fraimwork/main/bootstrap.sh
INVITE_INSTALL_KEYS='docker compose exec -T workspace install -o root -g root -m 0644 /etc/fraim/authorized_keys /etc/ssh/authorized_keys/claude'

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

invite_drop_key() {  # NAME: removes the key line of this invite and loads the file
  admin "grep -v ' fraim-invite-$1\$' config/authorized_keys > config/.authorized_keys.tmp || true; test -s config/.authorized_keys.tmp && cat config/.authorized_keys.tmp > config/authorized_keys; rm -f config/.authorized_keys.tmp; $INVITE_INSTALL_KEYS" >/dev/null
}

cmd_invite() {
  parse_flags "$@"
  local name="${POSITIONAL[0]:-}" target="${POSITIONAL[1]:-}"
  local usage_line="fraim invite NAME --share-url URL | NAME --no-share | list | revoke NAME"
  [ -n "$name" ] || usage "$usage_line"
  load_config
  case "$name" in
    list) admin "docker compose exec -T secrets fraim-secret gate-list"; return ;;
    revoke)
      printf '%s' "$target" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' || usage "$usage_line"
      invite_drop_key "$target"
      admin "docker compose exec -T secrets fraim-secret gate-rm $target" >/dev/null
      rm -f "$CONFIG_DIR/invites/$target.invite"
      say "Invite $target is revoked: that laptop can no longer log in or store keys. Keys it already stored stay on the server."
      return
      ;;
  esac
  printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' || usage "NAME must be lowercase letters, digits and dashes, starting with a letter"
  [ "$FRAIM_ACCESS" = tailscale ] || die "an invite holds a login key, so it only works for a server on Tailscale (this one is $FRAIM_ACCESS)"
  local share
  share="$(flag share-url)"
  if [ -z "$share" ] && [ -z "$(flag no-share)" ]; then
    human "Share this server with the person: open https://login.tailscale.com/admin/machines, open the menu of $FRAIM_HOST, click Share, and copy the link. Then Claude runs: fraim invite $name --share-url LINK"
  fi
  [ -z "$share" ] || printf '%s' "$share" | grep -Eq '^https://login\.tailscale\.com/[^[:space:]]+$' || usage "--share-url must be a https://login.tailscale.com/ link"

  local address host_key tmp token hash file
  address="$(server_env BIND_IP | tr -d '\r')"
  printf '%s' "$address" | grep -Eq '^100\.[0-9.]+$' || die "could not read the Tailscale address of the server"
  host_key="$(admin "docker compose exec -T workspace cat /etc/ssh/keys/ssh_host_ed25519_key.pub" | tr -d '\r' | awk '{ print $1, $2 }')"
  case "$host_key" in "ssh-ed25519 "*) ;; *) die "could not read the SSH host key of the workspace" ;; esac

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # the path is fixed now
  trap "rm -rf '$tmp'" EXIT
  ssh-keygen -q -t ed25519 -N "" -C "fraim-invite-$name" -f "$tmp/key"
  token="$(openssl rand -hex 32)"
  hash="$(printf '%s' "$token" | sha256_of)"

  printf '%s' "$hash" | admin_stdin "docker compose exec -T secrets fraim-secret gate-add $name" >/dev/null \
    || die "the server has no secrets gate yet; run fraim update first"
  invite_drop_key "$name"
  admin_stdin "cat >> config/authorized_keys" < "$tmp/key.pub"
  admin "$INVITE_INSTALL_KEYS" >/dev/null

  mkdir -p "$CONFIG_DIR/invites"
  file="$CONFIG_DIR/invites/$name.invite"
  (
    umask 077
    jq -n --arg name "$name" --arg host "$address" --arg port "$FRAIM_SSH_PORT" --arg known "$host_key" \
      --arg token "$token" --arg share "$share" --rawfile key "$tmp/key" \
      '{v: 1, name: $name, host: $host, port: $port, known: $known, token: $token, share: $share, key: $key}' \
      | base64 | tr -d '\n' | { printf '%s' "$INVITE_PREFIX"; cat; printf '\n'; } > "$file"
  )
  if command -v pbcopy >/dev/null; then pbcopy < "$file" || true; fi
  say "Invite for $name is ready in $file (and on your clipboard). It holds a login key: send it by a private channel."
  say "On their computer, in a terminal:"
  say "  curl -fsSL $BOOTSTRAP_URL | FRAIM_NO_TOKEN=1 FRAIM_NO_ALIASES=1 FRAIM_PROMPT='connect me to my fraim' bash"
  say "Then they copy the invite. Their Claude does the rest."
}

attach_reach() {  # the steps after the invite was stored; run again with --check
  local share=""
  [ ! -s "$CONFIG_DIR/$FRAIM_TARGET.share" ] || share="$(cat "$CONFIG_DIR/$FRAIM_TARGET.share")"
  if ! port_open "$FRAIM_HOST" "$FRAIM_SSH_PORT"; then
    if [ -n "$share" ]; then
      human "Connect this computer to your server: install Tailscale from https://tailscale.com/download and sign in with your own account (a free one is fine). Then open this link and accept the shared server: $share  Tell Claude 'done'; Claude then runs: fraim attach --check"
    fi
    human "This computer cannot reach the server. Check that Tailscale is on and signed in. Tell Claude 'done'; Claude then runs: fraim attach --check"
  fi
  workspace_ssh true < /dev/null || die "the server answers but refused the login; ask the person who runs your server for a new invite"
  say "Connected to $FRAIM_TARGET. This computer can use the server, but has no admin access to it."
}

cmd_attach() {
  parse_flags "$@"
  if [ -n "$(flag check)" ]; then
    load_config
    attached || die "fraim attach --check is for a computer that joined with an invite"
    attach_reach
    return
  fi
  local raw=""
  if [ -n "$(flag file)" ]; then
    [ -s "$(flag file)" ] || usage "no invite file at $(flag file)"
    raw="$(cat "$(flag file)")"
  elif [ -n "$(flag stdin)" ]; then
    raw="$(cat)"
  else
    usage "fraim attach --stdin | --file INVITE [--use] | --check"
  fi
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  case "$raw" in "$INVITE_PREFIX"*) ;; *) usage "that is not a fraim invite; ask the person who runs your server to send it again" ;; esac
  local json
  json="$(printf '%s' "${raw#"$INVITE_PREFIX"}" | { base64 -d 2>/dev/null || base64 -D; })" || usage "that invite is damaged; ask for a new one"
  jq -e . >/dev/null 2>&1 <<<"$json" || usage "that invite is damaged; ask for a new one"
  local name host port known token share key_path existing_admin
  name="$(jq -r '.name // ""' <<<"$json")"
  host="$(jq -r '.host // ""' <<<"$json")"
  port="$(jq -r '.port // ""' <<<"$json")"
  known="$(jq -r '.known // ""' <<<"$json")"
  token="$(jq -r '.token // ""' <<<"$json")"
  share="$(jq -r '.share // ""' <<<"$json")"
  printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' || usage "that invite has a bad name"
  printf '%s' "$host" | grep -Eq '^100\.[0-9]+\.[0-9]+\.[0-9]+$' || usage "that invite has a bad address"
  printf '%s' "$port" | grep -Eq '^[0-9]{1,5}$' || usage "that invite has a bad port"
  printf '%s' "$known" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+$' || usage "that invite has a bad host key"
  printf '%s' "$token" | grep -Eq '^[0-9a-f]{64}$' || usage "that invite has a bad token"
  [ -z "$share" ] || printf '%s' "$share" | grep -Eq '^https://login\.tailscale\.com/[^[:space:]]+$' || usage "that invite has a bad share link"
  jq -r '.key // ""' <<<"$json" | head -1 | grep -q 'BEGIN OPENSSH PRIVATE KEY' || usage "that invite has no login key"

  FRAIM_TARGET="$name"
  CONFIG="$CONFIG_DIR/$name.config"
  KNOWN_HOSTS="$STATE_DIR/known_hosts-$name"
  if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    existing_admin="$(. "$CONFIG"; printf '%s' "$FRAIM_ADMIN")"
    [ "$existing_admin" = none ] || die "this computer already manages a server named $name; nothing was changed"
  fi

  key_path="$HOME/.ssh/fraim-$name"
  mkdir -p "$HOME/.ssh" "$CONFIG_DIR"
  chmod 700 "$HOME/.ssh"
  (
    umask 077
    jq -r '.key' <<<"$json" > "$key_path"
    printf '%s\n' "$token" > "$(gate_file)"
    printf '%s' "$share" > "$CONFIG_DIR/$name.share"
  )
  chmod 600 "$key_path"
  printf '[%s]:%s %s\n' "$host" "$port" "$known" > "$KNOWN_HOSTS"
  FRAIM_HOST="$host" FRAIM_ADMIN=none FRAIM_ACCESS=tailscale FRAIM_SSH_PORT="$port" FRAIM_SSH_KEY="$key_path" FRAIM_PUBLIC_HOST=""
  save_config
  if [ -n "$(flag use)" ] || [ ! -f "$CONFIG_DIR/current" ]; then set_current "$name"; fi
  load_config
  attach_reach
}
