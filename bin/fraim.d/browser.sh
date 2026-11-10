# shellcheck shell=bash disable=SC2034,SC2154

cmd_chrome() {
  load_config
  local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  case "${1:-status}" in
    start)
      [ -x "$chrome" ] || chrome="$(command -v google-chrome || command -v chromium || true)"
      [ -n "$chrome" ] || human "Install Google Chrome on this computer."
      mkdir -p "$STATE_DIR/chrome-profile"
      bg_start chrome "$chrome" --user-data-dir="$STATE_DIR/chrome-profile" --remote-debugging-port=9222 \
        --no-first-run --no-default-browser-check
      # shellcheck disable=SC2046
      bg_start chrome-tunnel ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:9222:127.0.0.1:9222 $(ssh_opts) "claude@$FRAIM_HOST"
      say "Lending a separate Chrome profile ($STATE_DIR/chrome-profile) to the server as MCP server 'my-chrome'."
      ;;
    stop) bg_stop chrome-tunnel; bg_stop chrome; say "Chrome is no longer lent to the server." ;;
    status) if bg_running chrome-tunnel; then say "lent"; else say "not lent"; fi ;;
    *) usage "fraim chrome start|stop|status" ;;
  esac
}

cmd_browser() {
  parse_flags "$@"
  load_config
  local vnc
  vnc="$(space_get VNC_PORT 6080)"
  case "${POSITIONAL[0]:-open}" in
    stop) tunnel stop "$vnc"; return ;;
    open|start) ;;
    *) usage "fraim browser [--print-url | --url-only] | stop" ;;
  esac
  # Empty means the server could not say; only a known list without the browser is refused.
  local profiles
  profiles="$(remote_env COMPOSE_PROFILES 2>/dev/null || true)"
  case ",$profiles," in
    ,,|*,browser,*) ;;
    *) usage "the server browser is off; switch it on with: fraim space policy ${FRAIM_SPACE:-main} --modules $profiles,browser" ;;
  esac
  local url
  case "$FRAIM_ACCESS" in
    tailscale) url="http://$FRAIM_HOST:$vnc/vnc.html" ;;
    local) url="http://localhost:$vnc/vnc.html" ;;
    *)
      [ -z "$(flag url-only)" ] || die "public mode has no fixed browser URL; use fraim browser --print-url"
      # The tunnel runs through the space's workspace to the browser container on port 6080.
      url="http://localhost:$(TUNNEL_TARGET_PORT=6080 tunnel start "$vnc" "$(space_get BROWSER_IP 172.30.0.10)")/vnc.html"
      ;;
  esac
  # --url-only: a fixed URL for bookmarks and the cmux Dock. No tunnel, no password.
  if [ -n "$(flag url-only)" ]; then say "$url"; return; fi
  open_url "$url"
  say "VNC password: $(remote_env VNC_PASSWORD)"
}
