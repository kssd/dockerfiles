# Secure Python Docker Image Templates

Reference Dockerfiles for building **secure Python Docker images** in production — including **distroless Python**, Poetry / uv builds, **AWS Lambda Python container images**, and an **agent sandbox container** for running LLM-generated code. Eight variants are provided: pick the one that matches your dependency tooling and runtime target.

**Default runtime is Google Distroless (`gcr.io/distroless/python3-debian12:nonroot`).** Chainguard variants are provided as siblings (`Dockerfile.*.chainguard`) for users who prefer Chainguard's daily-rebuilt, signed/attested images. Chainguard's free Developer Edition only publishes `:latest` / `:latest-dev`; versioned tags like `:3.12-dev` require a paid subscription. The Chainguard variants in this repo default to `:latest-dev` and document digest-pinning so free-tier users can still get reproducible builds.

| File                           | Dependency manager                                                          | Runtime base                          | Use when                                                                                                                                          |
| ------------------------------ | --------------------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Dockerfile.python`            | `pip` + `requirements.txt`                                                  | Google Distroless                     | The project pins deps in `requirements.txt` and does not use `pyproject.toml` / `uv.lock`.                                                        |
| `Dockerfile.uv`                | [`uv`](https://docs.astral.sh/uv/) + `pyproject.toml` + `uv.lock`           | Google Distroless                     | The project uses `uv` for resolution and locking (recommended for new projects — faster, deterministic, PEP 621).                                 |
| `Dockerfile.poetry`            | [Poetry](https://python-poetry.org/) + `pyproject.toml` + `poetry.lock`     | Google Distroless                     | The project uses Poetry. Poetry exports a hash-pinned `requirements.txt` in the builder; the runtime image does not contain Poetry itself.        |
| `Dockerfile.python.chainguard` | `pip` + `requirements.txt`                                                  | Chainguard Python                     | You prefer Chainguard's signed/attested base over Distroless. Free-tier-compatible (`:latest-dev` default; pin by digest for reproducibility).    |
| `Dockerfile.uv.chainguard`     | `uv` + `pyproject.toml` + `uv.lock`                                         | Chainguard Python                     | uv workflow on Chainguard. Same paywall/digest-pin notes as above.                                                                                |
| `Dockerfile.poetry.chainguard` | Poetry + `pyproject.toml` + `poetry.lock`                                   | Chainguard Python                     | Poetry workflow on Chainguard. Same paywall/digest-pin notes as above.                                                                            |
| `Dockerfile.lambda`            | `pip` + `requirements.txt`                                                  | `public.ecr.aws/lambda/python`        | Deploying to AWS Lambda as a container image. Uses the Lambda Runtime Interface Client preinstalled in the base.                                  |
| `Dockerfile.sandbox`           | `python:*-slim` + curated, pinned tools (`git`, `curl`, `jq`, `ipython`, …) | `python:*-slim` (intentionally large) | Running LLM-agent-generated code. Non-root, tini-supervised, tool-rich on purpose. Pair with `--read-only`, `--network none`, tmpfs `/workspace`. |

The seven application variants produce a minimal, non-root, multi-stage image suitable for production workloads. `Dockerfile.sandbox` is intentionally the opposite: a tool-rich, pinned, non-root environment for running untrusted agent-generated code (see [Agentic usage](#agentic-usage)). The default Distroless variants pin `BASE_TAG=3.12-slim` for reproducible out-of-the-box builds; the Chainguard variants default to `BASE_TAG=latest` for free-tier compatibility and rely on digest-pinning for reproducibility (see the header of each `*.chainguard` file).

## Why these images are efficient

### Multi-stage build separates build-time from runtime

The **builder stage** uses `python:*-slim` (default variants) or `cgr.dev/chainguard/python:*-dev` (Chainguard variants) — both ship with a shell, `pip`, and the toolchain needed to compile native wheels. The `uv` variants bootstrap `uv` via pip; the Poetry variants install Poetry into an isolated `/opt/poetry` tree. The **runtime stage** uses the minimal distroless or Chainguard image — no shell, no package manager, no build tools. Only the resolved dependencies and application source are copied across, so build dependencies never ship to production.

Result: smaller final image, fewer installed packages, and a much smaller attack surface.

### Layer cache is optimized via two-phase install

Dependencies are installed **before** the application source is copied:

```dockerfile
COPY pyproject.toml uv.lock ./        # or: COPY requirements.txt ./
RUN uv export --frozen ...            # or: pip install -r requirements.txt
COPY . /app/src
```

Changing application code does not invalidate the (typically expensive) dependency-install layer. Re-builds for code-only changes complete in seconds.

### `pip install --target` for distroless-compatible installs

Default (distroless) variants install dependencies with `pip install --target=/app/deps` rather than into a virtualenv. A venv embeds absolute-path shebangs pointing at the builder's Python; copied into distroless those shebangs would be invalid. `--target` produces a plain site-packages tree that the runtime exposes via `PYTHONPATH=/app/deps:/app/src`. Chainguard variants can use a venv because both the `-dev` builder and the runtime ship with the same Python at the same path.

### `uv` for speed and determinism

The `uv` variants use `uv export --frozen --no-dev` (distroless) or `uv sync --frozen --no-cache` (Chainguard):

- `uv` resolves and installs an order of magnitude faster than `pip`.
- `--frozen` requires `uv.lock` to be consistent with `pyproject.toml` — builds fail loudly on drift instead of silently resolving a different graph.
- The distroless variant pipes the locked graph through `pip install --no-deps --require-hashes --target` for supply-chain integrity.
- `UV_LINK_MODE=copy` produces a self-contained venv with no hardlinks into uv's cache — required for cross-stage copy.

### `.dockerignore` keeps the build context small

The per-directory `.dockerignore` excludes `.venv/`, `__pycache__/`, test/lint caches, editor files, VCS metadata, and docs. This makes `COPY . .` faster, keeps the image small, and — critically — prevents the host's `.venv/` from clobbering the builder's `/app/.venv/`.

### Python runtime tuned for containers

The runtime stage sets:

- `PYTHONDONTWRITEBYTECODE=1` — no `.pyc` files written at runtime (they would only bloat the writable layer).
- `PYTHONUNBUFFERED=1` — `stdout` / `stderr` are flushed immediately so logs appear in real time in container log drivers.

## Why these images are secure

### Distroless runtime (default)

The default variants use [Google Distroless](https://github.com/GoogleContainerTools/distroless) (`gcr.io/distroless/python3-debian12:nonroot`):

- **Minimal runtime** — no shell (`/bin/sh`), no package manager, no `curl`, no `wget`, no compilers. A compromised process cannot drop into a shell, install tools, or fetch payloads using image-provided binaries.
- **Versioned, freely pinnable tags** — `debian12` and minor-aligned variants are publicly available; no paywall.
- **GCR-hosted, broadly trusted** — `gcr.io` is allow-listed in this repo's `.hadolint.yaml`.

### Chainguard runtime (alternative)

The `*.chainguard` variants use [Chainguard Images](https://www.chainguard.dev/chainguard-images):

- **Daily-rebuilt** with CVEs patched at source.
- **Signed and attested** — Sigstore-signed, with SLSA provenance and SBOMs for admission-controller verification (Kyverno, Connaisseur).
- **Free tier caveat** — Chainguard's free Developer Edition only publishes `:latest` / `:latest-dev`. Versioned tags like `:3.12-dev` need a paid subscription. The Chainguard templates here default to `:latest-dev` and document digest-pinning so free-tier users still get reproducible builds.

### Non-root user

The final stage runs as the prebuilt `nonroot` user (UID 65532) with `USER nonroot`. The copied venv and application files are `--chown=nonroot:nonroot`, so the process cannot write to its own code or dependencies. Combined with a read-only root filesystem at runtime (`docker run --read-only`), this strongly limits post-exploitation options.

### No build toolchain in the final image

Compilers, headers, and the package manager itself never reach the runtime image. A vulnerable C library in the builder cannot be exploited at runtime because it isn't there. Likewise, a supply-chain attack that targets `pip`/`uv` only affects the builder, not the running container.

### Locked, reproducible dependencies

- `Dockerfile.uv` uses `uv sync --frozen` — fails the build if `uv.lock` doesn't match `pyproject.toml`. No silent resolution drift between dev and prod.
- `Dockerfile.python` expects pinned `requirements.txt`. Use `pip-compile` (pip-tools) or `uv pip compile` to generate a fully pinned lock-style file from your top-level deps.

Both approaches make builds reproducible and auditable.

### Hadolint-clean

The repo CI runs `hadolint` at the `warning` threshold (`.github/workflows/lint.yml`). These templates follow the rules that matter most for security:

- **DL3007** — pin tags. Distroless variants default `BASE_TAG=3.12-slim`; Chainguard variants default `BASE_TAG=latest` (free-tier constraint) and must be digest-pinned in production.
- **DL3008 / DL3013** — pin apt/pip versions (no apt or unpinned pip in these images).
- **DL3009** — clean apt lists (no apt at all here).
- **DL3025** — use JSON-array `ENTRYPOINT` form (so signals reach the process correctly and there is no shell wrapping it).

### Signal handling and process model

`ENTRYPOINT ["python", "main.py"]` (exec/JSON form) means Python runs as PID 1 directly. `SIGTERM` from `docker stop` / Kubernetes is delivered to the Python process — no shell intermediary that swallows signals. Add a signal handler in your app (or run under a small init like `tini` if you need reaping of child processes).

## Build and run

```bash
# Default (distroless) — pip variant
docker build --build-arg BASE_TAG=3.12-slim -t myapp -f Dockerfile.python .

