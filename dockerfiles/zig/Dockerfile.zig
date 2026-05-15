# Zig application image (tarball builder + Google Distroless static, multi-stage).
#
# Downloads and SHA-256-verifies the official Zig toolchain tarball before
# use — the tarball is the supply-chain entry point for Zig builds, so hash
# pinning is mandatory (Zig does not ship signed packages via a package manager).
#
# Multi-arch note:
#   The builder selects the correct tarball URL and SHA-256 based on
#   TARGETARCH (amd64 -> x86_64, arm64 -> aarch64). The runtime stage is
#   architecture-neutral (distroless/static ships a per-arch image).
#
# Optimise mode (ZIG_OPTIMIZE):
#   ReleaseSafe  (default) — optimised + safety checks (bounds, overflow).
#   ReleaseFast  — maximum speed, safety checks disabled.
#   ReleaseSmall — minimum binary size, safety checks disabled.
#
# BIN_NAME must match the executable name in build.zig (root.name field).
#
# Runtime: gcr.io/distroless/static-debian12:nonroot — no libc, no shell.
# Zig targets musl libc by default (bundled), producing fully-static binaries
# that run without any shared libraries.
#
# Build:
#   docker build --build-arg BIN_NAME=myapp -t myapp -f Dockerfile.zig .
#
# Multi-arch:
#   docker buildx build --platform=linux/amd64,linux/arm64 \
#       --build-arg BIN_NAME=myapp -t myapp -f Dockerfile.zig .
#
# Run (hardened):
#   docker run --rm \
#     --read-only \
#     --cap-drop=ALL \
#     --security-opt=no-new-privileges \
#     myapp
ARG ZIG_VERSION=0.16.0
ARG DISTROLESS_TAG=debian12

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder
ARG ZIG_VERSION
ARG TARGETARCH
ARG BIN_NAME=app
ARG ZIG_OPTIMIZE=ReleaseSafe

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates=20230311 \
        curl=7.88.1-10+deb12u12 \
        xz-utils=5.4.1-0.2 \
    && rm -rf /var/lib/apt/lists/*

# Select tarball URL and SHA-256 by target architecture.
# Update both values together when upgrading ZIG_VERSION.
RUN case "${TARGETARCH}" in \
        amd64) \
            ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" ; \
            ZIG_SHA256="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00" ;; \
        arm64) \
            ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-linux-${ZIG_VERSION}.tar.xz" ; \
            ZIG_SHA256="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "${ZIG_URL}" -o /tmp/zig.tar.xz && \
    echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - && \
    tar -xJf /tmp/zig.tar.xz -C /usr/local && \
    ln -s "/usr/local/zig-"*"-linux-"*"-${ZIG_VERSION}/zig" /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /src
COPY build.zig build.zig.zon* ./
RUN zig build --fetch || true
COPY . .
RUN zig build -Doptimize="${ZIG_OPTIMIZE}" && \
    cp "zig-out/bin/${BIN_NAME}" /server

FROM gcr.io/distroless/static-${DISTROLESS_TAG}:nonroot
COPY --from=builder --chown=nonroot:nonroot /server /app/server

USER nonroot

ENTRYPOINT ["/app/server"]
