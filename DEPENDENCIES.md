# Dependencies

Third-party skills are **not bundled or redistributed**. Users must install
them independently under their respective licenses.

| dependency | role | preferred_name | min version | license | required/preferred/optional | fallback |
|---|---|---|---|---|---|---|
| potato-figure-audit | FIGURE_AUDITOR | potato-figure-audit | **≥ 0.4.3-alpha (R6.1 contract)** | MIT | preferred/core | manual review; FINAL gate cannot PASS |
| nature-figure | FIGURE_GENERATOR | nature-figure | 2.0.0 | third-party | preferred external | USER_PROVIDED_FIGURE |
| nature-statistics | STATISTICS_PROVIDER | nature-statistics | — | third-party | preferred external | USER_PROVIDED_STATISTICS / STATISTICAL_REVIEW_REQUIRED (never fake PASS) |
| paper-spine | PAPER_SPINE_PROVIDER | paper-spine | — | third-party | preferred external | USER_PROVIDED_MISSION / paper_spine_final.md by user |

## Resolution mechanics (v0.2.1-alpha)

Resolution is explicit and capability-based
(`provider_contracts.yaml` + `scripts/lib/orchestrator_core.R`):

1. preferred-name exact match wins (explicit intent).
2. Otherwise: ALL `required_tokens` must appear in the candidate's
   name+description AND no `reject_token` may appear.
3. Aggregates whose names match suite/kit/bundle/family are always
   rejected.
4. No match → `NOT_AVAILABLE`. The orchestrator never guesses and never
   substitutes a look-alike skill (e.g. a text "humanizer" can never be
   resolved as PAPER_SPINE_PROVIDER).

Discovery order: `--skills-root` > `$CODEX_HOME/skills` >
`~/.codex/skills` > `~/.claude/skills` > `~/.config/opencode/skills`.
`POTATO_SKILLS_NO_FALLBACK=1` restricts discovery to the explicit root.

## Contract requirement

FIGURE_AUDITOR output must be the **R6.1 tiered contract** emitted by
potato-figure-audit ≥ 0.4.3-alpha (`contract_version`,
`figure_integrity.status`, `publication_package.status`,
`publication_ready`, `repair_routes.NEXT_ACTION`, non-empty
`audited_artifacts`). Legacy flat-`verdict` JSON is rejected as
`CONTRACT_MISMATCH`.

The orchestrator re-verifies the **freshness binding** before trusting the
audit: every `audited_artifacts` entry (`{"rel/path": {"sha256","bytes"}}`)
is recomputed against the project directory. Any sha256 mismatch or
missing file → blocking `AUDIT_STALE`; recover with `--invoke-audit`
(forces re-audit).
