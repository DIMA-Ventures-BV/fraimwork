#!/usr/bin/env bats
# The channel seam: fraim-gateway and fraim-notify talk to any service that follows
# docs/channels.md, and fall back to the WhatsApp gateway.

load helper

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  FAKE="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME/fraim" "$FAKE"
  export PATH="$FAKE:$REPO/workspace/bin:$PATH"
  export FRAIM_RUNTIME_ENV="$BATS_TEST_TMPDIR/runtime.env"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  : > "$FRAIM_RUNTIME_ENV"
  : > "$CURL_LOG"
  unset FRAIM_CHANNEL_URL FRAIM_CHANNEL_TOKEN FRAIM_GATEWAY_URL FRAIM_GATEWAY_TOKEN FRAIM_MODULES WHATSAPP_OWNER
  cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit 0
EOF
  chmod +x "$FAKE/curl"
  GATEWAY="$REPO/workspace/bin/fraim-gateway"
  NOTIFY="$REPO/workspace/bin/fraim-notify"
}

runtime() { printf '%s\n' "$@" > "$FRAIM_RUNTIME_ENV"; }

WA=(FRAIM_MODULES=whatsapp FRAIM_GATEWAY_URL=http://whatsapp:8080 FRAIM_GATEWAY_TOKEN=wa-secret)

@test "gateway calls the channel when one is set" {
  runtime "${WA[@]}" FRAIM_CHANNEL_URL=http://telegram:9000 FRAIM_CHANNEL_TOKEN=tg-secret
  run "$GATEWAY" GET /status
  [ "$status" -eq 0 ]
  grep -q 'Bearer tg-secret' "$CURL_LOG"
  grep -q 'http://telegram:9000/status' "$CURL_LOG"
  ! grep -q 'wa-secret' "$CURL_LOG"
}

@test "gateway needs no whatsapp module when a channel is set" {
  runtime FRAIM_MODULES=scheduler FRAIM_CHANNEL_URL=http://telegram:9000 FRAIM_CHANNEL_TOKEN=tg-secret
  run "$GATEWAY" GET /status
  [ "$status" -eq 0 ]
  grep -q 'http://telegram:9000/status' "$CURL_LOG"
}

@test "gateway falls back to the WhatsApp gateway" {
  runtime "${WA[@]}" FRAIM_CHANNEL_URL= FRAIM_CHANNEL_TOKEN=
  run "$GATEWAY" GET /status
  [ "$status" -eq 0 ]
  grep -q 'Bearer wa-secret' "$CURL_LOG"
  grep -q 'http://whatsapp:8080/status' "$CURL_LOG"
}

@test "a channel without a token never gets the WhatsApp token" {
  runtime "${WA[@]}" FRAIM_CHANNEL_URL=http://telegram:9000
  run "$GATEWAY" GET /status
  [ "$status" -eq 2 ]
  [[ "$output" == *FRAIM_CHANNEL_TOKEN* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "without a channel the whatsapp module is still required" {
  runtime FRAIM_MODULES=scheduler FRAIM_GATEWAY_URL=http://whatsapp:8080 FRAIM_GATEWAY_TOKEN=wa-secret
  run "$GATEWAY" GET /status
  [ "$status" -eq 2 ]
  [[ "$output" == *"module is off"* ]]
}

@test "notify sends through the channel without the whatsapp module" {
  runtime FRAIM_MODULES=scheduler FRAIM_CHANNEL_URL=http://telegram:9000 FRAIM_CHANNEL_TOKEN=tg-secret
  FRAIM_NOTIFY_DIRECT=1 run "$NOTIFY" hello
  [ "$status" -eq 0 ]
  grep -q 'http://telegram:9000/send' "$CURL_LOG"
  grep -q 'hello' "$CURL_LOG"
}

@test "notify still goes to the WhatsApp owner by default" {
  runtime "${WA[@]}" WHATSAPP_OWNER=31612345678
  FRAIM_NOTIFY_DIRECT=1 run "$NOTIFY" hello
  [ "$status" -eq 0 ]
  grep -q 'http://whatsapp:8080/send' "$CURL_LOG"
  grep -q '31612345678' "$CURL_LOG"
}

@test "notify without any channel only writes the alert" {
  runtime FRAIM_MODULES=scheduler
  FRAIM_NOTIFY_DIRECT=1 run "$NOTIFY" hello
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_LOG" ]
  grep -q hello "$HOME/fraim/alerts.md"
}

@test "a server can set the channel in its .env" {
  grep -q 'FRAIM_CHANNEL_URL: ${CHANNEL_URL:-}' "$REPO/compose.yaml"
  grep -q 'FRAIM_CHANNEL_TOKEN: ${CHANNEL_TOKEN:-}' "$REPO/compose.yaml"
  grep -q "FRAIM_CHANNEL_URL=%q" "$REPO/workspace/bin/fraim-entrypoint"
  grep -q "FRAIM_CHANNEL_TOKEN=%q" "$REPO/workspace/bin/fraim-entrypoint"
}

@test "the contract names every route a channel must serve" {
  local route
  for route in 'GET /events' 'POST /send' 'POST /send-file' 'GET /status' 'GET /health'; do
    grep -qF "$route" "$REPO/docs/channels.md"
  done
}
