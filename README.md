# Dockerfiles — Secure, Multi-Stage Production Images

> Production-grade [Docker](https://www.docker.com/) image templates: [distroless](https://github.com/GoogleContainerTools/distroless), non-root, [hadolint](https://github.com/hadolint/hadolint)-clean, [multi-stage](https://docs.docker.com/build/building/multi-stage/), and signed-supply-chain ready.

[![Lint](https://github.com/kssd/dockerfiles/actions/workflows/lint.yml/badge.svg)](https://github.com/kssd/dockerfiles/actions/workflows/lint.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/kssd/dockerfiles)](https://github.com/kssd/dockerfiles/commits/main)
[![Open issues](https://img.shields.io/github/issues/kssd/dockerfiles)](https://github.com/kssd/dockerfiles/issues)
[![GitHub stars](https://img.shields.io/github/stars/kssd/dockerfiles?style=social)](https://github.com/kssd/dockerfiles/stargazers)

[![Docker](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![BuildKit](https://img.shields.io/badge/BuildKit-enabled-0DB7ED?logo=docker&logoColor=white)](https://docs.docker.com/build/buildkit/)
[![Python](https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Distroless](https://img.shields.io/badge/Google-Distroless-4285F4?logo=google&logoColor=white)](https://github.com/GoogleContainerTools/distroless)
[![Chainguard Images](https://img.shields.io/badge/Chainguard-Images-1B4F72)](https://www.chainguard.dev/chainguard-images)
[![Sigstore](https://img.shields.io/badge/Sigstore-Cosign-2E7D32?logo=sigstore&logoColor=white)](https://www.sigstore.dev/)
[![SLSA v1.0](https://img.shields.io/badge/SLSA-v1.0-FF6D00)](https://slsa.dev/spec/v1.0/)
[![Hadolint](https://img.shields.io/badge/Hadolint-clean-success)](https://github.com/hadolint/hadolint)
[![Prettier](https://img.shields.io/badge/Code_Style-Prettier-F7B93E?logo=prettier&logoColor=black)](https://prettier.io/)

Reference [Dockerfiles](https://docs.docker.com/engine/reference/builder/) and best-practice guides for building **secure container images** that ship to production: small, signed, scanner-friendly, [OCI](https://opencontainers.org/)-compliant. [Python](https://www.python.org/) is the first ecosystem covered; [Node.js](https://nodejs.org/), [TypeScript](https://www.typescriptlang.org/), [Go](https://go.dev/), [Rust](https://www.rust-lang.org/), and [JAX](https://jax.readthedocs.io/) are on the [roadmap](https://github.com/kssd/dockerfiles/issues).

## Why these templates

- **[Multi-stage builds](https://docs.docker.com/build/building/multi-stage/)** — build toolchains never reach the runtime image. Smaller attack surface, smaller layers.
- **Non-root by default** — explicit `USER nonroot`, read-only root filesystem friendly, plays nicely with [`runAsNonRoot`](https://kubernetes.io/docs/concepts/security/pod-security-standards/) in Kubernetes.
- **Pinned bases + locked deps** — reproducible builds, [scanner-friendly](https://aquasecurity.github.io/trivy/) (trivy, grype, scout), and ready for digest-pinning in production.
- **[Hadolint](https://github.com/hadolint/hadolint)-clean** at the `warning` threshold — CI enforces it on every push.
- **Supply-chain ready** — pairs with [Cosign](https://docs.sigstore.dev/cosign/overview/) signatures, [SPDX](https://spdx.dev/) SBOMs, [SLSA](https://slsa.dev/spec/v1.0/) provenance, and [Kyverno](https://kyverno.io/docs/writing-policies/verify-images/sigstore/) admission control. See the [supply-chain guide](docs/supply-chain.md).

## Quick start

```sh
# Clone and pick a template.
git clone https://github.com/kssd/dockerfiles.git && cd dockerfiles

# Build the default Python image (Google Distroless, pip).
docker build -t myapp -f dockerfiles/python/Dockerfile.python .

# Run it read-only, no privileges, no network — the hardened way.
docker run --rm \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --network=none \
  myapp
```

Need [uv](https://github.com/astral-sh/uv), [Poetry](https://python-poetry.org/), [AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/python-image.html), or a [Chainguard](https://www.chainguard.dev/) base? See the variants below.

## Available Dockerfile templates

### Python — secure container images for production

Secure [Python](https://www.python.org/) Docker images on [**Google Distroless**](https://github.com/GoogleContainerTools/distroless) by default, with [Chainguard](https://images.chainguard.dev/directory/image/python/overview) variants for users who want signed/attested daily-rebuilt images. Plus [AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/python-image.html) Python container images and an agent sandbox for LLM-generated code.

**Distroless (default — freely pinnable to versioned tags):**

- [pip](https://pip.pypa.io/) + `requirements.txt` → [`dockerfiles/python/Dockerfile.python`](dockerfiles/python/Dockerfile.python)
- [uv](https://github.com/astral-sh/uv) + `pyproject.toml` + `uv.lock` → [`dockerfiles/python/Dockerfile.uv`](dockerfiles/python/Dockerfile.uv)
- [Poetry](https://python-poetry.org/) + `poetry.lock` → [`dockerfiles/python/Dockerfile.poetry`](dockerfiles/python/Dockerfile.poetry)

**Chainguard (signed, attested, daily-rebuilt; free-tier compatible via digest-pinning):**

- pip + Chainguard → [`dockerfiles/python/Dockerfile.python.chainguard`](dockerfiles/python/Dockerfile.python.chainguard)
- uv + Chainguard → [`dockerfiles/python/Dockerfile.uv.chainguard`](dockerfiles/python/Dockerfile.uv.chainguard)
- Poetry + Chainguard → [`dockerfiles/python/Dockerfile.poetry.chainguard`](dockerfiles/python/Dockerfile.poetry.chainguard)

**Specialized runtimes:**

- [AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/python-image.html) container image → [`dockerfiles/python/Dockerfile.lambda`](dockerfiles/python/Dockerfile.lambda)
- Agent sandbox for untrusted LLM-generated code → [`dockerfiles/python/Dockerfile.sandbox`](dockerfiles/python/Dockerfile.sandbox)

Full documentation: [`dockerfiles/python/README.md`](dockerfiles/python/README.md).

### Coming soon

Tracked as issues — comment or 👍 to bump priority.

- [Node.js Dockerfile templates](https://github.com/kssd/dockerfiles/issues/6) _(planned)_
- [TypeScript Dockerfile templates](https://github.com/kssd/dockerfiles/issues/9) _(planned)_
- [Go Dockerfile templates](https://github.com/kssd/dockerfiles/issues/7) _(planned)_
- [Rust Dockerfile templates](https://github.com/kssd/dockerfiles/issues/8) _(planned)_
- [JAX Dockerfile templates](https://github.com/kssd/dockerfiles/issues/5) _(planned)_
- [Zig Dockerfile templates](https://github.com/kssd/dockerfiles/issues/11) _(planned)_

## Guides

- **[Secure software supply chain for Docker images](docs/supply-chain.md)** — [SBOMs](https://www.cisa.gov/sbom), [Cosign](https://docs.sigstore.dev/cosign/overview/) signing (keyless and key-based), [SLSA v1.0](https://slsa.dev/spec/v1.0/) provenance, and [Kyverno](https://kyverno.io/docs/writing-policies/verify-images/sigstore/) admission control. Applies to every ecosystem in this repo.
- **[Sandboxing LLM-agent-generated code](docs/sandboxing-agent-code.md)** — threat model, the full `docker run` hardening flag stack with rationale, [Kubernetes](https://kubernetes.io/docs/concepts/security/pod-security-standards/) / Compose / Lambda / [Fargate](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html) equivalents, and when to graduate to [gVisor](https://gvisor.dev/) / [Firecracker](https://firecracker-microvm.github.io/) / [Kata](https://katacontainers.io/).

## Repository layout

```text
dockerfiles/
└── <ecosystem>/        # e.g. python/, node/, go/
    ├── Dockerfile.<variant>
    └── README.md
docs/
└── <topic>.md          # cross-ecosystem guides (supply chain, hardening, …)
```

## Tooling

Requires [Node.js](https://nodejs.org/) 20+ (lint tooling only) and [hadolint](https://github.com/hadolint/hadolint) on `PATH`.

```sh
npm install        # installs prettier + markdownlint-cli2
npm run lint       # prettier check + markdownlint + hadolint
npm run format     # prettier --write
```

[GitHub Actions CI](.github/workflows/lint.yml) runs the same checks on every push and pull request.

## Docker for agentic applications

Containerizing [AI agents](https://www.anthropic.com/news/claude-code) and [LLM](https://www.anthropic.com/) tool-use breaks the traditional "minimal image" rulebook in interesting ways. The patterns below are why this repo ships an agent sandbox alongside the lean production images.

### The "kitchen sink" paradox vs. minimalism

> **Change:** maintain two distinct classes of image.

Traditional best practice says strip every binary not needed at runtime. But AI agents need a broad toolkit (curl, git, build tools, Python libraries, scratch interpreters). The reconciliation is **bimodal images**:

- **Agent Host (Controller)** — strict minimalism. Runs the LLM reasoning loop. Zero system tools so a compromised agent cannot pivot.
- **Execution Sandbox** — a fat, pinned, audited image preloaded with safe tools.

Instead of running `apt-get install` at runtime (which destroys reproducibility), use a **toolbox pattern**: images designed to be mounted or called by agents, containing verified versions of every tool the agent might need.

### Runtime security for generated code

> **Change:** "running as non-root" is no longer enough.

Agents write and execute their own code. A traditional container assumes the code inside is trusted — but here the container runs untrusted, [AI-generated](https://www.anthropic.com/news/claude-code) code.

- **No network by default** — drop network drivers entirely or use `--network=none`. Whitelist outbound only when justified.
- **Ephemeral and read-only** — agent workspaces are disposable. `--read-only` root filesystem with a mounted, wipe-after-task `/workspace` tmpfs.
- **Resource caps** — `--memory`, `--cpus`, `--pids-limit` keep runaway agents from taking the host down.

### MCP — Dockerfiles as server definitions

[Docker is actively integrating](https://www.docker.com/blog/) with the [Model Context Protocol (MCP)](https://modelcontextprotocol.io/), the emerging standard that lets agents discover and connect to data sources and tools.

> **Change:** Dockerfiles are becoming "server definitions" for agent tools.

- **Standardized entrypoints** — images expose [MCP server](https://modelcontextprotocol.io/specification) endpoints so agents can _discover_ what an image can do.
- **Sidecar patterns** — instead of bundling a database client into the agent image, run an MCP gateway alongside it that proxies scoped access.

### Traditional vs. agentic, at a glance

| Feature       | Traditional practice           | Agentic practice                              |
| ------------- | ------------------------------ | --------------------------------------------- |
| Image content | Minimal, only app dependencies | Bimodal — tiny controllers vs. fat toolboxes  |
| Code source   | Trusted (human-written)        | Untrusted (AI-generated and executed in-loop) |
| Network       | Allow necessary egress         | Default deny; strictly scoped per task        |
| Lifecycle     | Long-running services          | Hyper-ephemeral — spin up, execute, kill      |

## Security

Found a template that materially weakens image security? See [`SECURITY.md`](SECURITY.md). For supply-chain hardening (signing, SBOMs, provenance, admission control), see the [supply-chain guide](docs/supply-chain.md).

## Contributing

PRs welcome — especially for the planned ecosystems above. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) first.

## License

[Apache 2.0](LICENSE). See [`NOTICE`](NOTICE) for attribution.

---

<sub>Keywords: <a href="https://www.docker.com/">Docker</a> · <a href="https://docs.docker.com/engine/reference/builder/">Dockerfile</a> · <a href="https://github.com/GoogleContainerTools/distroless">Distroless</a> · <a href="https://www.chainguard.dev/chainguard-images">Chainguard</a> · <a href="https://docs.docker.com/build/building/multi-stage/">multi-stage build</a> · <a href="https://github.com/hadolint/hadolint">hadolint</a> · <a href="https://www.python.org/">Python</a> · <a href="https://github.com/astral-sh/uv">uv</a> · <a href="https://python-poetry.org/">Poetry</a> · <a href="https://docs.aws.amazon.com/lambda/latest/dg/python-image.html">AWS Lambda container image</a> · <a href="https://docs.sigstore.dev/cosign/overview/">Cosign</a> · <a href="https://slsa.dev/spec/v1.0/">SLSA</a> · <a href="https://spdx.dev/">SPDX SBOM</a> · <a href="https://kyverno.io/">Kyverno</a> · <a href="https://modelcontextprotocol.io/">MCP</a> · <a href="https://opencontainers.org/">OCI</a> · container security · supply-chain security · non-root container · agent sandbox</sub>
