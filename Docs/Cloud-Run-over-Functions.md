# ADR: Cloud Run with a pre-built image, not Cloud Run functions

**Status:** Accepted
**Scope:** `terraform/modules/cloud_run/`, `app/Dockerfile`

## Context

Aegis is a FastAPI application with three API routes and a server-rendered UI. Both Cloud Run and Cloud
Run functions can host it.

The build plan framed this decision as "containerization control, VPC Connector support, concurrency
model, cold start tradeoffs". **Three of those four no longer distinguish the options**, and writing the
ADR from that framing would have produced a comparison that was true in 2022 and misleading now.

Cloud Run functions (2nd gen) *are* Cloud Run. Google: "A function is a Cloud Run service that is
deployed from source code", automatically "built as containers and deployed as a Cloud Run service".
They support "up to 1000 concurrent requests per function instance" and give "complete access and
control over the function's behavior. For example, you can enable Direct VPC, configure GPUs, use
volume mounts"
([source](https://docs.cloud.google.com/functions/docs/concepts/version-comparison)).

So VPC egress, ingress settings, and concurrency are not differentiators. One difference is real: **who
builds the container image.**

## Decision

**Deploy a pre-built container image to Cloud Run.**

The deciding factor is the supply chain, not the runtime.

A function is deployed from source and the image is produced by Google's buildpacks. That forecloses
three things this project has already committed to:

1. **The distroless base image.** `Docs/Distroless-Container.md` chose `gcr.io/distroless/python3-debian12:nonroot`
   to remove the shell, package manager, and network utilities an attacker inherits after code
   execution. Buildpack-produced images ship a conventional userland. Choosing functions means
   reversing that ADR.
2. **Digest pinning.** The threat model records base images pinned by tag rather than digest as an open
   residual (T-07). The fix requires authoring the Dockerfile. When Google builds the image, there is no
   digest to pin.
3. **Reproducibility of the artifact under review.** The negative testing in Session 4 asserts
   properties of a specific image. That image has to be one we produced.

The workload shape reinforces it: Aegis is a multi-route web application with a UI, not an event
handler. The function abstraction adds a deployment convenience the project does not need.

## Consequences

**We own base image currency.** This is the real cost and it is ongoing. Google patches buildpack base
images; nobody patches ours. The compensating control is the Trivy gate failing on CRITICAL (Session 3)
plus digest pinning, which converts "silently drifting" into "explicitly updated".

**We own the build.** A Dockerfile, a builder stage, and a pipeline that produces and pushes the image.
More surface than `gcloud functions deploy`, and the reason Session 3 exists.

**The deployment target is portable in principle.** A container image runs on Cloud Run, GKE, or any
OCI runtime. Source-deployed functions do not move. Not a requirement here, but it is the difference
between a build artifact and a platform coupling.

## Alternatives rejected

**Cloud Run functions from source.** Faster to deploy, less to maintain, and Google keeps the base image
current. Rejected because it reverses the distroless decision and removes the ability to pin or verify
what runs. For a service whose entire purpose is demonstrating supply chain and hardening controls, not
controlling its own image is the wrong trade.

**GKE.** Provides everything and demands a cluster. One stateless service does not justify a control
plane, node pools, and their patching. Kubernetes-layer security is explicitly the other project's scope.

**App Engine.** Standard environment constrains the runtime; flexible is effectively deprecated in
favour of Cloud Run. No advantage here.

## Verification

- The image digest deployed to Cloud Run matches the digest the pipeline pushed to Artifact Registry
- `docker run -p 8080:8080` reproduces production behaviour locally with no GCP credentials
- The running container has no shell: `docker exec` with `/bin/sh` fails
