# Secure JAX Docker Image Templates

Reference Dockerfiles for building **secure JAX container images** — covering CPU workloads with distroless runtimes, GPU workloads with bundled CUDA support, and a VS Code devcontainer for local JAX development.

| File                      | JAX install   | Runtime base                                   | Use when                                                                                                      |
| ------------------------- | ------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Dockerfile.jax.cpu`      | `jax[cpu]`    | Google Distroless (`python3-debian12:nonroot`) | CPU-only inference or training. Builds for `linux/amd64` and `linux/arm64`. Minimal distroless runtime.       |
| `Dockerfile.jax.cuda`     | `jax[cuda12]` | `python:3.12-slim` (non-root `jax` user)       | GPU inference or training. Requires the NVIDIA Container Runtime and a CUDA 12-compatible driver on the host. |
| `Dockerfile.devcontainer` | `jax[cpu]`    | `mcr.microsoft.com/devcontainers/python`       | Local development in VS Code Remote-Containers. Full toolchain: JupyterLab, ruff, mypy, pytest, and more.     |

## Why no Chainguard variant?

Chainguard publishes a CUDA-enabled image, but GPU-capable Chainguard images are behind a paid subscription — the free Developer Edition does not include them. Since the primary reason to have a Chainguard JAX image is the CUDA variant, and the CPU variant is already well served by Google Distroless (freely pinnable, GCR-hosted), a Chainguard sibling is not included here. If Chainguard's GPU images become available on the free tier, a `Dockerfile.jax.cuda.chainguard` variant would follow the existing pattern in `dockerfiles/python/`.

## CUDA version matching

JAX is strict about CUDA compatibility. The CUDA variant uses `jax[cuda12]`, which pulls self-contained PyPI wheels that **bundle the CUDA 12 runtime, XLA, and cuDNN** — no `nvidia/cuda` base image is required. The only host requirement is a CUDA 12-compatible NVIDIA driver.

| Component                | Requirement                         |
| ------------------------ | ----------------------------------- |
| JAX wheel                | `jax[cuda12]==0.10.0` (PyPI)        |
| Bundled CUDA runtime     | CUDA 12.x (bundled in jaxlib wheel) |
| Host driver (Linux)      | ≥ 525.85.12 (CUDA 12.0 support)     |
| NVIDIA Container Runtime | Required for `--gpus` flag          |

Check your driver version:

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

Verify JAX sees the GPU inside the container:

```bash
docker run --rm --gpus all myapp python3 -c "import jax; print(jax.devices())"
# Expected: [CudaDevice(id=0), ...]
```

If JAX prints `[CpuDevice(id=0)]` inside a container started with `--gpus all`, the NVIDIA Container Runtime is not configured correctly on the host — check that `nvidia-container-runtime` is set as the Docker runtime in `/etc/docker/daemon.json`.

### arm64 and CUDA

`jax[cuda12]` wheels are only published for `linux/amd64`. The CUDA Dockerfile explicitly sets `--platform=linux/amd64` in both stages. For arm64 GPU workloads (NVIDIA Jetson, Ampere Grace-Hopper), consult the [NVIDIA JAX releases](https://developer.nvidia.com/jax) for Jetson-specific packages.

## Why these images are efficient

### CPU variant: distroless runtime

The builder stage uses `python:3.12-slim` — shell, pip, and any native build tools available. Dependencies are installed with `pip install --target=/app/deps`, producing a version-agnostic site-packages tree (no venv absolute-path shebangs). The runtime is `gcr.io/distroless/python3-debian12:nonroot` — only Python and glibc, no shell, no package manager, no compilers. Only `/app/deps` and `/app/src` are copied across.

### CUDA variant: slim runtime with bundled CUDA

`jax[cuda12]` wheels are self-contained: the XLA compiler, CUDA runtime, and cuDNN libraries are embedded in the jaxlib wheel itself. The runtime stage is `python:3.12-slim` — a libc-complete environment without compilers or a package manager. Using distroless for the CUDA variant is not practical: jaxlib's GPU backend requires `libstdc++` and several glibc symbols absent from the distroless python3 image.

### Layer-cache optimisation

`requirements.txt` is copied and deps installed before application source in both variants:

```dockerfile
COPY requirements.txt ./
RUN pip install --no-cache-dir --target=/app/deps "jax[cpu]==..." -r requirements.txt
COPY . /app/src
```

A code-only change does not invalidate the JAX install layer (typically 500–900 MB for the CUDA variant due to bundled XLA). Re-builds for code changes complete in seconds.

## Why these images are secure

### Non-root user

The CPU variant runs as the distroless `nonroot` user (UID 65532). The CUDA variant creates an explicit `jax` user (UID 10001) with no login shell. Both use `--chown` on `COPY` so the process cannot write to its own code.

### No build toolchain in the final image

`pip`, `gcc`, `make`, and build headers never reach the runtime image. Supply-chain attacks targeting the package manager are scoped to the builder stage only.

### Minimal runtime (CPU)

The distroless runtime has no `sh`, no `curl`, no `wget`, no `apt`. A compromised JAX process cannot drop to a shell, install tools, or fetch payloads with image-provided binaries.

### Hadolint-clean

Both production Dockerfiles are hadolint-clean at the `warning` threshold. The `docker.io` registry (for `python:*-slim`) is already allow-listed in `.hadolint.yaml`.

## Build and run

```bash
# CPU variant — amd64
docker build --platform=linux/amd64 \
    --build-arg JAX_VERSION=0.10.0 \
    -t myapp -f Dockerfile.jax.cpu .

