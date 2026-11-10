# shellcheck shell=bash disable=SC2034,SC2154

cmd_sync() {
  parse_flags "$@"
  load_config
  [ "$FRAIM_ACCESS" != local ] || usage "file sync is not part of the local test stack"
  local gui sport
  gui="$(space_get SYNC_GUI_PORT 8384)"
  sport="$(space_get SYNC_PORT 22000)"
  if [ "${POSITIONAL[0]:-}" = stop ]; then tunnel stop "$gui"; return; fi
  if [ "${POSITIONAL[0]:-}" = pair ]; then sync_pair; return; fi
  local url="http://$FRAIM_HOST:$gui"
  if [ "$FRAIM_ACCESS" = public ]; then url="http://localhost:$(TUNNEL_TARGET_PORT=8384 tunnel start "$gui" syncthing)"; fi
  open_url "$url"
  say "Syncthing GUI user: fraim, password: $(remote_env SYNCTHING_GUI_PASSWORD)"
  say "Server address for the laptop device: tcp://$FRAIM_HOST:$sport"
  [ "$FRAIM_SPACE" = main ] || say "Sync this space into its own laptop folder, for example ~/fraim-$FRAIM_SPACE, never into the main space's ~/fraim."
  command -v syncthing >/dev/null || [ -d /Applications/Syncthing.app ] \
    || say "HUMAN STEP: Install Syncthing on this computer (brew install --cask syncthing) and open it once."
}

