---
name: aws-scan-resources
description: Enumerate AWS compute, storage, network, and IAM resources and write a structured inventory to AWS_STATE_DIR.
model: sonnet
effort: medium
---

## Procedure

1. Verify: aws CLI, AWS_PROFILE, AWS_STATE_DIR.
2. Enumerate with read-only CLI (pass `--profile $AWS_PROFILE --region $AWS_DEFAULT_REGION` on every call):
   - EC2: `aws ec2 describe-instances --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,type:InstanceType}'`
   - ECS: `aws ecs list-clusters` + `aws ecs list-services --cluster <name>`
   - Lambda: `aws lambda list-functions --query 'Functions[].{name:FunctionName,runtime:Runtime}'`
   - S3: `aws s3api list-buckets --query 'Buckets[].Name'`
   - EBS: `aws ec2 describe-volumes --query 'Volumes[].{id:VolumeId,size:Size,state:State}'`
   - RDS: `aws rds describe-db-instances --query 'DBInstances[].{id:DBInstanceIdentifier,engine:Engine}'`
   - VPC/SG: `aws ec2 describe-vpcs`, `aws ec2 describe-security-groups`
   - IAM: `aws iam list-users`, `aws iam list-roles`, `aws iam list-policies --scope Local`
3. Write to `$AWS_STATE_DIR/resources-<YYYYMMDD>.json`. Single-region scope.
4. Print to conversation: resource type → count only (no ARNs, IDs, IPs).

## Rules

- Read-only: list-*, describe-*, get-* only.
- Identifiers must NOT appear in conversation.
- Use --no-paginate; fall back to --max-items 1000 where needed.
- Skip on AccessDeniedException — log to state file, continue.

## Skip Conditions

Skip if `$AWS_STATE_DIR/resources-<YYYYMMDD>.json` exists and is less than 4 hours old.
