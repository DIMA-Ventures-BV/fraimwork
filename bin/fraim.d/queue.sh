# shellcheck shell=bash disable=SC2034,SC2154

# --- queue and leads: the owner's review queue and the lead agents ---------------------
cmd_queue() {
  parse_flags "$@"
  load_config
  local action="${POSITIONAL[0]:-open}"
  case "$action" in
    keep) queue_keep ;;
    app) queue_app ;;
    open|url)
      local url start token
      # A kept tunnel (fraim queue keep) answers on a fixed port; the browser has the cookie.
      if [ -f "$(queue_keep_plist)" ] && curl -fsS -o /dev/null --max-time 3 "http://localhost:$(queue_keep_port)/health" 2>/dev/null; then
        token="$(workspace_ssh 'fraim-queue token')" || die "could not read the queue of space $FRAIM_SPACE"
        url="http://localhost:$(queue_keep_port)/?t=$token"
        if [ "$action" = url ]; then say "$url"; else open_url "$url"; fi
        return 0
      fi
      url="$(workspace_ssh 'fraim-queue url')" || die "could not read the queue of space $FRAIM_SPACE"
      # Public mode publishes the page on the server's 127.0.0.1 only, and a tailnet policy
      # may not open the preview ports: then tunnel the page through SSH, which always works.
      if [ "$FRAIM_ACCESS" = public ] || ! curl -fsS -o /dev/null --max-time 4 "${url%%\?*}health" 2>/dev/null; then
        start="$(space_get PREVIEW_PORTS 3100-3109)"; start="${start%%-*}"
        token="$(workspace_ssh 'fraim-queue token')" || die "could not read the queue of space $FRAIM_SPACE"
        url="http://localhost:$(TUNNEL_TARGET_PORT=3109 tunnel start "$((start + 9))" 127.0.0.1)/?t=$token"
      fi
      if [ "$action" = url ]; then say "$url"; else open_url "$url"; fi
      ;;
    list) workspace_ssh "fraim-queue list$( [ -z "$(flag all)" ] || printf ' --all')" ;;
    show|dismiss)
      [ -n "${POSITIONAL[1]:-}" ] || usage "fraim queue $action ID"
      workspace_ssh "fraim-queue $action $(printf '%q' "${POSITIONAL[1]}")" ;;
    approve|reject)
      [ -n "${POSITIONAL[1]:-}" ] || usage "fraim queue $action ID [NOTE]"
      workspace_ssh "fraim-queue $action $(printf '%q' "${POSITIONAL[1]}") --note $(printf '%q' "${POSITIONAL[*]:2}")" ;;
    *) usage "fraim queue [open|url|keep [--port N] [--off]|app [--off]|list [--all]|show ID|approve ID [NOTE]|reject ID NOTE|dismiss ID]" ;;
  esac
}

# fraim queue app: "Fraim Queue.app" in ~/Applications, a native Mac app (desktop/queue, built
# here with swiftc): its own window, the inbox count on the Dock icon and a notice for each new
# item. It wakes the kept tunnel itself. Without swiftc (no Command Line Tools) the app opens
# the page in Chrome's app mode instead.
queue_app() {
  [ "$(uname -s)" = Darwin ] || die "fraim queue app needs macOS"
  local app="$HOME/Applications/Fraim Queue.app" port token tmp
  if [ -n "$(flag off)" ]; then rm -rf "$app"; say "Removed $app."; return 0; fi
  [ -f "$(queue_keep_plist)" ] || queue_keep >/dev/null
  port="$(queue_keep_port)"
  token="$(workspace_ssh 'fraim-queue token')" || die "could not read the queue of space $FRAIM_SPACE"
  pkill -f "$app/Contents/MacOS/" 2>/dev/null || true
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  if command -v swiftc >/dev/null && [ -f "$REPO/desktop/queue/main.swift" ]; then
    queue_app_native "$app" "$port" "$token"
  else
    queue_app_chrome "$app" "$port" "$token"
  fi
  queue_app_icon "$app"
  [ ! -x /usr/bin/codesign ] || codesign --force --deep -s - "$app" >/dev/null 2>&1 || true
  touch "$app"
  say "Made $app. Open it from Spotlight (Cmd+Space, type Fraim Queue) or drag it to the Dock. Remove: fraim queue app --off"
}

queue_app_plist() {
  cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Fraim Queue</string>
  <key>CFBundleDisplayName</key><string>Fraim Queue</string>
  <key>CFBundleIdentifier</key><string>$(queue_keep_label).app</string>
  <key>CFBundleExecutable</key><string>fraim-queue</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Dictate a message to an agent.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Dictate a message to an agent.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF
}

queue_app_native() {
  local app="$1" port="$2" token="$3" log
  queue_app_plist "$app"
  ( umask 077; printf 'http://localhost:%s/?t=%s\n' "$port" "$token" > "$app/Contents/Resources/queue.url" )
  printf '%s\n' "$(queue_keep_label)" > "$app/Contents/Resources/queue.label"
  log="$(mktemp)"
  if ! swiftc -O -o "$app/Contents/MacOS/fraim-queue" "$REPO/desktop/queue/main.swift" >"$log" 2>&1; then
    printf 'fraim: swiftc could not build the native app (%s); making the Chrome version\n' "$(head -1 "$log")" >&2
    rm -f "$log" "$app/Contents/Resources/queue.url" "$app/Contents/Resources/queue.label"
    queue_app_chrome "$app" "$port" "$token"
    return 0
  fi
  rm -f "$log"
}

