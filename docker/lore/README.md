# Lore image

The Dockerfile consumes a BuildKit named context called `lore-source`. Build
only from the commit in `source.env`:

```bash
source docker/lore/source.env
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-context "lore-source=${LORE_SOURCE}.git#${LORE_REVISION}" \
  --build-arg "LORE_VERSION=${LORE_VERSION}" \
  --build-arg "LORE_REVISION=${LORE_REVISION}" \
  --build-arg "LORE_SOURCE=${LORE_SOURCE}" \
  --file docker/lore/Dockerfile \
  docker/lore
```

The builder uses `Cargo.lock` and the repository's `release-lto` profile. The
runtime is non-root and compatible with a read-only root filesystem.
