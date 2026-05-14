# Secure Rust Docker Image Templates

Reference Dockerfiles for building **secure Rust Docker images** in production — including a **Distroless cc** variant with cargo-chef dep caching, a **Chainguard** variant for signed/attested images, and a **devcontainer** variant for VS Code Remote-Containers.

**Default runtime is [`gcr.io/distroless/cc-debian12:nonroot`](https://github.com/GoogleContainerTools/distroless).** This image includes glibc and libstdc++ for dynamically-linked GNU Rust binaries. Chainguard variants are provided as siblings for users who prefer Chainguard's daily-rebuilt, signed/attested images.

| File                         | Runtime base                               | Use when                                                                                                        |
| ---------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `Dockerfile.rust`            | `gcr.io/distroless/cc-debian12:nonroot`    | Default. GNU Rust binary (glibc-linked). Full cargo-chef dep caching. Smallest image that works out of the box. |
| `Dockerfile.rust.chainguard` | `cgr.dev/chainguard/glibc-dynamic`         | You want Chainguard's daily CVE patches, Sigstore signatures, and SLSA provenance. Free-tier uses `:latest`.    |
| `Dockerfile.devcontainer`    | `mcr.microsoft.com/devcontainers/rust:1-*` | VS Code Remote-Containers / Dev Containers development environment.                                             |

## Why these images are efficient

### cargo-chef dep caching

The biggest Rust Docker pain point is recompiling all dependencies on every code change. The templates use [cargo-chef](https://github.com/LukeMathWalker/cargo-chef) to solve this:

```dockerfile
# Stage 1: chef — installs cargo-chef once
FROM rust:1.82-slim AS chef
RUN cargo install cargo-chef --version 0.1.77 --locked

# Stage 2: planner — extracts dependency metadata into recipe.json
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Stage 3: builder — cooks deps (cached), then compiles app
FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json   # <-- cached layer
COPY . .
RUN cargo build --release --bin "${BIN_NAME}"
```

`recipe.json` encodes only the dependency graph. It changes only when `Cargo.toml` / `Cargo.lock` change, not on every `src/` edit. Rebuilds for code-only changes skip the `cargo chef cook` layer entirely.

### Multi-stage build separates build-time from runtime

The **builder stages** use the full `rust:*-slim` image with the Rust toolchain. The **runtime stage** uses `distroless/cc` — no Rust toolchain, no cargo, no package manager. Only the compiled binary is copied across.

Result: the final image is typically under 50 MB for most Rust binaries (vs. 1+ GB for the full toolchain).

## Why these images are secure

### Minimal runtime (`distroless/cc`)

`distroless/cc` ships glibc and libstdc++ — just enough for a dynamically-linked Rust binary. There is no `/bin/sh`, no package manager, no curl. A compromised process cannot drop into a shell or install tools using image-provided binaries.

### Non-root by default

The final stage runs as the prebuilt `nonroot` user (UID 65532). The binary is `--chown=nonroot:nonroot` so the process cannot write to its own executable.

### Strip symbols in release builds

`cargo build --release` strips debug info by default. Add to `Cargo.toml` for maximum size reduction:

```toml
[profile.release]
strip = true
opt-level = "z"
lto = true
codegen-units = 1
```

## musl vs GNU

| Variant       | Cargo target                | Binary linker | Runtime image                |
| ------------- | --------------------------- | ------------- | ---------------------------- |
| GNU (default) | `x86_64-unknown-linux-gnu`  | glibc         | `distroless/cc-debian12`     |
| musl (static) | `x86_64-unknown-linux-musl` | musl (static) | `distroless/static-debian12` |

Switching to musl requires:

1. Add the target: `rustup target add x86_64-unknown-linux-musl`
2. Install the musl linker: `apt-get install musl-tools`
3. Set `RUSTFLAGS="-C target-feature=+crt-static"` and pass `--target x86_64-unknown-linux-musl`
4. The binary output path changes to `target/x86_64-unknown-linux-musl/release/<bin>`
5. Switch the runtime image to `gcr.io/distroless/static-debian12:nonroot`

This is a non-trivial change; the default template ships GNU to keep the Dockerfile straightforward.

## Build and run

```bash
# Distroless (default — set BIN_NAME to your binary)
docker build --build-arg BIN_NAME=mybin -t myapp -f Dockerfile.rust .

# Chainguard (free tier — pin by digest in production)
docker build --build-arg BIN_NAME=mybin -t myapp -f Dockerfile.rust.chainguard .

# Multi-arch (both amd64 and arm64)
docker buildx build --platform=linux/amd64,linux/arm64 \
    --build-arg BIN_NAME=mybin -t myapp -f Dockerfile.rust .

# Run (hardened)
docker run --rm \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  myapp
```

## Expected build-context layout

```text
.
├── Dockerfile.rust          # or Dockerfile.rust.chainguard
├── .dockerignore            # provided in this directory (excludes target/)
├── Cargo.toml
├── Cargo.lock               # commit this — cargo-chef needs it for reproducible builds
└── src/
    └── main.rs
```

> **Important**: commit `Cargo.lock` for binary crates. cargo-chef uses it to produce a stable `recipe.json`; without it, dep versions float and the cache layer invalidates unpredictably.

## Chainguard digest-pinning

The Chainguard free tier publishes only `:latest`. For reproducible builds, pin by digest:

```bash
docker pull cgr.dev/chainguard/rust:latest
docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/rust:latest

docker pull cgr.dev/chainguard/glibc-dynamic:latest
docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/glibc-dynamic:latest
```

Then replace the `FROM` lines with the digest form:

```dockerfile
FROM cgr.dev/chainguard/rust@sha256:<digest> AS chef
# ...
FROM cgr.dev/chainguard/glibc-dynamic@sha256:<digest>
```

Refresh digests deliberately (e.g. weekly) and re-scan with `grype` or `trivy`.

## Devcontainer variant

`Dockerfile.devcontainer` is based on `mcr.microsoft.com/devcontainers/rust:1-bookworm` and adds:

- `cargo-edit` — `cargo add` / `cargo rm` / `cargo upgrade` subcommands
- `cargo-watch` — auto-recompile on file changes (`cargo watch -x run`)
- `cargo-nextest` — fast parallel test runner (`cargo nextest run`)
- `cargo-chef` — same version as production templates
- `clippy` and `rustfmt` components via `rustup component add`

The companion `.devcontainer/devcontainer.json` wires up:

- `rust-lang.rust-analyzer` with clippy as the check command
- `vadimcn.vscode-lldb` for native debugger support
- `tamasfe.even-better-toml` for `Cargo.toml` syntax
- `serayuzgur.crates` + `fill-labs.dependi` for crate version hints
- `postCreateCommand: cargo fetch` to warm the dep cache on container start

### Reopen in Container

1. Open the `dockerfiles/rust/` folder in VS Code.
2. When prompted "Reopen in Container", click yes — or use `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**.
3. VS Code builds `Dockerfile.devcontainer`, mounts the workspace, and installs extensions.

## Multi-arch builds

```bash
docker buildx create --use

docker buildx build \
  --platform=linux/amd64,linux/arm64 \
  --push \
  --build-arg BIN_NAME=mybin \
  -t myregistry/myapp:latest \
  -f Dockerfile.rust .
```

## Hardening checklist

- [ ] Set `BIN_NAME` to your actual binary name — matches `[[bin]]` in `Cargo.toml`.
- [ ] Pin `RUST_TAG` to a real minor (default `1.82`) — never `latest`.
- [ ] Pin the base by digest in production (`gcr.io/distroless/cc-debian12@sha256:…`).
- [ ] Commit `Cargo.lock` for binary crates; include it in the build context.
- [ ] Add `strip = true`, `lto = true` to `[profile.release]` in `Cargo.toml`.
- [ ] Build with `--platform` matching your deployment target architecture.
- [ ] Run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- [ ] Set resource limits (`--memory`, `--cpus`) to bound runaway processes.
- [ ] Scan the built image (`grype`, `trivy`) before publishing.
- [ ] Sign the image and SLSA provenance with Cosign — see [`docs/supply-chain.md`](../../docs/supply-chain.md).
