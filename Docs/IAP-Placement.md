# ADR: IAP on Cloud Run directly, load balancer kept for TLS and the custom domain

**Status:** Accepted (supersedes the original decision below)
**Scope:** `terraform/modules/dns/`, `terraform/modules/security/`, `terraform/modules/cloud_run/`
**Addresses:** Threat model T-01, T-02. Resolves O-1.

## Update: the original decision was reversed

The original decision (kept below for context) was **IAP on the load balancer's backend service**. That
was reversed. Current decision: **`iap_enabled = true` on the Cloud Run service itself**, backend service
carries no `iap` block.

Two pieces of evidence drove this, verified against
[the current GCP doc](https://docs.cloud.google.com/iap/docs/enabling-cloud-run) directly, not from
memory:

1. **The two modes are mutually exclusive, not composable.** Verbatim: *"IAP can't be used on both Cloud
   Run services and the load balancer."* The original ADR's "Remaining uncertainty" section asked whether
   both could run together for defence in depth. They cannot. This was a real open question, now closed.

2. **IAP-on-Cloud-Run does not only guard the `run.app` hostname.** Verbatim: *"Protects the `run.app`
   endpoint directly... If you opt to place a load balancer in front of Cloud Run, the load balancer's
   endpoint is also protected."* This is the part that changes the architecture. It means keeping the
   external LB in front and enabling IAP on Cloud Run is not "IAP on one path, open on the other." IAP
   becomes the single identity check that every path (`run.app` or through the LB's serverless NEG) has
   to pass, because the underlying mechanism is an IAM restriction: only IAP's own service agent holds
   `roles/run.invoker` on the Cloud Run service, so nothing else, no LB, no NEG, no direct hostname,
   can invoke the container without going through IAP first.

The original ADR treated "IAP direct" and "keep the LB" as mutually exclusive choices, because Google's
docs frame IAP-direct as an alternative *to* provisioning a load balancer. That framing is true for a
service whose only reason to have an LB is IAP. It doesn't hold once you register that Cloud Armor,
the managed cert, and the custom domain are separate reasons to keep the LB that have nothing to do with
where the IAP check lives. The original "Alternatives rejected" section below conflated the two.

> **One of those three reasons did not survive contact with the project.** Cloud Armor is not deployed,
> because the project's quota for it is zero and the increase request was refused. The decision here is
> unaffected, since IAP-direct was never contingent on the WAF, but the justification for keeping the
> load balancer is now two reasons rather than three: the managed certificate and the custom domain.
> Both are sufficient on their own. See [Security-Exceptions.md](Security-Exceptions.md).

## What this changes mechanically

```
Old design:
  run.app URL ──(ingress filter + invoker IAM)──> Cloud Run   [bypass risk: T-01]
  LB path     ──(Cloud Armor)──> backend service (iap block) ──> serverless NEG ──> Cloud Run

New design:
  run.app URL ─────────┐
                        ├──(IAP, single check)──> Cloud Run
  LB path (Cloud Armor) ┘
```

`ingress` on the Cloud Run service is `INGRESS_TRAFFIC_ALL`, not restricted to internal+LB. That's
intentional now, not a gap: restricting ingress was the old mechanism for closing the `run.app` bypass.
Under the new design the bypass is closed by IAM (only IAP's service agent can invoke the container), so
ingress no longer needs to do that job. Two IAM bindings do the real work:

```hcl
google_cloud_run_v2_service_iam_member.iap_invoker
  role   = "roles/run.invoker"
  member = IAP's own service agent          # only IAP may call the container

google_iap_web_cloud_run_service_iam_member.user
  role   = "roles/iap.httpsResourceAccessor"
  member = the authorised human              # only this human may pass IAP's check
```

## Why the load balancer stays (original reasoning, still valid)

The load balancer was never carrying IAP for its own sake. It carries three other things IAP-direct
cannot provide:

| Control | Requires the LB | Consequence of removing it |
|---|---|---|
| ~~Cloud Armor WAF and rate limiting~~ **not deployed** | Attaches to a backend service | Already the case: quota is zero. T-04 control 2 has disappeared regardless of the LB |
| Google-managed SSL certificate | Belongs to the target HTTPS proxy | No custom domain TLS |
| SSL policy, TLS 1.2 minimum | Attached to the proxy | No control over cipher/version floor |
| Custom domain via the Route 53 A record | Points at the LB's global IP | Service reachable only at `run.app` |

Removing the LB to "simplify" would cost the three that are actually deployed. None of them depend on
where the IAP check lives, so none of them are reasons to prefer IAP-on-backend-service over
IAP-on-Cloud-Run.

## Consequences

**A standing cost floor, unchanged.** The forwarding rule still bills hourly regardless of traffic, same
as the original decision. This didn't change; only the IAP mechanism moved.

**One identity check instead of two.** The original design's "two identity checks fail independently,
which is the point" reasoning no longer applies, there is one IAP check now, sitting earlier in the path
and covering both entry points. This is not weaker: it closes O-1 (see below) rather than trading it for
a second check.

**`default_uri_disabled` (D4) is retired**, not merely deferred. It existed to remove the `run.app`
endpoint because, under the old design, that endpoint could be reached without passing IAP. Under this
design, `run.app` is already behind IAP, there is no bypass left to remove.

## Alternatives rejected

**IAP on the backend service (the original decision).** Rejected on new evidence: it leaves `run.app`
protected only by ingress filtering and invoker IAM, both of which are network/identity plumbing, not the
actual authentication boundary IAP provides. `T-01`'s residual risk was rated Low largely on the strength
of the ingress+invoker pairing; IAP-direct achieves a lower residual risk with fewer moving parts.

**Private-only service, no public entry point.** Unchanged from the original ADR: rejected because the
service is demonstrated in a browser to non-technical stakeholders, and VPN/bastion access defeats that.

**Public with no IAP, Cloud Armor alone.** Unchanged: a WAF is not an authentication control. Rejected.

## Resolved uncertainty

The original ADR flagged as unverified: *"Whether IAP on Cloud Run and IAP on the backend service can be
enabled simultaneously for defence in depth at TB-3."* Resolved: no, they are mutually exclusive by
design. This also resolves **O-1** (does `INGRESS_TRAFFIC_INTERNAL_AND_CLOUD_LOAD_BALANCING` admit a
third party's load balancer from another project). Under the current design, ingress is `ALL` and doesn't
need to answer that question: even if a third party fronted this service with their own LB, their NEG
still cannot invoke the container, because invoker IAM is scoped to IAP's service agent alone. The
network-shape question O-1 was trying to answer is now moot; the identity boundary answers it directly.

## Verification

- LB endpoint (custom domain) returns the IAP sign-in redirect for an unauthenticated session, and 200
  for an authorised user after sign-in
- `curl https://<service>.run.app/health` also returns the IAP sign-in redirect or a 403, not a raw
  Cloud Run response, confirming `run.app` is behind IAP, not just filtered by ingress
- ~~A SQLi payload through the LB path returns 403 attributed to Cloud Armor~~ **Not testable.** Cloud
  Armor is not deployed, so there is nothing to attribute a 403 to. Reinstate this check if quota is
  ever granted
  or the app
- SSL Labs reports A or A+ with TLS 1.2 as the floor
- `gcloud run services get-iam-policy` shows `roles/run.invoker` held only by IAP's service agent, no
  `allUsers`, no other principal
