# ADR: Python evaluation engine over OPA/Rego
At 13 rules with a single author, a dedicated policy engine adds integration complexity (sidecar process or native FFI dependency) without proportional benefit. The evaluation layer is designed to be replaceable: if rule count, authorship, or enforcement points grow, OPA/Rego is the natural migration path. The API contract is engine-agnostic by design.
---
                    Compliance Checkpoint API
                              │
                              ▼
                     Resource validation
                              │
                              ▼
                       Rule selection
                              │
                  ┌───────────┴───────────┐
                  ▼                       ▼
          Declarative evaluator      Custom evaluator
                  │                       │
             YAML rules              Python checks
                  │                       │
                  └───────────┬───────────┘
                              ▼
                       Finding model
                              │
                 ┌────────────┼────────────┐
                 ▼            ▼            ▼
                API           UI          Report