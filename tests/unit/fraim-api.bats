#!/usr/bin/env bats
# workspace/bin/fraim-api with a fake curl: the right header and format per service, the token
# never on the command line, and clear errors.

setup() {
  API="$BATS_TEST_DIRNAME/../../workspace/bin/fraim-api"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  export CURL_LOG="$T/curl.args" CURL_STDIN="$T/curl.stdin"
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *_services*)
    printf 'NAME HEADER FORMAT UPSTREAM\nopenai Authorization Bearer %%s https://api.openai.com\nanthropic x-api-key %%s https://api.anthropic.com\n'
    exit 0 ;;
esac
printf '%s\n' "$@" > "$CURL_LOG"
cat > "$CURL_STDIN"
echo '{"ok":true}'
EOF
  chmod +x "$T/bin/curl"
  printf 'FRAIM_SECRETS_URL=http://secrets:8080\nFRAIM_SECRETS_TOKEN=tok123\n' > "$T/runtime.env"
  export PATH="$T/bin:$PATH" FRAIM_RUNTIME_ENV="$T/runtime.env"
  unset FRAIM_SECRETS_URL FRAIM_SECRETS_TOKEN
}

@test "no arguments lists the services" {
  run "$API"
  [ "$status" -eq 0 ]
  [[ "$output" == *"openai Authorization Bearer %s"* ]]
}

@test "Bearer service: token in the header on stdin, never on the command line" {
  run "$API" openai /v1/models
  [ "$status" -eq 0 ]
  [ "$output" = '{"ok":true}' ]
  [ "$(cat "$CURL_STDIN")" = "Authorization: Bearer tok123" ]
  grep -qx 'http://secrets:8080/openai/v1/models' "$CURL_LOG"
  ! grep -q tok123 "$CURL_LOG"
}

@test "custom header and plain format" {
  run "$API" anthropic /v1/messages
  [ "$status" -eq 0 ]
  [ "$(cat "$CURL_STDIN")" = "x-api-key: tok123" ]
}

@test "extra options go to curl" {
  run "$API" openai /v1/chat -X POST -d @body.json
  [ "$status" -eq 0 ]
  grep -qx -- '-X' "$CURL_LOG"
  grep -qx -- '@body.json' "$CURL_LOG"
}

@test "unknown service fails with the next step" {
  run "$API" nosuch /x
  [ "$status" -eq 1 ]
  [[ "$output" == *"fraim secret add nosuch"* ]]
}

@test "bad name or path is a usage error" {
  run "$API" 'Bad;name' /x
  [ "$status" -eq 2 ]
  run "$API" openai v1/models
  [ "$status" -eq 2 ]
}

@test "no proxy settings fails clearly" {
  : > "$T/runtime.env"
  run "$API" openai /v1/models
  [ "$status" -eq 1 ]
  [[ "$output" == *"no secrets proxy settings"* ]]
}
