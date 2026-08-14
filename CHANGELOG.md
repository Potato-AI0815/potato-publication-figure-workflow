# CHANGELOG

## [0.2.1-alpha W2] - 2026-08-14

### Changed (release hardening: contract tightening)

- **Exact audit contract version match.** `EXPECTED_AUDIT_CONTRACT_VERSION
  <- "R6.1"` (single constant); `grepl("^R6")` prefix matching removed.
  `R6.0 / R6.2 / R6.999 / R6 / R6-foo / R7.0` are all rejected as
  CONTRACT_MISMATCH; `NULL`/empty → legacy/schema failure.
- **Ready invariant aligned with producer.** `PUBLICATION_READY=TRUE`
  requires `FIGURE_INTEGRITY ∈ {PASS, PASS_WITH_WARNINGS}` + package PASS +
  NEXT_ACTION NONE + binding VERIFIED. `PASS_WITH_LIMITED_EVIDENCE +
  ready=true` is now a SEMANTIC_FAIL.
- **CROSS_ARTIFACT_CONSISTENCY_GATE (new).** At the final gate the workflow
  machine-compares `figure_id`, `central_claim` (normalized exact match),
  `statistical_unit`, `biological_unit`, `paired_design`, and structured
  `primary_contrast` across figure_mission / statistics_contract /
  paper_spine_final. Core-field mismatch → `CROSS_ARTIFACT_MISMATCH`,
  FINAL_FIGURE_READY=false, exit 2. `alignment=CONFIRMED` no longer
  substitutes for machine claim comparison.
- **PUBLICATION_PACKAGE vocabulary tightened.** `REVISE` removed from the
  consumer enum; canonical set is `PASS | INCOMPLETE | FAIL |
  NOT_EVALUABLE` (matches producer).
- **audited_artifacts bytes verification.** Every audited artifact must
  carry numeric `bytes` (schema); `verify_audit_binding` now also compares
  actual file size, reporting `byte-size mismatch` as AUDIT_STALE (SHA
  mismatch still reported first when both fail).
- Contract version stays **W2** (no breaking schema change; consumer-only
  tightening).
- New behavioral suite `tests/run_contract_hardening_tests.R` (40 checks:
  contract version matrix, ready invariant, PP vocabulary, bytes binding,
  cross-artifact unit + real E2E C5/C6).

## [0.2.0-alpha R2] - 2026-08-14

### Changed (release-candidate hardening, round 2)

- **Required artifact status enums.** `figure_mission.yaml` now carries
  `status` ∈ `DRAFT | LOCKED | CHANGED`; only `LOCKED` missions may reach
  the final gate. `statistics_contract.yaml` now carries `status` ∈
  `PASS | FAIL | REVIEW_REQUIRED | UNAVAILABLE`; FAIL / REVIEW_REQUIRED /
  UNAVAILABLE can never become a stage PASS (semantic check enforces this).
- **`paper_spine_final.md` is now a machine contract.** YAML frontmatter
  (`figure_id`, `central_claim`, `alignment` ∈ `CONFIRMED | REVISED |
  REJECTED`; optional `date`) plus a non-empty body is required. A bare
  prose file (e.g. a one-line "hello") fails PARSE; only `CONFIRMED`
  passes; `figure_id` is cross-checked against the mission.
- **Stale-audit protection (freshness binding).** Stage 4 consumes
  `figure_audit.json` only after recomputing the SHA-256 of every
  `audited_artifacts` entry (emitted by potato-figure-audit ≥
  0.4.2-alpha). Any mismatch or missing file blocks the stage as
  `AUDIT_STALE` (blocking) with the offending path and recovery advice.
- **`--invoke-audit` now forces re-audit** even when `figure_audit.json`
  already exists — this is the recovery path for `AUDIT_STALE`.
- `figure_audit.json` schema check additionally requires a non-empty
  `audited_artifacts` binding and validates `figure_integrity.status` /
  `publication_package.status` against fixed vocabularies; a ready audit
  whose `NEXT_ACTION != NONE` is rejected as SEMANTIC_FAIL.
- Added `scripts/lib/sha256.R` (pure-R SHA-256 fallback; prefers
  `digest` / `openssl` when available) so binding verification has no
  hard external dependency.
