import hashlib
import hmac
import json
import logging
import os
import sys
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from .engine import load_rules, evaluate_all
from .schemas import CheckRequest, CheckResponse, RulesResponse, HealthResponse

SIGNING_KEY = os.environ.get("AEGIS_SIGNING_KEY")


class JsonFormatter(logging.Formatter):
    """Cloud Logging reads 'severity' and 'message' off JSON written to stdout."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }
        payload.update(getattr(record, "context", {}))
        return json.dumps(payload)


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[_handler], force=True)
log = logging.getLogger("aegis")

app = FastAPI(title="Aegis Compliance Checkpoint", version="1.0.0")

RULES_DIR = Path(__file__).parent / "rules"
rules = load_rules(RULES_DIR)

templates = Jinja2Templates(directory=Path(__file__).parent.parent / "templates")
app.mount("/static", StaticFiles(directory=Path(__file__).parent.parent / "static"), name="static")

log.info("rules loaded", extra={"context": {"rules_loaded": len(rules)}})


@app.get("/", response_class=HTMLResponse)
async def ui(request: Request):
    rules_by_category = {}
    for r in rules:
        cat = r["category"]
        if cat not in rules_by_category:
            rules_by_category[cat] = []
        rules_by_category[cat].append(r)
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "rules_by_category": rules_by_category,
            "total_rules": len(rules),
        },
    )


@app.post("/v1/check")
async def check(req: CheckRequest):
    results = evaluate_all(rules, req.config)
    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = sum(1 for r in results if r["status"] == "FAIL")
    warned = sum(1 for r in results if r["status"] == "WARN")
    total = len(results)
    score = f"{round(passed / total * 100)}%" if total > 0 else "0%"
    log.info("assessment completed", extra={"context": {
        "resource_type": req.resource_type,
        "total": total,
        "pass": passed,
        "fail": failed,
        "score": score,
    }})
    body = {
        "summary": {"total": total, "pass": passed, "fail": failed, "warn": warned, "score": score},
        "results": results,
    }
    content = json.dumps(body, separators=(",", ":"), sort_keys=True)
    headers = {}
    if SIGNING_KEY:
        sig = hmac.new(SIGNING_KEY.encode(), content.encode(), hashlib.sha256).hexdigest()
        headers["X-Aegis-Signature"] = f"sha256={sig}"
    return Response(content=content, media_type="application/json", headers=headers)


@app.get("/v1/rules", response_model=RulesResponse)
async def list_rules():
    categories = sorted(set(r["category"] for r in rules))
    return {
        "total": len(rules),
        "categories": categories,
        "rules": [
            {
                "rule_id": r["id"],
                "category": r["category"],
                "name": r["name"],
                "severity": r["severity"],
                "description": r["description"],
            }
            for r in rules
        ],
    }


@app.get("/health", response_model=HealthResponse)
async def health():
    return {"status": "healthy", "rules_loaded": len(rules)}
