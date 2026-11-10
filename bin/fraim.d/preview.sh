# shellcheck shell=bash disable=SC2034,SC2154

# --- preview: dev servers in a space on the phone or laptop ----------------------------
cmd_preview() {
  parse_flags "$@"
  load_config
  local port="${POSITIONAL[0]:-}"
  case "$port" in
    stop) workspace_ssh "fraim-preview stop $(printf '%q' "${POSITIONAL[1]:-all}")"; return ;;
    ""|list) ;;
    *)
      printf '%s' "$port" | grep -Eq '^[0-9]{1,5}$' || usage "fraim preview [PORT] | stop [PORT|all]"
      workspace_ssh "fraim-preview start $port" >/dev/null
      ;;
  esac
  local items
  items="$(workspace_ssh 'fraim-preview list --json')" || die "could not read the previews of space $FRAIM_SPACE"
  if [ "$FRAIM_ACCESS" = public ]; then
    # Public mode publishes previews on the server's 127.0.0.1 only: tunnel each one here
    # and show the local address.
    local start hostport local_port out='[]' item
    start="$(space_get PREVIEW_PORTS 3100-3109)"; start="${start%%-*}"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      hostport="$(printf '%s' "$item" | jq -r '.url | capture(":(?<p>[0-9]+)").p')"
      local_port="$(TUNNEL_TARGET_PORT=$((3100 + hostport - start)) tunnel start "$hostport" 127.0.0.1)"
      out="$(printf '%s' "$out" | jq -c --argjson i "$item" --arg u "http://localhost:$local_port" '. + [$i + {url: $u}]')"
    done < <(printf '%s' "$items" | jq -c '.[]')
    items="$out"
  fi
  if [ -n "$(flag json)" ]; then printf '%s\n' "$items"; return; fi
  if [ "$(printf '%s' "$items" | jq length)" = 0 ]; then say "No previews in space $FRAIM_SPACE. Start one with: fraim preview PORT$(space_hint)"; return; fi
  printf '%s' "$items" | jq -r '.[] | "\(.port)\t\(.url | sub(" \\(on the laptop.*$"; ""))\t\(.label)"'
}
