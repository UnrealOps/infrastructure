# Lore image

The Dockerfile packages Epic's published Lore server binaries; it does not
compile Lore from source. Each platform downloads the matching asset from the
[v0.8.5 release](https://github.com/EpicGames/lore/releases/tag/v0.8.5):

- `linux/amd64` uses Epic's x86_64 GNU/Linux server binary for the write tier.
- `linux/arm64` uses Epic's Neoverse GNU/Linux server binary for the C8gd edge
  tier.

BuildKit verifies the release archive against the SHA-256 recorded in
`source.env` and repeated in the Dockerfile's `ADD --checksum` instruction. A
changed or replaced download fails the build. The release license and
third-party notices are copied into the runtime image with the server binary.

Build the multi-architecture image from the pinned manifest:

```bash
source docker/lore/source.env
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg "LORE_VERSION=${LORE_VERSION}" \
  --build-arg "LORE_REVISION=${LORE_REVISION}" \
  --build-arg "LORE_SOURCE=${LORE_SOURCE}" \
  --file docker/lore/Dockerfile \
  docker/lore
```

Epic does not currently publish a container image for Lore. This Dockerfile is
therefore a hardened packaging layer around Epic's unmodified release binaries:
the runtime is digest-pinned, non-root, and compatible with a read-only root
filesystem.