# Default (distroless) — uv variant
docker build --build-arg BASE_TAG=3.12-slim -t myapp -f Dockerfile.uv .

# Default (distroless) — Poetry variant
docker build --build-arg BASE_TAG=3.12-slim -t myapp -f Dockerfile.poetry .

# Chainguard variants (free tier — pin by digest in production):
docker build -t myapp -f Dockerfile.python.chainguard .
docker build -t myapp -f Dockerfile.uv.chainguard .
docker build -t myapp -f Dockerfile.poetry.chainguard .

# run (read-only rootfs, drop all capabilities — recommended defaults)
docker run --rm \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  myapp
```

## Expected build-context layout

```text
.
├── Dockerfile.<variant>      # one of: python, uv, poetry, *.chainguard, lambda, sandbox
├── .dockerignore             # provided in this directory
├── main.py                   # default entry point (override CMD/ENTRYPOINT to change)
├── requirements.txt          # for the pip variants
└── pyproject.toml            # for uv / Poetry variants
    uv.lock                   # uv lockfile
    poetry.lock               # Poetry lockfile
```

Override the entry point at run time without rebuilding:

```bash
docker run --entrypoint python myapp -m mypkg
```

## Agentic usage

The top-level [README](../../README.md) describes two image classes for agentic systems: a strict-minimalist **Agent Host (Controller)** that runs the LLM reasoning loop, and a tool-rich **Execution Sandbox** that runs the code the agent generates. The Python templates here cover both.

### Controller — use the Chainguard / distroless variants

`Dockerfile.python`, `Dockerfile.uv`, `Dockerfile.poetry`, and `Dockerfile.distroless` are excellent controller images:

- No shell, no package manager, no `curl`, no compilers. A compromised reasoning loop cannot drop to `sh`, `apt-get install`, or `curl | sh` its way to a payload — those binaries are not in the image.
- Non-root by default.
- Pinned, lock-verified dependencies (`uv sync --frozen`, `pip install --require-hashes` in the Poetry variant).

Run them with the agentic hardening flags:

```bash
docker run --rm \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --network=none \
  --memory=512m --cpus=1 --pids-limit=128 \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  my-agent-controller
