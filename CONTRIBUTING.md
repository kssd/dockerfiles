# Contributing

Thanks for your interest in improving these Dockerfile templates and guides.

## Ground rules

- Templates are reference material. They should be **runnable as-is** for the documented build context, **hadolint-clean** at the `warning` threshold, and **non-root + multi-stage** wherever the runtime allows it.
- Pin everything: base image tags (digests in production), package versions, lock files. Floating `latest` tags are not accepted.
- Document the _why_ in Dockerfile headers (security trade-offs, footguns, version-compat notes). The header is the first thing a reader sees.

## Local setup

```bash
npm install              # prettier + markdownlint-cli2
brew install hadolint    # or: see https://github.com/hadolint/hadolint
```

## Before opening a PR

Run the full lint pipeline:

```bash
npm run lint             # prettier check + markdownlint + hadolint
```

If you changed a Dockerfile, also do a real build with `docker build --progress=plain` to confirm the build context is what you expect and the layer cache behaves as advertised.

## What we look for in review

- **Correctness**: the template builds, runs, and survives the documented invocation flags (`--read-only`, `--cap-drop=ALL`, etc. where applicable).
- **Reproducibility**: pinned bases, locked deps, no implicit network fetches at build time beyond the pinned package indexes.
- **Security posture**: non-root runtime, no shell / package manager in the final image unless the variant is explicitly a sandbox, no secrets in build args, `.dockerignore` actually excludes what it claims to.
- **Header documentation**: trade-offs are spelled out (e.g. distroless vs. Chainguard, sandbox vs. controller).
- **Hadolint**: any `# hadolint ignore=DLxxxx` must carry a one-line justification.

## Adding a new ecosystem

Create `dockerfiles/<ecosystem>/Dockerfile` (plus variants as `Dockerfile.<variant>`), a per-directory `.dockerignore` if the build context differs from the root one, and a `README.md` documenting the variants and their build/run invocations. Mirror the structure of `dockerfiles/python/`.

## Reporting bugs / requesting variants

Use the issue templates under `.github/ISSUE_TEMPLATE/`. For security issues, do **not** open a public issue — see `SECURITY.md`.

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0 (see `LICENSE`).
