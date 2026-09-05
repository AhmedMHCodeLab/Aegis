OVERPRIVILEGED_ROLES = {"roles/owner", "roles/editor"}


def evaluate(rule: dict, config: dict) -> dict:
    bindings = config.get("iam_bindings")
    # An absent key means the bindings were never declared, which is not the same as
    # declaring an empty set. Only the latter is evidence of compliance.
    declared = bindings is not None
    found = [b for b in bindings if b.get("role") in OVERPRIVILEGED_ROLES] if declared else []
    passed = declared and not found

    if not declared:
        actual = "iam_bindings not declared"
    elif found:
        actual = [b["role"] for b in found]
    else:
        actual = "no overprivileged roles"

    return {
        "rule_id": rule["id"],
        "category": rule["category"],
        "name": rule["name"],
        "status": "PASS" if passed else "FAIL",
        "severity": rule["severity"],
        "evidence": {
            "field": "iam_bindings[].role",
            "actual": actual,
            "expected": f"no roles in {sorted(OVERPRIVILEGED_ROLES)}",
        },
        "remediation": rule["remediation"],
    }
