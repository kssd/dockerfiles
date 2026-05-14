# Secure Zig Docker Image Templates

Reference Dockerfiles for building **secure Zig Docker images** in production — a **Distroless static** variant, a **Chainguard** variant for signed/attested images, and a **devcontainer** for VS Code.

**Default runtime is [`gcr.io/distroless/static-debian12:nonroot`](https://github.com/GoogleContainerTools/distroless).** Zig targets musl libc by default (bundled in the toolchain), producing fully-static binaries that need no shared libraries at runtime.

| File                        | Builder                                   | Runtime base                                      | Use when                                                                |
| --------------------------- | ----------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------- |
| `Dockerfile.zig`            | `debian:bookworm-slim` + Zig tarball      | `gcr.io/distroless/static-debian12:nonroot`       | Default. Fully-static binary, no libc dependency, smallest final image. |
| `Dockerfile.zig.chainguard` | `cgr.dev/chainguard/wolfi-base` + tarball | `cgr.dev/chainguard/static`                       | Chainguard daily CVE patches, Sigstore signatures, SLSA provenance.     |
| `Dockerfile.devcontainer`   | —                                         | `mcr.microsoft.com/devcontainers/base:1-bookworm` | VS Code Remote-Containers / Dev Containers development environment.     |

## Why the tarball approach — and why SHA-256 verification matters

Zig does not ship packages through `apt`, `apk`, or any other OS package manager. The official distribution channel is a direct tarball from `ziglang.org`. Because this is an unsigned download (no GPG, no apt signature), the only integrity check is the SHA-256 hash published on the Zig downloads page.

The Dockerfiles pin **both** the version and the SHA-256 hash and verify them with `sha256sum -c` before extracting. A tampered or substituted tarball fails the build.

```dockerfile
RUN curl -fsSL "${ZIG_URL}" -o /tmp/zig.tar.xz && \
    echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - && \
    tar -xJf /tmp/zig.tar.xz ...
```

When upgrading `ZIG_VERSION`, update both the version ARG and the SHA-256 constants. Fetch fresh hashes from [ziglang.org/download](https://ziglang.org/download/).

## Why distroless/static works for Zig

Zig uses a bundled musl libc by default. Unless you explicitly link against a system library with `-lc` (which pulls in glibc), the output binary has no shared library dependencies — it is fully self-contained. `ldd` on a default Zig release binary returns `not a dynamic executable`.

`gcr.io/distroless/static` contains only:

- CA certificates (for TLS)
- `/etc/passwd` and `/etc/group` with the `nonroot` user
- tzdata

There is no shell, no package manager, no curl, no libc. A compromised process cannot drop to a shell or install tools from the image.

If your application links a C library via `-lc` (glibc), switch the runtime to `gcr.io/distroless/cc-debian12:nonroot`.

## Optimize modes (`ZIG_OPTIMIZE`)

| Mode           | Safety checks | Speed    | Binary size | Use when                                 |
| -------------- | ------------- | -------- | ----------- | ---------------------------------------- |
| `ReleaseSafe`  | Yes           | Fast     | Medium      | Default. Production with safe defaults.  |
| `ReleaseFast`  | No            | Fastest  | Medium      | Maximum throughput; no bounds checks.    |
| `ReleaseSmall` | No            | Moderate | Smallest    | Embedded targets, Lambda, tight budgets. |
| `Debug`        | Yes           | Slow     | Large       | Development; never ship to production.   |

Pass `--build-arg ZIG_OPTIMIZE=ReleaseFast` to override.

## `zig build` vs `zig build-exe`

The Dockerfiles use `zig build`, which reads `build.zig` and outputs to `zig-out/bin/<name>`. This is the recommended approach for applications because it respects project-level build options, dependencies, and custom steps.

For a quick one-off binary without `build.zig`:

```dockerfile
RUN zig build-exe -O ReleaseSafe -target x86_64-linux-musl src/main.zig -femit-bin=/server
```

`zig build-exe` outputs directly to the specified path — no `zig-out/` directory. Use this only for single-file programs; real projects should use `build.zig`.

## Cross-compilation

Zig's cross-compilation is first-class. To build for a different target from the host:

```bash
# Build for Linux ARM64 on an x86_64 host (no QEMU needed)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

In Docker with `docker buildx`:

```bash
docker buildx build --platform=linux/arm64 \
    --build-arg BIN_NAME=myapp -t myapp -f Dockerfile.zig .
```

`--platform=$BUILDPLATFORM` on the builder stage keeps the Zig compiler itself running natively. Only the output binary is cross-compiled.

## Upgrading Zig version

1. Check the latest stable release at [ziglang.org/download](https://ziglang.org/download/).
2. Download the tarballs and verify them:

```bash
curl -fsSL https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz | sha256sum
curl -fsSL https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz | sha256sum
```

1. Update `ARG ZIG_VERSION` and both SHA-256 constants in `Dockerfile.zig`,
   `Dockerfile.zig.chainguard`, and `Dockerfile.devcontainer`.
1. Update `ZLS_VERSION` in `Dockerfile.devcontainer` and `devcontainer.json`
   to match — ZLS must match the Zig version exactly.

## Build and run

```bash
# Distroless (default)
docker build --build-arg BIN_NAME=myapp -t myapp -f Dockerfile.zig .

# Custom optimize mode
docker build --build-arg BIN_NAME=myapp --build-arg ZIG_OPTIMIZE=ReleaseSmall \
    -t myapp -f Dockerfile.zig .

# Chainguard (free tier -- pin by digest in production)
docker build --build-arg BIN_NAME=myapp -t myapp -f Dockerfile.zig.chainguard .

# Multi-arch
docker buildx build --platform=linux/amd64,linux/arm64 \
    --build-arg BIN_NAME=myapp -t myapp -f Dockerfile.zig .

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
├── Dockerfile.zig          # or Dockerfile.zig.chainguard
├── .dockerignore           # provided (excludes zig-cache/, .zig-cache/, zig-out/)
├── build.zig               # required: defines executable name and build options
├── build.zig.zon           # optional: package manifest (fetched during build)
└── src/
    └── main.zig
```

> **BIN_NAME** must match the executable name declared in `build.zig` (`b.addExecutable(.{ .name = "<BIN_NAME>" })`).

## Chainguard digest-pinning

The Chainguard free tier publishes only `:latest`. For reproducible builds, pin by digest:

```bash
docker pull cgr.dev/chainguard/wolfi-base:latest
docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/wolfi-base:latest

docker pull cgr.dev/chainguard/static:latest
docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/static:latest
```

Then replace the `FROM` lines with the digest form:

```dockerfile
FROM cgr.dev/chainguard/wolfi-base@sha256:<digest> AS builder
# ...
FROM cgr.dev/chainguard/static@sha256:<digest>
```

## Devcontainer variant

`Dockerfile.devcontainer` is based on `mcr.microsoft.com/devcontainers/base:1-bookworm` and adds:

- Zig toolchain (pinned, SHA-256 verified)
- ZLS (Zig Language Server, matching Zig version)
- `gdb`, `lldb`, `valgrind` for debugging and memory analysis

The companion `.devcontainer/devcontainer.json` wires up:

- `ziglang.vscode-zig` extension (uses the installed ZLS and Zig binaries)
- `vadimcn.vscode-lldb` for native debugger support
- Format on save via ZLS
- `postCreateCommand: zig version && zls --version` to verify the install

### Reopen in Container

1. Open the `dockerfiles/zig/` folder in VS Code.
2. When prompted "Reopen in Container", click yes — or use `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**.
3. VS Code builds `Dockerfile.devcontainer`, mounts the workspace, and installs extensions.

## Linking against libc

If your application calls C functions (e.g. via `@cImport`) and links glibc:

```zig
// Forces dynamic glibc linkage
exe.linkLibC();
```

Switch the runtime to `gcr.io/distroless/cc-debian12:nonroot` which includes glibc and libstdc++. Alternatively, target musl explicitly to keep the binary static:

```zig
// build.zig
exe.target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
    .abi = .musl,
});
```

## Hardening checklist

- [ ] Set `BIN_NAME` to the executable name declared in `build.zig`.
- [ ] Pin `ZIG_VERSION` (default `0.16.0`) and update both SHA-256 constants together.
- [ ] Commit `build.zig.zon` with exact dependency hashes — `zig build --fetch` verifies them.
- [ ] Use `ReleaseSafe` in production (bounds and overflow checks) unless benchmarks justify `ReleaseFast`.
- [ ] Build with `--platform` matching your deployment target architecture.
- [ ] Run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- [ ] Set resource limits (`--memory`, `--cpus`) to bound runaway processes.
- [ ] Scan the built image (`grype`, `trivy`) before publishing.
- [ ] Sign the image and SLSA provenance with Cosign — see [`docs/supply-chain.md`](../../docs/supply-chain.md).
