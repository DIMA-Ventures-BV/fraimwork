# shellcheck shell=bash disable=SC2034,SC2154
load_group repo sync tailscale

# --- setup: finish everything that is still open, in order ---------------------------
# Safe to run again and again: each step checks first and skips what is done. It stops at
# the first step only a human can do (exit 3); after that step, run it again.
setup_step() { say "== $*"; }

cmd_setup() {
  parse_flags "$@"
  load_config
  local profiles
  if [ "$FRAIM_ACCESS" = tailscale ]; then
    setup_step "Tailscale policy"
    local s port blocked=""
    for s in main $(list_spaces); do
      port="$( FRAIM_SPACE="$s"; apply_space; space_get SSH_PORT 2222 )"
      port_open "$FRAIM_HOST" "$port" || blocked="$blocked $s:$port"
    done
    if [ -n "$blocked" ]; then
      say "Not reachable from this laptop:$blocked"
      ts_apply ""
    else
      say "ok, every space is reachable"
    fi

    setup_step "Public SSH closed"
    if admin "test -f .public-ssh-locked"; then say "ok"; else cmd_lock; fi
  fi

  setup_step "Claude login (space $FRAIM_SPACE)"
  if server_logged_in; then
    say "ok"
  elif [ "$FRAIM_SPACE" != main ] && [ "$FRAIM_ACCESS" != local ] && ( login_from_space main ) 2>/dev/null; then
    :
  else
    cmd_login
  fi

  if [ -z "$(flag no-full-login)" ] && [ "$FRAIM_ACCESS" != local ]; then
    setup_step "Full Claude login: Remote Control and claude.ai connectors (space $FRAIM_SPACE)"
    if has_full_login; then say "ok"; else login_full_start; fi
  fi

  profiles="$(remote_env COMPOSE_PROFILES)"
  case ",$profiles," in
    *,sync,*)
      setup_step "File sync with this laptop (space $FRAIM_SPACE)"
      sync_pair
      ;;
  esac

  setup_step "Claude config on this laptop"
  if "$REPO/bin/fraim-config" status >/dev/null 2>&1; then
    say "ok"
  else
    local tries=0
    case ",$profiles," in
      *,sync,*)
        until [ -d "$HOME/fraim/claude" ]; do
          tries=$((tries + 1))
          [ "$tries" -lt 30 ] || die "$HOME/fraim/claude has not arrived from the server yet; Syncthing is still copying. Run fraim setup again in a few minutes."
          sleep 2
        done
        ;;
    esac
    "$REPO/bin/fraim-config" init --role laptop
  fi

  local repos repo
  repos="$(flag repo)"
  if [ -n "$repos" ]; then
    setup_step "GitHub repositories (space $FRAIM_SPACE)"
    secret_has_key github || cmd_repo token --owner "${repos%%/*}"
    for repo in ${repos//,/ }; do
      if workspace_ssh 'fraim-repo list --json' 2>/dev/null | jq -e --arg r "$repo" 'any(.[]; .remote | ascii_downcase | test("[/:]" + ($r | ascii_downcase) + "(\\.git)?$"))' >/dev/null; then
        say "ok, $repo"
      else
        workspace_ssh "fraim-repo add $(printf '%q' "$repo")"
      fi
    done
  fi

  setup_step "Health"
  workspace_ssh fraim-doctor || true
  say "Setup of space $FRAIM_SPACE is complete."
}
