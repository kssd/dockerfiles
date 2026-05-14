# Node.js Dockerfiles

Production-ready and development-ready Docker image templates for Node.js applications.

## Variants

| File                         | Base image                                                              | Use case              |
| ---------------------------- | ----------------------------------------------------------------------- | --------------------- |
| `Dockerfile.node`            | `node:22-slim` → `gcr.io/distroless/nodejs22-debian12:nonroot`          | Default production    |
| `Dockerfile.node.chainguard` | `cgr.dev/chainguard/node:latest-dev` → `cgr.dev/chainguard/node:latest` | Chainguard production |
| `Dockerfile.lambda`          | `public.ecr.aws/lambda/nodejs:22`                                       | AWS Lambda            |
| `Dockerfile.sandbox`         | `node:22-slim`                                                          | Agent code execution  |
| `Dockerfile.devcontainer`    | `mcr.microsoft.com/devcontainers/javascript-node:1-22-bookworm`         | VS Code devcontainer  |

## Build and run

```bash
# Default (distroless)
docker build --build-arg NODE_TAG=22-slim -t myapp -f Dockerfile.node .
docker run --rm myapp

# Chainguard
docker build -t myapp -f Dockerfile.node.chainguard .

# Lambda (always target the function's architecture)
docker build --platform=linux/amd64 -t myapp-lambda -f Dockerfile.lambda .

# Sandbox
docker build -t node-sandbox -f Dockerfile.sandbox .
docker run --rm -it \
  --read-only \
  --tmpfs /workspace:rw,exec,size=256m,uid=10001,gid=10001 \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --network none \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --memory=512m --cpus=1 \
  --pids-limit=256 \
  node-sandbox
```

## Multi-platform builds

```bash
docker buildx build \
  --platform=linux/amd64,linux/arm64 \
  -t myapp -f Dockerfile.node .
```

The sandbox targets only `linux/amd64` and `linux/arm64` (both supported by
`node:22-slim`). Lambda targets a single architecture matching your function.

## Distroless ENTRYPOINT note

`gcr.io/distroless/nodejs22-debian12` sets `ENTRYPOINT ["/nodejs/bin/node"]`.
Your `CMD` must be **the script path only** — not `["node", "/app/src/index.js"]`.

```dockerfile
# Correct
CMD ["/app/src/index.js"]

# Wrong — "node" becomes an argument to node, which tries to load a file
# named "node"
CMD ["node", "/app/src/index.js"]
```

## Efficiency

### Layer-cache layout

Both production variants copy `package*.json` before application source so the
`npm ci` layer is only invalidated when the lockfile changes:

```dockerfile
COPY package*.json ./
RUN npm ci --omit=dev   # cached until lockfile changes

COPY . .                # source changes here don't bust the install layer
```

### Production-only deps

`npm ci --omit=dev` keeps dev tooling (eslint, jest, ts-node, etc.) out of
the runtime image. The `NODE_ENV=production` env var reinforces this.

## Security

### Chainguard variant

`cgr.dev/chainguard/node:latest` receives daily CVE patches and ships with
Sigstore signatures and SBOMs. The free Developer Edition only publishes
`:latest` — pin by digest for reproducibility:

```bash
docker pull cgr.dev/chainguard/node:latest
docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/node:latest
# FROM cgr.dev/chainguard/node:latest@sha256:<digest>
```

### Sandbox

The sandbox follows the principle of least privilege:

- Non-root `agent` user (UID 10001) with a fixed UID for predictable
  `--tmpfs` ownership
- `tini` as PID 1 to reap zombie subprocesses
- Intended to run with `--read-only`, `--cap-drop=ALL`,
  `--security-opt=no-new-privileges`, and `--network none`
- `/workspace` is the only writable directory (tmpfs mount)

## Devcontainer

Open the `node/` directory in VS Code and select **Reopen in Container**.
The devcontainer installs additional global tools:

| Tool | Version | Purpose                                       |
| ---- | ------- | --------------------------------------------- |
| pnpm | 9.15.4  | Fast, disk-efficient package manager          |
| tsx  | 4.19.3  | Run TypeScript/ESM files without a build step |

## Hardening checklist

- [ ] Pin base image tag to a digest in production
- [ ] Scan the final image with `grype` or `trivy` before shipping
- [ ] Set `NODE_OPTIONS=--max-old-space-size=<MB>` to bound heap growth
- [ ] Use `--read-only` + tmpfs mounts at runtime where possible
- [ ] Prefer `npm ci` over `npm install` to ensure reproducible installs
- [ ] Strip dev dependencies from the runtime image (`npm ci --omit=dev`)
