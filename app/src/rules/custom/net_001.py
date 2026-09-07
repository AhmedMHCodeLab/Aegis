def evaluate(rule: dict, config: dict) -> dict:
    network = config.get("network")
    # An absent network block is an undeclared egress path, not a compliant one.
    declared = isinstance(network, dict)

    connector = network.get("vpc_connector") if declared else None
    interfaces = network.get("network_interfaces") if declared else None

    has_connector = bool(connector)
    has_direct_egress = bool(interfaces)
    passed = has_connector or has_direct_egress

    if not declared:
        actual = "network not declared"
    elif has_connector and has_direct_egress:
        actual = "VPC connector and direct VPC egress both declared"
    elif has_connector:
        actual = "Serverless VPC Access connector"
    elif has_direct_egress:
        actual = "direct VPC egress network interface"
    else:
        actual = "no VPC egress path declared"

    return {
        "rule_id": rule["id"],
        "category": rule["category"],
        "name": rule["name"],
        "status": "PASS" if passed else "FAIL",
        "severity": rule["severity"],
        "evidence": {
            "field": "network.vpc_connector | network.network_interfaces",
            "actual": actual,
            "expected": "a VPC connector or a direct VPC egress network interface",
        },
        "remediation": rule["remediation"],
    }
