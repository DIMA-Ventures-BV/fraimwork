# shellcheck shell=bash disable=SC2034,SC2154
SPACE_MAX=4

# Sets KEY=VALUE in the selected space's env file (on the server or the laptop).
put_env() {
  case "$2" in *[\\\|$'\n']*) usage "the value for $1 may not contain backslashes, | or line breaks" ;; esac
  if [ "$FRAIM_ACCESS" = local ]; then env_set "$1" "$2"; return; fi
  # The temp copy holds tokens: private (umask 077) and named outside the .env.space-* glob.
  admin "umask 077 && t=\$(mktemp .fraim-put-env.XXXXXX) && awk -v k=$(printf '%q' "$1") -v v=$(printf '%q' "$2") 'BEGIN { done = 0 } index(\$0, k \"=\") == 1 { print k \"=\" v; done = 1; next } { print } END { if (!done) print k \"=\" v }' $REMOTE_ENV > \"\$t\" && cat \"\$t\" > $REMOTE_ENV; rc=\$?; rm -f \"\$t\"; exit \$rc"
}

# Starts (or restarts with new settings) the selected space and waits for its workspace.
space_up() {
  if [ "$FRAIM_ACCESS" = local ]; then
    local output rc=0
    output="$(docker compose -p "$LOCAL_PROJECT" --env-file "$ENV_FILE" up -d --build --remove-orphans --quiet-pull 2>&1)" || rc=$?
    if [ "$rc" != 0 ]; then printf '%s\n' "$output" | tail -15 >&2; die "starting space $FRAIM_SPACE failed (exit $rc)"; fi
  else
    admin "grep -q 'start_space' install.sh" \
      || die "the server runs a fraimwork version without spaces; update it first: fraim update"
    local saved="$COMPOSE_ARGS"
    COMPOSE_ARGS=""
    ADMIN_TIMEOUT=3600 run_logged space admin "./install.sh --space $FRAIM_SPACE" || { COMPOSE_ARGS="$saved"; die "starting space $FRAIM_SPACE failed on the server"; }
    COMPOSE_ARGS="$saved"
  fi
  wait_for_workspace || die "space $FRAIM_SPACE started, but its workspace does not answer on port $FRAIM_SSH_PORT; check: fraim logs workspace --space $FRAIM_SPACE"
}

# KEY=VALUE lines of the main space that a new space copies or builds on.
MAIN_KEYS='SSH_PORT|MOSH_PORTS|VNC_PORT|SYNC_GUI_PORT|SYNC_PORT|PREVIEW_PORTS|ACCESS_MODE|BIND_IP|PRIVATE_BIND_IP|TZ|FRAIM_HOSTNAME|FRAIM_IMAGE_TAG|FRAIM_VERSION|FRAIM_COMMIT|FRAIM_RELEASES_REPO|AUTO_CONFIRM_CHANNEL|WHATSAPP_OWNER|PORT_OFFSET|VOICE'

# space_env_text NAME INDEX MODULES OWNER, with the main space's values on stdin.
space_env_text() {
  local name="$1" n="$2" modules="$3" owner="$4" main k
  main="$(cat)"
  m() { local v; v="$(printf '%s\n' "$main" | grep -E "^$1=" | tail -1 | cut -d= -f2-)"; printf '%s' "${v:-$2}"; }
  local ssh vnc sgui sport mosh preview access host b
  ssh="$(m SSH_PORT 2222)"; vnc="$(m VNC_PORT 6080)"; sgui="$(m SYNC_GUI_PORT 8384)"; sport="$(m SYNC_PORT 22000)"
  mosh="$(m MOSH_PORTS 60000-60010)"; mosh="${mosh%%-*}"
  preview="$(m PREVIEW_PORTS 3100-3109)"; preview="${preview%%-*}"
  access="$(m ACCESS_MODE public)"; host="$(m FRAIM_HOSTNAME fraim)"
  k=$(( $(m PORT_OFFSET 0) / 100 ))
  b=$(( n * 50 + k * 5 ))
  local view
  case "$access" in
    tailscale) view="http://$host:$((vnc + n))/vnc.html" ;;
    local) view="http://localhost:$((vnc + n))/vnc.html" ;;
    *) view="http://localhost:$((vnc + n))/vnc.html (run 'fraim browser --space $name' to open the tunnel)" ;;
  esac
  cat <<EOF
