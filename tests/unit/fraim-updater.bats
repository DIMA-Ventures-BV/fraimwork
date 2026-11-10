#!/usr/bin/env bats
# bin/fraim-updater with a fake GitHub (curl), Docker and install.sh, and real signatures:
# which release it picks, when it runs, what it keeps, how it rolls back and recovers.

setup() {
  UPD="$BATS_TEST_DIRNAME/../../bin/fraim-updater"
  T="$BATS_TEST_TMPDIR"
  export T
  mkdir -p "$T/bin" "$T/dl"
  export FRAIM_UPDATER_DIR="$T/opt" FRAIM_UPDATER_STATE="$T/state" FRAIM_UPDATER_SIGNERS="$T/signers"
  export FRAIM_UPDATER_NOW=1800000000 FRAIM_UPDATER_HOUR=4
  export FRAIM_UPDATER_SETTLE=0 FRAIM_UPDATER_TRIES=1 FRAIM_UPDATER_POLL=0
  mkdir -p "$FRAIM_UPDATER_DIR/config"
  printf 'FRAIM_VERSION=v1.0.0\nFRAIM_COMMIT=aaa\nSECRET=keep-me\n' > "$FRAIM_UPDATER_DIR/.env"
  echo 'ssh-ed25519 KEEP' > "$FRAIM_UPDATER_DIR/config/authorized_keys"
  echo old > "$FRAIM_UPDATER_DIR/code.txt"
  echo stale > "$FRAIM_UPDATER_DIR/removed-in-release.txt"
  write_install "$FRAIM_UPDATER_DIR"

  ssh-keygen -q -t ed25519 -N '' -C test -f "$T/key"
  printf 'fraim-release %s\n' "$(cut -d' ' -f1,2 "$T/key.pub")" > "$T/signers"

  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$T/curl-fail" ] || exit 22
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *api.github.com*) cat "$T/feed.json" ;;
  *) f="$T/dl/$(basename "$url")"; [ -f "$f" ] || exit 22; cp "$f" "$out" ;;
esac
EOF
  cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/docker.log"
case "$*" in
  *fraim-doctor*)
    v="$(grep '^FRAIM_VERSION=' "$FRAIM_UPDATER_DIR/.env" | cut -d= -f2)"
    if [ -f "$T/doctor.$v" ]; then cat "$T/doctor.$v"; else echo '{"checks":[]}'; fi ;;
  *"fraim-goal list"*) cat "$T/goals" 2>/dev/null ;;
  *fraim-notify*) printf '%s\n' "$*" >> "$T/notify.log" ;;
esac
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/flock"
  chmod +x "$T/bin/curl" "$T/bin/docker" "$T/bin/flock"
  export PATH="$T/bin:$PATH"
  echo '[]' > "$T/feed.json"
}

write_install() {
  cat > "$1/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s lock=%s\n' "$(grep '^FRAIM_VERSION=' .env | cut -d= -f2)" "${FRAIM_LOCK_HELD:-}" >> "$T/install.log"
[ ! -e "$T/install-fail.$(grep '^FRAIM_VERSION=' .env | cut -d= -f2)" ] || exit 1
EOF
  chmod +x "$1/install.sh"
}

# release VERSION [SIGNING_KEY]: a signed tarball in the fake download folder.
release() {
  local v="$1" key="${2:-$T/key}" d="$T/build-$1"
  mkdir -p "$d/config"
  echo "$v" > "$d/code.txt"
  printf 'version=%s\ncommit=commit-%s\n' "$v" "$v" > "$d/RELEASE"
  write_install "$d"
  tar -czf "$T/dl/fraimwork-$v.tar.gz" -C "$d" .
  rm -f "$T/dl/fraimwork-$v.tar.gz.sig"
  ssh-keygen -q -Y sign -f "$key" -n fraim-release "$T/dl/fraimwork-$v.tar.gz"
}

# feed "v1.1.0 HOURS_OLD" ...: what the GitHub API lists.
feed() {
  local out='[]' spec
  for spec in "$@"; do
    set -- $spec
    out="$(jq --arg t "$1" --argjson at "$((FRAIM_UPDATER_NOW - $2 * 3600))" \
      '. + [{tag_name: $t, draft: false, prerelease: false, published_at: ($at | todateiso8601)}]' <<<"$out")"
  done
  printf '%s' "$out" > "$T/feed.json"
}

