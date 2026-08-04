# syntax=docker/dockerfile:1.18@sha256:dabfc0969b935b2080555ace70ee69a5261af8a8f1b4df97b9e7fbcf6722eddf

FROM rust:slim-bookworm@sha256:99e09cb2284e2ddbb73a995deee3e91783fd04d177602ccf6eab326d778ee777 AS builder

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        build-essential \
        ca-certificates \
        libprotobuf-dev \
        protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY --from=lore-source . .

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/target \
    cargo build --locked --profile release-lto --bin loreserver \
    && cp /build/target/release-lto/loreserver /tmp/loreserver \
    && strip /tmp/loreserver

FROM ubuntu:24.04@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea

ARG LORE_VERSION=0.8.5
ARG LORE_REVISION=2d86d1dda98bfc1575ac7a20a6ff8c7fbc760383
ARG LORE_SOURCE=https://github.com/epicgames/lore

LABEL org.opencontainers.image.title="UnrealOps Lore Server" \
      org.opencontainers.image.description="Lore binary asset server with AWS storage plugins" \
      org.opencontainers.image.source="${LORE_SOURCE}" \
      org.opencontainers.image.revision="${LORE_REVISION}" \
      org.opencontainers.image.version="${LORE_VERSION}-unrealops.1" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        openssl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/lore/config /etc/lore/certs /var/lib/lore /tmp/lore \
    && chown -R 65532:65532 /var/lib/lore /tmp/lore

COPY --from=builder --chown=65532:65532 /tmp/loreserver /usr/local/bin/loreserver
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
