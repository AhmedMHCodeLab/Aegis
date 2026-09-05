class TestHealth:
    def test_returns_healthy_with_rule_count(self, client):
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "healthy", "rules_loaded": 13}


class TestListRules:
    def test_returns_all_thirteen_with_metadata(self, client):
        response = client.get("/v1/rules")
        assert response.status_code == 200
        body = response.json()
        assert body["total"] == 13
        assert len(body["rules"]) == 13
        assert body["categories"] == ["Cloud Run", "IAM", "KMS", "Network", "Secret Manager"]

    def test_each_rule_exposes_catalog_fields(self, client):
        for rule in client.get("/v1/rules").json()["rules"]:
            assert set(rule) == {"rule_id", "category", "name", "severity", "description"}


class TestCheck:
    def test_insecure_config_scores_zero(self, client, load_fixture):
        response = client.post("/v1/check", json=load_fixture("full_insecure.json"))
        assert response.status_code == 200
        summary = response.json()["summary"]
        assert summary == {"total": 13, "pass": 0, "fail": 13, "warn": 0, "score": "0%"}

    def test_secure_config_scores_one_hundred(self, client, load_fixture):
        summary = client.post("/v1/check", json=load_fixture("full_secure.json")).json()["summary"]
        assert summary == {"total": 13, "pass": 13, "fail": 0, "warn": 0, "score": "100%"}

    def test_summary_uses_the_pass_alias_not_passed(self, client, load_fixture):
        summary = client.post("/v1/check", json=load_fixture("full_secure.json")).json()["summary"]
        assert "pass" in summary
        assert "passed" not in summary

    def test_partial_config_scores_between(self, client, load_fixture):
        # Only the four Cloud Run fields are declared, so the other nine controls
        # fail closed for want of evidence rather than passing by omission.
        summary = client.post("/v1/check", json=load_fixture("cloud_run_secure.json")).json()["summary"]
        assert summary["pass"] == 4
        assert summary["fail"] == 9
        assert summary["score"] == "31%"

    def test_failure_carries_evidence_and_remediation(self, client, load_fixture):
        results = client.post("/v1/check", json=load_fixture("cloud_run_public.json")).json()["results"]
        cr001 = next(r for r in results if r["rule_id"] == "CR-001")
        assert cr001["status"] == "FAIL"
        assert cr001["evidence"]["actual"] == "all"
        assert "internal-and-cloud-load-balancing" in cr001["remediation"]

    def test_missing_config_is_rejected(self, client):
        assert client.post("/v1/check", json={"resource_type": "cloud_run_service"}).status_code == 422

    def test_missing_resource_type_is_rejected(self, client):
        assert client.post("/v1/check", json={"config": {}}).status_code == 422

    def test_wrong_config_type_is_rejected(self, client):
        body = {"resource_type": "cloud_run_service", "config": "not-a-dict"}
        assert client.post("/v1/check", json=body).status_code == 422

    def test_empty_config_still_evaluates_all_rules(self, client):
        body = {"resource_type": "cloud_run_service", "config": {}}
        response = client.post("/v1/check", json=body)
        assert response.status_code == 200
        assert response.json()["summary"]["total"] == 13


class TestUI:
    def test_serves_html_with_the_rules_catalog(self, client):
        response = client.get("/")
        assert response.status_code == 200
        assert "text/html" in response.headers["content-type"]
        body = response.text
        assert "CR-001" in body
        assert "Secret Manager" in body
