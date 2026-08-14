# Artifact Contracts

Standard hand-off files between workflow stages. The orchestrator consumes
contracts only — never provider-internal implementation.

## figure_mission.yaml (Stage 1 → 2)

```yaml
project_id: string
figure_id: string
manuscript_section: string
central_claim: string          # single figure-level claim
evidence_role: enum            # primary | supporting | context | inference
primary_question: string
primary_contrast: string
biological_unit: string
statistical_unit: string
paired_design: bool
must_show: string
must_not_claim: string
upstream_figure: string|null
downstream_figure: string|null
target_journal: string|null
visual_profile: string
status: enum                   # DRAFT|LOCKED|CHANGED
```

The central claim is the task anchor: all stages read it, no stage may
silently change it; changes route back to PAPER_SPINE.

## statistics_contract.yaml (Stage 2 → 3)

```yaml
biological_unit: string
statistical_unit: string
group_definition: string
paired: bool
n_by_group: map
test: string
effect_measure: string
CI: string
multiplicity: string
descriptive_vs_inferential: enum
limitations: string
status: enum                  # PASS|FAIL|REVIEW_REQUIRED|UNAVAILABLE
```

Statistics FAIL blocks inferential figure generation.

## figure_manifest.tsv (Stage 3 → 4)

Potato Figure Audit schema (12 columns). See Potato_Figure_Audit
`manifest_schema.md`.

## figure_audit.json (Stage 4 → 5)

Potato Figure Audit ≥ 0.4.3-alpha machine output — **R6.1 tiered
contract only**:

```json
{
  "contract_version": "R6.1",
  "version": "0.4.3-alpha",
  "figure_integrity": { "status": "PASS|PASS_WITH_WARNINGS|PASS_WITH_LIMITED_EVIDENCE|REVISE|FAIL|NOT_EVALUABLE" },
  "publication_package": { "status": "PASS|INCOMPLETE|REVISE|FAIL|NOT_EVALUABLE" },
  "publication_ready": true,
  "audited_artifacts": { "figure/figure.png": { "sha256": "<hex>", "bytes": 12345 } },
  "repair_routes": { "NEXT_ACTION": "COMPLETE_DELIVERY|REVISE_FIGURE|RETURN_TO_STATISTICS|RETURN_TO_CLAIM_EVIDENCE|FIX_DELIVERY|HUMAN_REVIEW_REQUIRED|NONE" }
}
```

`audited_artifacts` is the freshness binding: sha256 + byte size of every
audited input file (audit outputs excluded). The orchestrator recomputes
these hashes before trusting the audit; mismatch/missing → `AUDIT_STALE`.

Legacy flat-`verdict` JSON is rejected as CONTRACT_MISMATCH (re-run the
auditor; never hand-edited into compliance).

## paper_spine_final.md (Stage 6 → 7)

Machine-readable claim-alignment contract — YAML frontmatter + body:

```
---
figure_id: string            # must match figure_mission.yaml
central_claim: string        # the claim this figure supports
alignment: enum              # CONFIRMED|REVISED|REJECTED
date: string                 # optional
---

<non-empty body: how the figure supports the central claim>
```

Only `alignment: CONFIRMED` with a non-empty body and matching `figure_id`
passes the final gate. A bare prose file without frontmatter fails PARSE.

## visual_correction_brief.yaml (Stage 4/5)

Potato Figure Audit v0.4 schema (issue_id, severity, diagnosis,
recommended_action, preserve_constraints, global_recheck, upstream_owner,
confidence, evaluation_source).

## workflow_state.yaml

v0.2.1-alpha flat two-level machine state, rewritten on every run:

```yaml
workflow_version: 0.2.1-alpha
workflow_contract: W2
generated_at: "..."
project_dir: ...
audit_dir: ...
discovery_roots: "root1;root2"
providers.<ROLE>: <name@version | NOT_AVAILABLE>
validation.figure_mission: ACCEPT|FILE_MISSING|PARSE_FAIL|SCHEMA_FAIL|SEMANTIC_FAIL
validation.statistics_contract: ...
validation.paper_spine_final: ACCEPT|FILE_MISSING|PARSE_FAIL|SCHEMA_FAIL|SEMANTIC_FAIL
stages.<STAGE>: PASS|FAIL|BLOCKED|UNAVAILABLE|NOT_EVALUABLE|INVOCATION_REQUIRED|AUDIT_STALE|...
audit.contract_version: R6.1
audit.figure_integrity: ...
audit.publication_package: ...
audit.publication_ready: true|false
audit.NEXT_ACTION: ...
audit.binding: NOT_APPLICABLE|VERIFIED|STALE: <reason>
final.FINAL_FIGURE_READY: true|false
```

## final_gate_report.md (Stage 7)

Per-stage status table + FINAL_FIGURE_READY verdict + freshness-binding
line (`audited_artifacts` sha256 verification result) + routing advice.
