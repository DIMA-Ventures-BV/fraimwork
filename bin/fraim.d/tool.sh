# shellcheck shell=bash disable=SC2034,SC2154

# --- tool: extra command-line tools for a space ---------------------------------------
cmd_tool() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-}"
  local usage_line="fraim tool add npm:PACKAGE@VERSION|uv:PACKAGE@VERSION ... | list | rm NAME | sync"
  load_config
  case "$action" in
    add)
      [ "${#POSITIONAL[@]}" -gt 1 ] || usage "$usage_line"
      local spec quoted=""
      for spec in "${POSITIONAL[@]:1}"; do
        printf '%s' "$spec" | grep -Eq '^(npm|uv):@?[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)?@[0-9][A-Za-z0-9.+-]*$' \
          || usage "'$spec' is not npm:PACKAGE@VERSION or uv:PACKAGE@VERSION (an exact version)"
        quoted="$quoted $(printf '%q' "$spec")"
      done
      workspace_ssh "fraim-tools add$quoted"
      ;;
    list) workspace_ssh 'fraim-tools list' ;;
    rm)
      [ -n "${POSITIONAL[1]:-}" ] || usage "$usage_line"
      workspace_ssh "fraim-tools rm $(printf '%q' "${POSITIONAL[1]}")"
      ;;
    sync) workspace_ssh 'fraim-tools sync' ;;
    *) usage "$usage_line" ;;
  esac
}
