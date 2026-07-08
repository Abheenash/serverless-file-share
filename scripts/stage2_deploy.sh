#!/usr/bin/env bash
# Stage 2 — API layer: DynamoDB (TTL) + issue-url Lambda + IAM role + HTTP API.
# Idempotent-ish: skips resources that already exist. Reads as documentation.
#
# Usage: ./scripts/stage2_deploy.sh
# Requires: Stage 1 bucket already created (scripts/stage1_setup.sh).

set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-us-east-1}"
BUCKET="sfs-files-${ACCOUNT_ID}"
TABLE="sfs-metadata"
ROLE="sfs-issue-url-role"
FUNC="sfs-issue-url"
API_NAME="sfs-api"

echo ">> Account ${ACCOUNT_ID} | ${REGION} | bucket ${BUCKET}"

# 1. DynamoDB metadata table (on-demand) + TTL on expiresAt.
if ! aws dynamodb describe-table --table-name "${TABLE}" >/dev/null 2>&1; then
  aws dynamodb create-table --table-name "${TABLE}" \
    --attribute-definitions AttributeName=fileId,AttributeType=S \
    --key-schema AttributeName=fileId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "${TABLE}"
fi
aws dynamodb update-time-to-live --table-name "${TABLE}" \
  --time-to-live-specification "Enabled=true,AttributeName=expiresAt" >/dev/null || true

# 2. IAM execution role — least privilege: s3:PutObject on files/* + dynamodb:PutItem.
if ! aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${ROLE}" \
    --assume-role-policy-document file://iam/issue-url-trust.json >/dev/null
  aws iam attach-role-policy --role-name "${ROLE}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi
aws iam put-role-policy --role-name "${ROLE}" \
  --policy-name sfs-issue-url-inline \
  --policy-document file://iam/issue-url-policy.json
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}"

# 3. Lambda — package src/issue_url and create or update.
ZIP="$(mktemp -u).zip"
( cd src/issue_url && zip -q -j "${ZIP}" lambda_function.py )
if aws lambda get-function --function-name "${FUNC}" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "${FUNC}" --zip-file "fileb://${ZIP}" >/dev/null
else
  aws lambda create-function --function-name "${FUNC}" \
    --runtime python3.12 --handler lambda_function.handler \
    --role "${ROLE_ARN}" --zip-file "fileb://${ZIP}" \
    --timeout 10 --memory-size 128 \
    --environment "Variables={BUCKET=${BUCKET},TABLE=${TABLE}}" >/dev/null
fi
rm -f "${ZIP}"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC}"

# 4. HTTP API: POST /files -> Lambda, $default stage auto-deploy, throttled.
API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiId" --output text)"
if [ -z "${API_ID}" ]; then
  API_ID="$(aws apigatewayv2 create-api --name "${API_NAME}" --protocol-type HTTP --query ApiId --output text)"
  INT_ID="$(aws apigatewayv2 create-integration --api-id "${API_ID}" \
    --integration-type AWS_PROXY --integration-uri "${LAMBDA_ARN}" \
    --integration-method POST --payload-format-version 2.0 --query IntegrationId --output text)"
  aws apigatewayv2 create-route --api-id "${API_ID}" --route-key "POST /files" \
    --target "integrations/${INT_ID}" >/dev/null
  aws apigatewayv2 create-stage --api-id "${API_ID}" --stage-name '$default' --auto-deploy >/dev/null
  aws apigatewayv2 update-stage --api-id "${API_ID}" --stage-name '$default' \
    --default-route-settings "ThrottlingBurstLimit=5,ThrottlingRateLimit=2" >/dev/null
  aws lambda add-permission --function-name "${FUNC}" --statement-id apigw-invoke \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/files" >/dev/null
fi

echo ">> Deployed. Endpoint: https://${API_ID}.execute-api.${REGION}.amazonaws.com/files"
echo ">> Test it:  ./scripts/stage2_test.sh"
