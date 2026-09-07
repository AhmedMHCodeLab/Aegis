# Implementation deviations from the application specification

Every place `app/` departs from `aegis-app-specification.md`, and why. The
specification remains the contract; this is the errata against it.

Each item is one of:

- **Defect** — the specification's code could not work as written
- **Gap** — the specification requires something it does not supply
- **Judgement** — the specification is silent and a call had to be made

---

## 1. Dockerfile: the container could not start (Defect ×4)

Specification §10. Four independent faults, all verified against the real image
rather than inferred.

### 1.1 Interpreter version mismatch

The builder stage was `python:3.12-slim`; the runtime is
`gcr.io/distroless/python3-debian12`, which ships Debian bookworm's Python:

```
$ docker run --rm gcr.io/distroless/python3-debian12 -c "import sys; print(sys.version)"
3.11.2
```

`pip install --prefix=/install` under 3.12 writes to
`/install/lib/python3.12/site-packages`. A 3.11 interpreter never reads that path.

**Fix:** builder pinned to `python:3.11-slim` to match the runtime.

### 1.2 Dependencies invisible even at matching versions

The deeper fault. Distroless publishes a minimal `sys.path`:

```
/usr/lib/python311.zip
/usr/lib/python3.11
/usr/lib/python3.11/lib-dynload
```

There is no `site-packages` and no Debian `dist-packages` entry. So
`COPY --from=builder /install /usr/local` places FastAPI, uvicorn and PyYAML at
`/usr/local/lib/python3.11/site-packages`, a directory the interpreter has no reason
to consult. Fixing the version alone still yields `ModuleNotFoundError: uvicorn`.

**Fix:** `ENV PYTHONPATH=/usr/local/lib/python3.11/site-packages`. The application
package itself needs no entry: `python -m uvicorn` runs with `WORKDIR /app`, and
`-m` puts the working directory on `sys.path`, which is how `src.main:app` resolves.

### 1.3 Build context mismatch

`COPY requirements.txt .` cannot resolve: the file is at `app/requirements.txt` and
the build context is the repository root.

**Fix:** `COPY app/requirements.txt .`

### 1.4 Container ran as root

The locked decisions require a non-root container. §10's Dockerfile carries no
`USER`, and the default distroless tag runs as uid 0:

```
$ docker run --rm gcr.io/distroless/python3-debian12 -c "import os; print(os.getuid())"
0
$ docker run --rm gcr.io/distroless/python3-debian12:nonroot -c "import os; print(os.getuid())"
65532
```

**Fix:** base image pinned to `:nonroot`. Confirmed at runtime as uid 65532. The
upstream README lists `nonroot` as an available tag but does not publish the UID, so
this was established by running the image rather than from documentation.

### 1.5 Resulting build command

The Dockerfile lives at `app/Dockerfile` per the §2 structure, but needs the
repository root as context. §12's `docker build -t aegis .` finds no Dockerfile.

```bash
docker build -t aegis -f app/Dockerfile .
docker run -p 8080:8080 aegis
```

### 1.6 Note: the same trap exists on debian13

`gcr.io/distroless/python3-debian13:nonroot` ships Python **3.13.5**, uid 65532, and
the same three-entry `sys.path` with no `site-packages`. So the version-matching and
`PYTHONPATH` requirements are properties of distroless Python generally, not of
debian12. The base image is left as the specification pins it; the longer support
runway of 3.13 is noted as an input to a future base-image decision, not taken here.

---

## 2. Engine: fail-closed on undeclared fields (Defect)

Specification §5.1 and §7. `not_equals` and `not_in` return `True` for an absent
field, so a configuration that declared nothing about a control passed it. Recorded
in full, with alternatives and trade-offs, in
[Fail-Closed-Evaluation.md](./Fail-Closed-Evaluation.md).

Summary of the change:

- A rule may declare an ordered `assertions` list; all must hold for the control to
  pass, and the first unmet assertion becomes the evidence. `assertions_for()`
  normalises the inline single-assertion form, so the engine keeps one evaluation
  path and eight of the ten declarative rules are untouched.
- CR-002 and NET-002 assert `exists` before `not_equals` on the same field. These are
  the only two rules whose operator can pass on an absent field.
- `iam_001.py`, `iam_002.py` distinguish an absent `iam_bindings` key (FAIL,
  `iam_bindings not declared`) from a declared empty list (PASS).
- `iam_003.py` unchanged: already failed closed.

