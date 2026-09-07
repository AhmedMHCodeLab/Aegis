import pytest

from src.engine import OPERATORS, assertions_for, evaluate_rule, load_rules, resolve_field

# Operators that return True for an absent field, so they cannot stand alone:
# None != "all-traffic" is True, which would pass a control nobody declared.
NEGATIVE_OPERATORS = {"not_equals", "not_in"}


class TestResolveField:
    def test_top_level_key(self):
        assert resolve_field({"ingress": "all"}, "ingress") == "all"

    def test_dot_notation_walks_nested_dicts(self):
        config = {"encryption": {"kms_key": "projects/p/k"}}
        assert resolve_field(config, "encryption.kms_key") == "projects/p/k"

    def test_missing_intermediate_key_returns_none(self):
        assert resolve_field({}, "encryption.kms_key") is None

    def test_missing_leaf_key_returns_none(self):
        assert resolve_field({"encryption": {}}, "encryption.kms_key") is None

    def test_non_dict_intermediate_returns_none(self):
        assert resolve_field({"encryption": "not-a-dict"}, "encryption.kms_key") is None


class TestOperators:
    @pytest.mark.parametrize("actual,expected,result", [
        ("internal-and-cloud-load-balancing", "internal-and-cloud-load-balancing", True),
        ("all", "internal-and-cloud-load-balancing", False),
        (True, True, True),
        (False, True, False),
    ])
    def test_equals(self, actual, expected, result):
        assert OPERATORS["equals"](actual, expected) is result

    @pytest.mark.parametrize("actual,expected,result", [
        ("aegis-sa@project.iam.gserviceaccount.com", "default", True),
        ("default", "default", False),
    ])
    def test_not_equals(self, actual, expected, result):
        assert OPERATORS["not_equals"](actual, expected) is result

    @pytest.mark.parametrize("actual,expected,result", [
        ("roles/run.invoker", ["roles/owner", "roles/editor"], True),
        ("roles/owner", ["roles/owner", "roles/editor"], False),
    ])
    def test_not_in(self, actual, expected, result):
        assert OPERATORS["not_in"](actual, expected) is result

    @pytest.mark.parametrize("actual,result", [
        ("projects/p/keyRings/r/cryptoKeys/k", True),
        (None, False),
        ([], False),
        ("", False),
    ])
    def test_exists(self, actual, result):
        assert OPERATORS["exists"](actual, None) is result

    @pytest.mark.parametrize("actual,result", [
        (None, True),
        ([], True),
        ("", True),
        (["key-abc-123"], False),
    ])
    def test_not_exists(self, actual, result):
        assert OPERATORS["not_exists"](actual, None) is result

    @pytest.mark.parametrize("actual,expected,result", [
        ("1.3", "1.2", True),
        ("1.2", "1.2", True),
        ("1.0", "1.2", False),
        (None, "1.2", False),
        # Unparseable values fail closed instead of raising.
        ("TLSv1.2", "1.2", False),
        (["1.2"], "1.2", False),
        ({"v": 1.2}, "1.2", False),
    ])
    def test_gte(self, actual, expected, result):
        assert OPERATORS["gte"](actual, expected) is result

    def test_operator_set_is_exactly_the_six_specified(self):
        assert set(OPERATORS) == {
            "equals", "not_equals", "not_in", "exists", "not_exists", "gte",
        }

    @pytest.mark.parametrize("operator,expected", [
        ("not_equals", "all-traffic"),
        ("not_in", ["all-traffic"]),
    ])
    def test_negative_operators_pass_on_an_absent_field(self, operator, expected):
        # This is why a presence assertion has to guard them at the rule layer.
        assert operator in NEGATIVE_OPERATORS
        assert OPERATORS[operator](None, expected) is True


class TestAssertionsFor:
    def test_inline_shorthand_normalises_to_one_assertion(self):
        rule = {"field": "ingress", "operator": "equals", "expected": "internal"}
        assert assertions_for(rule) == [
            {"field": "ingress", "operator": "equals", "expected": "internal"}
        ]

    def test_shorthand_without_expected_defaults_to_none(self):
        rule = {"field": "encryption.kms_key", "operator": "exists"}
        assert assertions_for(rule) == [
            {"field": "encryption.kms_key", "operator": "exists", "expected": None}
        ]

    def test_explicit_list_is_passed_through(self):
        checks = [
            {"field": "a", "operator": "exists"},
            {"field": "a", "operator": "not_equals", "expected": "x"},
        ]
        assert assertions_for({"assertions": checks}) == checks