env_of() { grep "^$1=" "$FRAIM_UPDATER_DIR/.env" | tail -1 | cut -d= -f2-; }
set_var() { printf '%s=%s\n' "$1" "$2" >> "$FRAIM_UPDATER_DIR/.env"; }
set_version() { sed "s/^FRAIM_VERSION=.*/FRAIM_VERSION=$1/" "$FRAIM_UPDATER_DIR/.env" > "$T/e" && cat "$T/e" > "$FRAIM_UPDATER_DIR/.env"; }

# --- choosing a release

@test "check picks the highest published version on the canary ring" {
  set_var UPDATE_RING canary
  feed "v1.1.0 1" "v1.10.0 0" "v1.9.0 2"
  run "$UPD" check
  [ "$status" -eq 0 ]
  [ "$output" = "available v1.10.0" ]
}

@test "check ignores drafts, prereleases and odd tags" {
  set_var UPDATE_RING canary
  cat > "$T/feed.json" <<EOF
[{"tag_name":"v9.0.0","draft":true,"prerelease":false,"published_at":"2020-01-01T00:00:00Z"},
 {"tag_name":"v8.0.0","draft":false,"prerelease":true,"published_at":"2020-01-01T00:00:00Z"},
 {"tag_name":"latest","draft":false,"prerelease":false,"published_at":"2020-01-01T00:00:00Z"},
 {"tag_name":"v7.0.0-rc1","draft":false,"prerelease":false,"published_at":"2020-01-01T00:00:00Z"},
 {"tag_name":"v1.2.0","draft":false,"prerelease":false,"published_at":"2020-01-01T00:00:00Z"}]
EOF
  run "$UPD" check
  [ "$output" = "available v1.2.0" ]
}

@test "the stable ring holds a release for 24 hours" {
  feed "v1.1.0 23"
  run "$UPD" check
  [ "$output" = "held v1.1.0" ]
  feed "v1.1.0 25"
  run "$UPD" check
  [ "$output" = "available v1.1.0" ]
}

@test "a hand-deployed build is reported and left alone" {
  feed "v2.0.0 100"
  set_version abc123
  run "$UPD" check
  [ "$output" = "dev-build" ]
  set_version v1.2.3-4-gabc
  run "$UPD" check
  [ "$output" = "dev-build" ]
  set_version v1.0.0
  sed "s/^FRAIM_COMMIT=.*/FRAIM_COMMIT=aaa-dirty/" "$FRAIM_UPDATER_DIR/.env" > "$T/e" && cat "$T/e" > "$FRAIM_UPDATER_DIR/.env"
  run "$UPD" check
  [ "$output" = "dev-build" ]
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
}

@test "AUTO_UPDATE=off is reported" {
  set_var AUTO_UPDATE off
  feed "v2.0.0 100"
  run "$UPD" check
  [ "$output" = "off" ]
}

@test "same or lower versions are up to date" {
  feed "v1.0.0 100" "v0.9.0 200"
  run "$UPD" check
  [ "$output" = "up-to-date" ]
}

@test "a release marked bad is skipped and a newer one is not" {
  mkdir -p "$FRAIM_UPDATER_STATE"
  echo v1.1.0 > "$FRAIM_UPDATER_STATE/bad"
  feed "v1.1.0 100"
  run "$UPD" check
  [ "$output" = "up-to-date" ]
  feed "v1.1.0 100" "v1.2.0 100"
  run "$UPD" check
  [ "$output" = "available v1.2.0" ]
}

@test "GitHub unreachable: exit 3, nothing changes, no message" {
  touch "$T/curl-fail"
  run "$UPD" check
  [ "$status" -eq 3 ]
  run "$UPD" run
  [ "$status" -eq 3 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  [ ! -e "$T/notify.log" ]
}

# --- installing

@test "an update installs the release and tells the owner" {
  release v1.1.0
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = v1.1.0 ]
  [ "$(env_of FRAIM_VERSION)" = v1.1.0 ]
  [ "$(env_of FRAIM_COMMIT)" = commit-v1.1.0 ]
  [ ! -e "$FRAIM_UPDATER_DIR/.update-lock" ]
  grep -q 'v1.1.0 lock=1' "$T/install.log"
  grep -q 'v1.1.0' "$T/notify.log"
}