# fraimwork space "$name", made by 'fraim space add'. Same keys as the main .env.
FRAIM_SPACE=$name
SPACE_INDEX=$n
COMPOSE_PROFILES=$modules
ACCESS_MODE=$access
FRAIM_HOSTNAME=$host
SYNC_DEVICE_NAME=$host-$name
TZ=$(m TZ Europe/Amsterdam)
BIND_IP=$(m BIND_IP 127.0.0.1)
PRIVATE_BIND_IP=$(m PRIVATE_BIND_IP 127.0.0.1)
SSH_PORT=$((ssh + n))
MOSH_PORTS=$((mosh + 20 * n))-$((mosh + 20 * n + 10))
VNC_PORT=$((vnc + n))
SYNC_GUI_PORT=$((sgui + n))
SYNC_PORT=$((sport + n))
PREVIEW_PORTS=$((preview + 10 * n))-$((preview + 10 * n + 9))
FRAIM_SUBNET=172.29.$b.0/24
BROWSER_IP=172.29.$b.10
FRAIM_SUBNET_WA=172.29.$((b + 1)).0/24
FRAIM_SUBNET_SYNC=172.29.$((b + 2)).0/24
FRAIM_SUBNET_SECRETS=172.29.$((b + 3)).0/24
FRAIM_SUBNET_SECRETS_OUT=172.29.$((b + 4)).0/24
BROWSER_VIEW_URL=$view
WHATSAPP_OWNER=$owner
WHATSAPP_ALLOW=
AUTO_CONFIRM_CHANNEL=$(m AUTO_CONFIRM_CHANNEL 1)
MCP_DENY=
CLAUDEAI_CONNECTORS=on
GATEWAY_TOKEN=$(openssl rand -hex 24)
REPLY_TOKEN=$(openssl rand -hex 24)
VNC_PASSWORD=$(openssl rand -hex 4)
SYNCTHING_GUI_PASSWORD=$(openssl rand -hex 12)
SECRETS_TOKEN=$(openssl rand -hex 32)
EOF
  for k in FRAIM_IMAGE_TAG FRAIM_VERSION FRAIM_COMMIT FRAIM_RELEASES_REPO VOICE; do
    [ -z "$(m "$k" "")" ] || printf '%s=%s\n' "$k" "$(m "$k" "")"
  done
}

space_add() {
  local name="$1" modules owner existing n used
  [ -n "$name" ] || usage "fraim space add NAME [--modules scheduler,browser] [--whatsapp-owner N]"
  valid_space "$name" || usage "a space name is lowercase letters, digits and dashes (at most 16), starting with a letter"
  [ "$name" != main ] || usage "'main' is the first space; it always exists"
  existing="$(list_spaces)"
  if printf '%s\n' "$existing" | grep -qx "$name"; then
    say "Space $name already exists; starting it."
  else
    [ "$(printf '%s\n' "$existing" | grep -c .)" -lt "$SPACE_MAX" ] || usage "a server holds at most $((SPACE_MAX + 1)) spaces (main plus $SPACE_MAX)"
    modules="$(flag modules)"; modules="${modules:-scheduler}"
    check_modules "$modules"
    [ "$FRAIM_ACCESS" != local ] || case ",$modules," in *,sync,*) usage "file sync is not part of the local test stack" ;; esac
    owner=""
    if [ -n "$(flag whatsapp-owner)" ]; then owner="$(normalize_phone "$(flag whatsapp-owner)")" || exit 2; fi
    # Indexes in use: read each space's SPACE_INDEX.
    used=""
    local s
    for s in $existing; do
      used="$used $(FRAIM_SPACE="$s"; apply_space; space_info SPACE_INDEX)"
    done
    n=""
    for i in $(seq 1 "$SPACE_MAX"); do
      case " $used " in *" $i "*) ;; *) n="$i"; break ;; esac
    done
    [ -n "$n" ] || die "no free space slot"
    local main
    if [ "$FRAIM_ACCESS" = local ]; then
      main="$(grep -E "^($MAIN_KEYS)=" "$(space_env_local main)" || true)"
    else
      main="$(admin "grep -E '^($MAIN_KEYS)=' .env || true")"
    fi
    if [ -z "$owner" ] && case ",$modules," in *,whatsapp,*) true ;; *) false ;; esac; then
      owner="$(printf '%s\n' "$main" | grep -E '^WHATSAPP_OWNER=' | tail -1 | cut -d= -f2- || true)"
      [ -n "$owner" ] || usage "the whatsapp module needs --whatsapp-owner"
    fi
    local text
    text="$(printf '%s\n' "$main" | space_env_text "$name" "$n" "$modules" "$owner")"
    if [ "$FRAIM_ACCESS" = local ]; then
      (umask 077 && printf '%s\n' "$text" > "$(space_env_local "$name")")
    else
      printf '%s\n' "$text" | admin_stdin "umask 077 && cat > .env.space-$name"
    fi
    say "Space $name created (modules: $modules)."
  fi
  FRAIM_SPACE="$name"
  apply_space
  space_up
  say "Space $name is running. Use it with --space $name (SSH port $FRAIM_SSH_PORT)."
}

space_rm() {
  local name="$1"
  [ -n "$name" ] && [ "$name" != main ] || usage "fraim space rm NAME [--wipe --yes]; the main space cannot be removed"
  list_spaces | grep -qx "$name" || usage "there is no space '$name'"
  FRAIM_SPACE="$name"
  apply_space
  if [ -z "$(flag wipe)" ]; then
    # STOPPED=1 keeps it stopped through updates and installs, until `fraim space up`.
    put_env STOPPED 1
    ADMIN_TIMEOUT=300 admin "docker compose down"
    say "Space $name is stopped; its files, logins and keys are kept. Start it again with: fraim space up $name"
    return
  fi
  [ -n "$(flag yes)" ] || usage "--wipe deletes the space's files, Claude login, browser profile and keys for good; ask the user, then add --yes"
  ADMIN_TIMEOUT=300 admin "docker compose down -v"
  if [ "$FRAIM_ACCESS" = local ]; then rm -f "$ENV_FILE"; else admin "rm -f $REMOTE_ENV"; fi
  say "Space $name and all its data are deleted."
}

