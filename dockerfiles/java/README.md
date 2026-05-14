# Secure Java Docker Image Templates

Reference Dockerfiles for building **secure Java Docker images** in production — including a **Distroless JRE** variant with Maven/Gradle dep caching, a **GraalVM Native Image** variant, a **Chainguard** variant for signed/attested images, an **AWS Lambda** variant, and a **devcontainer** for VS Code.

**Default runtime is [`gcr.io/distroless/java21-debian12:nonroot`](https://github.com/GoogleContainerTools/distroless/blob/main/java/README.md).** This image ships the JRE but no shell, no package manager. Chainguard variants are provided as siblings for users who prefer daily-rebuilt, Sigstore-signed images.

| File                         | Builder                                         | Runtime base                                  | Use when                                                            |
| ---------------------------- | ----------------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------- |
| `Dockerfile.java`            | `eclipse-temurin:21-jdk-jammy`                  | `gcr.io/distroless/java21-debian12:nonroot`   | Default. Maven or Gradle fat JAR on the JVM.                        |
| `Dockerfile.java.native`     | `ghcr.io/graalvm/native-image-community:21-ol9` | `gcr.io/distroless/cc-debian12:nonroot`       | GraalVM Native Image for fast cold starts and lower memory.         |
| `Dockerfile.java.chainguard` | `cgr.dev/chainguard/maven`                      | `cgr.dev/chainguard/jre`                      | Chainguard daily CVE patches, Sigstore signatures, SLSA provenance. |
| `Dockerfile.lambda`          | `eclipse-temurin:21-jdk-jammy`                  | `public.ecr.aws/lambda/java:21`               | AWS Lambda container image with Lambda RIC pre-installed.           |
| `Dockerfile.devcontainer`    | —                                               | `mcr.microsoft.com/devcontainers/java:1-21-*` | VS Code Remote-Containers / Dev Containers development environment. |

## Why these images are efficient

### Maven dep-cache layer

Copy `pom.xml` before source so the dependency-download layer is only invalidated when dependencies change:

```dockerfile
COPY pom.xml ./
RUN mvn dependency:go-offline -q   # cached layer
COPY src ./src
RUN mvn package -DskipTests -q
```

Changing only `src/` reuses the `mvn dependency:go-offline` layer. Re-builds for code-only changes take seconds instead of minutes.

### Gradle dep-cache layer

Copy the Gradle wrapper and build files before source:

```dockerfile
COPY gradlew build.gradle* settings.gradle* ./
COPY gradle/ ./gradle/
RUN chmod +x gradlew && ./gradlew dependencies --no-daemon -q   # cached layer
COPY src ./src
RUN ./gradlew build --no-daemon -x test -q
```

### Maven vs Gradle via ARG BUILD_TOOL

`Dockerfile.java` supports both build tools via `--build-arg BUILD_TOOL=maven` (default) or `--build-arg BUILD_TOOL=gradle`. BuildKit builds only the stage that matches — the unused tool's dep-cache stage is never executed.

```bash
# Maven project (default)
docker build --build-arg BUILD_TOOL=maven -t myapp -f Dockerfile.java .

# Gradle project
docker build --build-arg BUILD_TOOL=gradle -t myapp -f Dockerfile.java .
```

### Multi-stage build

The builder stage (Temurin JDK + Maven/Gradle) stays out of the final image. Only the compiled JAR is copied into the distroless JRE runtime. Result: the final image contains the JRE and your JAR — no build toolchain.

### Spring Boot layered JARs

Spring Boot 2.3+ supports layered JARs that split the fat JAR into distinct layers. Use this to get much better Docker cache utilisation for framework applications:

```dockerfile
FROM eclipse-temurin:21-jdk-jammy AS builder
# ... build fat JAR ...
RUN java -Djarmode=layertools -jar target/app.jar extract

FROM gcr.io/distroless/java21-debian12:nonroot
COPY --from=builder /app/dependencies /
COPY --from=builder /app/spring-boot-loader /
COPY --from=builder /app/snapshot-dependencies /
COPY --from=builder /app/application /
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
```

The `dependencies` layer (all stable library JARs) is rarely invalidated. Only the `application` layer (your compiled classes) changes on code edits.

## JVM vs GraalVM Native Image

| Metric              | JVM (`Dockerfile.java`) | Native Image (`Dockerfile.java.native`) |
| ------------------- | ----------------------- | --------------------------------------- |
| Cold start          | 100–500 ms              | 10–50 ms                                |
| Steady-state RSS    | 200–500 MB              | 50–150 MB                               |
| Build time          | Seconds                 | Minutes                                 |
| Reflection          | Dynamic (no config)     | Requires AOT config or Spring Native    |
| JNI / Proxies       | Transparent             | Requires reachability metadata          |
| Profile-guided opts | Yes (JIT)               | Requires PGO instrumentation build      |

### GraalVM Native Image (`Dockerfile.java.native`)

The `Dockerfile.java.native` uses `ghcr.io/graalvm/native-image-community:21-ol9` to compile to a native binary via `mvn -Pnative native:compile`. The runtime is `gcr.io/distroless/cc-debian12:nonroot` (glibc-linked).

For **Spring Boot 3** applications, add the Spring AOT plugin:

```xml
<plugin>
  <groupId>org.graalvm.buildtools</groupId>
  <artifactId>native-maven-plugin</artifactId>
</plugin>
```

The plugin generates the AOT configuration (reflection, serialization, proxies) automatically at build time.

#### Fully-static native binary (musl)

To produce a fully-static binary and ship in `distroless/static-debian12:nonroot`:

1. Install the musl toolchain in the builder stage:

```dockerfile
RUN dnf install -y gcc musl-gcc && \
    curl -fsSL https://musl.libc.org/releases/musl-1.2.5.tar.gz | tar xz && \
    cd musl-1.2.5 && ./configure --prefix=/usr/local/musl && make install
```

1. Compile with `--static --libc=musl`:

```dockerfile
RUN native-image --static --libc=musl -jar target/app.jar app
```

1. Switch the runtime to `gcr.io/distroless/static-debian12:nonroot`.

## Why these images are secure

### No shell in the JVM runtime

`distroless/java21-debian12:nonroot` ships the JRE, CA certificates, and tzdata. There is no `/bin/sh`, no package manager, no curl. A compromised JVM process cannot drop into a shell.

### Non-root by default

All production final stages run as a non-root user (`nonroot` UID 65532 for distroless, `java` for Chainguard JRE). The JAR is `--chown=nonroot:nonroot` so the process cannot overwrite it.

## Build and run

```bash
# Distroless JVM (Maven, default)
docker build --build-arg BUILD_TOOL=maven -t myapp -f Dockerfile.java .

# Distroless JVM (Gradle)
docker build --build-arg BUILD_TOOL=gradle -t myapp -f Dockerfile.java .

# GraalVM Native Image
docker build --build-arg APP_NAME=myapp -t myapp-native -f Dockerfile.java.native .

# Chainguard (free tier -- pin by digest in production)
docker build -t myapp -f Dockerfile.java.chainguard .

# Lambda (match your function's architecture)
docker build --platform=linux/amd64 -t myapp-lambda -f Dockerfile.lambda .

# Multi-arch JVM
docker buildx build --platform=linux/amd64,linux/arm64 \
    --build-arg BUILD_TOOL=maven -t myapp -f Dockerfile.java .

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
├── Dockerfile.java          # or .native / .chainguard / .lambda
├── .dockerignore            # provided in this directory
├── pom.xml                  # Maven: required for dep-cache layer
├── src/
│   └── main/java/
│       └── com/example/
│           └── Main.java
```

For Gradle projects, replace `pom.xml` with `build.gradle` / `settings.gradle` / `gradlew` / `gradle/`.

## Lambda variant

The Lambda Java base image (`public.ecr.aws/lambda/java:21`) ships the AWS Lambda Runtime Interface Client. The fat JAR is copied to `${LAMBDA_TASK_ROOT}`. Set `CMD` to the fully-qualified handler class and method:

```dockerfile
CMD ["com.example.Handler::handleRequest"]
```

### Local invocation

```bash
docker run --rm -p 9000:8080 myapp-lambda
curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" \
    -d '{"key":"value"}'
```

### AWS Lambda SnapStart

SnapStart (available on the Java 21 Managed Runtime) snapshots the initialized Lambda execution environment and restores it on cold starts — reducing cold start latency from ~400 ms to ~10 ms. To use SnapStart with a container image, configure [CRaC (Coordinated Restore at Checkpoint)](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-supported-states.html) in your application and implement the `CracResource` interface to clean up and restore resources across checkpoints.

## Chainguard digest-pinning

The Chainguard free tier publishes only `:latest`. For reproducible builds, pin by digest:

```bash
docker pull cgr.dev/chainguard/maven:latest
docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/maven:latest

docker pull cgr.dev/chainguard/jre:latest
docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/jre:latest
```

Then replace the `FROM` lines with the digest form:

```dockerfile
FROM cgr.dev/chainguard/maven@sha256:<digest> AS builder
# ...
FROM cgr.dev/chainguard/jre@sha256:<digest>
```

## Devcontainer variant

`Dockerfile.devcontainer` is based on `mcr.microsoft.com/devcontainers/java:1-21-bookworm` and adds:

- Gradle (pinned) for projects not using the Gradle wrapper
- `jq` and `curl` for common dev tasks

The base image ships Maven, git, and common dev utilities.

The companion `.devcontainer/devcontainer.json` wires up:

- `redhat.java` Language Support for Java
- `vscjava.vscode-maven` and `vscjava.vscode-gradle` for build tool integration
- `vscjava.vscode-java-test` Test Runner UI
- `vscjava.vscode-spring-initializr` and `vmware.vscode-spring-boot` for Spring apps
- `postCreateCommand: mvn dependency:go-offline` to warm the dep cache on start

### Reopen in Container

1. Open the `dockerfiles/java/` folder in VS Code.
2. When prompted "Reopen in Container", click yes — or use `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**.
3. VS Code builds `Dockerfile.devcontainer`, mounts the workspace, and installs extensions.

## JLink custom JRE

For a middle ground between the full JDK and distroless, `jlink` can produce a minimal custom JRE that includes only the modules your application uses:

```dockerfile
FROM eclipse-temurin:21-jdk-jammy AS jlink
RUN jlink \
    --add-modules java.base,java.logging,java.sql,java.net.http \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --compress=zip-6 \
    --output /jre-custom

FROM debian:bookworm-slim
COPY --from=jlink /jre-custom /opt/java
ENV PATH="/opt/java/bin:${PATH}"
# ...
```

This is not provided as a separate Dockerfile but is a useful technique documented here. The modules list must be tuned per application via `jdeps --print-module-deps`.

## Multi-arch builds

GraalVM Native Image does **not** support cross-compilation — you must build natively on each target platform. Use separate `docker buildx build --platform=linux/amd64` and `--platform=linux/arm64` commands (or separate CI jobs) for the native variant.

The JVM variant (`Dockerfile.java`) supports multi-arch:

```bash
docker buildx create --use

docker buildx build \
  --platform=linux/amd64,linux/arm64 \
  --push \
  --build-arg BUILD_TOOL=maven \
  -t myregistry/myapp:latest \
  -f Dockerfile.java .
```

## Hardening checklist

- [ ] Pin `JAVA_VERSION` to `21` (or your target LTS) — never use `latest`.
- [ ] Pin the base image by digest in production (`gcr.io/distroless/java21-debian12@sha256:…`).
- [ ] Commit `pom.xml` / `build.gradle` with exact dependency versions (no SNAPSHOT ranges in production).
- [ ] Pass `-DskipTests` only in the Docker build; run tests in CI before building the image.
- [ ] For Spring Boot: enable layered JARs to improve cache utilisation (see above).
- [ ] For GraalVM: run `-DskipTests=false` in native profile in CI to catch AOT reflection issues.
- [ ] Run with `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`.
- [ ] Set resource limits (`--memory`, `--cpus`) — the JVM will size its heap to the container limit.
- [ ] Scan the built image (`grype`, `trivy`) before publishing.
- [ ] Sign the image and SLSA provenance with Cosign — see [`docs/supply-chain.md`](../../docs/supply-chain.md).
