---
name: potato-publication-figure-workflow
description: >
  Orchestrates biomedical publication-figure workflows across manuscript
  claim definition, statistical review, figure generation, independent
  figure audit, revision routing, and final manuscript-level evidence
  alignment. A gated multi-skill orchestrator — not an analytics,
  statistics, figure-generation, or paper-writing skill itself.
  触发：帮我做论文 Figure / 按我的工作流做主图 / 从统计到生图再审图 /
  论文作图全流程 / Figure 3 怎么做 / 投稿主图工作流 / 统计审查后画图 /
  图做完后检查论文逻辑.
license: MIT
---

# Potato Publication Figure Workflow

**One figure. Multiple expert skills. One controlled workflow.**

```
Paper Spine (Lite)          → figure_mission.yaml
        ↓
Statistics                  → statistics_contract.yaml
        ↓
Figure Generation           → figure/ + figure_manifest.tsv
        ↓
Potato Figure Audit         → figure_audit.json (R6.1 tiered contract)
        ↺ revision routing  → repair_routes.NEXT_ACTION
        ↓
Paper Spine (Final)         → paper_spine_final.md
        ↓
FINAL FIGURE GATE           → final_gate_report.md + workflow_state.yaml
```

## Roles

This skill is a **gated multi-skill orchestrator**. It does not:

- perform statistics itself (→ STATISTICS_PROVIDER)
- draw figures itself (→ FIGURE_GENERATOR)
- write the manuscript itself (→ PAPER_SPINE_PROVIDER)
- audit figures itself (→ FIGURE_AUDITOR = potato-figure-audit)

It defines the pipeline, the contracts between stages, the gates, and the
repair routing. Providers are resolved at runtime from installed skills
via **explicit capability contracts** (`provider_contracts.yaml`);
unresolved roles are reported `NOT_AVAILABLE` — never guessed.

## Artifact validation chain (v0.2.1-alpha)

"File exists" is never PASS. Every consumed artifact passes:

```
FILE EXISTS → PARSE → SCHEMA → SEMANTIC → ACCEPT
```

- `figure_mission.yaml`: required fields incl. `status` ∈
  `DRAFT | LOCKED | CHANGED`; non-empty central_claim; statistical_unit
  must not be a pseudoreplication-prone unit
  (cells/rois/fields/views/images/sections). **Only `LOCKED` missions may
  reach the final gate** — DRAFT/CHANGED block the workflow.
- `statistics_contract.yaml`: required fields incl. `status` ∈
  `PASS | FAIL | REVIEW_REQUIRED | UNAVAILABLE`; paired true/false,
  descriptive|inferential; inferential contracts need n_by_group ≥ 1 per
  group; pseudoreplication units rejected. **FAIL / REVIEW_REQUIRED /
  UNAVAILABLE can never become a stage PASS.**
- `paper_spine_final.md`: **machine-readable contract** — YAML frontmatter
  (`figure_id`, `central_claim`, `alignment` ∈ `CONFIRMED | REVISED |
  REJECTED`; optional `date`) delimited by `---`, plus a non-empty body.
  Only `alignment: CONFIRMED` passes; `figure_id` must match the mission.
  A bare prose file without frontmatter is PARSE_FAIL.
- `figure_audit.json`: **R6.1 tiered contract only** —
  `contract_version` must equal exactly `R6.1` (prefix matches such as `R6*` are rejected as CONTRACT_MISMATCH), `figure_integrity.status` ∈
  `PASS | PASS_WITH_WARNINGS | PASS_WITH_LIMITED_EVIDENCE | REVISE | FAIL |
  NOT_EVALUABLE`, `publication_package.status` ∈
  `PASS | INCOMPLETE | FAIL | NOT_EVALUABLE` (no `REVISE`), `publication_ready`,
  `repair_routes.NEXT_ACTION` ∈ vocabulary, and a non-empty
  `audited_artifacts` freshness binding (`{"rel/path": {"sha256","bytes"}}` — both sha256 and numeric bytes are verified).
  Legacy flat-`verdict` JSON is rejected as `CONTRACT_MISMATCH` (re-run
  potato-figure-audit ≥ 0.4.3-alpha).
- **Freshness binding**: before consuming `figure_audit.json` the
  orchestrator recomputes SHA-256 of every `audited_artifacts` entry. Any
  mismatch or missing file blocks Stage 4 as `AUDIT_STALE`. Recovery:
  re-run with `--invoke-audit`, which **forces** a fresh audit.

Any step short of ACCEPT blocks the corresponding stage with an explicit
status: `FILE_MISSING | PARSE_FAIL | SCHEMA_FAIL | SEMANTIC_FAIL |
CONTRACT_MISMATCH | AUDIT_STALE`.

## Stage map

| # | Stage | Provider | Output |
|---|---|---|---|
| 0 | Evidence Intake | orchestrator | evidence inventory |
| 1 | Paper-Spine Lite | PAPER_SPINE_PROVIDER | `figure_mission.yaml` |
| 2 | Statistics | STATISTICS_PROVIDER | `statistics_contract.yaml` |
| 3 | Figure Generation | FIGURE_GENERATOR | `figure/` + `figure_manifest.tsv` |
| 4 | Figure Audit | FIGURE_AUDITOR (potato-figure-audit ≥ 0.4.3-alpha) | `figure_audit.json` (R6.1) |
| 5 | Revision routing | orchestrator | NEXT_ACTION advice |
| 6 | Paper-Spine Final | PAPER_SPINE_PROVIDER | `paper_spine_final.md` |
| 7 | Final Gate | orchestrator | `final_gate_report.md` + `workflow_state.yaml` |