**§6 rule shape.** The specification gives every rule a single
`field`/`operator`/`expected` triple. Two rules now use the `assertions` list instead.
This changes rule *authoring*, not the API: `/v1/rules` and `/v1/check` still return
13 controls with unique IDs, and `summary.total` is still 13. The count of 13 is a
baseline and contract commitment; the number of YAML assertions expressing a control
is not part of it.

**Verified behaviour-preserving.** Results for all 12 fixtures plus three synthetic
configs were captured before the refactor and compared after: 195 results, **zero
verdict changes**, 22 evidence objects improved. An undeclared `service_account`
previously reported `expected: "default"`, citing a comparison that never ran; it now
reports the presence assertion it actually failed.

---

## 3. `main.py`: Starlette template signature (Defect, minor)

§8 calls `templates.TemplateResponse("index.html", {"request": request, ...})`, which
emits a `DeprecationWarning` on the pinned Starlette. Updated to the form the FastAPI
documentation gives for 0.108.0+, which passes all three as keyword arguments and
keeps `request` out of the context dict:

```python
templates.TemplateResponse(request=request, name="index.html", context={...})
```

Behaviour is identical; the warning is gone from the test run.

---

## 4. UI: ARIA tabs pattern (Defect ×2)

Both found by driving the rendered page, not by reading the code.

**Focus ring around the entire results panel.** The panels carried `tabindex="0"`.
The W3C ARIA Authoring Practices tabs pattern states a tabpanel takes `tabindex="0"`
only "when the tabpanel does not contain any focusable elements or the first element
with content is not focusable". All three panels are full of buttons. Removed.

**Masthead scrolled out of view on validate.** Focus was moved to the panel, which
scrolled it into view and pushed the tab bar off screen. Focus now moves to the
Results tab, which is the correct target once the panel has focusable children, and
the window returns to the top so the score leads the view.

---

## 5. `example_config` template variable (Gap)

§13 writes `{{ example_config | tojson(indent=2) }}`, but §8's route passes only
`rules_by_category` and `total_rules`. The route is left exactly as specified and the
example config is embedded as a JavaScript constant in the template. It drives a
button in the browser and is never read by the backend, so it is UI state, not
template context.

---

## 6. `pytest.ini` (Gap)

Rule handlers resolve as `src.rules.custom.iam_001`, so `src` must be importable as a
top-level package. `app/` is not on `sys.path` when pytest runs from the repository
root, so §12's own `pytest tests/ -v` could not import the application.

```ini
[pytest]
pythonpath = app
testpaths = tests
```

`app/src/__init__.py` and `app/src/rules/__init__.py` are added for the same reason:
explicit packages rather than relying on namespace-package resolution.

---

## 7. `app/static/` (Gap)

§8 mounts `StaticFiles(directory=.../static)`, which raises at import time if the
directory does not exist, while §13 requires a single self-contained `index.html`.
Both are satisfied: the mount stays as specified, `app/static/.gitkeep` keeps the
directory present, and all CSS remains inline in the template. §2 lists `style.css`
as conditional ("if separated from the template"); it is not separated.

---

## 8. Structured JSON logging (Gap)

The build plan's Day 1 requirements list "Structured JSON logging to stdout"; the
application specification never mentions it. Implemented as a ~12-line
`logging.Formatter` in `main.py` emitting one JSON object per line:

```json
{"severity": "INFO", "message": "assessment completed", "logger": "aegis",
 "resource_type": "cloud_run_service", "total": 13, "pass": 0, "fail": 13, "score": "0%"}
```

The `severity` key is what Cloud Logging reads to assign a log level to a Cloud Run
container's stdout, rather than filing every line as INFO text.

---

## 9. Evidence presentation (Judgement ×2)

**`expected: null` renders as "must be present".** KMS-001 and KMS-002 use
`operator: exists` with `expected: null`, so the API returns `"expected": null`
verbatim. NET-001 did too until §12 moved it to a handler that supplies its own
evidence text. The API contract is unchanged; the UI substitutes readable text, since
"Expected: null" means nothing to a client. Unambiguous here because no rule in the
baseline uses `not_exists`, so a null `expected` can only mean presence is required.
A null `actual` renders as "not set" for the same reason.

**The WARN pill is hidden at zero.** No rule or handler can emit WARN: the generic
engine returns PASS/FAIL and all three custom handlers do the same. §3.1's example
response showing `"warn": 1` is therefore not reachable. The field is still counted
and returned as `0`; the UI omits the pill rather than displaying a dead statistic.

---

## 10. Repository hygiene (Judgement)

