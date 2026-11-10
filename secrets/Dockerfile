FROM caddy:2.11.1-alpine

# The secrets proxy: holds the API keys, so Claude's workspace never does. Keys live in the
# secrets-store volume, which only this container mounts. See docs/secrets.md.
RUN apk add --no-cache socat=1.8.1.3-r0
COPY fraim-secret /usr/local/bin/fraim-secret
COPY fraim-secret-gate /usr/local/bin/fraim-secret-gate
COPY entrypoint.sh /usr/local/bin/fraim-secrets-entrypoint
RUN chmod 0755 /usr/local/bin/fraim-secret /usr/local/bin/fraim-secret-gate /usr/local/bin/fraim-secrets-entrypoint \
 && install -d -m 0700 /data/secrets

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/fraim-secrets-entrypoint"]