# --- sync pair: this laptop's Syncthing <-> the space's Syncthing ------------------------
# Both sides are set up through Syncthing's REST API, so nobody clicks "add device" or
# "share folder". Keys and env files never sync: both folders get a .stignore first.
SYNC_IGNORE='// fraim: keys and env files never sync between laptop and server
(?d).DS_Store
.env
.env.*
secrets.env
*.pem
*.key
id_rsa*
id_ed25519*
'
laptop_st_config() {
  local f
  for f in "${FRAIM_SYNCTHING_CONFIG:-}" "$HOME/Library/Application Support/Syncthing/config.xml" \
           "${XDG_STATE_HOME:-$HOME/.local/state}/syncthing/config.xml" "$HOME/.config/syncthing/config.xml"; do
    [ -n "$f" ] && [ -s "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}
st_local() {  # METHOD PATH [BODY]
  local cfg gui addr key scheme=http
  cfg="$(laptop_st_config)" || return 1
  gui="$(awk '/<gui[ >]/,/<\/gui>/' "$cfg")"
  addr="$(printf '%s\n' "$gui" | sed -n 's:.*<address>\(.*\)</address>.*:\1:p' | head -1)"
  key="$(printf '%s\n' "$gui" | sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' | head -1)"
  if printf '%s' "$gui" | grep -q 'tls="true"'; then scheme=https; fi
  curl -fsSk -X "$1" -H @<(printf 'X-API-Key: %s\n' "$key") ${3:+--data-binary "$3"} "$scheme://$addr/rest/$2"
}
st_server() {  # METHOD PATH [BODY]
  local body=""
  [ -z "${3:-}" ] || body="$(printf '%s' "$3" | base64 | tr -d '\n')"
  # shellcheck disable=SC2016
  admin_stdin "docker compose exec -T syncthing sh -s -- $1 $2 $body" <<'EOF'
key=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' /var/syncthing/config/config.xml)
if [ -n "${3:-}" ]; then printf '%s' "$3" | base64 -d > /tmp/fraim-st-body; fi
curl -fsS -X "$1" -H "X-API-Key: $key" ${3:+--data-binary @/tmp/fraim-st-body} "http://127.0.0.1:8384/rest/$2"
EOF
}
# Adds DEVICE to the folder with this path, or creates the folder (Syncthing's defaults
# plus id, label and path). Prints the folder id.
st_share_folder() {  # st_local|st_server PATH ID LABEL DEVICE
  local st="$1" path="$2" id="$3" label="$4" device="$5" folders existing folder
  folders="$("$st" GET config/folders)" || return 1
  existing="$(jq -r --arg p "$path" '[.[] | select(.path == $p or .path == ($p + "/"))][0].id // empty' <<<"$folders")"
  if [ -n "$existing" ]; then
    id="$existing"
    folder="$(jq --arg p "$path" --arg d "$device" '[.[] | select(.path == $p or .path == ($p + "/"))][0]
      | if any(.devices[]; .deviceID == $d) then . else .devices += [{deviceID: $d}] end' <<<"$folders")"
  else
    jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$folders" >/dev/null && die "a Syncthing folder with id $id already exists at another path; remove it in the Syncthing app first"
    folder="$("$st" GET config/defaults/folder | jq --arg id "$id" --arg l "$label" --arg p "$path" --arg d "$device" \
      '.id = $id | .label = $l | .path = $p | .devices += [{deviceID: $d}]')" || return 1
  fi
  "$st" PUT "config/folders/$id" "$folder" >/dev/null || return 1
  printf '%s' "$id"
}
st_add_device() {  # st_local|st_server DEVICE NAME ADDRESSES_JSON
  local st="$1"
  "$st" GET "config/devices/$2" >/dev/null 2>&1 && return 0
  "$st" PUT "config/devices/$2" "$("$st" GET config/defaults/device | jq --arg d "$2" --arg n "$3" --argjson a "$4" \
    '.deviceID = $d | .name = $n | .addresses = $a')" >/dev/null
}

sync_pair() {
  case ",$(remote_env COMPOSE_PROFILES)," in *,sync,*) ;; *) usage "space $FRAIM_SPACE has no sync module; add it with: fraim space policy $FRAIM_SPACE --modules ..." ;; esac
  laptop_st_config >/dev/null \
    || human "Install Syncthing on this computer (brew install --cask syncthing), open it once, then tell Claude 'done'. Claude runs: fraim sync pair$(space_hint)"
  local laptop_id server_id dir id sport
  laptop_id="$(st_local GET system/status 2>/dev/null | jq -r .myID)" && [ -n "$laptop_id" ] \
    || human "Open the Syncthing app on this computer (it is installed but not running), then tell Claude 'done'."
  server_id="$(st_server GET system/status | jq -r .myID)" && [ -n "$server_id" ] || die "the server's Syncthing does not answer; check: fraim logs syncthing$(space_hint)"
  dir="$(flag dir)"
  if [ -z "$dir" ]; then if [ "$FRAIM_SPACE" = main ]; then dir="$HOME/fraim"; else dir="$HOME/fraim-$FRAIM_SPACE"; fi; fi
  sport="$(space_get SYNC_PORT 22000)"
  id="fraim"; [ "$FRAIM_SPACE" = main ] || id="fraim-$FRAIM_SPACE"

  st_add_device st_server "$laptop_id" "$(hostname -s)" '["dynamic"]' || die "could not add this laptop to the server's Syncthing"
  # shellcheck disable=SC2016
  printf '%s' "$SYNC_IGNORE" | admin_stdin "docker compose exec -T syncthing sh -c 'test -e /var/syncthing/fraim/.stignore || cat > /var/syncthing/fraim/.stignore'" \
    || die "could not write the server's .stignore"
  id="$(st_share_folder st_server /var/syncthing/fraim "$id" "fraim ($FRAIM_TARGET $FRAIM_SPACE)" "$laptop_id")" || die "could not share the server's folder"

  mkdir -p "$dir"
  [ -e "$dir/.stignore" ] || printf '%s' "$SYNC_IGNORE" > "$dir/.stignore"
  st_add_device st_local "$server_id" "fraim $FRAIM_TARGET $FRAIM_SPACE" "[\"tcp://$FRAIM_HOST:$sport\"]" || die "could not add the server to this laptop's Syncthing"
  st_share_folder st_local "$dir" "$id" "fraim ($FRAIM_TARGET $FRAIM_SPACE)" "$server_id" >/dev/null || die "could not share $dir in this laptop's Syncthing"

  local tries=0
  until st_local GET system/connections 2>/dev/null | jq -e --arg d "$server_id" '.connections[$d].connected' >/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      say "Paired, but this laptop has not connected to the server yet (tcp://$FRAIM_HOST:$sport). Check the Tailscale policy (fraim tailscale apply) and run fraim sync pair$(space_hint) again."
      return 1
    fi
    sleep 2
  done
  say "Syncing $dir with the server (folder $id). Keys and env files are ignored on both sides."
}