# CPU variant — arm64
docker build --platform=linux/arm64 \
    --build-arg JAX_VERSION=0.10.0 \
    -t myapp -f Dockerfile.jax.cpu .

# CUDA variant — amd64 only
docker build --platform=linux/amd64 \
    --build-arg JAX_VERSION=0.10.0 \
    -t myapp-gpu -f Dockerfile.jax.cuda .

# Run CPU (hardened, read-only rootfs):
docker run --rm \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  myapp

# Run GPU (all GPUs, shared memory for multi-GPU collectives):
docker run --rm \
  --gpus all \
  --ipc=host \
  --ulimit memlock=-1 \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  myapp-gpu

# Run GPU (single GPU, more restrictive):
docker run --rm \
  --gpus '"device=0"' \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  myapp-gpu
```

### `--ipc=host` and `--ulimit memlock=-1`

`--ipc=host` shares the host IPC namespace, which NCCL (JAX's multi-GPU communication backend) uses for shared-memory collective operations. Omit it for single-GPU or CPU workloads. `--ulimit memlock=-1` removes the locked-memory limit, which CUDA drivers require to pin GPU memory. Both flags are only needed for GPU workloads.

## Expected build-context layout

```text
.
├── Dockerfile.jax.cpu       # CPU production variant
├── Dockerfile.jax.cuda      # GPU production variant
├── Dockerfile.devcontainer  # VS Code devcontainer
├── .devcontainer/
│   └── devcontainer.json
├── .dockerignore
├── main.py                  # default entry point
└── requirements.txt         # project deps (may be empty)
```

## Developer container

`Dockerfile.devcontainer` is the human-developer image: `python:3.12-slim` extended with the full JAX development toolchain — JupyterLab for notebooks, ruff + mypy for code quality, pytest for testing, and JAX[cpu] pre-installed so the container is immediately usable without a `pip install` step.

### What's included

| Tool              | Version | Purpose                              |
| ----------------- | ------- | ------------------------------------ |
| `jax[cpu]`        | 0.10.0  | JAX with CPU backend                 |
| `numpy`           | 2.2.5   | Array foundation                     |
| `matplotlib`      | 3.10.3  | Visualisation                        |
| `jupyterlab`      | 4.4.2   | Browser-based notebook environment   |
| `ipykernel`       | 6.29.5  | Jupyter kernel                       |
| `ruff`            | 0.11.12 | Linter and formatter                 |
| `black`           | 25.1.0  | Formatter (for projects using Black) |
| `mypy`            | 1.16.1  | Static type checker                  |
| `pytest`          | 8.4.1   | Test runner                          |
| `ipython`         | 8.34.0  | Interactive REPL                     |
| `debugpy`         | 1.8.14  | VS Code Python debugger adapter      |
| `build-essential` | system  | Native extension compilation         |
| `direnv`          | system  | Per-directory environment variables  |
| `gh`              | system  | GitHub CLI                           |

### Reopen in Container

1. Open the project folder in VS Code.
2. Click **Reopen in Container** when prompted (or run `Dev Containers: Reopen in Container`).
3. VS Code builds the image on first open — subsequent opens use the layer cache.
4. `postCreateCommand` runs `pip install --user -e '.[dev]'` if a `pyproject.toml` exists.
5. Port 8888 is forwarded — start JupyterLab with:

   ```bash
   jupyter lab --ip=0.0.0.0 --no-browser
   ```

### Using the GPU devcontainer

To develop with GPU access, change `jax[cpu]` to `jax[cuda12]` in the `Dockerfile.devcontainer` `ARG` and rebuild. Also add the `--gpus all` runtime argument in `devcontainer.json`:

```json
"runArgs": ["--gpus", "all", "--ipc=host"]
```

### Switching the Python minor

```bash
docker build --build-arg DEVCONTAINER_TAG=1-3.11-bookworm \
  -t jax-dev -f Dockerfile.devcontainer .
