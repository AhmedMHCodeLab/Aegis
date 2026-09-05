# ADR: Controls are conjunctions of assertions, and presence is asserted in the data

**Status:** Accepted
**Scope:** `app/src/engine.py`, `app/src/rules/cloud_run.yaml`, `app/src/rules/network.yaml`,
`app/src/rules/custom/iam_001.py`, `app/src/rules/custom/iam_002.py`

## Context

Aegis judges a configuration it is handed. It cannot query GCP to confirm what a
submitted document leaves out. So the engine must decide what an absent field means:
is silence compliance, or an unanswered question?

The specification's operator set answered inconsistently, by accident rather than
design:

| Operator     | Absent field evaluates as | Verdict                  |
|--------------|---------------------------|--------------------------|
| `equals`     | `None == "internal"`      | FAIL (closed)            |
| `gte`        | guarded `is not None`     | FAIL (closed)            |
| `exists`     | `None`                    | FAIL (correct by design) |
| `not_exists` | `None`                    | PASS (correct by design) |
| `not_equals` | `None != "all-traffic"`   | **PASS (open)**          |
| `not_in`     | `None not in [...]`       | **PASS (open)**          |

The negative operators inverted the tool's purpose. A configuration containing no
`network` block passed NET-002 ("Restricted egress"), because `None` genuinely is not
equal to `"all-traffic"`. CR-002 had the same hole, as did the custom IAM handlers,
which read a missing `iam_bindings` key as an empty list.

A config declaring only `{"ingress": "..."}` scored 38%. Four of those five passing
controls passed because the author had said nothing about them. A compliance tool
that certifies silence as compliance is worse than no tool: it produces an artefact
that reads as assurance while measuring nothing.

## Decision

**Absence of evidence is not evidence of compliance**, and that policy lives in the
rule data, not in the engine.

### A control is a conjunction

A rule may declare an ordered list of assertions. All must hold for the control to
pass. The first unmet assertion is the evidence, because it is the reason the control
failed.

```yaml
- id: NET-002
  name: Restricted egress
  category: Network
  severity: MEDIUM
  # not_equals passes on an absent field, so presence is asserted first: an
  # undeclared egress setting is missing evidence, not a restricted egress.
  assertions:
    - field: network.egress_setting
      operator: exists
    - field: network.egress_setting
      operator: not_equals
      expected: all-traffic
```

Single-assertion rules keep the concise inline form. `assertions_for()` normalises
both shapes at evaluation time, so the engine has exactly one evaluation path:

```python
def assertions_for(rule: dict) -> list[dict]:
    if "assertions" in rule:
        return rule["assertions"]
    return [{"field": rule["field"], "operator": rule["operator"],
             "expected": rule.get("expected")}]
```

Only CR-002 and NET-002 need pairing. The other eight declarative rules use operators
that already fail closed, so forcing them into a list would add nesting without
adding meaning.

### 13 controls, not 13 YAML entries

An earlier revision of this decision refused the rule-layer fix on the grounds that
it would break the locked count of 13. That was a category error: the lock protects
the **baseline against scope creep**, and 13 controls is an API contract. How many
assertions express a control is an authoring detail.

The distinction is load-bearing. Emitting one result per *assertion* would produce 15
results with duplicate `rule_id` values, making `summary.total` 15 and silently
changing the score denominator. The conjunction collapses to one result per control,
so `/v1/rules` returns 13, `/v1/check` returns 13, and rule IDs stay unique.

### Custom handlers apply the same principle in Python

`iam_001` and `iam_002` draw a distinction the previous code could not express:

- `iam_bindings` **key absent** → FAIL, evidence reads `iam_bindings not declared`
- `iam_bindings` **declared as `[]`** → PASS

An empty list is an attestation: the author states there are none. A missing key is a
gap in the submission. Different claims, different verdicts. `iam_003` was already
closed, since a missing `wif` block yields no provider.

### The rule data is linted

Moving policy into data means an author can forget it. That risk is carried by a test
over the rule files rather than by a runtime override:

```python
def test_every_negative_operator_is_preceded_by_a_presence_assertion(rules):
    # not_equals / not_in pass on an absent field, so each needs a prior
    # 'exists' assertion on the same field.
```

## Consequences

**The score changed meaning, for the better.** It was "controls not contradicted by
this document". It is now "controls this document positively demonstrates". The
denominator was always the full 13-control baseline; only now does the numerator mean
what the denominator implies.