SPACE_MODULES="browser,scheduler,whatsapp,sync,google"
check_modules() {
  local mod
  printf '%s' "$1" | grep -Eq '^([a-z]+)(,[a-z]+)*$' || usage "--modules is a comma list of: $SPACE_MODULES"
  for mod in ${1//,/ }; do
    case ",$SPACE_MODULES," in *,"$mod",*) ;; *) usage "unknown module '$mod'; use $SPACE_MODULES" ;; esac
  done
}

space_policy() {
  local name="$1" changed=""
  [ -n "$name" ] || usage "fraim space policy NAME [--deny 'claude.ai Gmail,NAME'] [--claudeai on|off] [--modules m,m]"
  FRAIM_SPACE="$name"
  apply_space
  if [ -n "$(flag deny)" ]; then
    local deny
    deny="$(flag deny)"
    [ "$deny" != none ] || deny=""
    put_env MCP_DENY "$deny"; changed=1
  fi
  if [ -n "$(flag claudeai)" ]; then
    case "$(flag claudeai)" in on|off) ;; *) usage "--claudeai is on or off" ;; esac
    put_env CLAUDEAI_CONNECTORS "$(flag claudeai)"; changed=1
  fi
  if [ -n "$(flag modules)" ]; then
    check_modules "$(flag modules)"
    case ",$(space_info COMPOSE_PROFILES),:,$(flag modules)," in
      *,google,*:*,google,*) ;;
      *,google,*:*) say "Google is now off for space $name. Its login stays stored; add google to --modules to turn it on again." ;;
    esac
    put_env COMPOSE_PROFILES "$(flag modules)"; changed=1
  fi
  SPACE_INFO=""
  if [ -n "$changed" ]; then
    if [ "$FRAIM_SPACE" = main ] && [ "$FRAIM_ACCESS" != local ]; then
      ADMIN_TIMEOUT=900 run_logged policy admin "docker compose up -d --remove-orphans"
    else
      space_up
    fi
  fi
  jq -n --arg space "$name" --arg deny "$(space_info MCP_DENY)" --arg claudeai "$(space_get CLAUDEAI_CONNECTORS on)" --arg modules "$(space_info COMPOSE_PROFILES)" \
    '{space: $space, modules: ($modules | split(",") | map(select(. != ""))), claudeai_connectors: $claudeai, denied_mcp_servers: ($deny | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")))}'
}

space_list() {
  local s names
  names="main $(list_spaces | tr '\n' ' ')"
  local rows=()
  for s in $names; do
    rows+=("$(
      FRAIM_SPACE="$s"
      apply_space
      ok=false
      if workspace_ssh 'fraim-doctor --json' 2>/dev/null | jq -e .ok >/dev/null 2>&1; then ok=true; fi
      jq -n --arg name "$s" --arg ssh "$FRAIM_SSH_PORT" --arg modules "$(space_info COMPOSE_PROFILES)" --argjson ok "$ok" \
        --arg claudeai "$(space_get CLAUDEAI_CONNECTORS on)" --arg previews "$(space_get PREVIEW_PORTS 3100-3109)" \
        '{name: $name, ssh_port: ($ssh | tonumber), modules: ($modules | split(",") | map(select(. != ""))), healthy: $ok, claudeai_connectors: $claudeai, preview_ports: $previews}'
    )")
  done
  if [ -n "$(flag json)" ]; then
    printf '%s\n' "${rows[@]}" | jq -s .
  else
    printf '%s\n' "${rows[@]}" | jq -r -s '.[] | "\(.name)\tport \(.ssh_port)\t\(if .healthy then "healthy" else "NOT healthy" end)\t\(.modules | join(","))"'
  fi
}

cmd_space() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-list}" name="${POSITIONAL[1]:-}"
  [ "$FRAIM_SPACE" = main ] || usage "name the space after the action (fraim space $action NAME), not with --space"
  load_config
  case "$action" in
    list) space_list ;;
    add) space_add "$name" ;;
    up)
      [ -n "$name" ] || usage "fraim space up NAME"
      FRAIM_SPACE="$name"; apply_space; put_env STOPPED 0; space_up; say "Space $name is running."
      ;;
    rm) space_rm "$name" ;;
    policy) space_policy "$name" ;;
    *) usage "fraim space list [--json] | add NAME [--modules m,m] [--whatsapp-owner N] | up NAME | policy NAME [--deny LIST|none] [--claudeai on|off] [--modules m,m] | rm NAME [--wipe --yes]" ;;
  esac
}