class TestConjunction:
    """A control is a conjunction: every assertion must hold for it to pass."""

    @staticmethod
    def guarded_rule():
        return {
            "id": "TEST-001", "name": "Test rule", "category": "Test", "severity": "HIGH",
            "assertions": [
                {"field": "network.egress_setting", "operator": "exists"},
                {"field": "network.egress_setting", "operator": "not_equals",
                 "expected": "all-traffic"},
            ],
            "remediation": "Declare a restricted egress setting.",
        }

    def test_absent_field_fails_on_the_presence_assertion(self):
        result = evaluate_rule(self.guarded_rule(), {})
        assert result["status"] == "FAIL"
        # Evidence cites the assertion that actually failed, not the one never reached.
        assert result["evidence"] == {
            "field": "network.egress_setting", "actual": None, "expected": None,
        }

    def test_declared_but_violating_field_fails_on_the_second_assertion(self):
        config = {"network": {"egress_setting": "all-traffic"}}
        result = evaluate_rule(self.guarded_rule(), config)
        assert result["status"] == "FAIL"
        assert result["evidence"]["actual"] == "all-traffic"
        assert result["evidence"]["expected"] == "all-traffic"

    def test_compliant_field_passes_and_reports_the_substantive_assertion(self):
        config = {"network": {"egress_setting": "private-ranges-only"}}
        result = evaluate_rule(self.guarded_rule(), config)
        assert result["status"] == "PASS"
        assert result["evidence"]["actual"] == "private-ranges-only"
        assert result["evidence"]["expected"] == "all-traffic"

    def test_conjunction_short_circuits_on_the_first_failure(self):
        rule = self.guarded_rule()
        rule["assertions"].append({"field": "never.reached", "operator": "exists"})
        assert evaluate_rule(rule, {})["evidence"]["field"] == "network.egress_setting"


class TestEvaluateRule:
    def test_declarative_rule_returns_full_result_shape(self):
        rule = {
            "id": "TEST-001", "name": "Test rule", "category": "Test", "severity": "HIGH",
            "field": "ingress", "operator": "equals", "expected": "internal",
            "remediation": "Set ingress to internal.",
        }
        result = evaluate_rule(rule, {"ingress": "all"})
        assert result == {
            "rule_id": "TEST-001",
            "category": "Test",
            "name": "Test rule",
            "status": "FAIL",
            "severity": "HIGH",
            "evidence": {"field": "ingress", "actual": "all", "expected": "internal"},
            "remediation": "Set ingress to internal.",
        }

    def test_custom_evaluator_dispatches_to_handler_module(self):
        rule = {
            "id": "IAM-003", "name": "WIF configured", "category": "IAM", "severity": "HIGH",
            "evaluator": "custom", "handler": "src.rules.custom.iam_003",
            "remediation": "Configure WIF.",
        }
        result = evaluate_rule(rule, {"wif": {"provider": "projects/123/x", "static_keys": []}})
        assert result["status"] == "PASS"
        assert result["rule_id"] == "IAM-003"


class TestLoadRules:
    def test_loads_thirteen_rules(self, rules):
        assert len(rules) == 13

    def test_every_rule_has_required_metadata(self, rules):
        for rule in rules:
            assert rule["id"]
            assert rule["name"]
            assert rule["category"]
            assert rule["severity"] in {"CRITICAL", "HIGH", "MEDIUM", "LOW"}
            assert rule["description"]
            assert rule["remediation"]

    def test_rule_ids_are_unique(self, rules):
        ids = [r["id"] for r in rules]
        assert len(ids) == len(set(ids))

    def test_every_rule_is_declarative_or_custom(self, rules):
        for rule in rules:
            if rule.get("evaluator") == "custom":
                assert rule["handler"].startswith("src.rules.custom.")
                continue
            for assertion in assertions_for(rule):
                assert assertion["operator"] in OPERATORS
                assert assertion["field"]


class TestBaselineIsGuardedAgainstFailOpen:
    """Lints the rule data, so a future author cannot reintroduce the fail-open bug.

    This replaces the engine-level override it supersedes: the policy lives in the
    rule files, and this test holds the rule files to it.
    """

    def test_every_negative_operator_is_preceded_by_a_presence_assertion(self, rules):
        for rule in rules:
            if rule.get("evaluator") == "custom":
                continue
            checks = assertions_for(rule)
            for i, assertion in enumerate(checks):
                if assertion["operator"] not in NEGATIVE_OPERATORS:
                    continue
                guards = [
                    c for c in checks[:i]
                    if c["field"] == assertion["field"] and c["operator"] == "exists"
                ]
                assert guards, (
                    f"{rule['id']}: '{assertion['operator']}' on '{assertion['field']}' "
                    "passes when the field is absent and needs a prior 'exists' assertion"
                )

    def test_the_two_known_negative_rules_declare_their_guard(self, rules):
        by_id = {r["id"]: r for r in rules}
        for rule_id, field in [("CR-002", "service_account"),
                               ("NET-002", "network.egress_setting")]:
            checks = assertions_for(by_id[rule_id])
            assert [c["operator"] for c in checks] == ["exists", "not_equals"]
            assert {c["field"] for c in checks} == {field}
