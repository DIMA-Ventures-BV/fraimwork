# shellcheck shell=bash disable=SC2034,SC2154
load_group space

# One redacted text file with everything needed to debug a server remotely.
cmd_support_bundle() {
  load_config
  mkdir -p "$STATE_DIR"
  local out
  out="$STATE_DIR/support-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "== fraim support bundle $(date -u +%FT%TZ)"
    echo "target=$FRAIM_TARGET access=$FRAIM_ACCESS instance=${FRAIM_INSTANCE:-}"
    echo "repo=$(git -C "$REPO" describe --always --dirty 2>/dev/null || echo unknown)"
    echo; echo "== status"; cmd_status --json 2>&1 || true
    echo; echo "== spaces"; space_list 2>&1 || true
    echo; echo "== versions"; workspace_ssh 'claude --version; node --version; cat /etc/os-release | head -2' 2>&1 || true
    echo; echo "== fraim-config"; workspace_ssh 'fraim-config status' 2>&1 || true
    echo; echo "== automations"; workspace_ssh 'fraim-auto list; fraim-auto check' 2>&1 || true
    echo; echo "== automation crontab"; workspace_ssh 'cat ~/.local/state/fraim/automations.crontab' 2>&1 || true
    echo; echo "== old jobs crontab"; workspace_ssh 'cat ~/fraim/jobs/crontab' 2>&1 || true
    echo; echo "== service logs (last 150 lines each)"; admin "docker compose logs --no-color --tail 150" 2>&1 || true
  } | sed -E \
      -e 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-[REDACTED]/g' \
      -e 's/(Bearer )[A-Za-z0-9._-]+/\1[REDACTED]/g' \
      -e 's/((TOKEN|PASSWORD|AUTHKEY|SECRET|KEY)[A-Z_]*=)[^ ]+/\1[REDACTED]/g' \
      -e 's/\+[0-9][0-9 ()-]{6,}[0-9]/[PHONE]/g' \
      -e 's/(^|[^0-9])[0-9]{10,15}([^0-9]|$)/\1[PHONE]\2/g' \
      -e 's/(^|[^0-9])[0-9]{10,15}([^0-9]|$)/\1[PHONE]\2/g' \
    > "$out"
  say "$out"
  say "This file has passwords, tokens and phone numbers removed. It can be sent to whoever helps you."
}
