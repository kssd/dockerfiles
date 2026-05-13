# Go application image (CGO_ENABLED=0 + Google Distroless static, multi-stage).
#
# Builds a fully-static binary (no libc, no cgo) and ships it in
# gcr.io/distroless/static-debian12:nonroot — the smallest Distroless
# variant, with no glibc, no shell, and a pre-built nonroot user.
#
# CGO trade-off:
#   CGO_ENABLED=0 means any package that wraps a C library (e.g.
#   mattn/go-sqlite3, some crypto edge cases) will fail to compile.
#   If your project requires CGO, switch the runtime to
#   gcr.io/distroless/base-debian12:nonroot (includes glibc) and set
#   CGO_ENABLED=1 in the build step.
#
# Multi-arch builds:
#   --platform=$BUILDPLATFORM on the builder ensures the compiler itself
#   runs natively on your host; TARGETOS / TARGETARCH control the output
#   binary. Pass --platform=linux/amd64 or linux/arm64 to docker build.
#
# Layer-cache optimisation:
#   go.mod + go.sum are copied and modules downloaded before source is
#   copied. Changing application code does not invalidate the module
#   download layer.
#
# Expected build context:
#   ./go.mod       - module definition
#   ./go.sum       - dependency checksums
#   ./**/*.go      - application source (adjust COPY if using a src/ layout)
#
# Build:
#   docker build --platform=linux/amd64 --build-arg GO_VERSION=1.23 \
#       -t myapp -f Dockerfile.go .
#
# Run (hardened):
#   docker run --rm \
#     --read-only \
#     --cap-drop=ALL \
#     --security-opt=no-new-privileges \
#     myapp
ARG GO_VERSION=1.23
ARG DISTROLESS_TAG=debian12

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS builder
ARG TARGETOS=linux
ARG TARGETARCH=amd64
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-${DISTROLESS_TAG}:nonroot
COPY --from=builder --chown=nonroot:nonroot /out/app /app

USER nonroot

ENTRYPOINT ["/app"]
