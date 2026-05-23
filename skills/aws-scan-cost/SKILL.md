---
name: aws-scan-cost
description: Query current AWS billing data and identify top cost drivers using Cost Explorer.
model: sonnet
effort: medium
context: fork
---

## Procedure

1. Verify prerequisites. Requires ce:GetCostAndUsage.
2. Query (pass `--profile $AWS_PROFILE`; Cost Explorer ignores region):
   - Current month: `aws ce get-cost-and-usage --time-period Start=<YYYY-MM-01>,End=<today> --granularity MONTHLY --metrics BlendedCost --group-by Type=DIMENSION,Key=SERVICE`
   - Previous month: same with prior month range
3. Identify top 5 cost drivers; calculate MoM delta.
4. Write raw data to `$AWS_STATE_DIR/cost-<YYYYMMDD>.json`.
5. Write human-readable summary to `$AWS_STATE_DIR/cost-<YYYYMMDD>.md`:
   - Top 5 services ranked by cost (no dollar amounts — relative % or rank only)
   - MoM trend per service (up/down/flat)
6. Print: rank 1–5 only (no dollar amounts in conversation).

## Rules

- Read-only. Dollar amounts must NOT appear in conversation.
- Skip gracefully if Cost Explorer disabled or access denied.
- Time ranges in UTC YYYY-MM-DD.

## Skip Conditions

Skip if `$AWS_STATE_DIR/cost-<YYYYMMDD>.json` exists and is less than 4 hours old.