@test "an update keeps owner files and removes code the release dropped" {
  release v1.1.0
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(env_of SECRET)" = keep-me ]
  [ "$(cat "$FRAIM_UPDATER_DIR/config/authorized_keys")" = 'ssh-ed25519 KEEP' ]
  [ ! -e "$FRAIM_UPDATER_DIR/removed-in-release.txt" ]
}

@test "outside the window nothing runs, --now runs anyway" {
  export FRAIM_UPDATER_HOUR=14
  release v1.1.0
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  run "$UPD" run --now
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = v1.1.0 ]
}

@test "AUTO_UPDATE=off blocks a scheduled run but not --now" {
  set_var AUTO_UPDATE off
  release v1.1.0
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  run "$UPD" run --now
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = v1.1.0 ]
}

@test "--now moves a hand-deployed build onto the latest release" {
  set_version abc123
  release v1.1.0
  feed "v1.1.0 1"
  run "$UPD" run --now
  [ "$status" -eq 0 ]
  [ "$(env_of FRAIM_VERSION)" = v1.1.0 ]
}

@test "--to installs an older release" {
  release v0.5.0
  feed "v1.1.0 100"
  run "$UPD" run --to v0.5.0
  [ "$status" -eq 0 ]
  [ "$(env_of FRAIM_VERSION)" = v0.5.0 ]
}

# --- refusing

@test "a tarball signed by another key is refused once and nothing changes" {
  ssh-keygen -q -t ed25519 -N '' -C evil -f "$T/evil"
  release v1.1.0 "$T/evil"
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$status" -eq 1 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  [ ! -e "$T/install.log" ]
  [ "$(grep -c 'v1.1.0' "$T/notify.log")" -eq 1 ]
  run "$UPD" run
  [ "$(grep -c 'v1.1.0' "$T/notify.log")" -eq 1 ]
}

@test "a tarball changed after signing is refused" {
  release v1.1.0
  printf 'x' >> "$T/dl/fraimwork-v1.1.0.tar.gz"
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$status" -eq 1 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
}

@test "a validly signed older tarball served as a newer tag is refused" {
  release v1.0.5
  cp "$T/dl/fraimwork-v1.0.5.tar.gz" "$T/dl/fraimwork-v1.1.0.tar.gz"
  cp "$T/dl/fraimwork-v1.0.5.tar.gz.sig" "$T/dl/fraimwork-v1.1.0.tar.gz.sig"
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$status" -eq 1 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
}

@test "a missing download exits 3 with no message" {
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$status" -eq 3 ]
  [ ! -e "$T/notify.log" ]
}

# --- rolling back

@test "a new failing health check rolls back and marks the release bad" {
  release v1.1.0
  feed "v1.1.0 100"
  echo '{"checks":[{"name":"queue-page","ok":false}]}' > "$T/doctor.v1.1.0"
  run "$UPD" run
  [ "$status" -eq 1 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  [ -e "$FRAIM_UPDATER_DIR/removed-in-release.txt" ]
  [ "$(env_of FRAIM_VERSION)" = v1.0.0 ]
  [ "$(env_of FRAIM_COMMIT)" = aaa ]
  grep -qx v1.1.0 "$FRAIM_UPDATER_STATE/bad"
  [ ! -e "$FRAIM_UPDATER_DIR/.update-lock" ]
  grep -q 'v1.1.0' "$T/notify.log"
  rm "$T/notify.log"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  [ ! -e "$T/notify.log" ]
}

@test "a check that already failed before does not cause a rollback" {
  release v1.1.0
  feed "v1.1.0 100"
  echo '{"checks":[{"name":"claude-login","ok":false}]}' > "$T/doctor.v1.0.0"
  echo '{"checks":[{"name":"claude-login","ok":false}]}' > "$T/doctor.v1.1.0"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(env_of FRAIM_VERSION)" = v1.1.0 ]
}

@test "low memory right after a rebuild does not cause a rollback" {
  release v1.1.0
  feed "v1.1.0 100"
  echo '{"checks":[{"name":"memory-headroom","ok":false}]}' > "$T/doctor.v1.1.0"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(env_of FRAIM_VERSION)" = v1.1.0 ]
}

@test "install.sh failing rolls back" {
  release v1.1.0
  feed "v1.1.0 100"
  touch "$T/install-fail.v1.1.0"
  run "$UPD" run
  [ "$status" -eq 1 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  [ "$(env_of FRAIM_VERSION)" = v1.0.0 ]
  grep -qx v1.1.0 "$FRAIM_UPDATER_STATE/bad"
}

# --- waiting for others

@test "running goals defer the update, once per night" {
  release v1.1.0
  feed "v1.1.0 100"
  echo 'g4  running  2026  build a thing' > "$T/goals"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  [ "$(cut -d' ' -f1 "$FRAIM_UPDATER_STATE/deferred")" = 1 ]
  run "$UPD" run
  [ "$(cut -d' ' -f1 "$FRAIM_UPDATER_STATE/deferred")" = 1 ]
}

@test "after three deferred nights the update goes ahead" {
  release v1.1.0
  feed "v1.1.0 100"
  echo 'g4  running  2026  build a thing' > "$T/goals"
  mkdir -p "$FRAIM_UPDATER_STATE"
  echo '3 2000-01-01 v1.1.0' > "$FRAIM_UPDATER_STATE/deferred"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = v1.1.0 ]
}

@test "a laptop update in progress means no run" {
  release v1.1.0
  feed "v1.1.0 100"
  mkdir "$FRAIM_UPDATER_DIR/.update-lock"
  echo 'started=x from=a to=b by=laptop' > "$FRAIM_UPDATER_DIR/.update-lock/info"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = old ]
  [ -e "$FRAIM_UPDATER_DIR/.update-lock" ]
}

