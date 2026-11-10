# shellcheck shell=bash disable=SC2034,SC2154
load_group repo host connect tool

# --- mirror: set up a space from one file -----------------------------------------------
# A mirror file lists what a space needs, one item per line, with no keys in it: keys come
# from this computer (an environment variable or a file in the home folder) when the line
# runs. Every line calls the same building block as the command of that kind, and a line
# that is already done is skipped, so running the file again only does what is missing.
# A mirror file can be shared, so nothing runs before the user has seen the plan (--yes).
# See docs/mirror.md.
MIRROR_KINDS="plugin repo tool env file connect host stdio mcpenv claude"

# Home-folder paths a file line may not read here or write there: login keys, and files
# that control the shell, git, Claude Code or fraim in the space.
mirror_file_allowed() {
  case "$1" in
    .ssh|.ssh/*|.gnupg|.gnupg/*|.claude|.claude/*|.claude.json|.config/fraim|.config/fraim/*) return 1 ;;
    .config/git|.config/git/*|.gitconfig|.local/bin|.local/bin/*) return 1 ;;
    .bashrc|.bash_profile|.bash_login|.profile|.zshrc|.zshenv|.zprofile|.zlogin|.inputrc) return 1 ;;
  esac
}

# mirror_check KIND ARGS...: exit 0 when the line is well formed.
mirror_check() {
  local kind="$1" a; shift
  # The one kind whose arguments are options of the program it starts (npx -y): only safe
  # characters, because they reach a remote shell.
  if [ "$kind" = stdio ]; then
    [ $# -ge 3 ] && printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' || return 1
    case "$2" in npx|uvx|bunx|pnpx) ;; *) return 1 ;; esac
    shift 2
    for a in "$@"; do printf '%s' "$a" | grep -Eq '^[A-Za-z0-9@._:/=+-]+$' || return 1; done
    return 0
  fi
  # No word may look like an option: the words reach the building blocks as arguments.
  for a in "$@"; do case "$a" in -*) return 1 ;; esac; done
  case "$kind" in
    plugin) [ $# -eq 2 ] && printf '%s' "$1" | grep -Eq '^https://[^[:space:]]+$' && printf '%s' "$2" | grep -Eq '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$' ;;
    repo) [ $# -eq 1 ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ;;
    tool) [ $# -ge 1 ] && ! printf '%s\n' "$@" | grep -Evq '^(npm|uv):@?[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)?@[0-9][A-Za-z0-9.+-]*$' ;;
    env) [ $# -eq 1 ] && printf '%s' "$1" | grep -Eq '^[A-Z_][A-Z0-9_]{0,63}$' ;;
    file)
      [ $# -eq 1 ] && printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' || return 1
      case "/$1/" in */../*|*/./*) return 1 ;; esac
      mirror_file_allowed "$1"
      ;;
    connect)
      [ $# -ge 3 ] && printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' && printf '%s' "$2" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$' || return 1
      case "$3" in
        oauth) [ $# -eq 3 ] ;;
        key)
          [ $# -ge 4 ] && [ $# -le 6 ] && printf '%s' "$4" | grep -Eq '^[A-Z_][A-Z0-9_]{0,63}$' || return 1
          [ -z "${5:-}" ] || printf '%s' "$5" | grep -Eq '^[A-Za-z][A-Za-z0-9-]{0,63}$' || return 1
          [ -z "${6:-}" ] || { printf '%s' "$6" | grep -Eq '^[^[:space:]]{1,64}$' && case "$6" in *%s*) true ;; *) false ;; esac; }
          ;;
        claudekey)
          [ $# -ge 4 ] && [ $# -le 5 ] && printf '%s' "$4" | grep -Eq '^[A-Za-z][A-Za-z0-9-]{0,63}$' || return 1
          [ -z "${5:-}" ] || { printf '%s' "$5" | grep -Eq '^[^[:space:]]{1,64}$' && case "$5" in *%s*) true ;; *) false ;; esac; }
          ;;
        *) false ;;
      esac
      ;;
    mcpenv) [ $# -eq 2 ] && printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' && printf '%s' "$2" | grep -Eq '^[A-Z_][A-Z0-9_]{0,63}$' ;;
    claude)
      [ $# -eq 1 ] || return 1
      case "/$1/" in */../*|*/./*) return 1 ;; esac
      [ "$1" = CLAUDE.md ] || printf '%s' "$1" | grep -Eq '^(skills/[A-Za-z0-9._-]+|(commands|agents)/[A-Za-z0-9._-]+\.md)$'
      ;;
    host) [ $# -ge 1 ] && [ $# -le 2 ] && printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,30}$' && printf '%s' "${2:-$1}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' ;;
    *) false ;;
  esac
}

# mirror_plan KIND ARGS...: one line saying what the line does and where keys go.
mirror_plan() {
  local kind="$1"; shift
  case "$kind" in
    plugin) say "plugin  install $2 from $1 (its skills, hooks and MCP servers run in the space)" ;;
    repo) say "repo    clone or fetch $1" ;;
    tool) say "tool    install $*" ;;
    env) say "env     copy \$$1 from this computer into the space (Claude there can read it)" ;;
    file) say "file    copy ~/$1 from this computer into the space (Claude there can read it)" ;;
    connect)
      if [ "$3" = oauth ]; then say "connect add MCP server $1 ($2) and sign in to it"
      elif [ "$3" = claudekey ]; then say "connect add MCP server $1: its key from this computer's Claude goes to $(printf '%s' "$2" | sed -E 's#^https://([^/:]+).*#\1#') with every request"
      else say "connect add MCP server $1: the key in \$$4 goes to $(printf '%s' "$2" | sed -E 's#^https://([^/:]+).*#\1#') with every request"; fi
      ;;
    host) say "host    give the space SSH access to ${2:-$1} as this computer reaches it (adds a key to its authorized_keys)" ;;
    stdio) say "stdio   add MCP server $1: runs ${*:2} in the space" ;;
    mcpenv) say "mcpenv  copy $2 of MCP server $1 from this computer's Claude into the space (Claude there can read it)" ;;
    claude) say "claude  copy ~/.claude/$1 from this computer into the space, when the space has none" ;;
  esac
}

claude_dir() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
claude_json() { if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then printf '%s/.claude.json' "$CLAUDE_CONFIG_DIR"; else printf '%s/.claude.json' "$HOME"; fi; }

# A value with something other than white space in it.
mirror_has_value() { [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

# mirror_step KIND ARGS...: runs one line, in a subshell with set -e. Exit 0 done, 4 skipped
# (the last output line says why), 3 a human step, anything else failed.
mirror_step() {
  local kind="$1"; shift
  # Flags of `fraim mirror` itself must not reach the building blocks.
  unset "${!FLAG_@}"
  case "$kind" in
    plugin)
      grep -qxF "$2" <<<"$MIRROR_PLUGINS" && { echo "installed"; return 4; }
      workspace_ssh "claude plugin marketplace add $(printf '%q' "$1") >/dev/null 2>&1; claude plugin install $(printf '%q' "$2")" < /dev/null
      ;;
    repo) cmd_repo add "$1" < /dev/null ;;
    tool)
      local spec missing=()
      for spec in "$@"; do grep -qxF "$spec" <<<"$MIRROR_TOOLS" || missing+=("$spec"); done
      [ "${#missing[@]}" -gt 0 ] || { echo "installed"; return 4; }
      cmd_tool add "${missing[@]}" < /dev/null
      ;;
    env)
      mirror_has_value "${!1:-}" || { echo "not set on this computer"; return 4; }
      local out
      out="$(printenv "$1" | workspace_ssh "fraim-env set $(printf '%q' "$1")")"
      case "$out" in Unchanged*) echo "unchanged"; return 4 ;; esac
      ;;
    file)
      [ -s "$HOME/$1" ] || { echo "not on this computer"; return 4; }
      local out
      out="$(workspace_ssh "fraim-env file $(printf '%q' "$1")" < "$HOME/$1")"
      case "$out" in Unchanged*) echo "unchanged"; return 4 ;; esac
      ;;
    connect)
      if [ "$3" = oauth ]; then
        grep -qxF "$1" <<<"$MIRROR_SIGNED_IN" && { echo "signed in"; return 4; }
        cmd_connect "$1" --url "$2" --oauth < /dev/null
        return
      fi
      if [ "$3" = claudekey ]; then
        grep -qxF "$1" <<<"$MIRROR_CONNECTED" && { echo "connected"; return 4; }
        local claude_extra=(--header "$4")
        [ -z "${5:-}" ] || claude_extra+=(--format "$5")
        jq -e --arg n "$1" --arg h "$4" '.mcpServers[$n].headers[$h] | strings' "$(claude_json)" >/dev/null 2>&1 || { echo "no such key in this computer's Claude"; return 4; }
        jq -j --arg n "$1" --arg h "$4" '.mcpServers[$n].headers[$h] | sub("^Bearer "; "")' "$(claude_json)" | cmd_connect "$1" --url "$2" --key --stdin "${claude_extra[@]}"
        return
      fi
      grep -qxF "$1" <<<"$MIRROR_CONNECTED" && { echo "connected; a new key: fraim connect $1 --url $2 --key"; return 4; }
      mirror_has_value "${!4:-}" || { echo "key $4 not set on this computer"; return 4; }
      local extra=()
      [ -z "${5:-}" ] || extra+=(--header "$5")
      [ -z "${6:-}" ] || extra+=(--format "$6")
      printenv "$4" | cmd_connect "$1" --url "$2" --key --stdin ${extra[@]+"${extra[@]}"}
      ;;
    host)
      workspace_ssh "fraim-hosts test $(printf '%q' "$1")" < /dev/null >/dev/null 2>&1 && { echo "reachable"; return 4; }
      cmd_host add "$1" --like "${2:-$1}" < /dev/null
      ;;
    stdio)
      grep -qxF "$1" <<<"$MIRROR_CONNECTED" && { echo "connected"; return 4; }
      cmd_connect "$1" --command "${*:2}" < /dev/null
      ;;
    mcpenv)
      jq -e --arg n "$1" --arg v "$2" '.mcpServers[$n].env[$v] | strings' "$(claude_json)" >/dev/null 2>&1 || { echo "not on this computer"; return 4; }
      local out
      out="$(jq -j --arg n "$1" --arg v "$2" '.mcpServers[$n].env[$v]' "$(claude_json)" | workspace_ssh "fraim-env set $(printf '%q' "$2")")"
      case "$out" in Unchanged*) echo "unchanged"; return 4 ;; esac
      ;;
    claude)
      local src size
      src="$(claude_dir)"
      [ -e "$src/$1" ] || { echo "not on this computer"; return 4; }
      workspace_ssh "test -e ~/.claude/$(printf '%q' "$1")" < /dev/null && { echo "the space already has one"; return 4; }
      size="$(du -sLk "$src/$1" | cut -f1)"
      [ "$size" -le 20480 ] || { echo "larger than 20 MB"; return 4; }
      COPYFILE_DISABLE=1 tar -C "$src" -chf - "$1" | workspace_ssh "mkdir -p ~/.claude && tar -xf - -C ~/.claude"
      ;;
  esac
}

cmd_mirror() {
  if [ "${1:-}" = scan ]; then
    shift
    exec "$REPO/bin/fraim-scan" "$@"
  fi
  parse_flags "$@"
  local file="${POSITIONAL[0]:-}"
  local usage_line="fraim mirror FILE [--only KIND,KIND...] [--dry-run] [--yes] | scan [--out FILE]   (kinds: $MIRROR_KINDS)"
  [ -n "$file" ] || usage "$usage_line"
  [ -f "$file" ] || usage "no mirror file $file"
  local only k
  only="$(flag only)"
  for k in ${only//,/ }; do
    case " $MIRROR_KINDS " in *" $k "*) ;; *) usage "unknown kind '$k' in --only (kinds: $MIRROR_KINDS)" ;; esac
  done
  # Check every line before anything runs.
  local lines=() raw n=0 bad="" words
  while IFS= read -r raw || [ -n "$raw" ]; do
    n=$((n + 1))
    raw="${raw//$'\r'/}"
    raw="${raw%%#*}"
    read -r -a words <<<"$raw" || true
    [ "${#words[@]}" -gt 0 ] || continue
    if mirror_check "${words[@]}"; then lines+=("${words[*]}"); else bad="$bad
  line $n: ${words[*]}"; fi
  done < "$file"
  [ -z "$bad" ] || usage "these lines in $file are not valid (see docs/mirror.md; no option-like words, no ~/.ssh, ~/.claude or shell files):$bad"
  # ${a[@]+"${a[@]}"}: an empty array under set -u on macOS's bash 3.2.
  local selected=() line
  for line in ${lines[@]+"${lines[@]}"}; do
    k="${line%% *}"
    [ -z "$only" ] || case ",$only," in *",$k,"*) ;; *) continue ;; esac
    selected+=("$line")
  done
  [ "${#selected[@]}" -gt 0 ] || { say "Nothing to do."; return; }
  if [ -n "$(flag dry-run)" ] || [ -z "$(flag yes)" ]; then
    for line in "${selected[@]}"; do
      read -r -a words <<<"$line"
      mirror_plan "${words[@]}"
    done
    [ -n "$(flag dry-run)" ] && return
    human "Show the user the plan above (a mirror file can come from someone else: check where each key goes, and every host line). On yes, Claude runs: fraim mirror $file --yes${only:+ --only $only}$(space_hint)"
  fi
  load_config
  MIRROR_TOOLS="$(workspace_ssh 'fraim-tools list' < /dev/null 2>/dev/null || true)"
  MIRROR_CONNECTED="$(workspace_ssh 'fraim-connect list --json' < /dev/null 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)"
  MIRROR_SIGNED_IN=""
  case " ${selected[*]} " in *" oauth "*)
    MIRROR_SIGNED_IN="$(workspace_ssh 'fraim-connect list' < /dev/null 2>/dev/null | sed -n 's/^\([a-z][a-z0-9-]*\): .* Connected$/\1/p' || true)" ;;
  esac
  MIRROR_PLUGINS="$(workspace_ssh 'jq -r ".plugins // {} | keys[]" ~/.claude/plugins/installed_plugins.json' < /dev/null 2>/dev/null || true)"
  local out rc tmp done=0 skipped=0 failed=0 steps="" reload=""
  tmp="$(mktemp)"
  for line in "${selected[@]}"; do
    read -r -a words <<<"$line"
    # A subshell with set -e, not inside `||` or `if`: there bash ignores set -e, and a
    # failed step would carry on and count as done.
    set +e
    (set -e; mirror_step "${words[@]}") > "$tmp" 2>&1
    rc=$?
    set -e
    out="$(cat "$tmp")"
    case "$rc" in
      0)
        done=$((done + 1)); say "done    $line"
        case "${words[0]}" in env|plugin|mcpenv|claude) reload=1 ;; esac
        ;;
      4) skipped=$((skipped + 1)); say "skip    $line${out:+ ($(printf '%s\n' "$out" | tail -1))}" ;;
      3)
        say "waiting $line"
        steps="$steps
- $(printf '%s\n' "$out" | sed -n 's/^HUMAN STEP: //p' | tail -1)"
        ;;
      *)
        failed=$((failed + 1)); say "failed  $line"
        printf '%s\n' "$out" | tail -3 | sed 's/^/        /' >&2
        ;;
    esac
  done
  rm -f "$tmp"
  # Only when something changed: a reload restarts the space's Claude session.
  [ -z "$reload" ] || workspace_ssh 'fraim-connect reload >/dev/null' < /dev/null || true
  say "Space $FRAIM_SPACE: $done done, $skipped skipped, $failed failed."
  [ -z "$steps" ] || human "Some lines need the user (run ${MIRROR_RERUN:-fraim mirror $file --yes} again afterwards; done lines are skipped):$steps"
  [ "$failed" -eq 0 ] || exit 1
}
