# Potato Publication Figure Workflow

**One figure. Multiple expert skills. One controlled workflow.**

```
Paper Spine (Lite)
    ↓
Statistics
    ↓
Figure Generation
    ↓
Potato Figure Audit (R6.1 tiered contract)
    ↺ revision routing (repair_routes.NEXT_ACTION)
    ↓
Paper Spine Final
    ↓
FINAL FIGURE GATE (fail-closed)
```

A gated multi-skill orchestrator for biomedical manuscript figures
(v0.2.1-alpha, W2 contract). It does not do statistics, draw figures,
audit figures, or write papers itself — it orchestrates providers
(resolved at runtime via explicit capability contracts) through a
controlled pipeline with validation chains, gates, and repair routing.

Key guarantees:

- "File exists" is never PASS: every artifact passes
  FILE EXISTS → PARSE → SCHEMA → SEMANTIC → ACCEPT.
- `figure_mission.yaml` carries a status state machine
  (`DRAFT | LOCKED | CHANGED`) — only `LOCKED` reaches the final gate.
- `statistics_contract.yaml` carries a required status
  (`PASS | FAIL | REVIEW_REQUIRED | UNAVAILABLE`) — anything but `PASS`
  blocks inferential generation; it can never become a stage PASS.
- `paper_spine_final.md` is a machine contract (YAML frontmatter with
  `figure_id` / `central_claim` / `alignment`, non-empty body); a bare
  prose file fails PARSE, `alignment` must be `CONFIRMED`, and
  `figure_id` must match the mission.
- `figure_audit.json` is consumed only via the R6.1 tiered contract
  (`figure_integrity.status`, `publication_package.status`,
  `publication_ready`, `repair_routes.NEXT_ACTION`, non-empty
  `audited_artifacts`); legacy flat-`verdict` JSON → CONTRACT_MISMATCH.
- Freshness binding: the orchestrator recomputes the SHA-256 of every
  `audited_artifacts` entry before trusting the audit; any mismatch or
  missing file → blocking `AUDIT_STALE`. `--invoke-audit` forces a fresh
  audit even if `figure_audit.json` already exists.
- FINAL_FIGURE_READY is fail-closed; exit 0 only when ready.
- Unresolved providers → NOT_AVAILABLE; never guessed (no fuzzy keyword
  matching, no humanizer-style misrouting).

## Quick start

```bash
# resolve installed providers (portable discovery + capability contracts)
Rscript scripts/resolve_dependencies.R [skills_root] [--json]

# run workflow state machine over a project dir
Rscript scripts/run_workflow.R <project_dir>
Rscript scripts/run_workflow.R <project_dir> --json

# invoke potato-figure-audit (>= 0.4.3-alpha) during Stage 4 (forces re-audit)
Rscript scripts/run_workflow.R <project_dir> --invoke-audit \
        --skills-root <dir-containing-potato-figure-audit>
```

Exit codes: 0 = FINAL_FIGURE_READY, 2 = ran but not ready,
3 = invalid input, 4 = internal error.

## Project dir contract

```
<project>/
  figure_mission.yaml        # task anchor (user or Paper-Spine Lite)
  statistics_contract.yaml   # statistics design (user or STATISTICS_PROVIDER)
  figure/                    # generated (or user-provided) figure + manifest
  figure/figure_audit.json   # potato-figure-audit R6.1 output
  paper_spine_final.md       # claim-alignment confirmation
  workflow_state.yaml        # machine state (written each run)
  final_gate_report.md       # final verdict (written each run)
```

## Dependency status (validation machine)

| Role | Provider |
|---|---|
| FIGURE_AUDITOR | potato-figure-audit ≥ 0.4.3-alpha (R6.1) |
| FIGURE_GENERATOR | nature-figure v2.0.0 |
| PAPER_SPINE_PROVIDER | paper-spine |
| STATISTICS_PROVIDER | NOT_AVAILABLE → USER_PROVIDED_STATISTICS / STATISTICAL_REVIEW_REQUIRED |

See `DEPENDENCIES.md` for resolution mechanics, license boundaries and
fallbacks.

## Documentation

- `references/architecture.md` — pipeline + contracts
- `references/routing-rules.md` — NEXT_ACTION → owner routing
- `references/gate-definitions.md` — validation chain, R6.1 consumption,
  final gate semantics, exit codes
- `references/artifact-contracts.md` — hand-off file schemas
- `references/failure-recovery.md` — degradation paths
- `provider_contracts.yaml` — explicit role capability contracts

## Tests

```bash
Rscript tests/run_orchestrator_tests.R <workflow_root> <potato-figure-audit_root>
```

60 behavioral checks (anti-misrouting, NOT_AVAILABLE honesty, validation
chain incl. status enums / spine frontmatter / audited_artifacts schema,
legacy-contract rejection, adversarial counter-examples, freshness-binding
stale→forced re-audit recovery cycle, two end-to-end real audit
invocations, exit-code contract).

## License

MIT — orchestrator logic only. Third-party skills are not bundled.
