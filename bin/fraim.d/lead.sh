# shellcheck shell=bash disable=SC2034,SC2154

cmd_lead() {
  load_config
  [ $# -gt 0 ] || set -- list
  case "$1" in
    new|list|show|run|pause|resume|tell|ask|events|rename) ;;
    *) usage 'fraim lead new NAME [--area TEXT] [--at "CRON"] [--budget N] [--chief|--engineer] [--off] | list | show NAME | run NAME | tell NAME -- TEXT | ask [NAME] -- TEXT | events NAME [--off] | pause NAME | resume NAME | rename OLD NEW' ;;
  esac
  [ "$1" != run ] || server_logged_in || need_login_step
  workspace_ssh "fraim-lead $(printf '%q ' "$@")"
}

cmd_brain() {
  load_config
  case "${1:-show}" in
    show|history|undo|distill|stats) workspace_ssh "fraim-brain $1" ;;
    note) shift; [ $# -gt 0 ] || usage 'fraim brain note "TEXT"'; workspace_ssh "fraim-brain note $(printf '%q' "$*")" ;;
    why|forget) [ $# -eq 2 ] || usage "fraim brain $1 rN"; workspace_ssh "fraim-brain $1 $(printf '%q' "$2")" ;;
    skills) workspace_ssh "fraim-brain skill list" ;;
    *) usage 'fraim brain [show | note "TEXT" | why rN | forget rN | undo | history | stats | distill | skills]' ;;
  esac
}
