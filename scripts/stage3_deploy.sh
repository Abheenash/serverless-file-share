#!/usr/bin/env bash
# Stage 3 — self-destruct: customer-managed KMS + DynamoDB Streams + reaper Lambda + S3 lifecycle backstop.
# Idempotent-ish. Assumes Stage 2 is deployed (table, issue-url role/lambda, API).
#
# Usage: ./scripts/stage3_deploy.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-us-east-1}"
BUCKET="sfs-files-${ACCOUNT_ID}"
TABLE="sfs-metadata"

# 1. Customer-managed KMS key (via alias/sfs-key), scoped key policy.
if ! aws kms describe-key --key-id alias/sfs-key >/dev/null 2>&1; then
  KEY_ID="$(aws kms create-key --description 'sfs — SSE-KMS for serverless-file-share' \
    --policy file://iam/kms-key-policy.json --query 'KeyMetadata.KeyId' --output text)"
  aws kms create-alias --alias-name alias/sfs-key --target-key-id "${KEY_ID}"
else
  KEY_ID="$(aws kms describe-key --key-id alias/sfs-key --query 'KeyMetadata.KeyId' --output text)"
fi

# 2. Let issue-url use the key (via S3 only) and switch the bucket to SSE-KMS.
aws iam put-role-policy --role-name sfs-issue-url-role \
  --policy-name sfs-issue-url-inline --policy-document file://iam/issue-url-policy.json
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"${KEY_ID}\"},\"BucketKeyEnabled\":true}]}"

# 3. Reaper IAM role: stream-read + logs (managed) plus delete-only inline.
if ! aws iam get-role --role-name sfs-reaper-role >/dev/null 2>&1; then
  aws iam create-role --role-name sfs-reaper-role \
    --assume-role-policy-document file://iam/issue-url-trust.json >/dev/null
  aws iam attach-role-policy --role-name sfs-reaper-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole
fi
aws iam put-role-policy --role-name sfs-reaper-role \
  --policy-name sfs-reaper-inline --policy-document file://iam/reaper-policy.json

# 4. Reaper Lambda.
ZIP="$(mktemp -u).zip"; ( cd src/reaper && zip -q -j "${ZIP}" lambda_function.py )
if aws lambda get-function --function-name sfs-reaper >/dev/null 2>&1; then
  aws lambda update-function-code --function-name sfs-reaper --zip-file "fileb://${ZIP}" >/dev/null
else
  for _ in 1 2 3 4 5; do
    aws lambda create-function --function-name sfs-reaper \
      --runtime python3.12 --handler lambda_function.handler \
      --role "arn:aws:iam::${ACCOUNT_ID}:role/sfs-reaper-role" \
      --zip-file "fileb://${ZIP}" --timeout 30 --memory-size 128 \
      --environment "Variables={BUCKET=${BUCKET}}" >/dev/null && break
    sleep 5   # wait out IAM role propagation
  done
fi
rm -f "${ZIP}"

# 5. DynamoDB Streams -> reaper, REMOVE events only.
STREAM_ARN="$(aws dynamodb update-table --table-name "${TABLE}" \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --query 'TableDescription.LatestStreamArn' --output text 2>/dev/null \
  || aws dynamodb describe-table --table-name "${TABLE}" --query 'Table.LatestStreamArn' --output text)"
if [ -z "$(aws lambda list-event-source-mappings --function-name sfs-reaper \
      --query "EventSourceMappings[?EventSourceArn=='${STREAM_ARN}'].UUID" --output text)" ]; then
  aws lambda create-event-source-mapping --function-name sfs-reaper \
    --event-source-arn "${STREAM_ARN}" --starting-position LATEST --batch-size 10 \
    --maximum-retry-attempts 3 \
    --filter-criteria '{"Filters":[{"Pattern":"{\"eventName\":[\"REMOVE\"]}"}]}' >/dev/null
fi

# 6. S3 lifecycle backstop (expire files/ after 8 days, just beyond the 7-day max TTL).
aws s3api put-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --lifecycle-configuration '{"Rules":[{"ID":"reaper-backstop","Filter":{"Prefix":"files/"},"Status":"Enabled","Expiration":{"Days":8}}]}'

echo ">> Stage 3 deployed. Bucket is SSE-KMS; reaper wired to the stream; lifecycle backstop set."
