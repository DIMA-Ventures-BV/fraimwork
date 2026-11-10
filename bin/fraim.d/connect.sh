# shellcheck shell=bash disable=SC2034,SC2154
load_group secret

# --- connect: MCP servers for a space -------------------------------------------------
# The port of a localhost redirect_uri in an OAuth link, or nothing.
oauth_callback_port() {
  printf '%s' "$1" | sed -nE 's#.*redirect_uri=http(%3A|:)(%2F%2F|//)(localhost|127\.0\.0\.1)(%3A|:)([0-9]{1,5})([^0-9].*)?$#\5#p' | head -1
}
# oauth_tunnel_start NAME PORT: forward localhost:PORT here to localhost:PORT in the
# workspace for 15 minutes (a sign-in that is never finished cleans itself up).
oauth_tunnel_start() {
  port_free "$2" || return 1
  bg_stop "$1"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC2046
  nohup ssh -o ExitOnForwardFailure=yes -L "127.0.0.1:$2:127.0.0.1:$2" $(ssh_opts) "claude@$FRAIM_HOST" 'sleep 900' >"$RUN_DIR/$1.log" 2>&1 &
  echo $! > "$RUN_DIR/$1.pid"
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    port_free "$2" || return 0
    bg_running "$1" || break
    sleep 1
  done
  bg_stop "$1"
  return 1
}
open_browser() {
  if command -v open >/dev/null; then open "$1" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null; then xdg-open "$1" >/dev/null 2>&1 || true; fi
}

