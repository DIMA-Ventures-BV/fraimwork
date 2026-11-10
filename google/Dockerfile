FROM python:3.13.9-slim

# Google (Gmail, Drive, Calendar) as an MCP server that any agent can use: Claude, Codex or
# another MCP client. The Google tokens live in the google-store volume, which only this
# container mounts, so the agent's workspace never holds them. See docs/google.md.
# Every package is pinned with its hash (requirements.txt, made from requirements.in with
# `uv pip compile google/requirements.in --generate-hashes --python-version 3.13 --universal
# -o google/requirements.txt`), so a changed or new upstream release never gets in unseen.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --require-hashes --only-binary=:all: -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt \
 && useradd --create-home --uid 1000 app \
 && install -d -o app -g app -m 0700 /data/google

COPY entrypoint.sh /usr/local/bin/fraim-google-entrypoint
COPY fraim-google /usr/local/bin/fraim-google
COPY fraim-reply fraim-mail-watch fraim_gmail.py /usr/local/bin/
RUN chmod 0755 /usr/local/bin/fraim-google-entrypoint /usr/local/bin/fraim-google /usr/local/bin/fraim-reply /usr/local/bin/fraim-mail-watch

USER app
# GOOGLE_CLIENT_SECRET_PATH is a file path in the private volume, not a secret.
# hadolint ignore=DL3064
ENV WORKSPACE_MCP_HOST=0.0.0.0 \
    WORKSPACE_MCP_PORT=8000 \
    WORKSPACE_MCP_BASE_URI=http://localhost \
    WORKSPACE_MCP_CREDENTIALS_DIR=/data/google/credentials \
    GOOGLE_CLIENT_SECRET_PATH=/data/google/client_secret.json \
    OAUTHLIB_INSECURE_TRANSPORT=1

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 CMD ["fraim-google", "health"]
ENTRYPOINT ["/usr/local/bin/fraim-google-entrypoint"]
