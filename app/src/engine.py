import importlib
import yaml
from pathlib import Path


OPERATORS = {
    "equals": lambda actual, expected: actual == expected,
    "not_equals": lambda actual, expected: actual != expected,
    "not_in": lambda actual, expected: actual not in expected,
    "exists": lambda actual, _: actual is not None and actual != [] and actual != "",
    "not_exists": lambda actual, _: actual is None or actual == [] or actual == "",
    "gte": lambda actual, expected: float(actual) >= float(expected) if actual is not None else False,
}


def resolve_field(config: dict, field_path: str):
    keys = field_path.split(".")
    current = config
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def load_rules(rules_dir: Path) -> list[dict]:
    rules = []
    for yaml_file in sorted(rules_dir.glob("*.yaml")):
        with open(yaml_file) as f:
            rules.extend(yaml.safe_load(f))
    return rules


def assertions_for(rule: dict) -> list[dict]:
    """A control is a conjunction of assertions, evaluated in order.

    Single-assertion rules declare field/operator/expected inline; the engine
    normalises both shapes so there is one evaluation path.
    """
    if "assertions" in rule:
        return rule["assertions"]
    return [{
        "field": rule["field"],
        "operator": rule["operator"],
        "expected": rule.get("expected"),
    }]


def build_result(rule: dict, assertion: dict, actual, passed: bool) -> dict:
    return {
        "rule_id": rule["id"],
        "category": rule["category"],
        "name": rule["name"],
        "status": "PASS" if passed else "FAIL",
        "severity": rule["severity"],
        "evidence": {
            "field": assertion["field"],
            "actual": actual,
            "expected": assertion.get("expected"),
        },
        "remediation": rule["remediation"],
    }


def evaluate_rule(rule: dict, config: dict) -> dict:
    if rule.get("evaluator") == "custom":
        module = importlib.import_module(rule["handler"])
        return module.evaluate(rule, config)

    checks = assertions_for(rule)
    for assertion in checks:
        actual = resolve_field(config, assertion["field"])
        if not OPERATORS[assertion["operator"]](actual, assertion.get("expected")):
            # The first unmet assertion is the evidence: it is why the control failed.
            return build_result(rule, assertion, actual, False)

    # Every assertion held. Report the substantive one, not the presence guard.
    final = checks[-1]
    return build_result(rule, final, resolve_field(config, final["field"]), True)


def evaluate_all(rules: list[dict], config: dict) -> list[dict]:
    return [evaluate_rule(rule, config) for rule in rules]
