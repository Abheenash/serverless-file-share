#!/usr/bin/env bash
# Stage 1 — the presigned-URL mechanic, demonstrated end to end.
# Uploads a file, proves it is private, hands out a short-lived link, and watches it expire.

set -euo pipefail

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="sfs-files-${ACCOUNT_ID}"
KEY="demo/secret.txt"

# 1. Upload a test object.
TMP="$(mktemp)"
echo "Top secret: the launch code is 0000. This message will self-destruct." > "${TMP}"
aws s3 cp "${TMP}" "s3://${BUCKET}/${KEY}"
rm -f "${TMP}"

# 2. Prove it is private: an unsigned request must be denied.
echo -n "Unsigned request  -> HTTP "
curl -s -o /dev/null -w "%{http_code}\n" "https://${BUCKET}.s3.amazonaws.com/${KEY}"   # expect 403

# 3. Presigned GET, valid for 120s: a signed request succeeds.
URL="$(aws s3 presign "s3://${BUCKET}/${KEY}" --expires-in 120)"
echo -n "Signed request    -> HTTP "
curl -s -o /dev/null -w "%{http_code}\n" "${URL}"                                       # expect 200

# 4. Expiry: a 5s link works now, and is dead moments later.
SHORT="$(aws s3 presign "s3://${BUCKET}/${KEY}" --expires-in 5)"
echo -n "5s link, T+0s     -> HTTP "; curl -s -o /dev/null -w "%{http_code}\n" "${SHORT}"   # 200
sleep 8
echo -n "5s link, T+8s     -> HTTP "; curl -s -o /dev/null -w "%{http_code}\n" "${SHORT}"   # 403

echo "Same URL, expired only by the passage of time. That is the core mechanic."