**Evidence got more accurate.** Previously an undeclared service account reported
`expected: "default"`, pointing at a comparison that never ran. It now reports the
presence assertion, which the UI renders as "Found: not set / Expected: must be
present". Across 15 configurations and 195 results, this refactor changed **zero
verdicts** and improved 22 evidence objects.

**Scoped configurations score honestly.** A config declaring only the four Cloud Run
fields scores 4/13, not 7/13. Each category fixture now passes exactly and only its
own category's controls, with no cross-category leakage. That exactness is the signal
the semantics are right, and it is pinned by
`test_category_fixture_passes_nothing_outside_its_category`.

**The burden moves to the config author, deliberately.** A service with genuinely no
IAM bindings must declare `"iam_bindings": []` rather than omit the key. This is the
real cost. It is the correct cost: an explicit empty declaration is a statement
someone is accountable for; an omission is not.

**The guard is opt-in, and that is the trade-off of this location.** An engine-level
override would be fail-safe by construction: a new rule using `not_equals` would be
guarded whether or not its author thought about it. Declaring the guard per rule
means an author can omit it, and the protection is then a test rather than a runtime
property. This was accepted because the alternative is worse: with both mechanisms in
place, a rule file could declare its presence assertions while the engine silently
enforced the same thing anyway, leaving two sources of truth and rule files that only
appear to be authoritative. The brief's architecture is "rules are data, not code";
a policy constant in `engine.py` contradicts it. One source of truth, linted.

**Two authoring shapes exist.** Inline single-assertion and explicit `assertions`.
A reader must recognise both. Mitigated by normalising to one shape before evaluation,
so the engine and every test see a uniform structure.

**Two distinct conditions still share one status.** "Declared and violating" and
"never declared" both render FAIL. The schema carries a `WARN` status no rule can
currently emit, which is where that distinction would live. Not used here: the score
is `passed / total`, and a third state makes the denominator ambiguous. A client
asking "why did this fail?" reads the evidence line and gets the answer.

## Alternatives rejected

**An engine-level `PRESENCE_REQUIRED` constant.** Implemented first, then removed. A
set of operators for which the engine forces FAIL on an absent field. Fewer lines and
fail-safe by default, but it puts a policy decision ("what does silence mean?") in
code, in a project whose stated architecture is that rules are data. It also makes
the rule files misleading: they would not say what is actually enforced.

**`not_in: [null, all-traffic]` in a single assertion.** This works with the existing
operator set and needs no engine change at all: an absent field resolves to `None`,
which is in the forbidden list, so it fails. Rejected as clever rather than clear.
A reviewer reading `[null, "all-traffic"]` has to infer that the `null` member encodes
a presence requirement. The explicit `exists` assertion states it.

**A `required: true` key per rule.** Special-cases presence instead of treating it as
what it is, an ordinary assertion, and adds a schema concept that the general
conjunction already covers.

**One result per assertion.** 15 results, duplicate `rule_id`s, `summary.total` of 15.
Breaks the 13-control API contract and the score denominator.

**Leave the specification's behaviour.** Faithful, and wrong. The specification never
chose fail-open semantics; it inherited them from Python's `!=` returning `True` for
`None`. There was no decision to preserve.

## Transferable principle

This is default-deny applied to evaluation rather than to traffic. A firewall that
forwards packets matching no rule, and a compliance engine that passes controls
matching no field, fail identically: the safe verdict must be the one requiring no
information, and the permissive verdict must be earned.

The mature expression in posture-management tooling is a third state separating
"evaluated and compliant" from "could not evaluate", so unevaluated resources never
inflate a compliance percentage. That is what `WARN` would carry here. Where a scoring
model has only two states, fail-closed is the only defensible default, because the
alternative lets an incomplete submission manufacture a passing grade.

## Verification

| Check | Result |
|---|---|
| Verdicts vs. pre-refactor baseline | 0 changes across 195 results, 15 configs |
| Evidence objects improved | 22 (absent field now cites the presence assertion) |
| Rules loaded / IDs unique | 13 / yes |
| `pytest` | 84 passed |
| `POST /v1/check` `full_secure.json` | 13 pass, `100%` |
| `POST /v1/check` `full_insecure.json` | 13 fail, `0%` |
| `POST /v1/check` `{"ingress": ...}` only | 1 pass, 12 fail, `8%` |