queue_app_chrome() {
  local app="$1" port="$2" token="$3"
  queue_app_plist "$app"
  cat > "$app/Contents/MacOS/fraim-queue" <<EOF
#!/bin/sh
# Made by: fraim queue app. Wakes the tunnel, then opens the queue page in its own window.
launchctl kickstart "gui/\$(id -u)/$(queue_keep_label)" >/dev/null 2>&1
i=0
while [ \$i -lt 20 ] && ! curl -fsS -o /dev/null --max-time 1 http://localhost:$port/health; do i=\$((i + 1)); sleep 0.5; done
url="http://localhost:$port/?t=$token"
if [ -d "/Applications/Google Chrome.app" ]; then
  exec open -na "Google Chrome" --args --app="\$url" --window-size=1440,900
fi
exec open "\$url"
EOF
  chmod 700 "$app/Contents/MacOS/fraim-queue"
}

# The icon: the page's own mark, drawn large and turned into an .icns with the macOS tools.
queue_app_icon() {
  local app="$1" tmp
  tmp="$(mktemp -d)"
  printf '%s' "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1024 1024'><rect x='64' y='64' width='896' height='896' rx='200' fill='#5e6ad2'/><rect x='256' y='288' width='512' height='96' rx='48' fill='#fff'/><rect x='256' y='480' width='384' height='96' rx='48' fill='#fff' opacity='.8'/><rect x='256' y='672' width='256' height='96' rx='48' fill='#fff' opacity='.55'/></svg>" > "$tmp/icon.svg"
  if qlmanage -t -s 1024 -o "$tmp" "$tmp/icon.svg" >/dev/null 2>&1 && [ -f "$tmp/icon.svg.png" ]; then
    mkdir -p "$tmp/icon.iconset"
    local s
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$tmp/icon.svg.png" --out "$tmp/icon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
      sips -z $((s * 2)) $((s * 2)) "$tmp/icon.svg.png" --out "$tmp/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$tmp/icon.iconset" -o "$app/Contents/Resources/icon.icns" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}

# fraim queue keep: a launchd agent on the Mac keeps an SSH tunnel to the queue page open on a
# fixed port, through logins, sleep and server restarts, so http://localhost:PORT always works.
queue_keep_label() { printf 'nl.fraim.queue.%s' "$FRAIM_TARGET"; }
queue_keep_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(queue_keep_label)"; }
queue_keep_port() {
  local p
  p="$(sed -n 's/.*127\.0\.0\.1:\([0-9]*\):127\.0\.0\.1:3109.*/\1/p' "$(queue_keep_plist)" 2>/dev/null | head -1)"
  printf '%s' "${p:-3109}"
}
queue_keep() {
  [ "$(uname -s)" = Darwin ] || die "fraim queue keep needs macOS (launchd); on other systems use: fraim queue open"
  local plist label port token arg args=()
  plist="$(queue_keep_plist)"; label="$(queue_keep_label)"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  if [ -n "$(flag off)" ]; then
    rm -f "$plist"
    say "The queue page is no longer kept open on this Mac."
    return 0
  fi
  port="$(flag port)"; port="${port:-3109}"
  printf '%s' "$port" | grep -Eq '^[0-9]{4,5}$' || usage "--port must be a port number like 3109"
  tunnel stop 3109 >/dev/null 2>&1 || true
  port_free "$port" || die "port $port is in use on this Mac; pick another one: fraim queue keep --port 3209"
  token="$(workspace_ssh 'fraim-queue token')" || die "could not read the queue of space $FRAIM_SPACE"
  # shellcheck disable=SC2046
  set -- ssh -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$port:127.0.0.1:3109" $(ssh_opts) "claude@$FRAIM_HOST"
  for arg in "$@"; do args+=("    <string>$(printf '%s' "$arg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>"); done
  mkdir -p "$(dirname "$plist")" "$RUN_DIR"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>Label</key>\n  <string>%s</string>\n  <key>ProgramArguments</key>\n  <array>\n' "$label"
    printf '%s\n' "${args[@]}"
    printf '  </array>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <true/>\n  <key>ThrottleInterval</key>\n  <integer>10</integer>\n'
    printf '  <key>StandardErrorPath</key>\n  <string>%s/queue-keep.log</string>\n</dict>\n</plist>\n' "$RUN_DIR"
  } > "$plist"
  launchctl bootstrap "gui/$(id -u)" "$plist" || die "launchd did not take $plist"
  local i=0
  until curl -fsS -o /dev/null --max-time 3 "http://localhost:$port/health" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 15 ] || die "the tunnel did not come up; see $RUN_DIR/queue-keep.log"
    sleep 1
  done
  open_url "http://localhost:$port/?t=$token"
  say "The queue page now stays open at http://localhost:$port, also after a restart of this Mac or the server. Bookmark it. Undo: fraim queue keep --off"
}
