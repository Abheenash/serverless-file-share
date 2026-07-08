"""download Lambda — resolves a share link to a short-lived download.

GET /files/{fileId}. Looks up the metadata item; if it is missing or past its
expiry, returns 410 Gone. Otherwise it presigns a short GET URL and 302-redirects
to it. The shareable link is thus a stable, clean API URL that hides the bucket
and stops working the moment the file self-destructs.
"""

import json
import os
import time

import boto3
from botocore.config import Config

# SigV4 required for SSE-KMS objects (see docs/stage3.md).
s3 = boto3.client("s3", config=Config(signature_version="s3v4"))
ddb = boto3.client("dynamodb")

BUCKET = os.environ["BUCKET"]
TABLE = os.environ["TABLE"]
DOWNLOAD_URL_TTL = 300  # the redirect target lives 5 minutes


def handler(event, context):
    file_id = (event.get("pathParameters") or {}).get("fileId")
    if not file_id:
        return _json(400, {"error": "missing fileId"})

    item = ddb.get_item(TableName=TABLE, Key={"fileId": {"S": file_id}}).get("Item")
    now = int(time.time())
    # item absent (reaped) or expiry passed (TTL lag) -> gone
    if not item or int(item["expiresAt"]["N"]) <= now:
        return _json(410, {"error": "this link has expired or does not exist"})

    key = item["objectKey"]["S"]
    filename = item.get("filename", {}).get("S", "download")
    url = s3.generate_presigned_url(
        "get_object",
        Params={
            "Bucket": BUCKET,
            "Key": key,
            "ResponseContentDisposition": f'attachment; filename="{filename}"',
        },
        ExpiresIn=DOWNLOAD_URL_TTL,
    )
    return {"statusCode": 302, "headers": {"Location": url}}


def _json(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
