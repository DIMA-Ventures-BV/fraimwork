# shellcheck shell=bash disable=SC2034,SC2154

cmd_whatsapp() {
  parse_flags "$@"
  load_config
  local status rc=0
  local off_hint="the whatsapp module is off; add it with: fraim local up --whatsapp-owner N (local) or --modules ...,whatsapp in fraim init + fraim deploy (server)"
  case "${POSITIONAL[0]:-status}" in
    status)
      workspace_ssh 'fraim-gateway GET /status' || rc=$?
      [ "$rc" != 2 ] || usage "$off_hint"
      [ "$rc" = 0 ] || die "the WhatsApp gateway is not reachable (exit $rc)"
      ;;
    link)
      status="$(workspace_ssh 'fraim-gateway GET /status')" || rc=$?
      [ "$rc" != 2 ] || usage "$off_hint"
      [ "$rc" = 0 ] || die "the WhatsApp gateway is not reachable (exit $rc)"
      if printf '%s' "$status" | grep -q '"connected":true'; then say "WhatsApp is already linked."; return; fi
      if [ -n "$(flag number)" ]; then
        local code
        local bot owner
        bot="$(normalize_phone "$(flag number)")" || exit 2
        owner="$(remote_env WHATSAPP_OWNER)"
        [ "$bot" != "$owner" ] || usage "the agent needs its own second number; $bot is the owner's personal number"
        code="$(workspace_ssh "fraim-gateway POST /pair '{\"number\":\"$bot\"}'" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')"
        [ -n "$code" ] || die "could not get a pairing code"
        human "On the phone with the agent's WhatsApp Business account: Settings > Linked devices > Link a device > 'Link with phone number instead', and enter code $code. The code works for about 1 minute; if it fails, tell Claude and it gets a new one."
      fi
      mkdir -p "$STATE_DIR"
      workspace_ssh 'fraim-gateway GET /qr.png' > "$STATE_DIR/whatsapp-qr.png" || die "no QR code yet; run this again in 10 seconds"
      human "Scan the QR code in $STATE_DIR/whatsapp-qr.png with the agent's WhatsApp Business app: Settings > Linked devices > Link a device. It expires in about 20 seconds; use --number <agent number> for a code that lasts longer."
      ;;
    relink)
      admin "docker compose stop whatsapp && docker compose run --rm --no-deps --entrypoint sh whatsapp -c 'rm -rf /data/auth/* /data/qr.png' && docker compose up -d whatsapp"
      say "WhatsApp session removed. Run: fraim whatsapp link --number <agent number>"
      ;;
    groups)
      status="$(workspace_ssh 'fraim-gateway GET /groups')" || rc=$?
      [ "$rc" != 2 ] || usage "$off_hint"
      [ "$rc" = 0 ] || die "could not list the groups (exit $rc): $status"
      jq -r 'if length == 0 then "The agent number is in no group yet. Add it to a group in WhatsApp first." else .[] | "\(if .open then "listens " else "closed  " end) \(.id)  \(.name)" end' <<<"$status"
      ;;
    listen)
      local target="${POSITIONAL[1]:-}" current next
      [ -n "$target" ] || usage "fraim whatsapp listen GROUP_ID | all | off   (fraim whatsapp groups shows the ids)"
      case "$target" in
        all | off) next="$target" ;;
        *@g.us)
          current="$(remote_env WHATSAPP_GROUPS)"
          next="$(printf '%s' "${current},${target}" | tr ',' '\n' | grep -E '@g\.us$' | sort -u | paste -sd, -)"
          ;;
        *) usage "a group id ends in @g.us; fraim whatsapp groups shows them" ;;
      esac
      [ "$next" != off ] || next=""
      if [ "$FRAIM_ACCESS" = local ]; then env_set WHATSAPP_GROUPS "$next"; else
        admin "if grep -q '^WHATSAPP_GROUPS=' $REMOTE_ENV; then sed -i 's|^WHATSAPP_GROUPS=.*|WHATSAPP_GROUPS=$next|' $REMOTE_ENV; else echo 'WHATSAPP_GROUPS=$next' >> $REMOTE_ENV; fi"
      fi
      admin "docker compose up -d whatsapp" >/dev/null
      say "WhatsApp now listens in: ${next:-no group}. Allowed numbers in those groups reach Claude, and its answers go back to the group."
      ;;
    test) workspace_ssh "fraim-notify 'fraim test message: WhatsApp works.'" && say "Test message sent to the owner." ;;
    check)
      local tries=0
      until status="$(workspace_ssh 'fraim-gateway GET /status')" && jq -e '.connected and .listeners > 0 and .queued == 0' <<<"$status" >/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt "${FRAIM_WHATSAPP_CHECK_TRIES:-30}" ] || die "WhatsApp does not reach Claude: $status"
        sleep "${FRAIM_WHATSAPP_CHECK_WAIT:-3}"
      done
      say "WhatsApp is linked, Claude listens, and no message waits."
      ;;
    *) usage "fraim whatsapp status | link [--number N] | relink | groups | listen GROUP_ID|all|off | test | check" ;;
  esac
}
