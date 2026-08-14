# Architecture

Potato Publication Figure Workflow is a **gated multi-skill orchestrator**
for biomedical manuscript figures. It is modality-agnostic: single-cell,
bulk omics, clinical, survival, IHC, WB, and imaging figures all flow
through the same pipeline. It is not itself an analytics, statistics,
figure-generation, or paper-writing skill.

## Pipeline

```
Stage 0  Evidence Intake         (orchestrator)
Stage 1  Paper-Spine Lite        (PAPER_SPINE_PROVIDER)
Stage 2  Statistics              (STATISTICS_PROVIDER)
Stage 3  Figure Generation       (FIGURE_GENERATOR)
Stage 4  Figure Audit            (FIGURE_AUDITOR = Potato Figure Audit ≥ 0.4.3-alpha)
Stage 5  Revision routing        (orchestrator; NEXT_ACTION)
Stage 6  Paper-Spine Final       (PAPER_SPINE_PROVIDER)
Stage 7  Final Gate              (orchestrator)
```

## Contracts between stages

The orchestrator consumes **contracts only**:

- `figure_mission.yaml` — task anchor + status state machine (Stage 1)
- `statistics_contract.yaml` — statistical design + required status (Stage 2)
- `figure_manifest.tsv` — panel provenance (Stage 3)
- `figure_audit.json` — R6.1 tiered audit + audited_artifacts freshness
  binding (Stage 4)
- `visual_correction_brief.yaml` — correction instructions (Stage 4/5)
- `paper_spine_final.md` — machine-readable claim alignment (Stage 6)
- `workflow_state.yaml` — stage state (all)
- `final_gate_report.md` — final verdict (Stage 7)

Providers are resolved at runtime from installed skills via explicit
capability contracts (`provider_contracts.yaml` +
`scripts/resolve_dependencies.R`). Preferred names match first; otherwise
all required capability tokens must be present and no reject token may
appear. Aggregates (suite/kit/bundle/family) are always rejected; an
unresolved role is `NOT_AVAILABLE`, never guessed.

## Provider roles

| Role | Preferred | Fallback |
|---|---|---|
| STATISTICS_PROVIDER | nature-statistics | USER_PROVIDED_STATISTICS / STATISTICAL_REVIEW_REQUIRED |
| FIGURE_GENERATOR | nature-figure | USER_PROVIDED_FIGURE |
| FIGURE_AUDITOR | potato-figure-audit ≥ 0.4.3-alpha (R6.1) | manual review only; FINAL gate cannot PASS |
| PAPER_SPINE_PROVIDER | paper-spine | USER_PROVIDED_MISSION / NOT_EVALUABLE |

## Graceful degradation

- Statistics unavailable → `STATISTICS = UNAVAILABLE`; no inferential final
  readiness; `USER_PROVIDED_STATISTICS` allowed.
- Figure generator unavailable but figure supplied → generation skipped,
  audit still runs.
- Paper-Spine unavailable → `MANUSCRIPT_ALIGNMENT = NOT_EVALUABLE`.
- Never fake a PASS for an unavailable stage.
