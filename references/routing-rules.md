# Routing Rules (v0.2.1-alpha)

Revision routing is driven by the audit's machine field
`repair_routes.NEXT_ACTION` (R6.1 contract, potato-figure-audit ≥
0.4.3-alpha). Never dump every problem on the figure generator; never
route statistical defects to rendering.

## NEXT_ACTION → owner

| NEXT_ACTION | route_to | action |
|---|---|---|
| COMPLETE_DELIVERY | FIGURE_GENERATOR / ANALYSIS_OWNER | Figure is sound; complete the publication package (exports, delivery metadata, session info, global state) and re-audit |
| REVISE_FIGURE | FIGURE_GENERATOR | Visual/color/panel work; apply the visual correction brief, re-render, re-audit |
| RETURN_TO_STATISTICS | STATISTICS_PROVIDER (or USER_PROVIDED_STATISTICS review) | Scientific/statistical defect; fix the analysis before any re-render |
| RETURN_TO_CLAIM_EVIDENCE | PAPER_SPINE_PROVIDER | Claim-evidence misalignment; re-align claim/panels, then regenerate |
| FIX_DELIVERY | FIGURE_GENERATOR / ANALYSIS_OWNER | Delivery material declared but wrong (hash/DPI/schema contradiction); fix the declared artifacts, not the figure |
| HUMAN_REVIEW_REQUIRED | human coordinator | Multiple distinct repair targets or not evaluable; stop automation |
| NONE | — | No repair routed |

Unknown NEXT_ACTION values are treated as HUMAN_REVIEW_REQUIRED
(fail-closed).

## Domain → owner (legacy mapping, still valid for human triage)

| issue_domain | route_to |
|---|---|
| STATISTICS / SCIENTIFIC | STATISTICS_PROVIDER |
| FIGURE_VISUAL / COLOR | FIGURE_GENERATOR |
| PANEL_ARCHITECTURE | FIGURE_GENERATOR |
| CLAIM_EVIDENCE | PAPER_SPINE_PROVIDER |
| GLOBAL_COHERENCE | FIGURE_GENERATOR + FIGURE_AUDITOR |
| SOURCE_DATA | ANALYSIS_OWNER |
| DELIVERY | FIGURE_GENERATOR / ANALYSIS_OWNER |

## Repair loop

- Repair rounds are capped (`MAX_AUTOMATIC_REPAIR_ROUNDS = 3` as an
  operational guideline for the calling agent). After the cap →
  HUMAN_REVIEW_REQUIRED.
- Statistical FAIL must NOT be routed to the figure generator.
- Claim/overclaim issues route to PAPER_SPINE_PROVIDER; if the central
  claim changed during figure development → return to Paper-Spine Lite.
- CONTRACT_MISMATCH (legacy audit JSON) is not a figure defect: re-run
  potato-figure-audit ≥ 0.4.3-alpha before any routing.
