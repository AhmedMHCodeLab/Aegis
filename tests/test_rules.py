import pytest

from src.engine import evaluate_all

CATEGORY_RULE_IDS = {
    "Cloud Run": ["CR-001", "CR-002", "CR-003", "CR-004"],
    "IAM": ["IAM-001", "IAM-002", "IAM-003"],
    "KMS": ["KMS-001", "KMS-002"],
    "Secret Manager": ["SEC-001", "SEC-002"],
    "Network": ["NET-001", "NET-002"],
}


def status_by_id(rules, config):
    return {r["rule_id"]: r["status"] for r in evaluate_all(rules, config)}


class TestFullConfigs:
    def test_secure_config_passes_all_thirteen(self, rules, config_of):
        statuses = status_by_id(rules, config_of("full_secure.json"))
        assert len(statuses) == 13
        assert all(s == "PASS" for s in statuses.values()), statuses

    def test_insecure_config_fails_all_thirteen(self, rules, config_of):
        statuses = status_by_id(rules, config_of("full_insecure.json"))
        assert len(statuses) == 13
        assert all(s == "FAIL" for s in statuses.values()), statuses

    def test_empty_config_never_raises(self, rules):
        assert len(status_by_id(rules, {})) == 13


@pytest.mark.parametrize("category,secure_fixture", [
    ("Cloud Run", "cloud_run_secure.json"),
    ("IAM", "iam_secure.json"),
    ("KMS", "kms_secure.json"),
    ("Secret Manager", "secrets_secure.json"),
    ("Network", "network_secure.json"),
])
def test_secure_fixture_passes_its_own_category(rules, config_of, category, secure_fixture):
    statuses = status_by_id(rules, config_of(secure_fixture))
    for rule_id in CATEGORY_RULE_IDS[category]:
        assert statuses[rule_id] == "PASS", f"{rule_id} should pass in {secure_fixture}"


@pytest.mark.parametrize("category,failing_fixture", [
    ("Cloud Run", "cloud_run_public.json"),
    ("IAM", "iam_overprivileged.json"),
    ("Secret Manager", "secrets_hardcoded.json"),
    ("Network", "network_no_vpc.json"),
])
def test_failing_fixture_fails_its_own_category(rules, config_of, category, failing_fixture):
    statuses = status_by_id(rules, config_of(failing_fixture))
    for rule_id in CATEGORY_RULE_IDS[category]:
        assert statuses[rule_id] == "FAIL", f"{rule_id} should fail in {failing_fixture}"


class TestTargetedFailures:
    def test_kms_no_rotation_isolates_the_rotation_rule(self, rules, config_of):
        statuses = status_by_id(rules, config_of("kms_no_rotation.json"))
        assert statuses["KMS-001"] == "PASS"
        assert statuses["KMS-002"] == "FAIL"

    def test_public_ingress_is_reported_with_evidence(self, rules, config_of):
        results = {r["rule_id"]: r for r in evaluate_all(rules, config_of("cloud_run_public.json"))}
        cr001 = results["CR-001"]
        assert cr001["status"] == "FAIL"
        assert cr001["evidence"]["field"] == "ingress"
        assert cr001["evidence"]["actual"] == "all"
        assert cr001["evidence"]["expected"] == "internal-and-cloud-load-balancing"
        assert cr001["remediation"]

    def test_public_iam_binding_is_critical(self, rules, config_of):
        results = {r["rule_id"]: r for r in evaluate_all(rules, config_of("iam_overprivileged.json"))}
        iam002 = results["IAM-002"]
        assert iam002["status"] == "FAIL"
        assert iam002["severity"] == "CRITICAL"
        assert iam002["evidence"]["actual"] == [
            {"role": "roles/run.invoker", "public_members": ["allUsers"]}
        ]

    def test_overprivileged_role_is_named_in_evidence(self, rules, config_of):
        results = {r["rule_id"]: r for r in evaluate_all(rules, config_of("iam_overprivileged.json"))}
        assert results["IAM-001"]["evidence"]["actual"] == ["roles/owner"]

    def test_wif_evidence_distinguishes_provider_from_keys(self, rules):
        config = {"wif": {"provider": "projects/123/x", "static_keys": ["k1"]}}
        results = {r["rule_id"]: r for r in evaluate_all(rules, config)}
        assert results["IAM-003"]["status"] == "FAIL"
        assert results["IAM-003"]["evidence"]["actual"] == "WIF configured but 1 static key(s) present"


class TestFailClosedHandlers:
    """Undeclared IAM bindings are not the same as a declared empty set."""

    def test_absent_bindings_fail_both_binding_rules(self, rules):
        statuses = status_by_id(rules, {})
        assert statuses["IAM-001"] == "FAIL"
        assert statuses["IAM-002"] == "FAIL"

    def test_absent_bindings_say_so_in_evidence(self, rules):
        results = {r["rule_id"]: r for r in evaluate_all(rules, {})}
        assert results["IAM-001"]["evidence"]["actual"] == "iam_bindings not declared"
        assert results["IAM-002"]["evidence"]["actual"] == "iam_bindings not declared"

    def test_declared_empty_bindings_pass(self, rules):
        statuses = status_by_id(rules, {"iam_bindings": []})
        assert statuses["IAM-001"] == "PASS"
        assert statuses["IAM-002"] == "PASS"

    def test_absent_wif_block_already_failed_closed(self, rules):
        assert status_by_id(rules, {})["IAM-003"] == "FAIL"


@pytest.mark.parametrize("category,secure_fixture", [
    ("Cloud Run", "cloud_run_secure.json"),
    ("IAM", "iam_secure.json"),
    ("KMS", "kms_secure.json"),
    ("Secret Manager", "secrets_secure.json"),
    ("Network", "network_secure.json"),
])
def test_category_fixture_passes_nothing_outside_its_category(rules, config_of, category, secure_fixture):
    # Under fail-closed evaluation a scoped fixture can only satisfy its own controls.
    statuses = status_by_id(rules, config_of(secure_fixture))
    passing = {rid for rid, status in statuses.items() if status == "PASS"}
    assert passing == set(CATEGORY_RULE_IDS[category])


class TestResultContract:
    def test_every_result_has_the_full_contract(self, rules, config_of):
        for result in evaluate_all(rules, config_of("full_insecure.json")):
            assert set(result) == {
                "rule_id", "category", "name", "status", "severity", "evidence", "remediation",
            }
            assert set(result["evidence"]) == {"field", "actual", "expected"}
            assert result["status"] in {"PASS", "FAIL", "WARN"}

    def test_every_declared_category_is_covered(self, rules):
        assert {r["category"] for r in rules} == set(CATEGORY_RULE_IDS)