## Gates (fail-closed)

- Mission must be `LOCKED` — DRAFT/CHANGED never reach the final gate.
- Statistics not PASS → no inferential figure generation (`BLOCKED`);
  FAIL/REVIEW_REQUIRED/UNAVAILABLE never become a stage PASS.
- FIGURE_AUDIT consumes only the R6.1 tiered contract:
  `publication_ready=true` → PASS; otherwise REVISE/FAIL/NOT_EVALUABLE by
  `figure_integrity.status`; legacy JSON → CONTRACT_MISMATCH; stale
  binding (sha256 mismatch/missing audited artifact) → AUDIT_STALE.
- Revision routing follows `repair_routes.NEXT_ACTION` — never blindly to
  the figure generator (see `references/routing-rules.md`).
- PAPER_SPINE_FINAL requires frontmatter `alignment: CONFIRMED`, a
  non-empty body, and `figure_id` matching the mission. `alignment:
  CONFIRMED` is an author declaration only — the machine still compares
  `central_claim` between mission and spine (exact normalized match).
- **Cross-artifact consistency (v0.2.1-alpha)**: before FINAL_FIGURE_READY
  the workflow machine-compares `figure_id`, `central_claim`,
  `statistical_unit`, `biological_unit`, `paired_design` (and structured
  `primary_contrast` groups) across figure_mission / statistics_contract /
  paper_spine_final. Any core-field mismatch →
  `CROSS_ARTIFACT_MISMATCH`, ready stays FALSE. Natural-language contrast
  without structured groups is `NOT_MACHINE_CHECKABLE` (never claimed as
  verified).
- FINAL_FIGURE_READY = TRUE only when PAPER_SPINE_LITE=PASS,
  STATISTICS=PASS, FIGURE_GENERATION=GENERATED, FIGURE_AUDIT=PASS,
  PAPER_SPINE_FINAL=PASS **and** cross-artifact consistency = PASS. Any
  FAIL/BLOCKED/UNAVAILABLE/CONTRACT_MISMATCH/AUDIT_STALE/SEMANTIC_FAIL/
  SCHEMA_FAIL/PARSE_FAIL/CROSS_ARTIFACT_MISMATCH → ready stays FALSE.

## NEXT_ACTION vocabulary (shared with potato-figure-audit ≥ 0.4.3-alpha)

`COMPLETE_DELIVERY | REVISE_FIGURE | RETURN_TO_STATISTICS |
RETURN_TO_CLAIM_EVIDENCE | FIX_DELIVERY | HUMAN_REVIEW_REQUIRED | NONE`

## Provider resolution (portable, explicit)

Discovery order: explicit `--skills-root` → `$CODEX_HOME/skills` →
platform defaults (`~/.codex/skills`, `~/.claude/skills`,
`~/.config/opencode/skills`). Matching: preferred-name exact match first,
then capability tokens (all required present, no reject tokens);
suite/kit/bundle/family aggregates are always rejected. A role with no
match is `NOT_AVAILABLE`; the orchestrator degrades honestly
(USER_PROVIDED_* / STATISTICAL_REVIEW_REQUIRED) and never fakes PASS.
`POTATO_SKILLS_NO_FALLBACK=1` restricts discovery to the explicit root
(hermetic runs/tests).

## Exit codes

| mode | exit 0 | exit 2 | exit 3 | exit 4 |
|---|---|---|---|---|
| `run_workflow.R` | FINAL_FIGURE_READY = TRUE | run completed, not ready | invalid input (e.g. missing project dir) | internal error |
| `resolve_dependencies.R` | resolution executed | — | contracts file missing | jsonlite missing for --json |

## Runtime requirements

- Requires R (Rscript + base packages; `jsonlite` for `--json` output).
- Runs on Windows/macOS/Linux; paths with spaces are supported.
- Requires potato-figure-audit ≥ 0.4.3-alpha installed for `--invoke-audit`
  (its R6.1 machine contract is the only accepted audit output).

## Quick start

```bash
# resolve providers (capability contracts; portable discovery)
Rscript scripts/resolve_dependencies.R [skills_root] [--json]

# run the workflow state machine over a project dir
Rscript scripts/run_workflow.R <project_dir>
Rscript scripts/run_workflow.R <project_dir> --json
Rscript scripts/run_workflow.R <project_dir> --invoke-audit \
        --skills-root <dir-containing-potato-figure-audit>
```

## Tests

```bash
Rscript tests/run_orchestrator_tests.R <workflow_root> <potato-figure-audit_root>
```

60 behavioral checks: anti-misrouting (humanizer/suite traps), empty-root
NOT_AVAILABLE, validation-chain unit cases (status enums, spine
frontmatter, audited_artifacts schema), legacy-contract rejection,
adversarial counter-examples (statistics FAIL/REVIEW_REQUIRED, mission
DRAFT, prose-only spine, stale/tampered audit JSON), freshness-binding
E2E (fresh audit exit 0 VERIFIED → tamper → AUDIT_STALE exit 2 →
`--invoke-audit` forced re-audit exit 0), end-to-end real audit
invocation (ready → exit 0; statistical defect → exit 2 with
RETURN_TO_STATISTICS), invalid input → exit 3, CLI contracts.

## License

MIT — orchestrator logic only. See LICENSE. Third-party providers are
never bundled, redistributed, or modified (see DEPENDENCIES.md).
