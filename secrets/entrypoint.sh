#!/bin/sh
# Secrets container entrypoint: write the Caddyfile from the store, start the gate for invited
# laptops, then run Caddy.
set -eu
fraim-secret render
socat -T 15 TCP-LISTEN:8081,fork,reuseaddr EXEC:/usr/local/bin/fraim-secret-gate &
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
