#!/usr/bin/env bash
# Runs as root inside a throwaway Ubuntu VM (tests/e2e-update.sh starts it). Only GitHub is
# faked, by a curl wrapper that serves a local release feed. Everything else is real: signatures,
# install.sh, Docker builds, fraim-doctor, the rollback.
set -euo pipefail
SRC="$1"
W=/root/e2e
OPT=/opt/fraimwork
rm -rf "$W" "$OPT" /var/lib/fraim/updates
mkdir -p "$W/bin" "$W/dl" "$W/trees" "$OPT"
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n=== %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
env_of() { grep "^$1=" "$OPT/.env" | tail -1 | cut -d= -f2-; }
exec_ws() { (cd "$OPT" && docker compose exec -T -u claude workspace "$@"); }
want_version() { [ "$(env_of FRAIM_VERSION)" = "$1" ] || fail "expected version $1, found $(env_of FRAIM_VERSION)"; pass "version is $1"; }
owner_data_kept() {
  [ "$(exec_ws cat /home/claude/fraim/owner-file)" = keep ] || fail "owner file lost"
  [ "$(env_of SECRETS_TOKEN)" = "$SECRET" ] || fail ".env secret changed"
  [ -s "$OPT/config/authorized_keys" ] || fail "authorized_keys lost"
  pass "owner data kept"
}
doctor_ok() {
  local json
  for _ in $(seq 60); do
    # fraim-doctor exits 1 while anything fails, and this server has no Claude login.
    json="$(exec_ws fraim-doctor --json 2>/dev/null || true)"
    if jq -e --arg n "$1" '.checks[] | select(.name == $n and .ok)' >/dev/null 2>&1 <<<"$json"; then pass "$1 is healthy"; return 0; fi
    sleep 5
  done
  printf '%s\n' "$json"
  (cd "$OPT" && docker compose ps -a) || true
  exec_ws sh -c 'tail -20 ~/.local/state/fraim/queue-page.log ~/.local/state/fraim/herdr.log' || true
  fail "$1 is not healthy"
}
updater() { env PATH="$W/bin:$PATH" FRAIM_UPDATER_HOUR=4 FRAIM_UPDATER_TRIES=18 /usr/local/sbin/fraim-updater "$@"; }

step "Preparing"
apt-get -o DPkg::Lock::Timeout=900 update -q
apt-get -o DPkg::Lock::Timeout=900 install -y -q rsync jq curl
rsync -a --exclude .git --exclude node_modules --exclude .env --exclude '.claude' "$SRC/" "$W/base/"
ssh-keygen -q -t ed25519 -N '' -C e2e -f "$W/key"
printf 'fraim-release %s\n' "$(cut -d' ' -f1,2 "$W/key.pub")" > "$W/base/config/release-signers"
echo '[]' > "$W/feed.json"
cat > "$W/bin/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *api.github.com/repos/*/releases*) exec cat "$W/feed.json" ;;
  *github.com/*/releases/download/*)
    out=""; url=""
    while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; -H|--max-time) shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac; done
    exec cp "$W/dl/\$(basename "\$url")" "\$out" ;;
esac
exec /usr/bin/curl "\$@"
EOF
chmod +x "$W/bin/curl"

# release VERSION: packs $W/trees/VERSION, signs it and lists it in the feed.
release() {
  local v="$1" t="$W/trees/$1"
  printf 'version=%s\ncommit=commit-%s\n' "$v" "$v" > "$t/RELEASE"
  tar -czf "$W/dl/fraimwork-$v.tar.gz" -C "$t" .
  rm -f "$W/dl/fraimwork-$v.tar.gz.sig"
  ssh-keygen -q -Y sign -f "$W/key" -n fraim-release "$W/dl/fraimwork-$v.tar.gz"
  jq --arg v "$v" '. + [{tag_name: $v, draft: false, prerelease: false, published_at: "2020-01-01T00:00:00Z"}]' "$W/feed.json" > "$W/feed.new"
  mv "$W/feed.new" "$W/feed.json"
}
tree() { cp -a "$W/base" "$W/trees/$1"; echo "$1" > "$W/trees/$1/workspace/bin/fraim-e2e-marker"; chmod +x "$W/trees/$1/workspace/bin/fraim-e2e-marker"; }

step "Installing the first version"
rsync -a "$W/base/" "$OPT/"
cp .env.example "$OPT/.env" 2>/dev/null || cp "$W/base/.env.example" "$OPT/.env"
sed -i -e 's/^ACCESS_MODE=.*/ACCESS_MODE=public/' -e 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=scheduler/' \
  -e 's/^UPDATE_RING=.*/UPDATE_RING=canary/' "$OPT/.env"
