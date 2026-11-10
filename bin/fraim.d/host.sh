# shellcheck shell=bash disable=SC2034,SC2154

# --- host: SSH access from a space to another machine ---------------------------------
cmd_host() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-list}" name="${POSITIONAL[1]:-}"
  local usage_line="fraim host add NAME (--like SSH_ALIAS | --address HOST [--user USER] [--port PORT]) [--authorize-via SSH_ALIAS] | test NAME | list [--json] | rm NAME [--authorize-via SSH_ALIAS]"
  load_config
  case "$action" in
    add)
      local address user port alias="" known="" like
      address="$(flag address)"; user="$(flag user)"; port="$(flag port)"
      like="$(flag like)"
      if [ -n "$like" ]; then
        # The same host as this computer's `ssh ALIAS`: its address, user, port and the host
        # keys this computer already trusts. The space still gets its own key.
        printf '%s' "$like" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || usage "--like must be a host name from your ~/.ssh/config"
        local cfg
        cfg="$(ssh -G -- "$like" 2>/dev/null)" || die "ssh on this computer does not know host $like"
        # ssh -G answers for any name. Without the config files it gives the defaults; when
        # both agree, ~/.ssh/config says nothing about this name.
        local bare g k
        bare="$(ssh -F /dev/null -G -- "$like" 2>/dev/null || true)"
        g=""
        for k in hostname user port hostkeyalias proxyjump; do
          [ "$(ssh_g_value "$cfg" "$k")" = "$(ssh_g_value "$bare" "$k")" ] || g=1
        done
        [ -n "$g" ] || die "this computer has no host $like in ~/.ssh/config; add it there, or use: fraim host add $name --address HOST --user USER"
        address="${address:-$(ssh_g_value "$cfg" hostname)}"
        user="${user:-$(ssh_g_value "$cfg" user)}"
        port="${port:-$(ssh_g_value "$cfg" port)}"
        alias="$(ssh_g_value "$cfg" hostkeyalias)"
        known="$(laptop_known_hosts "$cfg" "$address" "${port:-22}")"
        [ -n "$known" ] || say "Note: this computer has no known host key for $like, so the space trusts the key it sees first." >&2
        # shellcheck disable=SC2034  # read through flag authorize-via below
        [ -n "$(flag authorize-via)" ] || FLAG_AUTHORIZE_VIA="$like"
      fi
      [ -n "$name" ] && [ -n "$address" ] || usage "$usage_line"
      local args pub line via
      args="--address $(printf '%q' "$address")"
      [ -z "$user" ] || args="$args --user $(printf '%q' "$user")"
      [ -z "$port" ] || args="$args --port $(printf '%q' "$port")"
      [ -z "$alias" ] || args="$args --host-key-alias $(printf '%q' "$alias")"
      if [ -n "$known" ]; then
        pub="$(printf '%s\n' "$known" | workspace_ssh "fraim-hosts add $(printf '%q' "$name") $args --known-hosts-stdin")" || exit $?
      else
        pub="$(workspace_ssh "fraim-hosts add $(printf '%q' "$name") $args" < /dev/null)" || exit $?
      fi
      # No agent or X11 forwarding for this key; port forwarding stays (dev tools tunnel ports).
      line="no-agent-forwarding,no-X11-forwarding $pub"
      via="$(flag authorize-via)"
      if [ -n "$via" ]; then
        # shellcheck disable=SC2029  # expanded on purpose: the key line is quoted with %q
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$via" "k=$(printf '%q' "$line"); mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF \"\$k\" ~/.ssh/authorized_keys || printf '%s\n' \"\$k\" >> ~/.ssh/authorized_keys; }" \
          || die "could not add the key on $via from this computer; check that 'ssh $via' works here"
      fi
      if workspace_ssh "fraim-hosts test $(printf '%q' "$name")" 2>/dev/null; then
        say "Space $FRAIM_SPACE reaches $name: ssh $name, rsync and similar tools work there."
        return
      fi
      if tailnet_address "$address"; then
        human "Space $FRAIM_SPACE cannot reach $name ($address): it is a Tailscale address, and the tailnet policy keeps fraim servers away from other devices. Ask the user whether this server may reach $name. On yes, Claude runs: fraim tailscale reach TAG_OR_ADDRESS (the tag of $name in the Tailscale admin, for example tag:prod), then: fraim host test $name$(space_hint)"
      fi
      [ -z "$via" ] || die "the key is on $via, but space $FRAIM_SPACE still cannot log in to $name ($address); check the address, user and port, and that the host accepts SSH from the server"
      human "Add this line to ~/.ssh/authorized_keys of user $(printf '%s' "$user" | grep . || echo '<user>') on $address, then tell Claude 'done' (Claude then runs: fraim host test $name$(space_hint)): $line"
      ;;
    test)
      [ -n "$name" ] || usage "$usage_line"
      workspace_ssh "fraim-hosts test $(printf '%q' "$name")" && say "Space $FRAIM_SPACE reaches $name."
      ;;
    list) if [ -n "$(flag json)" ]; then workspace_ssh 'fraim-hosts list --json'; else workspace_ssh 'fraim-hosts list'; fi ;;
    rm)
      [ -n "$name" ] || usage "$usage_line"
      local pub=""
      pub="$(workspace_ssh "cat ~/.ssh/fraim-hosts/$(printf '%q' "$name").pub" 2>/dev/null || true)"
      workspace_ssh "fraim-hosts rm $(printf '%q' "$name")" >/dev/null
      if [ -n "$(flag authorize-via)" ] && [ -n "$pub" ]; then
        local keypart
        keypart="$(printf '%s' "$pub" | awk '{print $2}')"
        # shellcheck disable=SC2029
        # Only replace authorized_keys when grep ran cleanly (exit 0 or 1), never with a partial copy.
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$(flag authorize-via)" "f=\$HOME/.ssh/authorized_keys; [ -f \"\$f\" ] || exit 0; umask 077; grep -vF $(printf '%q' "$keypart") \"\$f\" > \"\$f.fraim-tmp\"; rc=\$?; if [ \$rc -le 1 ]; then cat \"\$f.fraim-tmp\" > \"\$f\"; rm -f \"\$f.fraim-tmp\"; else rm -f \"\$f.fraim-tmp\"; exit 1; fi" \
          || die "removed the host from space $FRAIM_SPACE, but could not remove its key on $(flag authorize-via)"
        say "Removed host $name from space $FRAIM_SPACE and its key from $(flag authorize-via)."
      else
        say "Removed host $name from space $FRAIM_SPACE. Its key line (fraim-$FRAIM_SPACE-$name) may still be in the host's authorized_keys."
      fi
      ;;
    *) usage "$usage_line" ;;
  esac
}

# One value from `ssh -G` output (lowercase keys), or nothing.
ssh_g_value() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }
# The known_hosts lines this computer has for the host, from the files `ssh -G` lists. ssh
# looks a HostKeyAlias up as it is, without the port; otherwise NAME, or [NAME]:PORT.
laptop_known_hosts() {  # SSH_G_OUTPUT NAME PORT
  local key="$2" f files
  [ "$3" = 22 ] || key="[$2]:$3"
  [ -z "$(ssh_g_value "$1" hostkeyalias)" ] || key="$(ssh_g_value "$1" hostkeyalias)"
  files="$(ssh_g_value "$1" userknownhostsfile)"
  for f in $files; do
    f="${f/#\~/$HOME}"
    [ -f "$f" ] || continue
    ssh-keygen -F "$key" -f "$f" 2>/dev/null | grep -v '^#' || true
  done | awk 'NF && !seen[$0]++'
}
tailnet_address() {  # 100.64.0.0/10 or a MagicDNS name
  case "$1" in *.ts.net) return 0 ;; esac
  printf '%s' "$1" | awk -F. 'NF == 4 && $1 == 100 && $2 >= 64 && $2 <= 127 { ok = 1 } END { exit !ok }'
}
