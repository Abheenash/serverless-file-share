"""issue-url Lambda — the API's core function.

Given a request for an upload link, it:
  1. mints a short-lived presigned PUT URL for a unique object key, and
  2. records the file's metadata in DynamoDB with a TTL == the file's lifetime.

The presigned URL is signed with THIS function's role credentials, so the
function's IAM role is the security boundary: a URL can never grant more than
the role holds (s3:PutObject on files/* only). See docs/stage2.md.
"""

import json
import os
import time
import uuid

import boto3

s3 = boto3.client("s3")
ddb = boto3.client("dynamodb")

BUCKET = os.environ["BUCKET"]
TABLE = os.environ["TABLE"]

UPLOAD_URL_TTL = 900                 # presigned PUT is valid 15 minutes
MIN_FILE_LIFETIME = 60               # 1 minute floor
MAX_FILE_LIFETIME = 7 * 24 * 3600    # 7-day cap (matches the product promise)
DEFAULT_FILE_LIFETIME = 24 * 3600    # 1 day default


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except (TypeError, ValueError):
        return _resp(400, {"error": "request body must be valid JSON"})

    filename = str(body.get("filename", "file"))
    lifetime = int(body.get("expiresInSeconds", DEFAULT_FILE_LIFETIME))
    lifetime = max(MIN_FILE_LIFETIME, min(lifetime, MAX_FILE_LIFETIME))

    file_id = str(uuid.uuid4())
    key = f"files/{file_id}/{filename}"
    now = int(time.time())
    expires_at = now + lifetime  # epoch seconds — DynamoDB TTL attribute

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key},
        ExpiresIn=UPLOAD_URL_TTL,
    )

    ddb.put_item(
        TableName=TABLE,
        Item={
            "fileId": {"S": file_id},
            "objectKey": {"S": key},
            "filename": {"S": filename},
            "createdAt": {"N": str(now)},
            "expiresAt": {"N": str(expires_at)},
        },
    )

    return _resp(201, {
        "fileId": file_id,
        "uploadUrl": upload_url,
        "objectKey": key,
        "expiresAt": expires_at,
        "uploadExpiresInSeconds": UPLOAD_URL_TTL,
    })


def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