```

Available tags follow the `1-<python-minor>-bookworm` pattern — see [Microsoft devcontainer images](https://github.com/devcontainers/images/tree/main/src/python).

## JAX-specific notes

### JAX install extras

| Extra         | What it installs                        | Use case                         |
| ------------- | --------------------------------------- | -------------------------------- |
| `jax[cpu]`    | JAX + CPU-only jaxlib                   | CPU training, inference, CI      |
| `jax[cuda12]` | JAX + jaxlib with CUDA 12 + XLA + cuDNN | GPU training on CUDA 12 hardware |

The CPU and CUDA extras are mutually exclusive: installing both will leave the last one installed active.

### Persistent compilation cache (XLA/HLO)

JAX JIT-compiles Python functions on first call. By default the compiled XLA programs are cached in memory only. To persist them across container restarts, mount a directory and set `JAX_COMPILATION_CACHE_DIR`:

```bash
docker run --rm \
  -v "$PWD/jax_cache:/jax_cache" \
  -e JAX_COMPILATION_CACHE_DIR=/jax_cache \
  myapp
```

Add `/jax_cache` to your `.dockerignore` to keep it out of the build context.

### Multi-device (pmap)

`jax.pmap` parallelises across physical devices. In Docker, devices are exposed as `/dev/nvidia*` by the NVIDIA Container Runtime. Use `--gpus all` (or `--gpus '"device=0,1"'` to restrict) to make them visible. Shared memory (`--ipc=host`) is required when NCCL uses NVLink.

### Upgrading JAX

Pin `JAX_VERSION` to a specific release to keep builds reproducible. The JAX project follows [semantic versioning](https://jax.readthedocs.io/en/latest/changelog.html); breaking changes are documented in the changelog. For the CUDA variant, always verify that the new jaxlib version's bundled CUDA is compatible with your host driver before upgrading.

## Hardening checklist

- [ ] Pin `JAX_VERSION` to a specific release — never a floating range.
- [ ] Add `requirements.txt` with pinned project dependencies.
- [ ] Commit a lockfile (`uv.lock` or fully-pinned `requirements.txt`) for reproducibility.
- [ ] Run CPU variant with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- [ ] Run GPU variant with `--gpus`, `--ipc=host`, `--ulimit memlock=-1`, plus the CPU hardening flags.
- [ ] Set resource limits (`--memory`, `--cpus`, `--pids-limit`) as defense against runaway workloads.
- [ ] Scan the built image with `grype` or `trivy` before publishing.
- [ ] Pin the base image by digest in production:

  ```bash
  docker inspect --format='{{index .RepoDigests 0}}' python:3.12-slim
  # then: FROM python@sha256:<digest>
  ```
