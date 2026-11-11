# shellcheck shell=bash disable=SC2034,SC2154

# --- queue: the owner's questions and answers; the questions themselves come in chat ----------
cmd_queue() {
  parse_flags "$@"
  load_config
  local action="${POSITIONAL[0]:-open}"
  case "$action" in
    keep|app) queue_leftovers ;;
    open|url)
      local url start token
      url="$(workspace_ssh 'fraim-queue url')" || die "could not read the settings link of space $FRAIM_SPACE"
      # Public mode publishes the page on the server's 127.0.0.1 only, and a tailnet policy
      # may not open the preview ports: then tunnel the page through SSH, which always works.
      if [ "$FRAIM_ACCESS" = public ] || ! curl -fsS -o /dev/null --max-time 4 "${url%%\?*}health" 2>/dev/null; then
        start="$(space_get PREVIEW_PORTS 3100-3109)"; start="${start%%-*}"
        token="$(workspace_ssh 'fraim-queue token')" || die "could not read the settings link of space $FRAIM_SPACE"
        url="http://localhost:$(TUNNEL_TARGET_PORT=3109 tunnel start "$((start + 9))" 127.0.0.1)/?t=$token"
      fi
      if [ "$action" = url ]; then say "$url"; else open_url "$url"; fi
      ;;
    list) workspace_ssh "fraim-queue list$( [ -z "$(flag all)" ] || printf ' --all')" ;;
    show|dismiss)
      [ -n "${POSITIONAL[1]:-}" ] || usage "fraim queue $action ID"
      workspace_ssh "fraim-queue $action $(printf '%q' "${POSITIONAL[1]}")" ;;
    approve|reject)
      [ -n "${POSITIONAL[1]:-}" ] || usage "fraim queue $action ID [NOTE]"
      workspace_ssh "fraim-queue $action $(printf '%q' "${POSITIONAL[1]}") --note $(printf '%q' "${POSITIONAL[*]:2}")" ;;
    *) usage "fraim queue [open|url|list [--all]|show ID|approve ID [NOTE]|reject ID NOTE|dismiss ID]" ;;
  esac
}

# The queue page, its kept tunnel and "Fraim Queue.app" are gone: the chief asks in chat now.
# This removes what an older fraim left on the Mac.
queue_leftovers() {
  local label app="$HOME/Applications/Fraim Queue.app"
  label="nl.fraim.queue.$FRAIM_TARGET"
  if [ "$(uname -s)" = Darwin ]; then
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
    pkill -f "$app/Contents/MacOS/" 2>/dev/null || true
    rm -rf "$app"
  fi
  say "The queue page and app are gone: the chief asks you everything in chat now. Settings: fraim queue open"
}