printf 'FRAIM_VERSION=v0.0.1\nFRAIM_COMMIT=base\n' >> "$OPT/.env"
cp "$W/key.pub" "$OPT/config/authorized_keys"
(cd "$OPT" && ./install.sh)
SECRET="$(env_of SECRETS_TOKEN)"
systemctl is-enabled fraim-updater.timer >/dev/null || fail "the update timer is not enabled"
systemctl is-active fraim-updater.timer >/dev/null || fail "the update timer is not running"
pass "update timer is on"
doctor_ok queue-page
exec_ws sh -c 'echo keep > /home/claude/fraim/owner-file'
[ "$(updater check)" = up-to-date ] || fail "check should say up-to-date with no releases"
pass "no releases: up to date"

step "A good release installs by itself"
tree v0.0.2
release v0.0.2
[ "$(updater check)" = "available v0.0.2" ] || fail "check should find v0.0.2"
updater run || fail "the update failed"
want_version v0.0.2
[ -x "$OPT/workspace/bin/fraim-e2e-marker" ] || fail "new code is not in place"
doctor_ok queue-page
exec_ws sh -c 'command -v fraim-e2e-marker' >/dev/null || fail "the rebuilt image has no new code"
pass "the rebuilt container runs the new code"
owner_data_kept
[ ! -e "$OPT/.update-lock" ] || fail "the lock stayed"

step "A release that breaks the server goes back"
tree v0.0.3
sed -i '1a process.exit(1)' "$W/trees/v0.0.3/workspace/bin/fraim-queue"
release v0.0.3
code=0; updater run || code=$?
[ "$code" = 1 ] || fail "a broken release must exit 1, got $code"
want_version v0.0.2
grep -qx v0.0.3 /var/lib/fraim/updates/bad || fail "not marked bad"
doctor_ok queue-page
owner_data_kept
[ "$(updater check)" = up-to-date ] || fail "the bad release must not be offered again"
pass "the bad release is not offered again"

step "A tampered release is refused"
tree v0.0.4
release v0.0.4
printf 'x' >> "$W/dl/fraimwork-v0.0.4.tar.gz"
code=0; updater run || code=$?
[ "$code" = 1 ] || fail "a tampered release must exit 1, got $code"
want_version v0.0.2
[ ! -e "$OPT/.update-lock" ] || fail "a refused release must not start an update"
pass "tampered release refused"
jq 'map(select(.tag_name != "v0.0.4"))' "$W/feed.json" > "$W/feed.new" && mv "$W/feed.new" "$W/feed.json"

step "An update cut off halfway recovers by itself"
tree v0.0.5
release v0.0.5
updater run >/dev/null 2>&1 &
pid=$!
for _ in $(seq 300); do [ ! -e "$OPT/.update-lock" ] || break; sleep 1; done
[ -e "$OPT/.update-lock" ] || fail "the update never started"
for _ in $(seq 120); do pgrep -f 'install.sh' >/dev/null && break; sleep 1; done
sleep 5
kill -9 "$pid" 2>/dev/null || true
pkill -9 -f 'fraim-updater run' || true
pkill -9 -f 'install.sh' || true
sleep 10
[ -e "$OPT/.update-lock" ] || fail "the marker should still be there after the crash"
updater run || fail "recovery failed"
want_version v0.0.2
[ ! -e "$OPT/.update-lock" ] || fail "the lock stayed after recovery"
grep -qx v0.0.5 /var/lib/fraim/updates/bad || fail "the interrupted release is not marked bad"
doctor_ok queue-page
owner_data_kept

step "A later good release still installs"
tree v0.0.6
release v0.0.6
updater run || fail "the update after recovery failed"
want_version v0.0.6
doctor_ok queue-page
owner_data_kept

printf '\nALL E2E UPDATE SCENARIOS PASSED\n'
