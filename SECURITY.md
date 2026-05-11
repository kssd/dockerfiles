# Security Policy

## Scope

This repository contains **reference Dockerfile templates and guides**. It does not ship a runtime service. "Security" here means two distinct things:

1. **Template correctness** — a published template that materially weakens the security posture of images built from it (e.g. accidentally running as root, leaking secrets through build args, shipping a build toolchain into a runtime image, broken `.dockerignore` patterns that ship credentials).
2. **Repository integrity** — supply-chain risks in this repo itself (CI workflow misconfiguration, dependency vulnerabilities in `package.json`, malicious commits).

Both are in scope. General vulnerabilities in upstream base images (Chainguard, AWS Lambda, Distroless) are **out of scope** — report those to the respective upstream vendors. We will, however, bump base-tag recommendations in response to upstream advisories.

## Reporting a vulnerability

**Do not open a public GitHub issue for security reports.**

Preferred channel:

- **GitHub Private Vulnerability Reporting** — open a report at `https://github.com/kssd/dockerfiles/security/advisories/new` once the repo is published. This keeps the disclosure private until coordinated release.

Backup channel:

- **Email**: `kunwar.sangram@gmail.com` with `[security] dockerfiles` in the subject line.

Please include:

- The affected file path(s) and template variant.
- A concrete reproduction: the build command, build context, and the resulting weakness (e.g. "image runs as UID 0 despite `USER nonroot`", "secret leaks into layer X via `--build-arg`").
- The image scanner output if applicable (`grype`, `trivy`, `docker scout`).
- Your assessment of severity and any suggested mitigation.

## Response expectations

| Stage                                  | Target                                                  |
| -------------------------------------- | ------------------------------------------------------- |
| Acknowledgement of report              | within 3 days                                           |
| Initial triage / severity decision     | within 7 days                                           |
| Fix or mitigation for confirmed issues | within 30 days for high/critical; best effort otherwise |
| Public disclosure                      | coordinated with the reporter, after a fix ships        |

Severity is judged against the image built from the template, not just the template text.

## What gets a CVE

Reference templates do not get CVEs in this repo (they are not a deployed product). If a downstream user reports a CVE filed against an image built from one of these templates and the root cause is in the template, we will reference the downstream CVE in the changelog and patch the template.

## Hardening guarantees we try to uphold

Templates in `dockerfiles/` aim to meet **all** of the following unless a variant explicitly documents a deviation (e.g. `Dockerfile.sandbox`):

- Multi-stage build; no build toolchain in the runtime image.
- Non-root final stage with explicit `USER`.
- Pinned `BASE_TAG`, digest-pinning documented for production.
- Locked dependencies (`uv.lock`, `poetry.lock`, or fully pinned `requirements.txt`).
- Hadolint-clean at the `warning` threshold.
- No secrets accepted via `ARG` for values that would be baked into layers.
- `.dockerignore` excludes credential patterns (`*.pem`, `*.key`, SSH keys, cloud credential dirs).

A regression against any of these in a merged template is a valid security report.

For the post-build half of the picture — SBOMs, image signing, SLSA build provenance, and admission-time verification — see [`docs/supply-chain.md`](docs/supply-chain.md).

## Out of scope

- Vulnerabilities in upstream base images themselves (report upstream).
- Issues in user code copied into the image (the template can only do so much; we'll still review reports that suggest a template change would have mitigated the issue).
- Denial-of-service or resource-exhaustion reports for the build process itself (these are quality issues, not security issues).
- Findings that depend on disabling the documented runtime hardening flags (`--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--network=none` for the sandbox variant).

## Coordinated disclosure

We commit to:

- Not pursuing legal action against good-faith security researchers acting within this policy.
- Crediting reporters in the fix's release notes unless anonymity is requested.
- Not requiring NDAs as a precondition for accepting a report.
