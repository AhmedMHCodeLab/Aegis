import json
from pathlib import Path

import pytest

from src.engine import load_rules

FIXTURES = Path(__file__).parent / "fixtures"
RULES_DIR = Path(__file__).parent.parent / "app" / "src" / "rules"


@pytest.fixture(scope="session")
def rules():
    return load_rules(RULES_DIR)


@pytest.fixture(scope="session")
def client():
    from fastapi.testclient import TestClient
    from src.main import app
    return TestClient(app)


@pytest.fixture
def load_fixture():
    def _load(name: str) -> dict:
        return json.loads((FIXTURES / name).read_text(encoding="utf-8"))
    return _load


@pytest.fixture
def config_of(load_fixture):
    def _config(name: str) -> dict:
        return load_fixture(name)["config"]
    return _config