cmd_connect() {
  parse_flags "$@"
  local name="${POSITIONAL[0]:-}"
  local usage_line="fraim connect NAME --url https://HOST/PATH [--key [--header H --format F] [--stdin] | --oauth] | NAME --command 'CMD ARGS' | NAME --finish | NAME --redirect | rm NAME | list [--json]"
  [ -n "$name" ] || usage "$usage_line"
  # A key on stdin is read before anything else can touch stdin.
  local piped_key=""
  if [ -n "$(flag stdin)" ] && { [ -n "$(flag key)" ] || [ -n "$(flag redirect)" ]; }; then
    piped_key="$(read_secret_input "")"
  fi
  load_config
  case "$name" in
    list)
      if [ -n "$(flag json)" ]; then workspace_ssh 'fraim-connect list --json'; else workspace_ssh 'fraim-connect list'; fi
      return
      ;;
    rm)
      local target="${POSITIONAL[1]:-}"
      [ -n "$target" ] || usage "$usage_line"
      # Delete the key too, but only when this MCP server used it through the proxy (a key
      # added with `fraim secret add` for something else stays).
      local via_proxy=""
      if workspace_ssh 'fraim-connect list --json' 2>/dev/null \
        | jq -e --arg n "$target" 'map(select(.name == $n and ((.url // "") | startswith("http://secrets:8080/" + $n + "/")))) | length > 0' >/dev/null 2>&1; then
        via_proxy=1
      fi
      workspace_ssh "fraim-connect rm $(printf '%q' "$target") && fraim-connect reload >/dev/null"
      if [ -n "$via_proxy" ] && admin "docker compose exec -T secrets fraim-secret list" 2>/dev/null | awk -F'\t' -v n="$target" '$1 == n { f = 1 } END { exit !f }'; then
        admin "docker compose exec -T secrets fraim-secret rm $(printf '%q' "$target")" >/dev/null
        say "Removed $target and its key from space $FRAIM_SPACE."
      fi
      return
      ;;
  esac
  printf '%s' "$name" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' || usage "NAME must be lowercase letters, digits and dashes, starting with a letter"
  case "$name" in
    github|github-api|github-mcp|browser|my-chrome|whatsapp|google) usage "'$name' is used by fraim itself (fraim repo, fraim google, the browser or WhatsApp); pick another name" ;;
  esac
  local qname
  qname="$(printf '%q' "$name")"
  local tunnel_name="oauth-$FRAIM_TARGET-$FRAIM_SPACE-$name"
  if [ -n "$(flag finish)" ]; then
    if workspace_ssh "fraim-tty wait mcp-$name 'success|authenticated|signed in|connected' 10"; then
      bg_stop "$tunnel_name"
      workspace_ssh "fraim-tty stop mcp-$name; fraim-connect reload >/dev/null"
      say "$name is signed in for space $FRAIM_SPACE. The Claude session restarts with it."
      return
    fi
    workspace_ssh "fraim-tty show mcp-$name | tail -8" >&2 || true
    die "the sign-in for $name is not finished: click Approve in the browser and run this again, or paste the address with: fraim connect $name --redirect$(space_hint)"
  fi
  if [ -n "$(flag redirect)" ]; then
    bg_stop "$tunnel_name"
    local redirect
    need_secret_input "In your own Terminal app (not in the Claude chat), run: fraim connect $name --redirect$(space_hint)  and paste the full address from the browser's address bar. Then tell Claude 'done'."
    redirect="${piped_key:-$(read_secret_input "Paste the full address from the browser's address bar")}"
    printf '%s\n' "$redirect" | workspace_ssh "fraim-tty send mcp-$name" || die "no sign-in for $name is waiting; start again with: fraim connect $name --url URL --oauth$(space_hint)"
    if workspace_ssh "fraim-tty wait mcp-$name 'success|authenticated|signed in|connected' 30"; then
      workspace_ssh "fraim-tty stop mcp-$name; fraim-connect reload >/dev/null"
      say "$name is signed in for space $FRAIM_SPACE. The Claude session restarts with it."
      return
    fi
    workspace_ssh "fraim-tty show mcp-$name | tail -8" >&2 || true
    die "the sign-in for $name did not finish; the screen above shows why"
  fi
  if [ -n "$(flag command)" ]; then
    # shellcheck disable=SC2086  # the command is split into words on purpose
    workspace_ssh "fraim-connect stdio $qname -- $(flag command) && fraim-connect reload >/dev/null"
    return
  fi
  local url
  url="$(flag url)"
  printf '%s' "$url" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$' || usage "$usage_line"
  if [ -n "$(flag key)" ]; then
    local upstream path header format
    upstream="$(printf '%s' "$url" | sed -E 's#^(https://[^/]+).*#\1#')"
    path="${url#"$upstream"}"; path="${path:-/}"
    header="$(flag header)"; header="${header:-Authorization}"
    format="$(flag format)"; format="${format:-Bearer %s}"
    secret_define "$name" "$upstream" "$header" "$format"
    if ! secret_has_key "$name" || [ -n "$(flag stdin)" ]; then
      need_secret_input "In your own Terminal app (not in the Claude chat), run: fraim connect $name --url $url --key$( [ "$header" = Authorization ] || printf ' --header %s' "$header")$( [ "$format" = 'Bearer %s' ] || printf " --format '%s'" "$format")$(space_hint)  and paste the key for $name. Then tell Claude 'done'."
      local key
      key="${piped_key:-$(read_secret_input "Paste the key for $name")}"
      printf '%s' "$key" | secret_store "$name"
    fi
    workspace_ssh "fraim-connect proxied $qname $(printf '%q' "$path") && fraim-connect reload >/dev/null"
    say "$name works in space $FRAIM_SPACE through the secrets proxy; Claude never sees its key."
    return
  fi
  workspace_ssh "fraim-connect http $qname $(printf '%q' "$url")"
  if [ -n "$(flag oauth)" ]; then
    local link
    link="$(workspace_ssh "fraim-connect login $qname")" || die "could not start the sign-in for $name"
    # The provider sends the browser to localhost:PORT, where `claude mcp login` listens
    # inside the workspace. With the same port tunneled from this computer, the browser
    # lands on the server by itself and nobody copies an address.
    local port
    port="$(oauth_callback_port "$link")"
    if [ -n "$port" ] && oauth_tunnel_start "$tunnel_name" "$port"; then
      [ -n "$(flag print-url)" ] || open_browser "$link"
      human "Sign in to $name in the browser and click Approve: $link  Then tell Claude 'done'; Claude then runs: fraim connect $name --finish$(space_hint)"
    fi
    human "Open this link and sign in to $name: $link  The browser then goes to an address that may not load; that is fine. Copy the full address from the address bar, then in your own Terminal app run: fraim connect $name --redirect$(space_hint)  and paste it. Then tell Claude 'done'."
  fi
  workspace_ssh "fraim-connect reload >/dev/null"
  say "$name is connected in space $FRAIM_SPACE."
}
