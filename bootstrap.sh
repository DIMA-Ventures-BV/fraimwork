#!/usr/bin/env bash
# One-command laptop setup for fraimwork. Safe to run again.
#   curl -fsSL https://raw.githubusercontent.com/DIMA-Ventures-BV/fraimwork/main/bootstrap.sh | bash
# Installs Claude Code, adds short aliases, installs the fraim plugin, stores a
# Claude login token in the macOS Keychain, then opens Claude with "set up fraim".
# Env: FRAIM_NO_ALIASES=1, FRAIM_NO_TOKEN=1, FRAIM_NO_LAUNCH=1 skip those steps.
#      FRAIM_MARKETPLACE=<path or owner/repo> installs the plugin from elsewhere (tests, forks).
set -euo pipefail

MARKETPLACE="${FRAIM_MARKETPLACE:-DIMA-Ventures-BV/fraimwork}"
KEYCHAIN_SERVICE="fraim-claude-token"
BLOCK_START="# >>> fraimwork >>>"
BLOCK_END="# <<< fraimwork <<<"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  done: %s\n' "$*"; }
warn() { printf '  note: %s\n' "$*" >&2; }
die()  { printf '\nfraimwork setup stopped: %s\n' "$*" >&2; exit 1; }

# With `curl | bash`, stdin is the script itself. Questions read from the terminal.
ask() { local reply; printf '%s ' "$1" >/dev/tty; read -r reply </dev/tty || true; printf '%s' "$reply"; }

# Everything runs from main, called on the last line. When a download breaks off,
# bash sees an unfinished function and runs nothing, instead of half the steps.
main() {
( : </dev/tty ) 2>/dev/null || die "run this in a terminal window"

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
# /usr/bin/git exists without the Command Line Tools; its first use opens an install dialog.
if [ "$(uname -s)" = Darwin ] && ! xcode-select -p >/dev/null 2>&1; then
  echo "  Your Mac needs Apple's developer tools (free, about 5 to 10 minutes)."
  xcode-select --install >/dev/null 2>&1 || true
  until xcode-select -p >/dev/null 2>&1; do
    reply="$(ask "Click Install in the window that opened. When it says done, press Enter (or type skip):")"
    case "$reply" in [Ss]kip*) warn "skipped; Claude asks for it again later"; break ;; esac
  done
  xcode-select -p >/dev/null 2>&1 && ok "developer tools installed"
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
# The PATH line is always written; FRAIM_NO_ALIASES=1 only leaves out the aliases.
{
  touch "$rc_file"
  # Names the user already uses elsewhere in the rc file or as a program stay theirs.
  outside_block="$(sed "/^$BLOCK_START\$/,/^$BLOCK_END\$/d" "$rc_file")"
  block="$BLOCK_START"$'\n'"# Managed by fraimwork bootstrap.sh; rerunning it rewrites this block."
  # The Claude Code installer puts claude in ~/.local/bin but may not add it to PATH.
  block+=$'\n''case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  taken() {
    printf '%s\n' "$outside_block" \
      | grep -qE "^[[:space:]]*(alias[[:space:]]+)?$1=|^[[:space:]]*(function[[:space:]]+)?$1[[:space:]]*\(\)" \
      || command -v "$1" >/dev/null 2>&1
  }
  added=()
  # cc is the C compiler on macOS, so "continue" is cn.
  pairs=("c=claude" "cn=claude --continue" "cr=claude --resume" "fraim-setup=claude \"set up fraim\"")
  [ -z "${FRAIM_NO_ALIASES:-}" ] || pairs=()
  for pair in ${pairs[@]+"${pairs[@]}"}; do
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
  # Write through the file: a dotfiles symlink stays a link and the mode stays the same.
  cat "$tmp" > "$rc_file"
  rm -f "$tmp"
  if [ ${#added[@]} -gt 0 ]; then
    ok "added: ${added[*]}  (type c to start Claude, cn to continue the last chat)"
  else
    ok "no new commands added"
  fi
}

say "Step 3 of 4: the fraim plugin"
if claude plugin marketplace list 2>/dev/null | grep -q fraimwork; then
  claude plugin marketplace update fraimwork >/dev/null 2>&1 || true
  ok "fraimwork plugin source already added"
else
  claude plugin marketplace add "$MARKETPLACE" >/dev/null \
    || die "could not download fraimwork. Check your internet connection. If that works, the fraimwork repo is not public yet: ask whoever sent you this link."
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
    case "$token" in *[!A-Za-z0-9_-]*) ;; sk-ant-*) break ;; esac
    token=""
    warn "the clipboard does not hold a token that starts with sk-ant-. Copy it again."
  done
  pbcopy </dev/null
  if [ -n "$token" ]; then
    # Through stdin, so the token never shows in the process list.
    printf 'add-generic-password -U -s %s -a %s -j "created %s" -w %s\n' \
      "$KEYCHAIN_SERVICE" "$USER" "$(date +%Y-%m-%d)" "$token" | security -i \
      || die "could not save the token in your Keychain"
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
}

main "$@"
