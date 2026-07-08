#!/usr/bin/env bash
# Stage 2 — end-to-end test: API -> presigned URL -> upload -> verify in S3.

set -euo pipefail

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-us-east-1}"
BUCKET="sfs-files-${ACCOUNT_ID}"
API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='sfs-api'].ApiId" --output text)"
ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/files"

echo ">> POST ${ENDPOINT}"
RESP="$(curl -s -X POST "${ENDPOINT}" -H 'Content-Type: application/json' \
  -d '{"filename":"invoice.txt","expiresInSeconds":3600}')"
UPLOAD_URL="$(echo "${RESP}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["uploadUrl"])')"
OBJECT_KEY="$(echo "${RESP}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["objectKey"])')"

TMP="$(mktemp)"; echo "Invoice #42 — paid in full." > "${TMP}"
echo -n ">> upload via presigned PUT -> HTTP "
curl -s -o /dev/null -w "%{http_code}\n" -X PUT --upload-file "${TMP}" "${UPLOAD_URL}"
rm -f "${TMP}"

echo ">> object in S3:"
aws s3api head-object --bucket "${BUCKET}" --key "${OBJECT_KEY}" \
  --query '{Encryption:ServerSideEncryption,Size:ContentLength}' --output table
