FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      chromium xvfb x11vnc novnc websockify socat tini procps ca-certificates \
      fonts-liberation fonts-noto-color-emoji fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -u 1000 -s /bin/bash browser \
 && install -d -o browser -g browser /data /fraim

COPY policies.json /etc/chromium/policies/managed/fraim.json
COPY start.sh /usr/local/bin/browser-start
RUN chmod 0755 /usr/local/bin/browser-start

USER browser
EXPOSE 6080 9223
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/browser-start"]
