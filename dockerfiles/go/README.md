# Secure Go Docker Image Templates

Reference Dockerfiles for building **secure Go Docker images** in production — including a **Distroless static** variant for fully-static binaries, a **Chainguard** variant for signed/attested images, an **AWS Lambda** custom-runtime variant, and a **devcontainer** variant for VS Code Remote-Containers.

**Default runtime is [`gcr.io/distroless/static-debian12:nonroot`](https://github.com/GoogleContainerTools/distroless).** Chainguard variants are provided as siblings for users who prefer Chainguard's daily-rebuilt, signed/attested images.

| File                       | Runtime base                                  | Use when                                                                                                     |
| -------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `Dockerfile.go`            | `gcr.io/distroless/static-debian12:nonroot`   | Default. Pure-Go project with `CGO_ENABLED=0`. Smallest possible final image (no libc, no shell).            |
| `Dockerfile.go.chainguard` | `cgr.dev/chainguard/static`                   | You want Chainguard's daily CVE patches, Sigstore signatures, and SLSA provenance. Free-tier uses `:latest`. |
| `Dockerfile.lambda`        | `public.ecr.aws/lambda/provided:al2023`       | Deploying to AWS Lambda as a container image. Binary named `bootstrap`; uses aws-lambda-go SDK.              |
| `Dockerfile.devcontainer`  | `mcr.microsoft.com/devcontainers/go:1-1.23-*` | VS Code Remote-Containers / Dev Containers development environment.                                          |

## Why these images are efficient

### Multi-stage build separates build-time from runtime

The **builder stage** uses the official `golang:*-bookworm` image with the full toolchain. The **runtime stage** uses `distroless/static` — a minimal image with no libc, no shell, no package manager. Only the compiled binary is copied across.

Result: the final image is typically under 10 MB (just the OS CA bundle, tzdata, and your binary).

### Layer-cache optimisation

Module downloads are cached in a separate layer before source is copied:

```dockerfile
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
```

Changing application code does not invalidate the module download layer. Re-builds for code-only changes complete in seconds.

### Multi-arch cross-compilation

`--platform=$BUILDPLATFORM` on the builder ensures the Go compiler runs natively on your host. `TARGETOS` / `TARGETARCH` control the output binary's target. A single `docker buildx build --platform linux/amd64,linux/arm64` produces both variants from the same Dockerfile.

## Why these images are secure

### No libc, no shell (`distroless/static`)

`distroless/static` ships nothing but the Go binary, the OS CA bundle, and tzdata. There is no `/bin/sh`, no `curl`, no package manager. A compromised process cannot drop into a shell, install tools, or fetch payloads using image-provided binaries.

### Non-root by default

The final stage runs as the prebuilt `nonroot` user (UID 65532). The binary is `--chown=nonroot:nonroot` so the process cannot write to its own executable.

### `CGO_ENABLED=0` + `-trimpath -ldflags="-s -w"`

- `CGO_ENABLED=0` produces a fully-static binary — no dynamic linker, no libc dependency.
- `-trimpath` strips host filesystem paths from the binary (prevents accidental path disclosure).
- `-ldflags="-s -w"` strips the symbol table and debug information, reducing binary size ~30%.

### CGO escape hatch

If your project requires CGO (e.g. `mattn/go-sqlite3`, some low-level crypto), switch the runtime to `gcr.io/distroless/base-debian12:nonroot` (includes glibc) and set `CGO_ENABLED=1` in the build step. The Chainguard equivalent is `cgr.dev/chainguard/glibc-dynamic`.

### go.sum verification

`go mod verify` in the builder checks that module contents match the checksums in `go.sum`. Tampered modules fail the build.

### Hadolint-clean

The repo CI runs `hadolint` at the `warning` threshold. These templates follow the rules that matter most for security:

- **DL3007** — pin image tags (`GO_VERSION=1.23`; Chainguard `:latest` is the free-tier constraint, pin by digest in production).
- **DL3025** — JSON-array `ENTRYPOINT` form so signals reach the process directly.

## Build and run

```bash
# Distroless (default)
docker build --platform=linux/amd64 --build-arg GO_VERSION=1.23 \
    -t myapp -f Dockerfile.go .

# Chainguard (free tier — pin by digest in production)
docker build --platform=linux/amd64 -t myapp -f Dockerfile.go.chainguard .

# Lambda (match your function's architecture)
docker build --platform=linux/amd64 --build-arg GO_VERSION=1.23 \
    -t myapp-lambda -f Dockerfile.lambda .

# Multi-arch (both amd64 and arm64)
docker buildx build --platform=linux/amd64,linux/arm64 \
    -t myapp -f Dockerfile.go .

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
├── Dockerfile.go          # or Dockerfile.go.chainguard / Dockerfile.lambda
├── .dockerignore          # provided in this directory
├── go.mod
├── go.sum
└── main.go                # package main entry point (or ./cmd/myapp/main.go)
```

## Lambda variant

The Go Lambda custom runtime uses `public.ecr.aws/lambda/provided:al2023`. The binary **must be named `bootstrap`** — it is the runtime itself, not a handler. Add `github.com/aws/aws-lambda-go` to your module and call `lambda.Start(handler)` in `main()`.

```bash
# Local invocation with the bundled RIE
docker run --rm -p 9000:8080 myapp-lambda
curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" \
    -d '{"key":"value"}'
```

## Devcontainer variant

`Dockerfile.devcontainer` is based on `mcr.microsoft.com/devcontainers/go:1-1.23-bookworm` and includes:

- Go 1.23 toolchain, `gopls`, `go vet`
- `golangci-lint` (pinned), `staticcheck` (pinned)
- Delve debugger `dlv` (required by the VS Code Go extension)
- `goose` DB migration tool (remove from the Dockerfile if unused)
- `make`, `jq`, `git`, `curl` — common dev utilities

The companion `.devcontainer/devcontainer.json` wires up:

- The `golang.go` VS Code extension with `golangci-lint` as the lint tool
- Workspace mounted at `/workspaces/<repo-name>`
- `remoteUser: vscode` (UID 1000, matches the base image's pre-built user)
- `postCreateCommand` that verifies Go and golangci-lint are installed

### Reopen in Container

1. Open the `dockerfiles/go/` folder in VS Code.
2. When prompted "Reopen in Container", click yes — or use `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**.
3. VS Code builds `Dockerfile.devcontainer`, mounts the workspace, and installs extensions.

### Adding ecosystem-specific extensions

Add extension IDs to the `customizations.vscode.extensions` array in `.devcontainer/devcontainer.json`. Common additions:

- `zxh404.vscode-proto3` — Protocol Buffers
- `ms-kubernetes-tools.vscode-kubernetes-tools` — Kubernetes
- `humao.rest-client` — HTTP REST client

### Prebuild caveat

For fast container starts in GitHub Codespaces or large teams, configure a [prebuild](https://docs.github.com/en/codespaces/prebuilding-your-codespaces). Point it at `dockerfiles/go/.devcontainer/devcontainer.json`. The Go module download in `go mod download` is the most expensive step — prebuilds eliminate that wait.

## CGO trade-offs

| Scenario                          | `CGO_ENABLED` | Runtime image                      |
| --------------------------------- | ------------- | ---------------------------------- |
| Pure Go (recommended)             | `0`           | `distroless/static`                |
| Needs libc (sqlite3, some crypto) | `1`           | `distroless/base-debian12`         |
| Chainguard, pure Go               | `0`           | `cgr.dev/chainguard/static`        |
| Chainguard, needs glibc           | `1`           | `cgr.dev/chainguard/glibc-dynamic` |

## Multi-arch builds

```bash
# Enable BuildKit multi-arch
docker buildx create --use

# Build for both amd64 and arm64, push to registry
docker buildx build \
  --platform=linux/amd64,linux/arm64 \
  --push \
  -t myregistry/myapp:latest \
  -f Dockerfile.go .
```

`--platform=$BUILDPLATFORM` in the builder stage ensures the Go compiler binary runs natively (no emulation). Only the output binary is cross-compiled via `GOOS` / `GOARCH`.

## go.sum dep integrity

`go mod verify` checks that downloaded module content matches `go.sum`. This is a build-time supply-chain check: if any module in the cache has been modified since it was downloaded, the build fails.

For deeper supply-chain guarantees — signing images, generating SBOMs, attaching SLSA provenance — see [`docs/supply-chain.md`](../../docs/supply-chain.md).

## Hardening checklist

- [ ] Pin `GO_VERSION` to a real minor (default `1.23`) — never `latest`.
- [ ] Pin the base by digest in production (`gcr.io/distroless/static-debian12@sha256:…`).
- [ ] Commit `go.sum` and let `go mod verify` fail fast on tampered modules.
- [ ] Build with `CGO_ENABLED=0` unless CGO is genuinely required.
- [ ] Use `--platform` flags to build the architecture that matches your runtime target.
- [ ] Run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- [ ] Set resource limits (`--memory`, `--cpus`) to bound runaway processes.
- [ ] Scan the built image (`grype`, `trivy`) before publishing.
- [ ] Sign the image and SLSA provenance with Cosign — see [`docs/supply-chain.md`](../../docs/supply-chain.md).
