FROM node:24-bookworm

ARG TARGETARCH
ARG CLAUDE_CODE_VERSION=2.1.318
ARG CHROME_DEVTOOLS_MCP_VERSION=1.12.0
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA256_AMD64=cc232108374e8e2b537045f2d5eaa1229f619db314c3ba6a14d38b35dc0aa123
ARG SUPERCRONIC_SHA256_ARM64=4ae22576a78223d8ccdf5f3b3660a5cbb5288416bf0ca96afc4a36d195932b94

# No usage statistics from chrome-devtools-mcp: each copy (one per Claude) otherwise starts
# a telemetry watchdog of about 50 MB.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISABLE_AUTOUPDATER=1 \
    CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1

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

# herdr-core (hc): the terminals every Claude session on the server lives in (docs/sessions.md).
# Pinned and checksummed; root owns the binary, so `hc update` cannot swap it.
ARG HERDR_CORE_VERSION=0.1.19
ARG HERDR_CORE_SHA256_AMD64=4adcfb423d52f24c5cc4a1e2cd2fcad1f62d28bb77876ac472c29082a3eaa424
ARG HERDR_CORE_SHA256_ARM64=f95c34fd7177ed58807d74fe4ee78bb3dc73eb37f21c69496064000a21abcb10
RUN case "${TARGETARCH}" in \
      amd64) arch=x86_64 sha="${HERDR_CORE_SHA256_AMD64}" ;; \
      arm64) arch=aarch64 sha="${HERDR_CORE_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSLo /tmp/hc.tgz "https://releases.herdr.dev/core/${HERDR_CORE_VERSION}/herdr-core-linux-${arch}.tar.gz" \
 && echo "${sha}  /tmp/hc.tgz" | sha256sum -c - \
 && mkdir -p /usr/local/share/herdr-core \
 && tar -xzf /tmp/hc.tgz -C /usr/local/share/herdr-core \
 && install -m 0755 /usr/local/share/herdr-core/herdr-core /usr/local/bin/herdr-core \
 && rm -f /usr/local/share/herdr-core/herdr-core /tmp/hc.tgz \
 && ln -s herdr-core /usr/local/bin/hc \
 && hc --version

RUN npm install -g \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}" \
 && npm cache clean --force

RUN groupmod -n claude node \
 && usermod -l claude -d /home/claude -m -s /bin/bash node \
 && install -d -o claude -g claude /home/claude/fraim /home/claude/pc

COPY channel/package.json channel/package-lock.json /opt/fraim/channel/
RUN cd /opt/fraim/channel && npm ci --omit=dev && npm cache clean --force
COPY channel/whatsapp-channel.mjs channel/main-session.mjs channel/verdict.mjs channel/goal-command.mjs channel/unanswered.mjs channel/context.mjs channel/voice.mjs channel/quote.mjs /opt/fraim/channel/

# Speech to text for WhatsApp voice messages (fraim-transcribe). The model is part of the
# image, so a voice message never waits for a download. "base" needs about 500 MB while it
# runs; "small" is more exact but needs 1.2 GB, too much next to Claude on a 4 GB server.
ARG FASTER_WHISPER_VERSION=1.2.1
ARG WHISPER_MODEL=base
RUN python3 -m venv /opt/fraim/whisper/venv \
 && /opt/fraim/whisper/venv/bin/pip install --no-cache-dir "faster-whisper==${FASTER_WHISPER_VERSION}" \
 && /opt/fraim/whisper/venv/bin/python -c "from faster_whisper import download_model; download_model('${WHISPER_MODEL}', output_dir='/opt/fraim/whisper/model')"
# Pillow: still pictures from videos (fraim-frames). poppler-utils: Claude reads PDFs with it.
ARG PILLOW_VERSION=11.3.0
RUN /opt/fraim/whisper/venv/bin/pip install --no-cache-dir "pillow==${PILLOW_VERSION}" \
 && apt-get update \
 && apt-get install -y --no-install-recommends poppler-utils \
 && rm -rf /var/lib/apt/lists/*
COPY whisper/transcribe.py whisper/frames.py /opt/fraim/whisper/

COPY sshd_config /etc/ssh/sshd_config.d/fraim.conf
COPY managed-settings.json /etc/claude-code/managed-settings.json
COPY managed-CLAUDE.md /etc/claude-code/CLAUDE.md
COPY system.crontab /etc/fraim/system.crontab
COPY skel/ /etc/fraim/skel/
COPY skel-jobs/ /etc/fraim/skel-jobs/
COPY automation-kit/ /etc/fraim/automation-kit/
COPY prompts/ /etc/fraim/prompts/
COPY ui/ /etc/fraim/ui/
COPY bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/fraim-*

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/fraim-entrypoint"]
CMD ["workspace"]
