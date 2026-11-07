#!/usr/bin/env bash
# One-command laptop setup for fraimwork. Safe to run again.
#   curl -fsSL https://raw.githubusercontent.com/MHilhorst/fraimwork/main/bootstrap.sh | bash
# Installs Claude Code, adds short aliases, installs the fraim plugin, stores a
# Claude login token in the macOS Keychain, then opens Claude with "set up fraim".
# Env: FRAIM_NO_ALIASES=1, FRAIM_NO_TOKEN=1, FRAIM_NO_LAUNCH=1 skip those steps.
#      FRAIM_MARKETPLACE=<path or owner/repo> installs the plugin from elsewhere (tests, forks).
set -euo pipefail

MARKETPLACE="${FRAIM_MARKETPLACE:-MHilhorst/fraimwork}"
KEYCHAIN_SERVICE="fraim-claude-token"
BLOCK_START="# >>> fraimwork >>>"
BLOCK_END="# <<< fraimwork <<<"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  done: %s\n' "$*"; }
warn() { printf '  note: %s\n' "$*" >&2; }
die()  { printf '\nfraimwork setup stopped: %s\n' "$*" >&2; exit 1; }

# With `curl | bash`, stdin is the script itself. Questions read from the terminal.
[ -r /dev/tty ] || die "run this in a terminal window"
ask() { local reply; printf '%s ' "$1" >/dev/tty; read -r reply </dev/tty || true; printf '%s' "$reply"; }

[ "$(uname -s)" = Darwin ] || warn "this script is written for macOS; other systems may need manual steps"
export PATH="$HOME/.local/bin:$PATH"

say "fraimwork setup: your own always-on Claude"
echo "  You need a Claude Pro or Max plan. This takes about 5 minutes."

say "Step 1 of 4: Claude Code"
if command -v claude >/dev/null; then
  ok "Claude Code is already installed ($(claude --version 2>/dev/null | head -1))"
else
  curl -fsSL https://claude.ai/install.sh | bash
  command -v claude >/dev/null || die "Claude Code did not install. Install it from https://claude.com/claude-code and run this again."
  ok "Claude Code installed"
fi
for tool in git ssh jq; do
  command -v "$tool" >/dev/null && continue
  if command -v brew >/dev/null; then
    brew install -q "$tool" && ok "installed $tool"
  else
    warn "$tool is missing. Claude will help you install it during setup."
  fi
done

say "Step 2 of 4: short commands"
rc_file="$HOME/.zshrc"
case "${SHELL:-}" in */bash) rc_file="$HOME/.bashrc" ;; esac
if [ -n "${FRAIM_NO_ALIASES:-}" ]; then
  ok "skipped"
else
  touch "$rc_file"
  # Names the user already uses elsewhere in the rc file or as a program stay theirs.
  outside_block="$(sed "/^$BLOCK_START\$/,/^$BLOCK_END\$/d" "$rc_file")"
  block="$BLOCK_START"$'\n'"# Managed by fraimwork bootstrap.sh; rerunning it rewrites this block."
  taken() {
    printf '%s\n' "$outside_block" \
      | grep -qE "^[[:space:]]*(alias[[:space:]]+)?$1=|^[[:space:]]*(function[[:space:]]+)?$1[[:space:]]*\(\)" \
      || command -v "$1" >/dev/null 2>&1
  }
  added=()
  # cc is the C compiler on macOS, so "continue" is cn.
  for pair in "c=claude" "cn=claude --continue" "cr=claude --resume" "fraim-setup=claude \"set up fraim\""; do
    name="${pair%%=*}" value="${pair#*=}"
    if taken "$name"; then
      warn "'$name' already means something on this computer; left it alone"
      continue
    fi
    block+=$'\n'"alias $name='$value'"
    added+=("$name")
  done
  block+=$'\n'"$BLOCK_END"
  tmp="$(mktemp)"
  printf '%s\n' "$outside_block" > "$tmp"
  printf '%s\n' "$block" >> "$tmp"
  cp "$rc_file" "$rc_file.fraim-backup"
  mv "$tmp" "$rc_file"
  if [ ${#added[@]} -gt 0 ]; then
    ok "added: ${added[*]}  (type c to start Claude, cn to continue the last chat)"
  else
    ok "no new commands added"
  fi
fi

say "Step 3 of 4: the fraim plugin"
if claude plugin marketplace list 2>/dev/null | grep -q fraimwork; then
  claude plugin marketplace update fraimwork >/dev/null 2>&1 || true
  ok "fraimwork plugin source already added"
else
  claude plugin marketplace add "$MARKETPLACE" >/dev/null || die "could not add the fraimwork plugin source"
  ok "fraimwork plugin source added"
fi
if claude plugin list 2>/dev/null | grep -q "fraim@fraimwork"; then
  ok "fraim plugin already installed"
else
  claude plugin install fraim@fraimwork >/dev/null || die "could not install the fraim plugin"
  ok "fraim plugin installed"
fi

say "Step 4 of 4: a login token for your server"
if [ -n "${FRAIM_NO_TOKEN:-}" ] || [ "$(uname -s)" != Darwin ]; then
  ok "skipped; Claude asks for it later"
elif security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  ok "a token is already saved in your Keychain"
else
  echo "  Your server needs its own Claude login. A browser window opens now."
  echo "  1. Approve in the browser."
  echo "  2. Come back here and copy the long token that starts with sk-ant-."
  ask "Press Enter to open the browser." >/dev/null
  claude setup-token </dev/tty >/dev/tty 2>&1 || warn "claude setup-token stopped early"
  token=""
  for _ in 1 2 3; do
    ask "Copy the token, then press Enter (or type skip):" | grep -qi '^skip' && break
    token="$(pbpaste | tr -d '[:space:]')"
    case "$token" in sk-ant-*) break ;; esac
    token=""
    warn "the clipboard does not hold a token that starts with sk-ant-. Copy it again."
  done
  pbcopy </dev/null
  if [ -n "$token" ]; then
    security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$USER" \
      -j "created $(date +%Y-%m-%d)" -w "$token"
    unset token
    ok "token saved in your Keychain. Claude sends it to your server later; you never paste it."
  else
    ok "skipped; Claude asks for it later"
  fi
fi

say "All set. Claude opens now and sets up the rest with you."
echo "  Later, open a new terminal and type: c"
[ -n "${FRAIM_NO_LAUNCH:-}" ] && exit 0
exec claude "set up fraim" </dev/tty
