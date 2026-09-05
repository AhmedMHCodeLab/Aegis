def evaluate(rule: dict, config: dict) -> dict:
    wif = config.get("wif", {})
    provider = wif.get("provider")
    static_keys = wif.get("static_keys", [])

    has_provider = provider is not None and provider != ""
    no_static_keys = len(static_keys) == 0
    passed = has_provider and no_static_keys

    if not has_provider and not no_static_keys:
        actual_desc = f"no WIF provider, {len(static_keys)} static key(s)"
    elif not has_provider:
        actual_desc = "no WIF provider configured"
    elif not no_static_keys:
        actual_desc = f"WIF configured but {len(static_keys)} static key(s) present"
    else:
        actual_desc = "WIF configured, zero static keys"

    return {
        "rule_id": rule["id"],
        "category": rule["category"],
        "name": rule["name"],
        "status": "PASS" if passed else "FAIL",
        "severity": rule["severity"],
        "evidence": {
            "field": "wif.provider + wif.static_keys",
            "actual": actual_desc,
            "expected": "WIF provider present, zero static keys",
        },
        "remediation": rule["remediation"],
    }
