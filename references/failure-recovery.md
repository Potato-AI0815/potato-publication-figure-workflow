# Failure Recovery

## Unavailable providers

| Failure | Recovery |
|---|---|
| STATISTICS_PROVIDER unavailable | `USER_PROVIDED_STATISTICS` (user supplies statistics_contract.yaml) or `STATISTICAL_REVIEW_REQUIRED`; never fake PASS |
| FIGURE_GENERATOR unavailable | `USER_PROVIDED_FIGURE`; skip Stage 3, still audit |
| FIGURE_AUDITOR unavailable | `USER_PROVIDED_REVIEW` / manual review; FINAL gate not reached |
| PAPER_SPINE unavailable | `USER_PROVIDED_MISSION`; MANUSCRIPT_ALIGNMENT = NOT_EVALUABLE |

## Stage failures

| Stage | On FAIL | On NOT_EVALUABLE |
|---|---|---|
| PAPER_SPINE_LITE | return to Stage 1 (mission must be redefined) | require user mission |
| STATISTICS | block inferential generation; route to statistics owner | require statistics contract |
| FIGURE_GENERATION | route to figure generator owner | require figure |
| FIGURE_AUDIT | route per domain (see routing-rules) | require audit evidence |
| PAPER_SPINE_FINAL | return to Stage 1 if central claim changed | require spine review |

## Repair loop

`MAX_AUTOMATIC_REPAIR_ROUNDS = 3`. After cap → `HUMAN_REVIEW_REQUIRED`.
Never silently drop a FAIL to reach readiness.

## State persistence

Workflow state is written to `workflow_state.yaml` after each stage so a
run can resume; failed stages keep their `blocking_issues`.
