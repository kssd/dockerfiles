# Python Dockerfile templates

Reference Dockerfiles for building production Python images. Six variants are provided; pick the one that matches your dependency tooling and runtime target.

| File                    | Dependency manager                                                                                    | Use when                                                                                                                                          |
| ----------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Dockerfile.python`     | `pip` + `requirements.txt`                                                                            | The project pins deps in `requirements.txt` and does not use `pyproject.toml` / `uv.lock`.                                                        |
| `Dockerfile.uv`         | [`uv`](https://docs.astral.sh/uv/) + `pyproject.toml` + `uv.lock`                                     | The project uses `uv` for resolution and locking (recommended for new projects — faster, deterministic, PEP 621).                                 |
| `Dockerfile.poetry`     | [Poetry](https://python-poetry.org/) + `pyproject.toml` + `poetry.lock`                               | The project uses Poetry. Poetry exports a `requirements.txt` in the builder; the runtime image does not contain Poetry itself.                    |
| `Dockerfile.distroless` | `pip` + `requirements.txt` on [Google Distroless](https://github.com/GoogleContainerTools/distroless) | You want a distroless runtime but cannot use Chainguard (registry/account constraints). Larger than the Chainguard variants.                      |
| `Dockerfile.lambda`     | `pip` + `requirements.txt` on AWS Lambda base                                                         | Deploying to AWS Lambda as a container image. Uses `public.ecr.aws/lambda/python` with the Lambda Runtime Interface Client preinstalled.          |
| `Dockerfile.sandbox`    | `python:*-slim` + curated, pinned tools (`git`, `curl`, `jq`, `ipython`, `pytest`, `ruff`, …)         | Running LLM-agent-generated code. Non-root, tini-supervised, tool-rich on purpose. Pair with `--read-only`, `--network none`, tmpfs `/workspace`. |

The first five variants produce a minimal, non-root, multi-stage image suitable for production application workloads. `Dockerfile.sandbox` is intentionally the opposite: a tool-rich, pinned, non-root environment for running untrusted agent-generated code (see [Agentic usage](#agentic-usage)). All variants default `BASE_TAG` to a real minor (`3.12` for the application variants, `3.12-slim` for the sandbox and distroless builder) so out-of-the-box builds are reproducible — override at build time to pick a different Python minor.

## Why these images are efficient

### Multi-stage build separates build-time from runtime

The **builder stage** uses `cgr.dev/chainguard/python:*-dev` (or `cgr.dev/chainguard/uv:*-dev`), which ships with a shell, package manager, and toolchain needed to compile native wheels. The **runtime stage** uses the minimal `cgr.dev/chainguard/python:*` image — no shell, no package manager, no build tools. Only the resolved virtualenv and application source are copied across, so build dependencies never ship to production.

Result: smaller final image, fewer installed packages, and a much smaller attack surface.

### Layer cache is optimized via two-phase install

Dependencies are installed **before** the application source is copied:

```dockerfile
COPY pyproject.toml uv.lock ./        # or: COPY requirements.txt ./
RUN uv sync --frozen --no-install-project   # or: pip install -r requirements.txt
COPY . .
RUN uv sync --frozen                  # installs the project itself
```

Changing application code does not invalidate the (typically expensive) dependency-install layer. Re-builds for code-only changes complete in seconds. The `uv` variant goes further with a two-phase `uv sync` so the project install is its own thin layer on top of the dependency layer.

### Relocatable virtualenv enables clean cross-stage copy

The builder creates a relocatable venv at `/app/.venv` and the runtime stage reuses the exact same path with a matching `PATH`. This means:

- No reinstall in the runtime stage — the resolved venv is copied byte-for-byte.
- No `pip` / `uv` invocation at runtime, so neither tool needs to exist in the final image.

### `uv` for speed and determinism

The `Dockerfile.uv` variant uses `uv sync --frozen --no-cache`:

- `uv` resolves and installs an order of magnitude faster than `pip`.
- `--frozen` requires `uv.lock` to be consistent with `pyproject.toml` — builds fail loudly on drift instead of silently resolving a different graph.
- `--no-cache` keeps the builder layer small (we don't need uv's cache after the venv is built).
- `UV_LINK_MODE=copy` produces a self-contained venv with no hardlinks into uv's cache — required for cross-stage copy.

### `.dockerignore` keeps the build context small

The per-directory `.dockerignore` excludes `.venv/`, `__pycache__/`, test/lint caches, editor files, VCS metadata, and docs. This makes `COPY . .` faster, keeps the image small, and — critically — prevents the host's `.venv/` from clobbering the builder's `/app/.venv/`.

### Python runtime tuned for containers

The runtime stage sets:

- `PYTHONDONTWRITEBYTECODE=1` — no `.pyc` files written at runtime (they would only bloat the writable layer).
- `PYTHONUNBUFFERED=1` — `stdout` / `stderr` are flushed immediately so logs appear in real time in container log drivers.

## Why these images are secure

### Distroless base from Chainguard

Both stages use [Chainguard Images](https://www.chainguard.dev/chainguard-images):

- **Minimal runtime** — the non-`-dev` image has no shell (`/bin/sh`), no package manager, no `curl`, no `wget`, no compilers. A compromised process cannot drop into a shell, install tools, or fetch payloads using image-provided binaries.
- **Continuously rebuilt** — Chainguard ships updated base images on a daily cadence with CVEs patched at source. Pinning a minor (`3.12`) keeps you on the latest patch automatically when you rebuild.
- **Signed and attested** — images are signed with Sigstore and ship with SLSA provenance and SBOMs, enabling verification in admission controllers (e.g. Kyverno, Connaisseur).
- **Trusted registry** — `cgr.dev` is allow-listed in this repo's `.hadolint.yaml`.

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

- **DL3007** — pin tags. All templates default `BASE_TAG=3.12`; do not override to `latest`.
- **DL3008 / DL3013** — pin apt/pip versions (no apt or unpinned pip in these images).
- **DL3009** — clean apt lists (no apt at all here).
- **DL3025** — use JSON-array `ENTRYPOINT` form (so signals reach the process correctly and there is no shell wrapping it).

### Signal handling and process model

`ENTRYPOINT ["python", "main.py"]` (exec/JSON form) means Python runs as PID 1 directly. `SIGTERM` from `docker stop` / Kubernetes is delivered to the Python process — no shell intermediary that swallows signals. Add a signal handler in your app (or run under a small init like `tini` if you need reaping of child processes).

## Build and run

```bash
# pip variant
docker build --build-arg BASE_TAG=3.12 -t myapp -f Dockerfile.python .

# uv variant
docker build --build-arg BASE_TAG=3.12 -t myapp -f Dockerfile.uv .

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
├── Dockerfile.python OR Dockerfile.uv
├── .dockerignore             # provided in this directory
├── main.py                   # default entry point (override ENTRYPOINT to change)
├── requirements.txt          # for Dockerfile.python
└── pyproject.toml            # for Dockerfile.uv
    uv.lock
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
