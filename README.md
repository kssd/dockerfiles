# Dockerfile Templates — Secure, Multi-Stage Production Images

Reference Dockerfiles and best-practice guides for building **secure container images**: distroless, non-root, hadolint-clean, multi-stage. Python is the first ecosystem covered; Node, TypeScript, Go, Rust, and JAX are planned.

## Available Dockerfile templates

### Python Dockerfile templates

Secure Python Docker images on **Google Distroless** by default, with Chainguard variants for users who want signed/attested daily-rebuilt images. Plus AWS Lambda Python container images and an agent sandbox for LLM-generated code.

**Distroless (default — freely pinnable to versioned tags):**

- pip → [dockerfiles/python/Dockerfile.python](dockerfiles/python/Dockerfile.python)
- uv → [dockerfiles/python/Dockerfile.uv](dockerfiles/python/Dockerfile.uv)
- Poetry → [dockerfiles/python/Dockerfile.poetry](dockerfiles/python/Dockerfile.poetry)

**Chainguard (signed/attested; free-tier compatible via digest-pinning):**

- pip + Chainguard → [dockerfiles/python/Dockerfile.python.chainguard](dockerfiles/python/Dockerfile.python.chainguard)
- uv + Chainguard → [dockerfiles/python/Dockerfile.uv.chainguard](dockerfiles/python/Dockerfile.uv.chainguard)
- Poetry + Chainguard → [dockerfiles/python/Dockerfile.poetry.chainguard](dockerfiles/python/Dockerfile.poetry.chainguard)

**Specialized runtimes:**

- AWS Lambda container image → [dockerfiles/python/Dockerfile.lambda](dockerfiles/python/Dockerfile.lambda)
- Agent sandbox container → [dockerfiles/python/Dockerfile.sandbox](dockerfiles/python/Dockerfile.sandbox)

Full documentation: [dockerfiles/python/README.md](dockerfiles/python/README.md).

### Node Dockerfile templates _(planned)_

### TypeScript Dockerfile templates _(planned)_

### Go Dockerfile templates _(planned)_

### Rust Dockerfile templates _(planned)_

### JAX Dockerfile templates _(planned)_

## Why these Dockerfile templates

- **Multi-stage builds** keep build toolchains out of runtime images.
- **Non-root containers** with explicit `USER` directives.
- **Pinned base tags and locked dependencies** — reproducible, scanner-friendly.
- **Hadolint-clean** at the `warning` threshold; CI enforces it.

## Repository layout

- `dockerfiles/` — Dockerfile templates organized per ecosystem (e.g. `python/`, `node/`, `go/`).
- `docs/` — Best-practice guides (multi-stage builds, image hardening, caching, etc.).

## Guides

- [Secure software supply chain for Docker images](docs/supply-chain.md) — SBOMs, Cosign signing, SLSA provenance, and Kyverno admission control. Applies to every ecosystem in this repo.

## Tooling

Requires Node.js 20+ (for the lint tooling only) and [hadolint](https://github.com/hadolint/hadolint) on `PATH`.

```sh
npm install        # installs prettier + markdownlint-cli2
npm run lint       # prettier check + markdownlint + hadolint
npm run format     # prettier --write
```

CI runs the same checks on every push and PR (`.github/workflows/lint.yml`).

## Docker for Agentic Applications and components

### "Kitchen Sink" Pradox vs Minimalism

> Change - Maintain two distinct types of images

Traditional best practice/advice is to remove every thing that is not needed for the app to run. However AI agents need broad set of tools (CI utilities, Python libraries, curl, git etc). To solve this:

- **Agent Host (Controller)**
  Follows strict minimalism. This container runs LLM reasoning loop. It should have zero system tools to prevent a compromised agent from breaking out.
- **Execution Sandbox**
  A new class of fat images preloaded with safe, verified tools.

> Instead of using `apt-get install` at runtime (which breaks reproducibility), use "Toolbox" patterns. Build images specifically designed to be mounted or called by agents, containing verified versions of all potenetial tools required by agent.

### Runtime security for generated code

> Change - "Running as non-root" is no longer enough.

Agents often write and execute their own code. A traditional container assumes the codde inside is trusted, but container runs untrusted (ai-generated) code.

- **No network by default**
  Build agent execution images with no network drivers or restricted outbound rules (`--network none` in run commands) unless explicitly needed.
- **Ephemeral & Read-Only**
  Agent workspaces should be disposable. Use `--read-only` root filesystem with a mounted temporary `/workspace` volume which is wiped after every task.

### MCP

Docker is actively integrating with the MCP, a standard that lets agent discover and connect to data sources and tools.

> Change - Dockerfiles are becomming "server definitions" for agent tools.

- **Standardized Entrypoints**
  Images now need to expose standardized endpoints (like MCP servers) so agents can "discover" what images can do.
- **Sidecar Patterns**
  Instead of installing database client inside the agent's image, run the agent alongside an "MCP Gateway" (container that proxies secure access to database).

### Summary

| Feature       | Traditional Practice           | Agentic Practice                            |
| ------------- | ------------------------------ | ------------------------------------------- |
| Image content | Minimal, only app dependencies | Bimodal: Tiny Controllers vs. Fat Toolboxes |
