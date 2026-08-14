# Gate Definitions (v0.2.1-alpha)

## Artifact validation chain

Every artifact consumed by the orchestrator passes, in order:

```
FILE EXISTS → PARSE → SCHEMA → SEMANTIC → ACCEPT
```

Failure statuses: `FILE_MISSING`, `PARSE_FAIL`, `SCHEMA_FAIL`,
`SEMANTIC_FAIL` (and `CONTRACT_MISMATCH` for legacy audit JSON,
`AUDIT_STALE` for a stale freshness binding). None of these is ever
treated as PASS.

## Per-stage gates

| Stage | PASS requires |
|---|---|
| PAPER_SPINE_LITE | figure_mission.yaml ACCEPT (required fields incl. `status` ∈ DRAFT\|LOCKED\|CHANGED; status = LOCKED for the final gate; non-empty central_claim, non-pseudo statistical_unit) |
| STATISTICS | statistics_contract.yaml ACCEPT (required fields incl. `status` ∈ PASS\|FAIL\|REVIEW_REQUIRED\|UNAVAILABLE and status = PASS; paired true/false; descriptive\|inferential; n_by_group ≥ 1 if inferential; no pseudoreplication unit) |
| FIGURE_GENERATION | figure/ with figure_manifest.tsv + figure.(png\|pdf\|svg\|tiff); STATISTICS = PASS |
| FIGURE_AUDIT | figure_audit.json ACCEPT under the R6.1 tiered contract AND publication_ready = true AND freshness binding VERIFIED |
| FIGURE_REVISION | NOT_REQUIRED when FIGURE_AUDIT = PASS; else REQUIRED with NEXT_ACTION routing advice |
| PAPER_SPINE_FINAL | FIGURE_AUDIT = PASS AND paper_spine_final.md ACCEPT (frontmatter figure_id/central_claim/alignment; alignment = CONFIRMED; non-empty body; figure_id matches mission) |
| FINAL_GATE | all five readiness conditions PASS |

## R6.1 audit contract consumption

`figure_audit.json` is accepted only if:

- `contract_version` equals exactly `R6.1` (v0.2.1-alpha: prefix matches such as `R6*` are rejected);
- `figure_integrity.status` present and ∈ { PASS, PASS_WITH_WARNINGS,
  PASS_WITH_LIMITED_EVIDENCE, REVISE, FAIL, NOT_EVALUABLE };
- `publication_package.status` present and ∈ { PASS, INCOMPLETE, FAIL,
  NOT_EVALUABLE } (v0.2.1-alpha: `REVISE` removed — producer never emits it);
- `publication_ready` boolean present;
- `repair_routes.NEXT_ACTION` ∈ { COMPLETE_DELIVERY, REVISE_FIGURE,
  RETURN_TO_STATISTICS, RETURN_TO_CLAIM_EVIDENCE, FIX_DELIVERY,
  HUMAN_REVIEW_REQUIRED, NONE };
- `audited_artifacts` non-empty, each entry carrying `sha256`; the
  orchestrator recomputes every hash — any mismatch or missing file →
  `AUDIT_STALE` (blocking; recover with `--invoke-audit`);
- internal consistency: `publication_ready=true` requires
  figure_integrity ∈ {PASS, PASS_WITH_WARNINGS,
  PASS_WITH_LIMITED_EVIDENCE}, publication_package = PASS and
  NEXT_ACTION = NONE.

Legacy flat-`verdict` JSON → `CONTRACT_MISMATCH` → FINAL_FIGURE_READY
cannot be TRUE until the figure is re-audited with potato-figure-audit ≥
0.4.2-alpha.

## Final gate (fail-closed)

```
FINAL_FIGURE_READY = TRUE
  only if:
    PAPER_SPINE_LITE  = PASS
    STATISTICS        = PASS
    FIGURE_GENERATION = GENERATED
    FIGURE_AUDIT      = PASS
    PAPER_SPINE_FINAL = PASS
```

Any of FAIL, BLOCKED, UNAVAILABLE, NOT_EVALUABLE, PARSE_FAIL,
SCHEMA_FAIL, SEMANTIC_FAIL, CONTRACT_MISMATCH, AUDIT_STALE, open
REQUIRED revision → `FINAL_FIGURE_READY != TRUE`. Warning-only audit
outcomes are ready only because the auditor itself sets
`publication_ready=true`; the workflow never upgrades readiness on its
own.

## Exit-code contract

| exit | meaning |
|---|---|
| 0 | FINAL_FIGURE_READY = TRUE |
| 2 | workflow ran to completion; readiness not satisfied |
| 3 | invalid input (e.g. project directory does not exist) |
| 4 | internal error |

## Repair loop cap

`MAX_AUTOMATIC_REPAIR_ROUNDS = 3` (operational guideline); beyond →
`HUMAN_REVIEW_REQUIRED`. Never silently drop a FAIL to reach readiness.
