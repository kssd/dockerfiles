# Building multi-platform Docker images

Step-by-step guide to building images that run on multiple CPU architectures
— both locally with `docker buildx` and in CI with GitHub Actions.

The two most common targets are `linux/amd64` (x86-64 servers, most CI
runners) and `linux/arm64` (Apple Silicon, AWS Graviton, Raspberry Pi 4).
A single multi-platform push produces one manifest list / OCI image index;
`docker pull` automatically selects the right variant for the host.

## How it works

BuildKit drives every `docker buildx build`. For each target platform it
either:

1. **Cross-compiles natively** — when the language toolchain supports it
   (Go, Rust with the right target, Zig). The builder stage runs on your
   host architecture; only the output binary is for the target. Fast.
2. **Emulates via QEMU** — when the build must _run_ target-arch binaries
   (e.g. compiling native Node modules, running `apt` inside an arm64
   layer). Slow but universal.

The builder stage pattern `FROM --platform=$BUILDPLATFORM ...` selects
strategy 1 wherever possible. Runtime stages need no special treatment —
BuildKit selects the correct base image digest automatically.

## Pre-defined ARGs

These build arguments are injected by BuildKit with no `ARG` declaration
needed on the first `FROM` line. They _must_ be declared with `ARG` in any
stage that uses them.

| ARG              | Example       | What it describes                        |
| ---------------- | ------------- | ---------------------------------------- |
| `BUILDPLATFORM`  | `linux/amd64` | Platform where BuildKit is running       |
| `BUILDOS`        | `linux`       | OS component of the build platform       |
| `BUILDARCH`      | `amd64`       | Arch component of the build platform     |
| `TARGETPLATFORM` | `linux/arm64` | Platform being built (from `--platform`) |
| `TARGETOS`       | `linux`       | OS component of the target platform      |
| `TARGETARCH`     | `arm64`       | Arch component of the target platform    |
| `TARGETVARIANT`  | `v8`          | Variant (e.g. `v7` for 32-bit ARM)       |

## Local builds

### 1. Set up a builder

The default `docker` driver does not support multi-platform builds. Create a
`docker-container` driver builder once per machine:

```bash
docker buildx create \
  --name multiarch \
  --driver docker-container \
  --use
```

Verify the builder is active and see which platforms it supports:

```bash
docker buildx ls
docker buildx inspect --bootstrap
```

### 2. Install QEMU (for emulated targets)

Only required when the build must _run_ binaries for a non-native
architecture (e.g. building an arm64 image on an amd64 host with native
arm64 `RUN` steps):

```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

On an amd64 host building Go or Rust images with native cross-compilation
(`--platform=$BUILDPLATFORM` builder stage), this step is optional.

### 3. Build and push

`--load` only works for a single platform (it loads into the local Docker
daemon, which cannot store a manifest list). Use `--push` for multi-arch:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t myregistry/myapp:latest \
  -f dockerfiles/go/Dockerfile.go \
  .
```

To export locally without a registry (e.g. for offline inspection), write
an OCI tarball:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --output type=oci,dest=image.tar \
  .
```

To build a single platform and load it into the local daemon (for `docker run`
testing before the multi-arch push):

```bash
docker buildx build \
  --platform linux/amd64 \
  --load \
  -t myapp:test \
  .
```

### 4. Inspect the manifest

After pushing, verify that both platform entries are present:

```bash
docker buildx imagetools inspect myregistry/myapp:latest
```

Output shows a manifest list with one entry per platform, each with its own
digest. Pin those digests in dependent Dockerfiles instead of relying on
the mutable tag.

## Cross-compilation patterns by language

### Go

Go cross-compiles natively — no QEMU needed. The key is pinning the builder
to `$BUILDPLATFORM` and passing `GOOS`/`GOARCH` to the compiler:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.23-bookworm AS builder
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

RUN CGO_ENABLED=0 \
    GOOS=$TARGETOS \
    GOARCH=$TARGETARCH \
    GOARM=${TARGETVARIANT#v} \
    go build -trimpath -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/app /app
ENTRYPOINT ["/app"]
```

`CGO_ENABLED=0` is required. With CGO enabled, Go links against libc and the
cross-compilation degrades to the QEMU path.

### Rust

Rust requires a cross-compilation target toolchain. Install it in the builder
stage and set `CARGO_BUILD_TARGET`:

```dockerfile
FROM --platform=$BUILDPLATFORM rust:1.82-bookworm AS builder
ARG TARGETARCH

RUN case "$TARGETARCH" in \
      arm64) TARGET=aarch64-unknown-linux-musl ;; \
      amd64) TARGET=x86_64-unknown-linux-musl ;; \
    esac && \
    rustup target add "$TARGET" && \
    cargo build --release --target "$TARGET" && \
    cp target/$TARGET/release/myapp /out/myapp

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/myapp /app
ENTRYPOINT ["/app"]
```

