#!/bin/sh
# Brings this mod to the fraimwork version the server runs, so a server update also updates
# the owner's Herdr app without a laptop update. The mod runs code on this laptop, so it only
# installs a release signed with the key in ./release-signers, which `fraim herdr link` put
# here from the laptop's own checkout and which this script never replaces.
#
#   refresh.sh vX.Y.Z MOD_DIR
#
# Exit codes: 0 updated or already there, 1 failed (nothing changed), 2 usage.
set -eu
[ $# -eq 2 ] || { echo "usage: refresh.sh vX.Y.Z MOD_DIR" >&2; exit 2; }
v="$1" dir="$2"
case "$v" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "refresh.sh: not a release: $v" >&2; exit 2 ;; esac
case "$v" in *[!v0-9.]*) echo "refresh.sh: not a release: $v" >&2; exit 2 ;; esac
[ "$(cat "$dir/version" 2>/dev/null || true)" != "$v" ] || exit 0
[ -s "$dir/release-signers" ] || { echo "refresh.sh: no release key; run: fraim herdr link" >&2; exit 1; }
repo="${FRAIM_RELEASES_REPO:-DIMA-Ventures-BV/fraimwork}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="${FRAIM_RELEASES_BASE:-https://github.com/$repo/releases/download}/$v/fraimwork-$v.tar.gz"
curl -fsSL --max-time 120 -o "$tmp/release.tar.gz" "$base"
curl -fsSL --max-time 30 -o "$tmp/release.tar.gz.sig" "$base.sig"
ssh-keygen -q -Y verify -f "$dir/release-signers" -I fraim-release -n fraim-release \
  -s "$tmp/release.tar.gz.sig" < "$tmp/release.tar.gz" >/dev/null 2>&1 \
  || { echo "refresh.sh: the $v release is not signed with the trusted key; nothing changed" >&2; exit 1; }
mkdir "$tmp/x"
tar -xzf "$tmp/release.tar.gz" -C "$tmp/x" ./desktop/herdr/mods/fraim
src="$tmp/x/desktop/herdr/mods/fraim"
[ -s "$src/main.js" ] || { echo "refresh.sh: the release has no Herdr mod" >&2; exit 1; }
# Each file is swapped in whole; main.js last, because the app reloads on it.
for f in "$src"/*; do
  name="$(basename "$f")"
  [ "$name" != main.js ] && [ "$name" != release-signers ] && [ "$name" != version ] || continue
  cp "$f" "$dir/.$name.new" && mv "$dir/.$name.new" "$dir/$name"
done
printf '%s\n' "$v" > "$dir/.version.new" && mv "$dir/.version.new" "$dir/version"
cp "$src/main.js" "$dir/.main.js.new" && mv "$dir/.main.js.new" "$dir/main.js"
echo "Herdr's fraim look is now $v."
