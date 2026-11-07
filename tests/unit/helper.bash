# shellcheck shell=bash disable=SC2034  # REPO, FRAIM and FRAIM_CONFIG are used by the .bats files
# Shared setup for the unit tests. Every test gets its own HOME and config dirs, and a fake
# ssh on PATH, so no test touches the real machine, the real repo .env or a real server.

bats_require_minimum_version 1.5.0

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
FRAIM="$REPO/bin/fraim"
FRAIM_CONFIG="$REPO/bin/fraim-config"

setup_isolated() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export FRAIM_DIR="$HOME/fraim"
  unset FRAIM_TARGET FRAIM_INSTANCE FRAIM_STATE_DIR FRAIM_SECRETS FRAIM_CLAUDE_DIR FRAIM_TEMPLATE
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"

  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  export SSH_STDIN_LOG="$BATS_TEST_TMPDIR/ssh.stdin"
  export SSH_HANDLER="$BATS_TEST_TMPDIR/ssh-handler.sh"
  : > "$SSH_LOG"
  # Fake ssh: logs every call (one line) and its stdin, then runs SSH_HANDLER with the
  # remote command in $REMOTE. Without a handler it succeeds silently.
  cat > "$STUBS/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
REMOTE="${!#}"
if [ ! -t 0 ]; then cat >> "$SSH_STDIN_LOG"; fi
if [ -f "$SSH_HANDLER" ]; then . "$SSH_HANDLER"; fi
exit 0
EOF
  chmod +x "$STUBS/ssh"
  # Fake claude for fraim-config: plugin listings are empty, installs succeed.
  cat > "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"--json"*) echo '[]' ;; esac
exit 0
EOF
  chmod +x "$STUBS/claude"
  export FRAIM_CLAUDE_BIN="$STUBS/claude"
  export PATH="$STUBS:$PATH"
}

# A remote (public mode) target, so every server call goes through the fake ssh.
use_public_target() {
  mkdir -p "$XDG_CONFIG_HOME/fraim"
  cat > "$XDG_CONFIG_HOME/fraim/config" <<EOF
FRAIM_HOST=test.invalid
FRAIM_ADMIN=root@test.invalid
FRAIM_ACCESS=public
FRAIM_SSH_PORT=2222
FRAIM_SSH_KEY=
FRAIM_PUBLIC_HOST=203.0.113.7
FRAIM_INSTANCE=local
EOF
}

# ssh_handler 'shell code': what the fake ssh does; $REMOTE holds the remote command.
ssh_handler() { printf '%s\n' "$1" > "$SSH_HANDLER"; }
