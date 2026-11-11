# shellcheck shell=bash disable=SC2034,SC2154
# The Herdr app on this computer shows the server's agents live (docs/sessions.md, "Watch them
# in the Herdr app"). This computer reaches the server over SSH, never the reverse.

HERDR_BIN="$HOME/.local/bin"
herdr_hc() { "$HERDR_BIN/hc" "$@"; }
herdr_app() { "$HERDR_BIN/herdr-app" "$@"; }
herdr_machine() { if [ "$FRAIM_SPACE" = main ]; then printf 'fraim'; else printf 'fraim-%s' "$FRAIM_SPACE"; fi; }

herdr_install() {
  [ -x "$HERDR_BIN/herdr-app" ] && [ -x "$HERDR_BIN/hc" ] && return 0
  say "Installing the Herdr app (it also installs herdr-core)..."
  curl -fsSL "${FRAIM_HERDR_INSTALL_URL:-https://releases.herdr.dev/app/install.sh}" | sh || die "the Herdr install failed"
  [ -x "$HERDR_BIN/herdr-app" ] || die "the Herdr install put no herdr-app in $HERDR_BIN"
}

# herdr-app answers only while its window is open.
herdr_open() {
  local i
  herdr_app ls >/dev/null 2>&1 && return 0
  if [ "$(uname -s)" = Darwin ]; then open -a Herdr; else (nohup "$HERDR_BIN/herdr-app" >/dev/null 2>&1 &); fi
  for i in $(seq "${FRAIM_HERDR_WAIT:-30}"); do
    herdr_app ls >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "the Herdr app did not open; open it once by hand, then run: fraim herdr link"
}

herdr_space_id() {
  herdr_app ls 2>/dev/null | jq -r --arg m "$1" '[.spaces[]? | select(.machine == $m and .name == "fraim") | .id] | first // empty' | sed 's|^.*/||'
}

cmd_herdr_link() {
  local machine space
  machine="$(herdr_machine)"
  herdr_install
  # shellcheck disable=SC2046
  if ! herdr_hc machine ls --json 2>/dev/null | jq -e --arg m "$machine" '.machines[]? | select(.name == $m)' >/dev/null; then
    herdr_hc machine add --name "$machine" --via "ssh $(ssh_opts) -o BatchMode=yes claude@$FRAIM_HOST" --json >/dev/null \
      || die "Herdr could not reach the server over SSH; check: fraim status"
  fi
  herdr_open
  space="$(herdr_space_id "$machine")"
  if [ -z "$space" ]; then
    herdr_app "do" space.new --name fraim --machine "$machine" --folder /home/claude/fraim >/dev/null \
      || die "Herdr could not make the fraim space on the server"
    space="$(herdr_space_id "$machine")"
  fi
  [ -n "$space" ] || die "Herdr made no fraim space; run: fraim herdr link"
  printf '%s\n' "$space" | workspace_ssh 'mkdir -p ~/.config/fraim && cat > ~/.config/fraim/herdr-space' \
    || die "could not tell the server which Herdr space to use"
  say "Herdr shows the server as '$machine'. Leads, goals and coding sessions appear in its 'fraim' space while they run."
}

cmd_herdr_unlink() {
  local machine
  machine="$(herdr_machine)"
  workspace_ssh 'rm -f ~/.config/fraim/herdr-space' || die "could not reach the server"
  [ ! -x "$HERDR_BIN/hc" ] || herdr_hc machine rm "$machine" --json >/dev/null 2>&1 || true
  say "Herdr no longer shows this server. Its agents keep running."
}

cmd_herdr() {
  load_config
  case "${1:-}" in
    link) cmd_herdr_link ;;
    unlink) cmd_herdr_unlink ;;
    *) usage "fraim herdr link | unlink   (show the server's agents in the Herdr app on this computer)" ;;
  esac
}
