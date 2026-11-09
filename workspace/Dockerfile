FROM node:24-bookworm

ARG TARGETARCH
ARG CLAUDE_CODE_VERSION=2.1.318
ARG CHROME_DEVTOOLS_MCP_VERSION=1.12.0
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA256_AMD64=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
ARG SUPERCRONIC_SHA256_ARM64=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISABLE_AUTOUPDATER=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server mosh tmux git curl ca-certificates jq ripgrep less vim-tiny \
      python3 python3-venv procps tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && echo 'LANG=C.UTF-8' > /etc/default/locale

# GitHub's published host keys (api.github.com/meta, "ssh_keys"), so plugin marketplaces can
# fall back to SSH without a prompt. A file, not ssh-keyscan: no network needed at build time.
COPY github_known_hosts /etc/ssh/ssh_known_hosts

RUN case "${TARGETARCH}" in \
      amd64) sha="${SUPERCRONIC_SHA256_AMD64}" ;; \
      arm64) sha="${SUPERCRONIC_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSLo /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
 && echo "${sha}  /usr/local/bin/supercronic" | sha256sum -c - \
 && chmod 0755 /usr/local/bin/supercronic

RUN npm install -g \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}" \
 && npm cache clean --force

RUN groupmod -n claude node \
 && usermod -l claude -d /home/claude -m -s /bin/bash node \
 && install -d -o claude -g claude /home/claude/fraim /home/claude/pc

COPY channel/package.json channel/package-lock.json /opt/fraim/channel/
RUN cd /opt/fraim/channel && npm ci --omit=dev && npm cache clean --force
COPY channel/whatsapp-channel.mjs channel/verdict.mjs channel/goal-command.mjs channel/queue-command.mjs /opt/fraim/channel/

COPY sshd_config /etc/ssh/sshd_config.d/fraim.conf
COPY managed-settings.json /etc/claude-code/managed-settings.json
COPY managed-CLAUDE.md /etc/claude-code/CLAUDE.md
COPY system.crontab /etc/fraim/system.crontab
COPY skel/ /etc/fraim/skel/
COPY skel-jobs/ /etc/fraim/skel-jobs/
COPY automation-kit/ /etc/fraim/automation-kit/
COPY bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/fraim-*

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/fraim-entrypoint"]
CMD ["workspace"]
