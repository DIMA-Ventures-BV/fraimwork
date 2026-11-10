# shellcheck shell=bash disable=SC2034,SC2154
load_group space secret

# Gmail, Drive and Calendar as an MCP server in the space's own google container. It does
# not depend on the Claude account, so any agent can use it. See docs/google.md.
cmd_google() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-}"
  local usage_line="fraim google setup --email YOU@DOMAIN [--file client_secret.json | --stdin] | code [--stdin] | status | signout | push --topic projects/P/topics/T --subscription projects/P/subscriptions/S [--file key.json | --stdin] | push --off"
  case "$action" in setup|code|status|signout|push) ;; *) usage "$usage_line" ;; esac
  local client="" redirect="" key=""
  if [ "$action" = push ] && [ -z "$(flag off)" ]; then
    [ -n "$(flag topic)" ] && [ -n "$(flag subscription)" ] || usage "$usage_line"
    if [ -n "$(flag file)" ]; then
      [ -s "$(flag file)" ] || die "no file at $(flag file)"
      key="$(cat "$(flag file)")"
    elif [ -n "$(flag stdin)" ]; then
      key="$(cat)"
    else
      usage "give the service account key: --file key.json"
    fi
  fi
  if [ "$action" = setup ]; then
    printf '%s' "$(flag email)" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' || usage "$usage_line"
    if [ -n "$(flag file)" ]; then
      [ -s "$(flag file)" ] || die "no file at $(flag file)"
      client="$(cat "$(flag file)")"
    elif [ -n "$(flag stdin)" ]; then
      client="$(cat)"
    else
      usage "give the downloaded OAuth client file: --file ~/Downloads/client_secret_....json"
    fi
  fi
  if [ "$action" = code ]; then
    need_secret_input "In your own Terminal app (not in the Claude chat), run: fraim google code$(space_hint)  and paste the full address from the browser's address bar (it starts with http://localhost:8000). Then tell Claude 'done'."
    redirect="$(read_secret_input "Paste the full address from the browser's address bar")"
  fi
  load_config
  case "$action" in
    setup)
      local modules
      modules="$(space_info COMPOSE_PROFILES)"
      case ",$modules," in
        *,google,*) ;;
        *) put_env COMPOSE_PROFILES "${modules:+$modules,}google" ;;
      esac
      say "Starting the google container (the first build takes a few minutes)."
      ADMIN_TIMEOUT=1200 admin "docker compose up -d --build google" >/dev/null || die "starting the google container failed; check: fraim logs google$(space_hint)"
      printf '%s' "$client" | admin_stdin "docker compose exec -T google fraim-google set-client $(printf '%q' "$(flag email)")"
      workspace_ssh "fraim-connect internal google http://google:8000/mcp && fraim-connect reload >/dev/null"
      say "Google is set up for space $FRAIM_SPACE. Ask the agent to search your Gmail: it shows a Google sign-in link. After you approve, the browser shows an error page on localhost:8000. Copy that address and run in your own Terminal: fraim google code$(space_hint)"
      ;;
    code)
      printf '%s\n' "$redirect" | admin_stdin "docker compose exec -T google fraim-google callback"
      ;;
    status) admin "docker compose exec -T google fraim-google status" ;;
    signout) admin "docker compose exec -T google fraim-google signout" ;;
    push)
      if [ -n "$(flag off)" ]; then
        admin "docker compose exec -T google fraim-google clear-push"
      else
        printf '%s' "$key" | admin_stdin "docker compose exec -T google fraim-google set-push $(printf '%q' "$(flag topic)") $(printf '%q' "$(flag subscription)")"
      fi
      ;;
  esac
}
