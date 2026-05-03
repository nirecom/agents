---
name: aws-scan-apps
description: Map application-layer AWS resources (ECS, Lambda, ALB, API Gateway) and write a topology to AWS_STATE_DIR.
model: sonnet
effort: medium
---

## Procedure

1. Verify prerequisites.
2. Enumerate (pass `--profile $AWS_PROFILE --region $AWS_DEFAULT_REGION`):
   - ECS: list-clusters, list-services, describe-task-definition
   - Lambda: `aws lambda list-functions`
   - ALB/NLB: `aws elbv2 describe-load-balancers`
   - API GW REST: `aws apigateway get-rest-apis`
   - API GW HTTP: `aws apigatewayv2 get-apis`
   - CloudFront: `aws cloudfront list-distributions`
3. Build topology: entry points (ALB/API GW/CloudFront) → compute (ECS/Lambda).
4. Write to `$AWS_STATE_DIR/apps-<YYYYMMDD>.json`.
5. Print: counts by type (no ARNs, domain names, IDs).

## Rules

- Read-only. Domain names, ARNs, IDs must NOT appear in conversation.
- AccessDeniedException → log to state file, continue.
- Include region in each state file entry.

## Skip Conditions

Skip if `$AWS_STATE_DIR/apps-<YYYYMMDD>.json` exists and is less than 4 hours old.
