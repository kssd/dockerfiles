# Java application image (Eclipse Temurin + Google Distroless java21, multi-stage).
#
# Supports both Maven and Gradle via BUILD_TOOL build-arg (default: maven).
# Dependency manifests are copied before source, so a source-only change does
# not invalidate the dependency-download layer.
#
# BUILD_TOOL stages:
#   maven-deps  — copies pom.xml and resolves deps offline (Maven projects).
#   gradle-deps — copies Gradle wrappers and resolves deps (Gradle projects).
#   builder     — FROM ${BUILD_TOOL}-deps; compiles and packages the fat JAR.
#
# Only the stage matching BUILD_TOOL is executed by BuildKit — the other is
# skipped entirely, so the Gradle stage never runs in a Maven project and
# vice versa.
#
# Runtime: gcr.io/distroless/java21-debian12:nonroot — ships the JRE but no
# shell, no package manager. The process cannot drop into a shell or install
# tools. Incompatible with GraalVM native image; use Dockerfile.java.native
# for native compilation.
#
# Spring Boot layered JARs:
#   For Spring Boot 2.3+ apps, unpack the fat JAR into layers to get better
#   Docker cache utilisation — each layer (dependencies, spring-boot-loader,
#   snapshot-dependencies, application) is a separate COPY. See README.md.
#
# Multi-arch builds:
#   docker buildx build --platform=linux/amd64,linux/arm64 \
#       --build-arg BUILD_TOOL=maven -t myapp -f Dockerfile.java .
#
# Build:
#   docker build --build-arg BUILD_TOOL=maven -t myapp -f Dockerfile.java .
#   docker build --build-arg BUILD_TOOL=gradle -t myapp -f Dockerfile.java .
#
# Run (hardened):
#   docker run --rm \
#     --read-only \
#     --cap-drop=ALL \
#     --security-opt=no-new-privileges \
#     myapp
ARG BUILD_TOOL=maven
ARG JAVA_VERSION=21
ARG DISTROLESS_TAG=debian12

# -- Maven: cache pom.xml before source
FROM eclipse-temurin:${JAVA_VERSION}-jdk-jammy AS maven-deps
WORKDIR /app
COPY pom.xml ./
RUN mvn dependency:go-offline -q

# -- Gradle: cache wrapper + build files before source
FROM eclipse-temurin:${JAVA_VERSION}-jdk-jammy AS gradle-deps
WORKDIR /app
COPY gradlew build.gradle* settings.gradle* ./
COPY gradle/ ./gradle/
RUN chmod +x gradlew && ./gradlew dependencies --no-daemon -q

# -- Build: compile and package (inherits deps layer from chosen tool)
FROM ${BUILD_TOOL}-deps AS builder
ARG BUILD_TOOL
WORKDIR /app
COPY src ./src
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN if [ "${BUILD_TOOL}" = "maven" ]; then \
        mvn package -DskipTests -q && cp target/*.jar /app/app.jar; \
    else \
        ./gradlew build --no-daemon -x test -q && cp build/libs/*.jar /app/app.jar; \
    fi

# -- Runtime
FROM gcr.io/distroless/java${JAVA_VERSION}-${DISTROLESS_TAG}:nonroot
WORKDIR /app
COPY --from=builder --chown=nonroot:nonroot /app/app.jar /app/app.jar

USER nonroot

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
