# TypeScript Dockerfiles

Production-ready and development-ready Docker image templates for TypeScript applications.

## Variants

| File                               | Base image                                                              | Use case              |
| ---------------------------------- | ----------------------------------------------------------------------- | --------------------- |
| `Dockerfile.typescript`            | `node:22-slim` → `gcr.io/distroless/nodejs22-debian12:nonroot`          | Default production    |
| `Dockerfile.typescript.chainguard` | `cgr.dev/chainguard/node:latest-dev` → `cgr.dev/chainguard/node:latest` | Chainguard production |
| `Dockerfile.devcontainer`          | `mcr.microsoft.com/devcontainers/typescript-node:1-22-bookworm`         | VS Code devcontainer  |

## Build and run

```bash
# Default (distroless)
docker build --build-arg NODE_TAG=22-slim -t myapp -f Dockerfile.typescript .
docker run --rm myapp

# Chainguard
docker build -t myapp -f Dockerfile.typescript.chainguard .
```

## Multi-platform builds

```bash
docker buildx build \
  --platform=linux/amd64,linux/arm64 \
  -t myapp -f Dockerfile.typescript .
```

## Three-stage build

The default Dockerfile uses three stages to minimise layer invalidation:

```text
deps  → npm ci --omit=dev          (production node_modules only)
build → npm ci + tsc               (full devDeps + TypeScript compile)
final → distroless + dist + deps   (no compiler, no devDeps, no shell)
```

The `deps` stage is separate from `build` so that a source-only change
re-runs `tsc` without re-running `npm ci --omit=dev`. The expensive install
is only busted when `package-lock.json` changes.

## Expected project layout

The Dockerfiles assume:

```text
package.json
package-lock.json
tsconfig.json          # outDir must be "./dist"
src/
  index.ts             # compiled to dist/index.js
```

If your `outDir` or entry point differs, update the `CMD` in the Dockerfile:

```dockerfile
CMD ["/app/dist/server.js"]
```

## Distroless ENTRYPOINT note

`gcr.io/distroless/nodejs22-debian12` sets `ENTRYPOINT ["/nodejs/bin/node"]`.
Your `CMD` must be **the compiled JS path only** — not `["node", "dist/index.js"]`.

```dockerfile
# Correct
CMD ["/app/dist/index.js"]

# Wrong — "node" is treated as an argument to node, which looks for a file
# named "node"
CMD ["node", "/app/dist/index.js"]
```

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

### No Lambda variant

TypeScript projects compile to JavaScript before deployment. Use the
[Node.js `Dockerfile.lambda`](../node/Dockerfile.lambda) with your compiled
`dist/` output — build `dist/` in CI, then copy it into the Lambda image.

## Devcontainer

Open the `typescript/` directory in VS Code and select **Reopen in Container**.
The devcontainer installs additional global tools:

| Tool | Version | Purpose                                       |
| ---- | ------- | --------------------------------------------- |
| pnpm | 9.15.4  | Fast, disk-efficient package manager          |
| tsx  | 4.19.3  | Run TypeScript/ESM files without a build step |

The base `mcr.microsoft.com/devcontainers/typescript-node` image already
ships `typescript` and `ts-node` globally, so they are not re-installed here.

## Hardening checklist

- [ ] Pin base image tags to digests in production
- [ ] Scan the final image with `grype` or `trivy` before shipping
- [ ] Enable `"strict": true` in `tsconfig.json` to catch type errors early
- [ ] Use `npm ci` (not `npm install`) to ensure reproducible installs
- [ ] Strip dev dependencies from the runtime image (`npm ci --omit=dev`)
- [ ] Set `NODE_OPTIONS=--max-old-space-size=<MB>` to bound heap growth
- [ ] Set `NODE_ENV=production` to disable dev-only framework features
