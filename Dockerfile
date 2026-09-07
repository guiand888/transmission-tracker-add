# transmission-tracker-add
#
# Alpine 3.24 (3.24.1, released 2026-06-13) is the current stable series,
# supported until 2028. Upstream shipped Alpine 3.15.4, EOL since 2023-11-01.
FROM docker.io/library/alpine:3.24

ARG TRACKER_ADD_VERSION=dev
ARG TRACKER_ADD_REVISION=unknown

LABEL org.opencontainers.image.title="transmission-tracker-add" \
      org.opencontainers.image.description="Applies a public tracker list to every torrent in Transmission, over JSON-RPC." \
      org.opencontainers.image.source="https://github.com/guiand888/transmission-tracker-add" \
      org.opencontainers.image.url="https://github.com/guiand888/transmission-tracker-add" \
      org.opencontainers.image.documentation="https://github.com/guiand888/transmission-tracker-add#readme" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.24" \
      org.opencontainers.image.version="${TRACKER_ADD_VERSION}" \
      org.opencontainers.image.revision="${TRACKER_ADD_REVISION}"

# bash            - the script is bash (arrays, [[ ]], EPOCHSECONDS), not POSIX sh.
# curl            - the ONLY network client: Transmission JSON-RPC and tracker-list fetches.
# jq              - builds and parses every JSON-RPC request/response. Replaces upstream's
#                   transmission-remote text scraping, which produced the header-row and
#                   inverted-grep bugs this fork exists to fix.
# ca-certificates - musl ships no CA bundle; without it HTTPS to raw.githubusercontent.com fails.
# tzdata          - makes TZ= actually change log timestamps.
#
# Deliberately NOT installed:
#   transmission-remote - the script talks RPC directly. One less thing whose text output
#                          can change format under us (see the README's fixes list).
#   coreutils            - the script uses only bash builtins (EPOCHSECONDS, printf %()T) and
#                           RPC epoch integers for all date/time handling, so busybox's
#                           `date` (which cannot parse relative or ctime-style strings) is
#                           never invoked and coreutils buys nothing.
#
# apk package versions are intentionally NOT pinned: Alpine's branch repositories carry
# exactly one version of each package, so a pin turns the next CVE patch into a hard build
# failure. The alpine:3.24 base tag already pins the whole set to a supported, patched
# branch; `docker compose build --pull --no-cache` (see README) picks up patches in place.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        bash \
        curl \
        jq \
        ca-certificates \
        tzdata \
 && addgroup -g 1001 -S tracker \
 && adduser -u 1001 -S -D -H -G tracker tracker

COPY LICENSE /usr/share/licenses/transmission-tracker-add/LICENSE
COPY tracker-add.sh /usr/local/bin/tracker-add.sh
RUN chmod 0755 /usr/local/bin/tracker-add.sh

# Defaults match the env var contract documented at the top of tracker-add.sh
# and in the README. TR_AUTH is deliberately NOT defaulted here: it is a
# credential and belongs in env_file / a mounted secret, never baked into
# the image or a plain `environment:` value.
ENV HOSTPORT=localhost:9091 \
    RPC_URL_PATH=/transmission/rpc/ \
    TORRENTLIST=https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt \
    INTERVAL=60 \
    STATE_DIR=/tmp/ttaa \
    LOG_LEVEL=INFO \
    TZ=UTC

# /tmp (and $STATE_DIR beneath it) is the only writable path under
# `read_only: true` + a tmpfs mount — see compose.yaml. Any accidental
# relative-path write lands here instead of failing with EROFS.
WORKDIR /tmp

# Numeric form, per Docker's official image best practices: survives a
# passwd/group rewrite and lets the runtime enforce the UID without
# resolving a name — matters under `read_only: true`, where /etc/passwd
# cannot be rewritten anyway.
USER 1001:1001

# Delegates to the script's own --healthcheck mode (see tracker-add.sh):
# reads an epoch timestamp from a heartbeat file and compares it to "now",
# entirely in bash builtins — no coreutils, no busybox `find -mmin`
# granularity games, works under read_only.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/tracker-add.sh", "--healthcheck"]

ENTRYPOINT ["/usr/local/bin/tracker-add.sh"]
