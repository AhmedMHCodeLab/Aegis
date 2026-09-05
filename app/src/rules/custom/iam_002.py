PUBLIC_MEMBERS = {"allUsers", "allAuthenticatedUsers"}


def evaluate(rule: dict, config: dict) -> dict:
    bindings = config.get("iam_bindings")
    # An absent key means the bindings were never declared, which is not the same as
    # declaring an empty set. Only the latter is evidence of compliance.
    declared = bindings is not None

    public_bindings = []
    for b in bindings if declared else []:
        public_in_binding = [m for m in b.get("members", []) if m in PUBLIC_MEMBERS]
        if public_in_binding:
            public_bindings.append({"role": b["role"], "public_members": public_in_binding})

    passed = declared and not public_bindings

    if not declared:
        actual = "iam_bindings not declared"
    elif public_bindings:
        actual = public_bindings
    else:
        actual = "no public bindings"

    return {
        "rule_id": rule["id"],
        "category": rule["category"],
        "name": rule["name"],
        "status": "PASS" if passed else "FAIL",
        "severity": rule["severity"],
        "evidence": {
            "field": "iam_bindings[].members",
            "actual": actual,
            "expected": "zero allUsers or allAuthenticatedUsers members",
        },
        "remediation": rule["remediation"],
    }
