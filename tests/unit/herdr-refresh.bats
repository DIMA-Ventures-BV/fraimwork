#!/usr/bin/env bats
# desktop/herdr/mods/fraim/refresh.sh: the Herdr mod follows the server's version, and installs
# only a release signed with the key the laptop holds.

setup() {
  REFRESH="$BATS_TEST_DIRNAME/../../desktop/herdr/mods/fraim/refresh.sh"
  T="$BATS_TEST_TMPDIR"
  ssh-keygen -q -t ed25519 -N '' -C test -f "$T/key"
  ssh-keygen -q -t ed25519 -N '' -C other -f "$T/other"
  MOD="$T/mod"
  mkdir -p "$MOD"
  echo old > "$MOD/main.js"
  echo v0.1.0 > "$MOD/version"
  printf 'fraim-release %s\n' "$(cat "$T/key.pub")" > "$MOD/release-signers"
  export FRAIM_RELEASES_BASE="file://$T/releases"
}

release() {
  local v="$1" key="$2" tree="$T/tree-$1"
  mkdir -p "$tree/desktop/herdr/mods/fraim" "$T/releases/$v"
  echo "new $v" > "$tree/desktop/herdr/mods/fraim/main.js"
  echo '{}' > "$tree/desktop/herdr/mods/fraim/mod.json"
  printf 'fraim-release evil\n' > "$tree/desktop/herdr/mods/fraim/release-signers"
  tar -czf "$T/releases/$v/fraimwork-$v.tar.gz" -C "$tree" .
  ssh-keygen -q -Y sign -f "$key" -n fraim-release "$T/releases/$v/fraimwork-$v.tar.gz" >/dev/null
}

@test "a release signed with the laptop's key replaces the mod, but never the key" {
  release v0.2.0 "$T/key"
  run "$REFRESH" v0.2.0 "$MOD"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOD/main.js")" = "new v0.2.0" ]
  [ "$(cat "$MOD/version")" = v0.2.0 ]
  [ -f "$MOD/mod.json" ]
  grep -q "$(cut -d' ' -f2 "$T/key.pub")" "$MOD/release-signers"
}

@test "a release signed with another key changes nothing" {
  release v0.2.0 "$T/other"
  run "$REFRESH" v0.2.0 "$MOD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not signed with the trusted key"* ]]
  [ "$(cat "$MOD/main.js")" = old ]
  [ "$(cat "$MOD/version")" = v0.1.0 ]
}

@test "the same version, a missing release or a version that is no release changes nothing" {
  echo v0.2.0 > "$MOD/version"
  run "$REFRESH" v0.2.0 "$MOD"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOD/main.js")" = old ]
  run "$REFRESH" v0.3.0 "$MOD"
  [ "$status" -ne 0 ]
  [ "$(cat "$MOD/main.js")" = old ]
  run "$REFRESH" 'v1.0.0;rm' "$MOD"
  [ "$status" -eq 2 ]
  run "$REFRESH" dev "$MOD"
  [ "$status" -eq 2 ]
}