Alternatively, use the [`cross`](https://github.com/cross-rs/cross) crate
to manage cross-compile toolchains outside the Dockerfile.

### Node.js

Pure JavaScript projects cross-compile trivially. The problem is native
modules (node-gyp, `better-sqlite3`, `bcrypt`, etc.) which must compile
for the target architecture. Options, ordered by preference:

1. **Pre-built binaries** — many packages publish pre-built `.node` binaries
   for common architectures; `npm install` selects them automatically.
2. **QEMU** — add `docker/setup-qemu-action` (CI) or `tonistiigi/binfmt`
   (local); remove `--platform=$BUILDPLATFORM` from the builder stage so
   `npm install` runs under emulation.
3. **`--platform=$BUILDPLATFORM` + `--target-arch`** — pass the target
   architecture to `node-gyp` explicitly. Complex and package-specific.

```dockerfile
# Pure-JS project (no native modules): cross-platform, no QEMU needed
FROM --platform=$BUILDPLATFORM node:20-bookworm-slim AS builder
RUN npm ci --omit=dev
```

```dockerfile
# Native modules: run npm install under QEMU (no BUILDPLATFORM pin)
FROM node:20-bookworm-slim AS builder
RUN npm ci --omit=dev
```

## GitHub Actions

### Actions used

| Action                       | Version | Purpose                                                  |
| ---------------------------- | ------- | -------------------------------------------------------- |
| `docker/setup-qemu-action`   | `v3`    | Install QEMU static binaries for emulation               |
| `docker/setup-buildx-action` | `v3`    | Create and configure a `docker-container` buildx builder |
| `docker/login-action`        | `v3`    | Authenticate to a container registry                     |
| `docker/metadata-action`     | `v5`    | Generate OCI-compliant tags and labels from git metadata |
| `docker/build-push-action`   | `v6`    | Build and push with BuildKit                             |

### Minimal workflow

Builds `linux/amd64` and `linux/arm64` on every push to `main`, using the
GitHub Actions cache for layer reuse:

```yaml
name: Build

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-qemu-action@v3

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          push: true
          platforms: linux/amd64,linux/arm64
          tags: ghcr.io/${{ github.repository }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### Production workflow with metadata and provenance

Generates semantic-version tags from git tags, attaches OCI labels and
SLSA provenance, and pushes only on `main` or a version tag:

```yaml
name: Build and push

on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
    branches: [main]

env:
  IMAGE: ghcr.io/${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write # required for keyless Cosign signing

    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-qemu-action@v3
        with:
          platforms: linux/amd64,linux/arm64

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        if: github.event_name != 'pull_request'
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.IMAGE }}
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,prefix={{branch}}-,format=short

      - uses: docker/build-push-action@v6
        with:
          push: ${{ github.event_name != 'pull_request' }}
          platforms: linux/amd64,linux/arm64
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: mode=max
          sbom: true
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### Caching strategies

#### GitHub Actions cache (`type=gha`)

Stores layer cache in GitHub's hosted cache (up to 5 GB per repo, evicted
after 7 days of no access). Best default for most projects.

```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```

`mode=max` caches every layer including intermediate stages (e.g. the
builder stage). Worth the extra storage for builds with expensive dep-install
layers.

#### Registry cache (`type=registry`)

Stores the cache in the container registry as a separate tag. Survives
longer, is shareable across workflows and forks, and is not subject to
GitHub's per-repo cache limit.

```yaml
cache-from: type=registry,ref=${{ env.IMAGE }}:buildcache
cache-to: type=registry,ref=${{ env.IMAGE }}:buildcache,mode=max
```

#### Per-branch fallback strategy

Feature-branch builds warm a branch-specific cache but fall back to the
main-branch cache on the first run of a new branch:

```yaml
cache-from: |
  type=registry,ref=${{ env.IMAGE }}:cache-${{ github.ref_name }}
  type=registry,ref=${{ env.IMAGE }}:cache-main
cache-to: >-
  type=registry,ref=${{ env.IMAGE }}:cache-${{ github.ref_name }},mode=max
```

## Common pitfalls

| Pitfall                                     | Symptom                                                  | Fix                                                                  |
| ------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------- |
| `--load` with multiple platforms            | `error: docker exporter does not support manifest lists` | Remove `--load`; use `--push` or `--output type=oci,dest=image.tar`  |
| QEMU for a pure-Go build                    | Build takes 10× longer than expected                     | Add `--platform=$BUILDPLATFORM` to the builder `FROM` line           |
| `TARGETOS` undefined in a non-builder stage | Empty variable, wrong binary shipped                     | Declare `ARG TARGETOS` in every stage that uses it                   |
| Missing QEMU in GitHub Actions              | `exec format error` during `RUN` for non-native arch     | Add `docker/setup-qemu-action@v3` before `setup-buildx-action`       |
| Signing a mutable tag                       | Signature becomes invalid when the tag moves             | Sign by digest: `cosign sign image@sha256:<digest>`                  |
| Cache writes on PRs from forks              | `cache-to` step fails (no write permission)              | Wrap `cache-to` with `if: github.event_name != 'pull_request'`       |
| `arm64` vs `linux/arm64/v8` mismatch        | Platform not found in manifest                           | Always use the full `os/arch` form; `linux/arm64` ≡ `linux/arm64/v8` |

## Verifying the result

After a multi-platform push, inspect the manifest to confirm both entries
are present and correct:

```bash
# List all platforms in the manifest
docker buildx imagetools inspect ghcr.io/org/repo:latest

# Extract the config for a specific platform
docker buildx imagetools inspect \
  --format '{{json (index .Image "linux/arm64")}}' \
  ghcr.io/org/repo:latest

# Pull and run the arm64 variant explicitly (on any host)
docker run --platform linux/arm64 --rm ghcr.io/org/repo:latest
```

## Further reading

- [Multi-platform images — Docker docs](https://docs.docker.com/build/building/multi-platform/)
- [docker/build-push-action](https://github.com/docker/build-push-action)
- [docker/metadata-action](https://github.com/docker/metadata-action)
- [Signing and attestation](supply-chain.md) — sign the multi-platform manifest and attach SLSA provenance
