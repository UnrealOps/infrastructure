# syntax=docker/dockerfile:1.18@sha256:dabfc0969b935b2080555ace70ee69a5261af8a8f1b4df97b9e7fbcf6722eddf

ARG BUILDPLATFORM
ARG TARGETARCH

FROM scratch AS release-amd64
ADD --checksum=sha256:e14eeaca47aef92a65f70a1112507f9651e5459d9c6a34be2a41ba8043e89b30 \
    https://github.com/EpicGames/lore/releases/download/v0.8.5/loreserver-v0.8.5-x86_64-unknown-linux-gnu.tar.gz \
    /loreserver.tar.gz

FROM scratch AS release-arm64
ADD --checksum=sha256:02a0e47c672748136b2467efe65961685f5cfb7a341dae0115e0564e3a6ec91d \
    https://github.com/EpicGames/lore/releases/download/v0.8.5/loreserver-v0.8.5-aarch64-unknown-linux-gnu-neoverse-512tvb.tar.gz \
    /loreserver.tar.gz

FROM release-${TARGETARCH} AS release-archive

FROM --platform=${BUILDPLATFORM} ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea AS release

COPY --from=release-archive /loreserver.tar.gz /tmp/loreserver.tar.gz

RUN mkdir -p /tmp/release /out/licenses \
    && tar --extract --gzip --file /tmp/loreserver.tar.gz --directory /tmp/release \
    && install --mode 0555 /tmp/release/loreserver /out/loreserver \
    && install --mode 0444 /tmp/release/LICENSE.txt /out/licenses/LICENSE.txt \
    && install --mode 0444 /tmp/release/THIRD-PARTY-NOTICES.txt /out/licenses/THIRD-PARTY-NOTICES.txt

FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea

ARG LORE_VERSION=0.8.5
ARG LORE_REVISION=2d86d1dda98bfc1575ac7a20a6ff8c7fbc760383
ARG LORE_SOURCE=https://github.com/epicgames/lore

LABEL org.opencontainers.image.title="UnrealOps Lore Server" \
      org.opencontainers.image.description="Lore binary asset server with AWS storage plugins" \
      org.opencontainers.image.source="${LORE_SOURCE}" \
      org.opencontainers.image.revision="${LORE_REVISION}" \
      org.opencontainers.image.version="${LORE_VERSION}-unrealops.1" \
      org.opencontainers.image.licenses="MIT" \
      com.unrealops.lore.release.amd64.sha256="e14eeaca47aef92a65f70a1112507f9651e5459d9c6a34be2a41ba8043e89b30" \
      com.unrealops.lore.release.arm64.sha256="02a0e47c672748136b2467efe65961685f5cfb7a341dae0115e0564e3a6ec91d"

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        openssl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/lore/config /etc/lore/certs /var/lib/lore /tmp/lore \
    && chown -R 65532:65532 /var/lib/lore /tmp/lore

COPY --from=release --chown=65532:65532 /out/loreserver /usr/local/bin/loreserver
COPY --from=release /out/licenses /usr/share/doc/lore
COPY --chown=65532:65532 entrypoint.sh /usr/local/bin/lore-entrypoint

ENV LORE_CONFIG_PATH=/etc/lore/config \
    LORE_ENV=production \
    RUST_LOG=info \
    TMPDIR=/tmp

USER 65532:65532
WORKDIR /var/lib/lore

EXPOSE 41337/tcp 41337/udp 41339/tcp 41340/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl --fail --silent --show-error http://127.0.0.1:41339/health_check || exit 1

ENTRYPOINT ["/usr/local/bin/lore-entrypoint"]
