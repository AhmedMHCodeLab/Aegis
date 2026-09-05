from pydantic import BaseModel, Field
from enum import Enum


class Severity(str, Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"


class Status(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    WARN = "WARN"


class CheckRequest(BaseModel):
    resource_type: str = Field(
        ...,
        description="Type of resource being validated",
        examples=["cloud_run_service"],
    )
    config: dict = Field(
        ...,
        description="Resource configuration to validate",
    )


class Evidence(BaseModel):
    field: str
    actual: object
    expected: object


class RuleResult(BaseModel):
    rule_id: str
    category: str
    name: str
    status: Status
    severity: Severity
    evidence: Evidence
    remediation: str


class Summary(BaseModel):
    total: int
    passed: int = Field(alias="pass")
    fail: int
    warn: int
    score: str


class CheckResponse(BaseModel):
    summary: Summary
    results: list[RuleResult]


class RuleInfo(BaseModel):
    rule_id: str
    category: str
    name: str
    severity: Severity
    description: str


class RulesResponse(BaseModel):
    total: int
    categories: list[str]
    rules: list[RuleInfo]


class HealthResponse(BaseModel):
    status: str
    rules_loaded: int