- Behavioral test suite grown 39 → 60 checks, including the six required
  adversarial counter-examples and the full stale→tamper→forced re-audit
  recovery cycle.
- Added `agents/openai.yaml`; `manifest.yaml` now declares the new status
  vocabularies and the freshness-binding contract.
- No change to provider-resolution semantics, NEXT_ACTION vocabulary, or
  exit-code contract (0/2/3/4).

## [0.2.0-alpha] - 2026-08-13

### Changed (release-hardening per independent audit review)

- **Artifact validation chain**: every consumed artifact is validated
  FILE EXISTS → PARSE → SCHEMA → SEMANTIC → ACCEPT. "File exists" no
  longer implies PASS (`scripts/lib/orchestrator_core.R::validate_artifact`).
- **R6.1 tiered audit contract only**: `figure_audit.json` is consumed via
  `contract_version`, `figure_integrity.status`,
  `publication_package.status`, `publication_ready`,
  `repair_routes.NEXT_ACTION`. Legacy flat-`verdict` JSON is rejected as
  `CONTRACT_MISMATCH`; the workflow never reads `$verdict` again.
- **Capability-based provider resolution**: `provider_contracts.yaml`
  (preferred_name exact match → required/reject capability tokens;
  suite/kit/bundle/family always rejected). Unresolved → `NOT_AVAILABLE`,
  never guessed. Fuzzy keyword matching removed (fixes humanizer-style
  misrouting).
- **Portable skills-root discovery**: `--skills-root` > `$CODEX_HOME/skills`
  > `~/.codex/skills`, `~/.claude/skills`, `~/.config/opencode/skills`.
  `POTATO_SKILLS_NO_FALLBACK=1` for hermetic discovery.
- **Exit-code contract**: `run_workflow.R` exit 0 = FINAL_FIGURE_READY,
  2 = ran but not ready, 3 = invalid input, 4 = internal error.
- **Revision routing** now driven by `repair_routes.NEXT_ACTION`
  vocabulary: COMPLETE_DELIVERY | REVISE_FIGURE | RETURN_TO_STATISTICS |
  RETURN_TO_CLAIM_EVIDENCE | FIX_DELIVERY | HUMAN_REVIEW_REQUIRED | NONE.
- `run_workflow.R` rewritten as an execution orchestrator: real audit
  invocation via `--invoke-audit`, per-run `workflow_state.yaml` (flat
  two-level YAML) + `final_gate_report.md`.
- Statistics gate: inferential contracts must declare n_by_group ≥ 1 per
  group; pseudoreplication units (cells/rois/fields/views/images/sections)
  rejected at mission and statistics level.

### Added

- `provider_contracts.yaml` (explicit role contracts).
- `scripts/lib/orchestrator_core.R` (shared contract library).
- `manifest.yaml` (package metadata + test map).
- `tests/run_orchestrator_tests.R` rewritten as 39 behavioral checks with
  real subprocess runs and end-to-end audit invocations.

### Removed

- Hard-coded `~/.config/opencode/skills` discovery path as sole root.
- Description-keyword fuzzy provider matching.
- Static documentation-assertion tests (replaced by behavioral tests).

## [0.1.0-alpha] - 2026-08-10

### Added

- Potato Publication Figure Workflow orchestrator (v0.1.0-alpha)
- Gated multi-skill pipeline: Paper-Spine Lite → Statistics → Figure
  Generation → Potato Figure Audit → revision routing → Paper-Spine Final →
  Final Gate
- Dynamic provider resolution (`scripts/resolve_dependencies.R`)
- Workflow state machine (`scripts/run_workflow.R`) with per-stage status
  and fail-closed final gate
- Graceful degradation: statistics unavailable → UNAVAILABLE (never fake
  PASS); figure generator absent + user figure → generation skipped;
  paper-spine absent → NOT_EVALUABLE
- Contracts: figure_mission.yaml, statistics_contract.yaml,
  workflow_state.yaml, final_gate_report.md

### Boundary

Third-party skills are never bundled or redistributed; users install them
under their own licenses. See DEPENDENCIES.md.
