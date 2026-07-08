#!/usr/bin/env bash
# Stage 1 — Manual MVP: private encrypted bucket + presigned URL mechanic.
# Idempotent-ish setup for the files bucket. Safe to read top-to-bottom as documentation.
#
# Usage: ./scripts/stage1_setup.sh
# Requires: AWS CLI v2 configured as an admin user (NOT root), with MFA.

set -euo pipefail

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-us-east-1}"
BUCKET="sfs-files-${ACCOUNT_ID}"

echo ">> Account: ${ACCOUNT_ID} | Region: ${REGION} | Bucket: ${BUCKET}"

# 1. Create the bucket (us-east-1 needs no LocationConstraint).
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo ">> Bucket already exists, skipping create."
else
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
fi

# 2. Block ALL public access at the bucket level. The only path to a file is a presigned URL.
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 3. Default encryption at rest. SSE-S3 for now; Stage 3 swaps this for a customer-managed KMS key.
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# 4. Deny any non-HTTPS request. Belt-and-suspenders on top of Block Public Access.
POLICY_FILE="$(mktemp)"
cat > "${POLICY_FILE}" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
POLICY
aws s3api put-bucket-policy --bucket "${BUCKET}" --policy "file://${POLICY_FILE}"
rm -f "${POLICY_FILE}"

echo ">> Done. Bucket is private, encrypted, and HTTPS-only."
echo ">> Try the mechanic:  ./scripts/stage1_demo.sh"
