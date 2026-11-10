#!/bin/sh
# Google MCP entrypoint. Without an OAuth client (fraim google setup) it waits instead of
# crash-looping, so the rest of the space starts normally.
set -eu
umask 077
mkdir -p /data/google/credentials
while ! fraim-google configured; do
  echo "fraim-google: no Google OAuth client yet; run on the laptop: fraim google setup" >&2
  sleep 30
done
USER_GOOGLE_EMAIL="$(cat /data/google/email)"
export USER_GOOGLE_EMAIL
# The reply sender holds the only send path for mail; the MCP server below offers agents drafts.
if [ -n "${REPLY_TOKEN:-}" ]; then
  ( while :; do fraim-reply; sleep 5; done ) &
fi
unset REPLY_TOKEN
# shellcheck disable=SC2086  # GOOGLE_PERMISSIONS is a list of service:level words
exec workspace-mcp --single-user --transport streamable-http \
  --permissions ${GOOGLE_PERMISSIONS:-gmail:drafts drive:readonly calendar:readonly}