@test "an update cut off halfway restores the previous code by itself" {
  release v1.1.0
  feed "v1.1.0 100"
  run "$UPD" run
  [ "$(env_of FRAIM_VERSION)" = v1.1.0 ]
  # A second update dies after applying: the snapshot holds v1.1.0, the code is v1.2.0.
  mkdir -p "$FRAIM_UPDATER_STATE/previous"
  rm -rf "$FRAIM_UPDATER_STATE/previous"
  mkdir -p "$FRAIM_UPDATER_STATE/previous"
  cp -R "$FRAIM_UPDATER_DIR/." "$FRAIM_UPDATER_STATE/previous/"
  rm -f "$FRAIM_UPDATER_STATE/previous/.env"
  printf 'FRAIM_VERSION=v1.1.0\nFRAIM_COMMIT=commit-v1.1.0\n' > "$FRAIM_UPDATER_STATE/previous.version"
  mkdir "$FRAIM_UPDATER_DIR/.update-lock"
  echo 'started=x from=a to=b by=fraim-updater tag=v1.2.0' > "$FRAIM_UPDATER_DIR/.update-lock/info"
  echo half > "$FRAIM_UPDATER_DIR/code.txt"
  set_version v1.2.0
  feed "v1.1.0 100" "v1.2.0 100"
  run "$UPD" run
  [ "$status" -eq 0 ]
  [ "$(cat "$FRAIM_UPDATER_DIR/code.txt")" = v1.1.0 ]
  [ "$(env_of FRAIM_VERSION)" = v1.1.0 ]
  [ ! -e "$FRAIM_UPDATER_DIR/.update-lock" ]
  grep -qx v1.2.0 "$FRAIM_UPDATER_STATE/bad"
}

@test "status --json reports the state" {
  set_var UPDATE_RING canary
  feed "v1.1.0 1"
  run "$UPD" status --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .current <<<"$output")" = v1.0.0 ]
  [ "$(jq -r .ring <<<"$output")" = canary ]
  [ "$(jq -r .auto <<<"$output")" = on ]
  [ "$(jq -r .latest <<<"$output")" = v1.1.0 ]
}

@test "other spaces are health checked, stopped ones are not" {
  release v1.1.0
  feed "v1.1.0 100"
  printf 'STOPPED=0\n' > "$FRAIM_UPDATER_DIR/.env.space-work"
  printf 'STOPPED=1\n' > "$FRAIM_UPDATER_DIR/.env.space-old"
  run "$UPD" run
  [ "$status" -eq 0 ]
  grep -q -- '-p fraimwork-work .*fraim-doctor' "$T/docker.log"
  ! grep -q -- '-p fraimwork-old ' "$T/docker.log"
  [ -f "$FRAIM_UPDATER_DIR/.env.space-work" ]
}

@test "usage errors exit 2" {
  run "$UPD" nonsense
  [ "$status" -eq 2 ]
  run "$UPD" run --to latest
  [ "$status" -eq 2 ]
}