`.gitignore` (`.venv/`, `__pycache__/`, `.pytest_cache/`) and `.dockerignore`
(the same plus `.git/`, `tests/`, `Docs/`, `*.md`). The `.dockerignore` matters
functionally: without it the whole virtualenv is uploaded as build context on every
`docker build`.

Both grew once infrastructure landed. `.gitignore` excludes Terraform state, the
provider cache and environment tfvars; `.dockerignore` excludes `terraform/` and
`.github/` so infrastructure changes do not invalidate the Docker build cache or
enter the image.

---

## 11. `gte` raised on values that were not numbers (Defect)

Specification §5.1. The operator called `float()` on submitted config:

```python
"gte": lambda actual, expected: float(actual) >= float(expected) if actual is not None else False
```

The `None` guard covers an absent field, but not a present one that is not numeric.
`{"tls_min_version": "TLSv1.2"}` is a plausible submission and raised `ValueError`,
which surfaced as HTTP 500. A malformed request became a server error rather than a
failed control, which is both a defect and free error-rate noise.

**Fix:** the operator is a named function that returns `False` on `TypeError` or
`ValueError`. A value that cannot be read as a number is not evidence of compliance,
so it fails the control and the assessment still returns 200.

---

## 12. NET-001 named a mechanism, not an outcome (Defect)

Specification §6. The rule asserted `network.vpc_connector` exists. A Cloud Run
service using **direct VPC egress** has no connector: it places a network interface
on the subnet instead. Egress traverses the same customer-controlled VPC, with the
same firewall rules and the same Private Google Access, and the rule failed it.

Aegis's own infrastructure uses direct VPC egress, so the baseline would have failed
the service it ships on. The control's intent is that egress is subject to VPC
controls, not that one product is present.

The engine has no disjunction operator and adding one to express a two-way choice was
disproportionate, so the rule became a custom handler that accepts either mechanism,
reports which was found as evidence, and fails closed when the `network` block is
absent entirely. Reasoning in [Direct-VPC-Egress.md](./Direct-VPC-Egress.md).

---

## 13. Evidence values were interpolated into `innerHTML` unescaped (Defect)

Specification §13. `fmt()` returned submitted config verbatim, and both call sites
concatenated the result into `innerHTML`. Evidence is attacker-controlled by
definition: it is the config the caller supplied, echoed back. A value carrying
markup executed in the reviewer's browser.

Reflected rather than stored, and the endpoint is behind IAP, so exploitation needs a
crafted request the victim submits themselves. Fixed regardless: `fmt()` now escapes
everything it returns, string or serialised.

---

## 14. Response signing (Gap)

The specification defines no response integrity mechanism. Aegis issues compliance
verdicts, and a verdict that can be altered in transit or fabricated by something
sitting between the service and its caller is not evidence of anything.

`POST /v1/check` returns a canonical body, keys sorted and separators compact, with
an `X-Aegis-Signature` header carrying HMAC-SHA256 over exactly those bytes. The key
is generated by Terraform, stored in a CMEK-encrypted secret and injected by
reference, so it exists in no source file. Absent the key the response is unsigned
rather than failing, which keeps local development and the test suite unchanged.

This is integrity and origin authentication between the service and its caller, not
non-repudiation: the caller can verify the response, and could also produce it,
because HMAC is symmetric.

---

## Verification

All deviations verified against the running container, not against the source.

| Check | Result |
|---|---|
| `pytest` | 92 passed |
| `curl /health` | `{"status":"healthy","rules_loaded":13}`, HTTP 200 |
| `curl /v1/rules` | 13 rules with full metadata |
| `POST /v1/check`, `full_secure.json` | 13 pass, 0 fail, `100%` |
| `POST /v1/check`, `full_insecure.json` | 0 pass, 13 fail, `0%` |
| `POST /v1/check`, `{"ingress": ...}` only | 1 pass, 12 fail, `8%` (fail-closed) |
| Container uid | 65532 |
| `GET /` | HTTP 200, renders the catalogue |
| Refactor vs. pre-change baseline | 0 verdict changes across 195 results |

## Sources consulted

- W3C ARIA Authoring Practices, Tabs pattern — tabpanel `tabindex`, arrow-key
  behaviour, required roles and attributes
- FastAPI documentation, Advanced / Templates — current `TemplateResponse` signature
- GoogleContainerTools/distroless README and `examples/python3/Dockerfile` — tag list
  and nonroot variants; the example covers no dependency installation, so the
  multi-stage `PYTHONPATH` finding is empirical, from running the images
