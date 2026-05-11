# Dockerfiles

Best practices and templates for building efficient and secure Docker images.

## Layout

- `dockerfiles/` — Dockerfile templates organized per ecosystem (e.g. `node/`, `python/`, `go/`).
- `docs/` — Best-practice guides (multi-stage builds, image hardening, caching, etc.).

## Tooling

Requires Node.js 20+ (for the lint tooling only) and [hadolint](https://github.com/hadolint/hadolint) on `PATH`.

```sh
npm install        # installs prettier + markdownlint-cli2
npm run lint       # prettier check + markdownlint + hadolint
npm run format     # prettier --write
```

CI runs the same checks on every push and PR (`.github/workflows/lint.yml`).

## Docker for Agentic Applications and components

### "Kitchen Sink" Pradox vs Minimalism

> Change - Maintain two distinct types of images

Traditional best practice/advice is to remove every thing that is not needed for the app to run. However AI agents need broad set of tools (CI utilities, Python libraries, curl, git etc). To solve this:

- **Agent Host (Controller)**
  Follows strict minimalism. This container runs LLM reasoning loop. It should have zero system tools to prevent a compromised agent from breaking out.
- **Execution Sandbox**
  A new class of fat images preloaded with safe, verified tools.

> Instead of using `apt-get install` at runtime (which breaks reproducibility), use "Toolbox" patterns. Build images specifically designed to be mounted or called by agents, containing verified versions of all potenetial tools required by agent.

### Runtime security for generated code

> Change - "Running as non-root" is no longer enough.

Agents often write and execute their own code. A traditional container assumes the codde inside is trusted, but container runs untrusted (ai-generated) code.

- **No network by default**
  Build agent execution images with no network drivers or restricted outbound rules (`--network none` in run commands) unless explicitly needed.
- **Ephemeral & Read-Only**
  Agent workspaces should be disposable. Use `--read-only` root filesystem with a mounted temporary `/workspace` volume which is wiped after every task.

### MCP

Docker is actively integrating with the MCP, a standard that lets agent discover and connect to data sources and tools.

> Change - Dockerfiles are becomming "server definitions" for agent tools.

- **Standardized Entrypoints**
  Images now need to expose standardized endpoints (like MCP servers) so agents can "discover" what images can do.
- **Sidecar Patterns**
  Instead of installing database client inside the agent's image, run the agent alongside an "MCP Gateway" (container that proxies secure access to database).

### Summary

| Feature       | Traditional Practice           | Agentic Practice                            |
| ------------- | ------------------------------ | ------------------------------------------- |
| Image content | Minimal, only app dependencies | Bimodal: Tiny Controllers vs. Fat Toolboxes |
