#!/usr/bin/env bash
# Stage 4 — web UI: download path (GET /files/{id}) + S3 site + CloudFront (OAC) + CORS.
# Assumes Stages 2-3 are deployed. Idempotent-ish.
#
# Usage: ./scripts/stage4_deploy.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-us-east-1}"
FILES="sfs-files-${ACCOUNT_ID}"
SITE="sfs-site-${ACCOUNT_ID}"
TABLE="sfs-metadata"
API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='sfs-api'].ApiId" --output text)"

# 1. download role + lambda.
if ! aws iam get-role --role-name sfs-download-role >/dev/null 2>&1; then
  aws iam create-role --role-name sfs-download-role \
    --assume-role-policy-document file://iam/issue-url-trust.json >/dev/null
  aws iam attach-role-policy --role-name sfs-download-role \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi
aws iam put-role-policy --role-name sfs-download-role \
  --policy-name sfs-download-inline --policy-document file://iam/download-policy.json
ZIP="$(mktemp -u).zip"; ( cd src/download && zip -q -j "${ZIP}" lambda_function.py )
if aws lambda get-function --function-name sfs-download >/dev/null 2>&1; then
  aws lambda update-function-code --function-name sfs-download --zip-file "fileb://${ZIP}" >/dev/null
else
  for _ in 1 2 3 4 5; do
    aws lambda create-function --function-name sfs-download \
      --runtime python3.12 --handler lambda_function.handler \
      --role "arn:aws:iam::${ACCOUNT_ID}:role/sfs-download-role" \
      --zip-file "fileb://${ZIP}" --timeout 10 --memory-size 128 \
      --environment "Variables={BUCKET=${FILES},TABLE=${TABLE}}" >/dev/null && break
    sleep 5
  done
fi
rm -f "${ZIP}"

# 2. GET /files/{fileId} route.
if [ -z "$(aws apigatewayv2 get-routes --api-id "${API_ID}" --query "Items[?RouteKey=='GET /files/{fileId}'].RouteId" --output text)" ]; then
  DL_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:sfs-download"
  INT_ID="$(aws apigatewayv2 create-integration --api-id "${API_ID}" \
    --integration-type AWS_PROXY --integration-uri "${DL_ARN}" \
    --integration-method POST --payload-format-version 2.0 --query IntegrationId --output text)"
  aws apigatewayv2 create-route --api-id "${API_ID}" \
    --route-key "GET /files/{fileId}" --target "integrations/${INT_ID}" >/dev/null
  aws lambda add-permission --function-name sfs-download --statement-id apigw-invoke-download \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/files/*" >/dev/null
fi

# 3. private site bucket.
if ! aws s3api head-bucket --bucket "${SITE}" 2>/dev/null; then
  aws s3api create-bucket --bucket "${SITE}" --region "${REGION}" >/dev/null
fi
aws s3api put-public-access-block --bucket "${SITE}" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 4. CloudFront distribution (OAC). Reuse if one already exists for this comment.
CF_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='serverless-file-share UI'].Id | [0]" --output text 2>/dev/null || true)"
if [ "${CF_ID}" = "None" ] || [ -z "${CF_ID}" ]; then
  OAC_ID="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config Name=sfs-oac,OriginAccessControlOriginType=s3,SigningBehavior=always,SigningProtocol=sigv4 \
    --query 'OriginAccessControl.Id' --output text)"
  CFG="$(mktemp)"
  cat > "${CFG}" <<JSON
{ "CallerReference": "sfs-${SITE}", "Comment": "serverless-file-share UI", "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": { "Quantity": 1, "Items": [{ "Id": "sfs-site-origin",
    "DomainName": "${SITE}.s3.${REGION}.amazonaws.com",
    "OriginAccessControlId": "${OAC_ID}", "S3OriginConfig": { "OriginAccessIdentity": "" } }] },
  "DefaultCacheBehavior": { "TargetOriginId": "sfs-site-origin", "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6", "Compress": true } }
JSON
  CF_ID="$(aws cloudfront create-distribution --distribution-config "file://${CFG}" --query 'Distribution.Id' --output text)"
  rm -f "${CFG}"
fi
CF_DOMAIN="$(aws cloudfront get-distribution --id "${CF_ID}" --query 'Distribution.DomainName' --output text)"

# 5. site bucket policy: only this distribution may read.
POL="$(mktemp)"
cat > "${POL}" <<JSON
{ "Version": "2012-10-17", "Statement": [{ "Sid": "AllowCloudFrontOAC", "Effect": "Allow",
  "Principal": { "Service": "cloudfront.amazonaws.com" }, "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::${SITE}/*",
  "Condition": { "StringEquals": { "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_ID}" } } }] }
JSON
aws s3api put-bucket-policy --bucket "${SITE}" --policy "file://${POL}"; rm -f "${POL}"

# 6. CORS: API + files bucket must trust the CloudFront origin.
CF_ORIGIN="https://${CF_DOMAIN}"
aws apigatewayv2 update-api --api-id "${API_ID}" \
  --cors-configuration "AllowOrigins=${CF_ORIGIN},AllowMethods=GET,POST,OPTIONS,AllowHeaders=content-type" >/dev/null
CORS="$(mktemp)"
echo "{\"CORSRules\":[{\"AllowedOrigins\":[\"${CF_ORIGIN}\"],\"AllowedMethods\":[\"PUT\",\"GET\"],\"AllowedHeaders\":[\"*\"],\"ExposeHeaders\":[\"ETag\"],\"MaxAgeSeconds\":3000}]}" > "${CORS}"
aws s3api put-bucket-cors --bucket "${FILES}" --cors-configuration "file://${CORS}"; rm -f "${CORS}"

# 7. generate config.js and upload the UI.
printf 'window.SFS_CONFIG = { apiBase: "https://%s.execute-api.%s.amazonaws.com" };\n' "${API_ID}" "${REGION}" > web/config.js
aws s3 cp web/index.html "s3://${SITE}/index.html" --quiet
aws s3 cp web/app.js "s3://${SITE}/app.js" --quiet
aws s3 cp web/config.js "s3://${SITE}/config.js" --quiet

echo ">> Stage 4 deployed. UI: https://${CF_DOMAIN}  (allow ~10 min on first deploy)"
