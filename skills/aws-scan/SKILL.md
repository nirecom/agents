---
name: aws-scan
description: Orchestrate a full AWS infrastructure scan across resources, security, cost, and applications.
model: opus
effort: high
context: fork
---

## Procedure

1. Verify: `aws --version`, AWS_PROFILE set, AWS_STATE_DIR set (default ~/.aws-state). Create dir if absent.
2. Invoke /aws-scan-resources
3. Invoke /aws-scan-security
4. Invoke /aws-scan-cost
5. Invoke /aws-scan-apps
6. Write consolidated summary to $AWS_STATE_DIR/scan-<YYYYMMDD>.md

## Rules

- Read-only API calls only. Never mutate resources.
- All output to $AWS_STATE_DIR only. Never write to public repo paths.
- Account IDs, ARNs, IP addresses must NOT appear in conversation.
- AWS_STATE_DIR and AWS_WORK_DIR never hardcoded. Default AWS_STATE_DIR to ~/.aws-state if unset.
- Exit early on QNAP ($OSDIST = "qnap").

## Skip Conditions

Invoke a sub-skill directly when only one phase is needed.
