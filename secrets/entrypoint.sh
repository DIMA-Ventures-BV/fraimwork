#!/bin/sh
# Secrets container entrypoint: write the Caddyfile from the store, then run Caddy.
set -eu
fraim-secret render
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
