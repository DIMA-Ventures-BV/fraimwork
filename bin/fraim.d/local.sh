# shellcheck shell=bash disable=SC2034,SC2154,SC2164

used_subnets() {
  docker network ls -q | xargs docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n'
}
# First offset (0, 100, ...) whose ports and subnet are free and not claimed by another instance.
pick_offset() {
  local o claimed subnets
  claimed="$(grep -h '^PORT_OFFSET=' "$REPO"/.env.* 2>/dev/null | cut -d= -f2 || true)"
  subnets="$(used_subnets)"
  for o in 0 100 200 300 400 500 600 700 800 900; do
    printf '%s\n' "$claimed" | grep -qx "$o" && continue
    printf '%s\n' "$subnets" | grep -qx "172.30.$((o / 100)).0/24\|172.31.$((o / 100)).0/24\|172.31.$((128 + o / 100)).0/24\|172.31.$((64 + o / 100)).0/24\|172.31.$((192 + o / 100)).0/24" && continue
    { port_free $((2299 + o)) && port_free $((6080 + o)) && port_free $((60000 + o)) && port_free $((3100 + o)); } || continue
    printf '%s' "$o"
    return
  done
  die "no free port offset found between 0 and 900"
}

cmd_local() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-}"
  cd "$REPO"
  ENV_FILE="$REPO/.env.$FRAIM_INSTANCE"
  FRAIM_ACCESS=local
  [ "$FRAIM_SPACE" = main ] || usage "fraim local starts and stops every space of the instance; leave out --space"
  local offset
  offset="$(flag port-offset)"
  case "$action" in
    up)
      command -v docker >/dev/null || human "Install Docker Desktop from https://www.docker.com/products/docker-desktop/ and start it."
      docker info >/dev/null 2>&1 || human "Start Docker Desktop (open it from Applications) and wait until it says it is running."
      if [ -f "$ENV_FILE" ] && [ -n "$(flag port-offset)" ] && [ "$(flag port-offset)" != "$(env_get PORT_OFFSET | grep . || echo 0)" ]; then
        usage "instance '$FRAIM_INSTANCE' already uses port offset $(env_get PORT_OFFSET | grep . || echo 0); the offset is fixed, run 'fraim local down --wipe' first"
      fi
      if [ ! -f "$ENV_FILE" ]; then
        if [ -z "$offset" ]; then
          offset="$(pick_offset)"
          [ "$offset" = 0 ] || say "Another stack uses the default ports; using port offset $offset (SSH $((2299 + offset)), browser view $((6080 + offset)))."
        fi
        cp .env.example "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        env_set PORT_OFFSET "$offset"
        env_set FRAIM_IMAGE_TAG "$FRAIM_INSTANCE"
        env_set FRAIM_HOSTNAME "fraim-$FRAIM_INSTANCE"
        env_set ACCESS_MODE local
        env_set SSH_PORT "$((2299 + offset))"
        env_set VNC_PORT "$((6080 + offset))"
        env_set MOSH_PORTS "$((60000 + offset))-$((60010 + offset))"
        env_set FRAIM_SUBNET "172.30.$((offset / 100)).0/24"
        env_set FRAIM_SUBNET_WA "172.31.$((offset / 100)).0/24"
        env_set FRAIM_SUBNET_SYNC "172.31.$((128 + offset / 100)).0/24"
        env_set BROWSER_IP "172.30.$((offset / 100)).10"
        env_set GATEWAY_TOKEN "$(openssl rand -hex 24)"
        env_set REPLY_TOKEN "$(openssl rand -hex 24)"
        env_set VNC_PASSWORD "$(openssl rand -hex 4)"
        env_set BIND_IP 127.0.0.1
        env_set PRIVATE_BIND_IP 127.0.0.1
        env_set BROWSER_VIEW_URL "http://localhost:$((6080 + offset))/vnc.html"
        # Syncthing stays off locally: it would clash with a Syncthing app on this computer.
        env_set COMPOSE_PROFILES scheduler
      fi
      # Secrets proxy: token and subnets, also for instances created before it existed.
      [ -n "$(env_get SECRETS_TOKEN)" ] || env_set SECRETS_TOKEN "$(openssl rand -hex 32)"
      local o
      o="$(env_get PORT_OFFSET | grep . || echo 0)"
      [ -n "$(env_get FRAIM_SUBNET_SECRETS)" ] || env_set FRAIM_SUBNET_SECRETS "172.31.$((64 + o / 100)).0/24"
      [ -n "$(env_get FRAIM_SUBNET_SECRETS_OUT)" ] || env_set FRAIM_SUBNET_SECRETS_OUT "172.31.$((192 + o / 100)).0/24"
      # Preview ports per instance (spaces of the instance add 10 per space, up to +49).
      [ -n "$(env_get PREVIEW_PORTS)" ] || env_set PREVIEW_PORTS "$((3100 + o))-$((3109 + o))"
      local new_owner="" new_allow=""
      if [ -n "$(flag whatsapp-owner)" ]; then new_owner="$(normalize_phone "$(flag whatsapp-owner)")" || exit 2; fi
      if [ -n "$(flag whatsapp-allow)" ]; then new_allow="$(normalize_phone_list "$(flag whatsapp-allow)")" || exit 2; fi
      if [ -n "$new_owner" ]; then
        env_set WHATSAPP_OWNER "$new_owner"
        has_module whatsapp || env_set COMPOSE_PROFILES "$(env_get COMPOSE_PROFILES),whatsapp"
      fi
      [ -z "$new_allow" ] || env_set WHATSAPP_ALLOW "$new_allow"
      [ -z "$(flag modules)" ] || env_set COMPOSE_PROFILES "$(flag modules)"
      if has_module whatsapp && [ -z "$(env_get WHATSAPP_OWNER)" ]; then usage "the whatsapp module needs --whatsapp-owner"; fi
      if [ -z "$(env_get VOICE)" ]; then
        if has_module whatsapp; then env_set VOICE on; else env_set VOICE off; fi
      fi

      FRAIM_SSH_KEY="$(find_ssh_key)"
      [ -n "$FRAIM_SSH_KEY" ] || human "Create an SSH key on this computer: run ssh-keygen -t ed25519 and press Enter at every question."
      add_authorized_key "$FRAIM_SSH_KEY"

      local output rc=0
      output="$(docker compose -p "$LOCAL_PROJECT" --env-file "$ENV_FILE" up -d --build --remove-orphans --quiet-pull 2>&1)" || rc=$?
      if [ "$rc" != 0 ]; then
        printf '%s\n' "$output" | tail -15 >&2
        if printf '%s' "$output" | grep -qi 'pool overlaps\|address already in use\|port is already allocated'; then
          die "another stack uses these ports or this subnet; use FRAIM_INSTANCE=<name> with --port-offset 100 (after 'fraim local down --wipe' for this instance)"
        fi
        die "docker compose up failed (exit $rc)"
      fi
      CONFIG="$CONFIG_DIR/$FRAIM_INSTANCE.config"
      FRAIM_HOST=127.0.0.1 FRAIM_ADMIN=local FRAIM_ACCESS=local FRAIM_SSH_PORT="$(env_get SSH_PORT)"
      FRAIM_SSH_KEY="$(find_ssh_key)"
      save_config
      if [ "$FRAIM_INSTANCE" = local ] || [ ! -f "$CONFIG_DIR/current" ]; then set_current "$FRAIM_INSTANCE"; fi
      local waited=0
      # shellcheck disable=SC2046
      until ssh $(ssh_opts) -o BatchMode=yes -o ConnectTimeout=2 "claude@$FRAIM_HOST" true 2>/dev/null; do
        waited=$((waited + 1))
        [ "$waited" -lt 30 ] || die "the stack started but SSH does not answer after 30 seconds; check: fraim logs workspace"
        sleep 1
      done
      say "Local fraim is running (instance $FRAIM_INSTANCE, modules: $(env_get COMPOSE_PROFILES))."
      local s
      for s in $(list_spaces); do
        if local_space_stopped "$s"; then say "Space $s is stopped (fraim space up $s starts it)."; continue; fi
        docker compose -p "$LOCAL_PROJECT-$s" --env-file "$(space_env_local "$s")" up -d --build --remove-orphans --quiet-pull >/dev/null 2>&1 \
          || { say "Space $s did not start; check: fraim logs --space $s"; continue; }
        say "Space $s is running."
      done
      ;;
    down)
      local s
      for s in $(list_spaces); do
        if [ -n "$(flag wipe)" ]; then
          docker compose -p "$LOCAL_PROJECT-$s" --env-file "$(space_env_local "$s")" down -v
          rm -f "$(space_env_local "$s")"
        else
          docker compose -p "$LOCAL_PROJECT-$s" --env-file "$(space_env_local "$s")" down
        fi
      done
      if [ -n "$(flag wipe)" ]; then
        docker compose -p "$LOCAL_PROJECT" --env-file "$ENV_FILE" down -v
        rm -f "$ENV_FILE" "$CONFIG_DIR/$FRAIM_INSTANCE.config"
        [ "$(cat "$CONFIG_DIR/current" 2>/dev/null)" != "$FRAIM_INSTANCE" ] || rm -f "$CONFIG_DIR/current"
      else
        docker compose -p "$LOCAL_PROJECT" --env-file "$ENV_FILE" down
      fi
      ;;
    *) usage "fraim local up [--whatsapp-owner N] [--whatsapp-allow N,N] [--modules m,m] [--port-offset N] | down [--wipe]" ;;
  esac
}
