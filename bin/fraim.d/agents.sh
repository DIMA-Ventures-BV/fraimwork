# shellcheck shell=bash disable=SC2034,SC2154

cmd_ask() {
  parse_flags "$@"
  load_config
  server_logged_in || need_login_step
  local prompt="${POSITIONAL[*]:-}" remote
  [ -n "$prompt" ] || usage 'fraim ask "<prompt>" [--allow "Read,Bash(git:*)"] [--json]'
  remote="cd ~/fraim && fraim-claude -p $(printf '%q' "$prompt")"
  [ -z "$(flag allow)" ] || remote="$remote --allowedTools $(printf '%q' "$(flag allow)")"
  [ -z "$(flag json)" ] || remote="$remote --output-format json"
  workspace_ssh "$remote"
}

cmd_goal() {
  load_config
  local action="${1:-}"
  case "$action" in
    list|"") workspace_ssh "fraim-goal list" ;;
    show|stop|read)
      [ -n "${2:-}" ] || usage "fraim goal $action ID"
      workspace_ssh "fraim-goal $action $(printf '%q' "$2")" ;;
    send)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || usage 'fraim goal send ID "message"'
      workspace_ssh "fraim-goal send $(printf '%q' "$2") $(printf '%q' "${*:3}")" ;;
    attach)
      [ -n "${2:-}" ] || usage "fraim goal attach ID"
      cmd_shell "$2" ;;
    *)
      server_logged_in || need_login_step
      workspace_ssh "fraim-goal start -- $(printf '%q' "$*")" ;;
  esac
}

# Coding sessions on the server: live Claude Code sessions in a repo under ~/code.
cmd_session() {
  load_config
  local action="${1:-list}"
  case "$action" in
    list|ls) workspace_ssh "fraim-sessions list" ;;
    all) workspace_ssh "fraim-herdr ls" ;;
    new)
      [ -n "${2:-}" ] || usage 'fraim session new REPO ["task"]'
      server_logged_in || need_login_step
      workspace_ssh "fraim-sessions new $(printf '%q' "$2") -- $(printf '%q' "${*:3}")" ;;
    send)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || usage 'fraim session send ID "message"'
      workspace_ssh "fraim-sessions send $(printf '%q' "$2") $(printf '%q' "${*:3}")" ;;
    read|stop)
      [ -n "${2:-}" ] || usage "fraim session $action ID"
      workspace_ssh "fraim-sessions $action $(printf '%q' "$2")" ;;
    attach)
      [ -n "${2:-}" ] || usage "fraim session attach ID"
      cmd_shell "$2" ;;
    *) usage 'fraim session [list | all | new REPO ["task"] | send ID "message" | read ID | attach ID | stop ID]' ;;
  esac
}

cmd_auto() {
  load_config
  local action="${1:-list}" a remote="fraim-auto"
  case "$action" in
    run|fire) server_logged_in || need_login_step ;;
  esac
  for a in "$@"; do remote="$remote $(printf '%q' "$a")"; done
  workspace_ssh "$remote"
}

# Every Claude session on the server lives in a herdr terminal (docs/sessions.md): main,
# goals (g3), coding sessions (s1); any other name is a plain shell that stays.
cmd_shell() {
  load_config
  is_tty || usage "fraim shell is interactive and for humans; use 'fraim exec' or 'fraim ask' instead"
  local session="${1:-main}" remote mosh_ports
  printf '%s' "$session" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,31}$' || usage "fraim shell [main|g3|s1|NAME]"
  remote="fraim-herdr attach $session"
  if command -v mosh >/dev/null && [ "$FRAIM_ACCESS" != local ]; then
    mosh_ports="$(space_get MOSH_PORTS 60000-60010)"
    exec mosh --ssh="ssh $(ssh_opts)" --port="${mosh_ports/-/:}" "claude@$FRAIM_HOST" -- sh -c "$remote"
  fi
  # shellcheck disable=SC2046
  exec ssh -t $(ssh_opts) "claude@$FRAIM_HOST" "$remote"
}
