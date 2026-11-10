# shellcheck shell=bash disable=SC2034,SC2154

# API keys for the secrets proxy. Keys go to the secrets container only: the value is read
# hidden (terminal) or from stdin, sent over stdin, and never printed or put in an argument.
cmd_secret() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-}" name="${POSITIONAL[1]:-}" value=""
  local usage_line="fraim secret list | add NAME --upstream https://HOST [--header H] [--format 'Bearer %s'] | set NAME [--stdin] | rm NAME | env NAME [--stdin] | env-rm NAME | file PATH [--stdin]"
  case "$action" in
    list|add|set|rm|env|env-rm|file) ;;
    *) usage "$usage_line" ;;
  esac
  load_config
  case "$action" in
    list)
      attached || admin "docker compose exec -T secrets fraim-secret list"
      local envs
      envs="$(workspace_ssh 'fraim-env list' 2>/dev/null || true)"
      if [ -n "$envs" ]; then
        say ""
        say "Environment keys in space $FRAIM_SPACE (Claude can read these):"
        say "$envs"
      fi
      ;;
    env|file)
      [ -n "$name" ] || usage "$usage_line"
      [ "$action" = env ] || [ -n "$(flag stdin)" ] || usage "fraim secret file PATH --stdin < LOCAL_FILE  (the file's content goes to ~/PATH in the workspace)"
      need_secret_input "In your own Terminal app (not in the Claude chat), run: fraim secret $action $name$(space_hint)  and paste the value. Then tell Claude 'done'."
      if [ -n "$(flag stdin)" ]; then value="$(cat)"; else value="$(read_secret_input "Paste the value for $name")"; fi
      [ -n "$value" ] || usage "no value given for $name"
      if [ "$action" = env ]; then
        printf '%s' "$value" | workspace_ssh "fraim-env set $(printf '%q' "$name")"
        workspace_ssh "fraim-connect reload >/dev/null"
      else
        printf '%s\n' "$value" | workspace_ssh "fraim-env file $(printf '%q' "$name")"
      fi
      ;;
    env-rm)
      [ -n "$name" ] || usage "$usage_line"
      workspace_ssh "fraim-env rm $(printf '%q' "$name") && fraim-connect reload >/dev/null"
      ;;
    add)
      [ -n "$name" ] && [ -n "$(flag upstream)" ] || usage "$usage_line"
      local header format
      header="$(flag header)"; header="${header:-Authorization}"
      format="$(flag format)"; format="${format:-Bearer %s}"
      secret_define "$name" "$(flag upstream)" "$header" "$format"
      say "Added $name ($(flag upstream))."
      ;;
    set)
      [ -n "$name" ] || usage "$usage_line"
      need_secret_input "In your own Terminal app (not in the Claude chat), run: fraim secret set $name$(space_hint)  and paste the key when it asks. Then tell Claude 'done'."
      value="$(read_secret_input "Paste the key for $name")"
      printf '%s' "$value" | secret_store "$name"
      say "Key for $name stored. It is never shown again."
      ;;
    rm)
      [ -n "$name" ] || usage "$usage_line"
      admin "docker compose exec -T secrets fraim-secret rm $(printf '%q' "$name")"
      ;;
  esac
}

# --- secrets helpers for repo and connect -------------------------------------------
gate_file() { printf '%s/%s.gate' "$CONFIG_DIR" "$FRAIM_TARGET"; }
# gate_call REQUEST [with-value]: one request to the secrets gate. With-value: the key is on
# stdin. The token and the key travel on stdin only. Prints what follows "ok".
gate_call() {
  local answer
  [ -s "$(gate_file)" ] || die "no gate token on this computer; ask the person who runs your server for a new invite"
  answer="$( { cat "$(gate_file)"; printf '%s\n' "$1"; if [ -n "${2:-}" ]; then cat; printf '\n'; fi; } | workspace_ssh fraim-gate )" \
    || die "the secrets gate does not answer; the server may need an update (the person who runs your server does this)"
  case "$answer" in
    ok*) printf '%s\n' "${answer#ok }" ;;
    *) die "the secrets gate refused this: ${answer#error }" ;;
  esac
}

secret_define() {  # NAME UPSTREAM HEADER FORMAT
  if attached; then
    gate_call "$(printf 'add\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")" >/dev/null
    return
  fi
  admin "docker compose exec -T secrets fraim-secret add $(printf '%q' "$1") --upstream $(printf '%q' "$2") --header $(printf '%q' "$3") --format $(printf '%q' "$4")" >/dev/null
}
secret_store() {  # NAME, value on stdin
  if attached; then
    gate_call "$(printf 'set\t%s' "$1")" with-value >/dev/null
    return
  fi
  admin_stdin "docker compose exec -T secrets fraim-secret set $(printf '%q' "$1")" >/dev/null
}
secret_has_key() {  # NAME
  if attached; then
    [ "$(gate_call "$(printf 'has\t%s' "$1")")" = yes ]
    return
  fi
  admin "docker compose exec -T secrets fraim-secret list" 2>/dev/null | awk -F'\t' -v n="$1" '$1 == n && $4 == "key set" { found = 1 } END { exit !found }'
}
# A key for this command comes from --stdin or a hidden prompt in a terminal. Without
# either, the human runs the command in their own Terminal: call this first (not inside
# $(...), so the HUMAN STEP line reaches the output), then read_secret_input.
need_secret_input() {  # HUMAN_STEP_TEXT
  [ -n "$(flag stdin)" ] || is_tty || human "$1"
}
read_secret_input() {  # PROMPT
  local value=""
  if [ -n "$(flag stdin)" ]; then
    value="$(cat)"
  else
    read -r -s -p "$1 (it stays hidden), then press Enter: " value
    printf '\n' >&2
  fi
  value="$(printf '%s' "$value" | tr -d '[:space:]')"
  [ -n "$value" ] || usage "nothing was pasted"
  printf '%s' "$value"
}
