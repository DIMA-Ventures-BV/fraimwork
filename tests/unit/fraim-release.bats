#!/usr/bin/env bats
# bin/fraim-release in a throwaway git repo with a fake gh: what it refuses and what it publishes.

setup() {
  SRC="$BATS_TEST_DIRNAME/../.."
  T="$BATS_TEST_TMPDIR"
  export T
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  git init -q --bare -b main "$T/origin.git"
  git init -q -b main "$T/repo"
  cd "$T/repo" || exit 1
  mkdir -p bin config
  cp "$SRC/bin/fraim-release" bin/
  ssh-keygen -q -t ed25519 -N '' -C test -f "$T/key"
  printf 'fraim-release %s\n' "$(cut -d' ' -f1,2 "$T/key.pub")" > config/release-signers
  echo code > code.txt
  git add -A
  git commit -qm first
  git remote add origin "$T/origin.git"
  git push -q origin main
  export FRAIM_RELEASE_KEY="$T/key"
  mkdir "$T/bin"
  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "run list") cat "$T/ci" ;;
  "release create") printf '%s\n' "$*" > "$T/gh.log"; for a in "$@"; do case "$a" in *.tar.gz|*.sig) cp "$a" "$T/pub-$(basename "$a")" ;; esac; done ;;
esac
EOF
  chmod +x "$T/bin/gh"
  export PATH="$T/bin:$PATH"
  echo success > "$T/ci"
}

@test "a good run signs, tags and publishes a release the updater accepts" {
  run bin/fraim-release v1.0.0
  [ "$status" -eq 0 ]
  git rev-parse -q --verify refs/tags/v1.0.0
  git --git-dir="$T/origin.git" rev-parse -q --verify refs/tags/v1.0.0
  grep -q 'release create v1.0.0' "$T/gh.log"
  ssh-keygen -q -Y verify -f config/release-signers -I fraim-release -n fraim-release \
    -s "$T/pub-fraimwork-v1.0.0.tar.gz.sig" < "$T/pub-fraimwork-v1.0.0.tar.gz"
  mkdir "$T/x"
  tar -xzf "$T/pub-fraimwork-v1.0.0.tar.gz" -C "$T/x"
  grep -qx 'version=v1.0.0' "$T/x/RELEASE"
  grep -qx "commit=$(git rev-parse HEAD)" "$T/x/RELEASE"
  [ -f "$T/x/code.txt" ]
  [ ! -e "$T/x/.git" ]
}

@test "--dry-run publishes nothing and makes no tag" {
  run bin/fraim-release v1.0.0 --dry-run
  [ "$status" -eq 0 ]
  ! git rev-parse -q --verify refs/tags/v1.0.0
  [ ! -e "$T/gh.log" ]
}

@test "a dirty checkout is refused" {
  echo x >> code.txt
  run bin/fraim-release v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *uncommitted* ]]
}

@test "another branch is refused" {
  git checkout -q -b feature
  run bin/fraim-release v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *main* ]]
}

@test "an unpushed commit is refused" {
  echo x >> code.txt
  git commit -qam second
  run bin/fraim-release v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *origin/main* ]]
}

@test "a version not above the newest release is refused" {
  git tag -a v2.0.0 -m v2.0.0
  git push -q origin v2.0.0
  run bin/fraim-release v1.9.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"not above"* ]]
  run bin/fraim-release v2.0.0
  [ "$status" -eq 1 ]
}

@test "a key the servers do not trust is refused" {
  ssh-keygen -q -t ed25519 -N '' -C other -f "$T/other"
  FRAIM_RELEASE_KEY="$T/other" run bin/fraim-release v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not match"* ]]
  ! git rev-parse -q --verify refs/tags/v1.0.0
}

@test "CI that is not green is refused" {
  echo failure > "$T/ci"
  run bin/fraim-release v1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *CI* ]]
  ! git rev-parse -q --verify refs/tags/v1.0.0
}

@test "a bad version is a usage error" {
  run bin/fraim-release 1.0
  [ "$status" -eq 2 ]
}