```

Grant network or filesystem access only via explicit `--network` / `-v` flags, ideally pointing at an MCP gateway sibling container rather than at production data directly.

### Sandbox — use `Dockerfile.sandbox`

`Dockerfile.sandbox` is the tool-rich half of the pattern: `python:3.12-slim` with a curated, pinned tool list (`git`, `curl`, `jq`, `ipython`, `pytest`, `ruff`, `requests`, `httpx`), a non-root `agent` user (UID 10001), and `tini` as PID 1 to reap subprocesses the agent's code may spawn.

The intended invocation pairs the image with strict runtime constraints — the image is permissive on tools, the runtime locks everything else down:

```bash
docker run --rm -it \
  --read-only \
  --tmpfs /workspace:rw,exec,size=256m,uid=10001,gid=10001 \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --network=none \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --memory=512m --cpus=1 --pids-limit=256 \
  python-sandbox
```

`/workspace` is a writable tmpfs owned by the `agent` user (UID 10001); the rest of the rootfs is read-only. To pass an input script in, use `docker cp` after the container starts, or add a separate read-only bind mount at a non-conflicting path:

```bash
docker run ... \
  --mount type=bind,src="$PWD/task",dst=/work-input,readonly \
  python-sandbox python /work-input/script.py
```

Do not bind-mount over `/workspace` itself — that shadows the writable tmpfs and leaves the sandbox with no place to write.

When the agent legitimately needs egress, attach a constrained network (e.g. a docker network that can only reach an MCP gateway) instead of removing `--network=none` outright.

**Do not** add tools at run time. If the agent needs a new tool, extend `Dockerfile.sandbox`'s pinned install layers and rebuild — that keeps the toolbox auditable.

## Hardening checklist

- [ ] Keep `BASE_TAG` pinned to a real minor (default `3.12`) — never `latest`.
- [ ] Pin the base by digest in production (`cgr.dev/chainguard/python@sha256:…`).
- [ ] Commit a lockfile (`uv.lock` or fully-pinned `requirements.txt`).
- [ ] Verify Chainguard image signatures in your admission controller.
- [ ] Run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- [ ] Set resource limits (`--memory`, `--cpus`) — defense against runaway processes.
- [ ] Scan the built image (`grype`, `trivy`, or Chainguard's own scanner) before publishing.
