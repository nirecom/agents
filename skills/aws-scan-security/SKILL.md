---
name: aws-scan-security
description: Evaluate IAM posture, public exposure, and security service status of the current AWS account.
model: opus
effort: high
---

## Procedure

1. Verify prerequisites.
2. IAM posture (pass `--profile $AWS_PROFILE --region $AWS_DEFAULT_REGION`):
   - Root MFA: `aws iam get-account-summary --query 'SummaryMap.AccountMFAEnabled'`
   - Users without MFA: `aws iam list-virtual-mfa-devices --assignment-status Unassigned`
   - Admin policies on users: `aws iam list-attached-user-policies` per user, flag AdministratorAccess
   - Access keys >90 days: `aws iam list-access-keys`, check CreateDate
3. Public exposure:
   - Public S3: `aws s3api get-bucket-acl` + `aws s3api get-bucket-policy-status` per bucket
   - SGs 0.0.0.0/0 on 22/3389/3306/5432: `aws ec2 describe-security-groups --filters Name=ip-permission.cidr,Values=0.0.0.0/0`
   - Public RDS: `aws rds describe-db-instances --query 'DBInstances[?PubliclyAccessible==\`true\`]'`
4. Security services: CloudTrail, GuardDuty, AWS Config, Security Hub (describe/list/get commands)
5. Write raw findings to `$AWS_STATE_DIR/security-<YYYYMMDD>.json` (severity: critical/high/medium/low).
6. Write human-readable summary to `$AWS_STATE_DIR/security-<YYYYMMDD>.md`:
   - Severity table: critical/high/medium/low counts
   - One bullet per finding category (no identifiers)
7. Print: counts by severity only — no identifiers.

## Rules

- Read-only only. Identifiers must NOT appear in conversation.
- Critical findings must be highlighted.
- AccessDeniedException → mark as unknown (not pass).

## Skip Conditions

Skip if `$AWS_STATE_DIR/security-<YYYYMMDD>.json` exists and is less than 4 hours old.
