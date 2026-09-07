# ADR: Direct VPC egress over a Serverless VPC Access connector

**Status:** Accepted
**Scope:** `terraform/modules/networking/`, `terraform/modules/cloud_run/`, `app/src/rules/network.yaml`
**Addresses:** Threat model flow 8; rule NET-001

## Context

The build plan specifies a Serverless VPC Access connector. Two mechanisms now route Cloud Run egress
into a VPC, and Google's guidance between them is conditional rather than absolute.

The documented reason to prefer a connector is startup latency: "With Cloud NAT, you might experience
cold start delays of 30s or more on instance startup when using Direct VPC egress. For better startup
performance, we recommend using Serverless VPC Access connectors with Cloud NAT." Direct VPC egress
otherwise has the advantage that "network costs scale to zero just like the service itself"
([source](https://docs.cloud.google.com/run/docs/configuring/vpc-direct-vpc)).

**That recommendation is conditioned on Cloud NAT, and Aegis does not need Cloud NAT.** The application
makes no outbound internet calls: `app/src/engine.py` performs no network operations, and its only
outbound traffic is to Secret Manager and Cloud KMS, which are Google APIs reachable through Private
Google Access. With no internet egress there is no NAT gateway, and the sole documented reason to prefer
a connector does not apply to this workload.

## Decision

**Use direct VPC egress. No Serverless VPC Access connector.**

What remains after the NAT caveat is removed: a connector is a set of always-on instances that must be
sized, paid for, and patched, in front of a service that otherwise scales to zero. Direct VPC egress
achieves the same security outcome, egress traversing a subnet where firewall rules and Private Google
Access apply, with no standing compute.

## The rule this contradicted, and why the rule changed

This decision exposed a defect in Aegis's own baseline.

`NET-001` asserted `network.vpc_connector` exists, and its remediation named Serverless VPC Access
explicitly. Its **description** stated the actual intent: "route egress through your VPC where firewall
rules and Private Google Access apply." Direct VPC egress satisfies that intent by another mechanism.

Deploying the recommended architecture would have made Aegis fail its own HIGH-severity control. Two
wrong ways to resolve that: pick the connector to keep the product self-consistent, letting a rule
dictate infrastructure; or ship the contradiction and document it, leaving a compliance tool that fails
its own baseline.

**The rule was wrong. It encoded a mechanism where it meant an outcome**, so it aged the moment the
platform grew a second way to achieve that outcome.

`NET-001` is now `VPC egress path configured`, and it passes when either mechanism is present:

```yaml
- id: NET-001
  name: VPC egress path configured
  description: Cloud Run egress must traverse a customer-controlled VPC where firewall
    rules and Private Google Access apply.
  evaluator: custom
  handler: src.rules.custom.net_001
```

The custom evaluator is the documented escape hatch, used because the engine's assertions are a
conjunction and this control needs a disjunction. Fail-closed semantics are preserved: an absent
`network` block reports "network not declared" and FAILs, matching the treatment of undeclared
`iam_bindings` in `iam_001` and `iam_002`.

The control count stays at 13, so the API contract is unchanged.

## Consequences

**Subnet sizing becomes a design input.** Direct VPC egress consumes addresses from the subnet per
instance, so the subnet CIDR must accommodate `max_instance_count` plus headroom. A connector would have
hidden this behind its own scaling. Getting it wrong surfaces as instances failing to start under load,
which is a worse failure mode than a slow cold start.

**One less resource to patch and pay for**, and one less always-on component in a serverless
architecture.

**The rule change is a behaviour change for existing users.** A configuration declaring direct VPC
egress previously failed NET-001 and now passes. That is the point, but it means the control's verdict
is not comparable across the change. Four tests pin the new behaviour, including that neither mechanism
declared still fails.

**A precedent worth applying to the rest of the baseline.** NET-001 was not uniquely wrong. Any rule
naming a product rather than a property has the same latent defect. Not audited here; recorded as a
follow-up.

## Alternatives rejected

**Serverless VPC Access connector, per the build plan.** Google's recommendation under Cloud NAT, more
widely documented, and predictable cold starts. Rejected because the condition attaching to that
recommendation does not hold for this workload, and adopting it would mean paying for always-on
instances to satisfy guidance aimed at a different problem.

**Keep NET-001 as written and deploy a connector.** Zero rule changes, product and infrastructure
consistent. Rejected because it inverts the relationship: the compliance rule would be choosing the
architecture, and the rule was the thing that was wrong.

**No VPC egress at all.** Cloud Run reaching Google APIs over the public path. Simplest, and defensible
for a service with no private dependencies. Rejected because it forfeits egress control entirely and
NET-002's default-deny posture has nothing to attach to.

## Remaining uncertainty

Direct VPC egress support in `me-central1` is assumed, not verified. Confirmed empirically in Session 2.
If unavailable, the connector returns and this ADR is superseded, but the NET-001 rule change stands on
its own merits either way.

## Verification

| Check | Result |
|---|---|
| `pytest` after the rule change | 92 passed |
| Direct egress config passes NET-001 | Evidence reads "direct VPC egress network interface" |
| Connector config still passes NET-001 | Evidence reads "Serverless VPC Access connector" |
| Declared network with neither mechanism | FAIL, "no VPC egress path declared" |
| Absent network block | FAIL, "network not declared" |
| Rules loaded | 13 |

Session 2 adds: egress to an unauthorised internet destination fails, and Private Google Access reaches
Secret Manager from the subnet.
