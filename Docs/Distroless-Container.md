# ADR: Distroless container image with nonroot execution

**Status:** Accepted
**Scope:** `app/Dockerfile`

## Context

Aegis runs as a Cloud Run service. The container image choice determines the
attack surface available to an adversary who achieves code execution inside the
container, whether through a dependency vulnerability, a deserialization flaw,
or any other vector that grants arbitrary execution within the process boundary.

The question is not whether the initial exploit can be prevented at the image
level (it cannot), but what the attacker can do after landing.

## Decision

**Use `gcr.io/distroless/python3-debian12:nonroot` as the runtime base image.**

### What distroless removes

A standard Python image (`python:3.11-slim`, ~150MB) ships a Debian userland:
`bash`, `sh`, `apt-get`, `curl`, `wget`, coreutils, and hundreds of system
libraries the application never calls. Every one of those binaries is available
to an attacker after initial access.

Distroless (~50MB) ships only the Python interpreter, its standard library, and
the minimal set of shared libraries they depend on. There is no shell, no
package manager, no network utilities, no text editors.

| Post-exploitation action | Standard image | Distroless |
|---|---|---|
| Download a payload (`curl`, `wget`) | Available | No binary exists |
| Spawn a reverse shell (`bash`, `sh`) | Available | No shell exists |
| Install tools (`apt-get install`) | Available | No package manager |
| Enumerate the filesystem | Full coreutils | No `ls`, `find`, `cat` |
| Read `/etc/passwd`, system config | Present and readable | Minimal, unprivileged |

This does not make exploitation impossible. An attacker with code execution can
still make raw syscalls, write to `/tmp`, or use Python itself as a scripting
environment. But it removes the commodity toolchain that post-exploitation
frameworks, automated scanners, and most manual attackers depend on. The attack
goes from "download and run" to "write it from scratch in the language already
running," which raises the cost substantially.

### The `:nonroot` tag

The default distroless tag runs as uid 0. The `:nonroot` tag runs as uid 65532,
a user with no special privileges. This layers least-privilege on top of the
reduced surface: even with code execution, the process cannot bind privileged
ports, write to system directories, or modify its own image.

```
$ docker run --rm gcr.io/distroless/python3-debian12 -c "import os; print(os.getuid())"
0
$ docker run --rm gcr.io/distroless/python3-debian12:nonroot -c "import os; print(os.getuid())"
65532
```

This is verified empirically because the distroless README lists the tag but
does not publish the UID.

### Why this matters for Aegis specifically

Aegis is a compliance checkpoint service that evaluates Cloud Run security
posture. Shipping it in a container with a shell, running as root, would
contradict the controls the tool itself enforces (CR-002: dedicated service
account, CR-003: authentication required). The container is part of the
security argument.

## Consequences

**Reduced attack surface.** The commodity post-exploitation path (land, download,
escalate) is broken at the "download" step. An attacker must bring their own
tooling through the initial vector or build it in Python at runtime.

**No interactive debugging.** `docker exec -it container /bin/sh` fails because
there is no shell. Debugging a running distroless container requires:

- Structured logging (implemented: JSON to stdout with `severity` for Cloud
  Logging)
- A debug sidecar container
- Temporarily swapping to the `:debug` tag (ships busybox) in non-production
  environments
- `kubectl debug` with an ephemeral container (if running on GKE)

For production, this is the correct trade-off. Observability through logs
replaces observability through shell access. For local development, the app
runs directly via `uvicorn` without a container.

**Build complexity.** Distroless strips `site-packages` from `sys.path`, so
dependencies installed by pip are invisible to the interpreter without an
explicit `ENV PYTHONPATH`. This is a property of distroless Python generally,
not specific to debian12 (verified on debian13 as well). Documented in
[Spec-Deviations.md](./Spec-Deviations.md) §1.2.

**Image size.** ~50MB vs ~150MB for `python:3.11-slim`. Smaller images pull
faster (cold start on Cloud Run) and present less to scan.

## Alternatives considered

**`python:3.11-slim`:** Full Debian userland available. Smaller than the full
`python:3.11` image but still ships a shell, package manager, and network
utilities. The standard choice when debugging convenience outweighs hardening.

**`python:3.11-alpine`:** Musl libc instead of glibc. Smaller than slim (~45MB)
but introduces compatibility issues with compiled Python packages (numpy,
cryptography, etc.) because wheels are built against glibc. Not relevant for
Aegis's pure-Python dependencies today, but creates a hidden constraint for
future additions. Alpine also ships a shell (`/bin/sh` via busybox), so the
attack surface reduction is smaller than distroless.

**`chainguard/python`:** Wolfi-based hardened image from Chainguard. Similar
philosophy to distroless (minimal surface, nonroot by default) with better
supply-chain provenance (signed SBOMs, daily rebuilds). Commercially supported.
A strong alternative; distroless was chosen because it is the Google-maintained
option and Aegis runs on GCP, keeping the supply chain within one vendor's
ecosystem.

## Cross-platform equivalents

The pattern of stripping containers to the minimum viable runtime exists across
all major cloud providers:

| Provider | Equivalent | Notes |
|---|---|---|
| **GCP** | `gcr.io/distroless/python3-debian12` | Google-maintained, used here |
| **AWS** | `public.ecr.aws/lambda/python` | Lambda's managed runtime image |
| **Azure** | `mcr.microsoft.com/cbl-mariner/distroless/python` | CBL-Mariner based |
| **Vendor-neutral** | `cgr.dev/chainguard/python` | Wolfi-based, signed SBOMs |

The underlying principle is the same everywhere: every binary you ship is
attack surface you maintain. A container should contain what the application
needs to run and nothing else.
