"""issue-url Lambda — the API's core function.

Given a request for an upload link, it:
  1. mints a short-lived presigned PUT URL for a unique object key, and
  2. records the file's metadata in DynamoDB with a TTL == the file's lifetime.

The presigned URL is signed with THIS function's role credentials, so the
function's IAM role is the security boundary: a URL can never grant more than
the role holds (s3:PutObject on files/* only). See docs/stage2.md.

Level-up (Phase 1) adds three OPTIONAL, no-login controls on a share link:
  * password       -> stored only as a PBKDF2-SHA256 hash (never the plaintext)
  * maxDownloads   -> a download-count cap; the link dies after N fetches
  * notifyEmail    -> the uploader is emailed (via SES) on each download
The download Lambda enforces all three. DynamoDB is schemaless past its key, so
these are just extra attributes — no table migration.
"""

import hashlib
import json
import os
import re
import time
import uuid

import boto3
from botocore.config import Config

# SSE-KMS requires SigV4-signed requests; force it (the global S3 endpoint
# otherwise defaults presigned URLs to legacy SigV2, which KMS rejects).
s3 = boto3.client("s3", config=Config(signature_version="s3v4"))
ddb = boto3.client("dynamodb")

BUCKET = os.environ["BUCKET"]
TABLE = os.environ["TABLE"]

UPLOAD_URL_TTL = 900                 # presigned PUT is valid 15 minutes
MIN_FILE_LIFETIME = 60               # 1 minute floor
MAX_FILE_LIFETIME = 7 * 24 * 3600    # 7-day cap (matches the product promise)
DEFAULT_FILE_LIFETIME = 24 * 3600    # 1 day default
MAX_UPLOAD_BYTES = 100 * 1024 * 1024  # hard cap on file size (100 MB)
MAX_DOWNLOADS_CAP = 1000             # sanity ceiling on the download-count limit
PBKDF2_ITERATIONS = 120_000          # cost factor for password hashing

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _hash_password(plaintext):
    """PBKDF2-SHA256 with a random per-file salt. Format: pbkdf2$sha256$iters$salt$hash."""
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", plaintext.encode("utf-8"), salt, PBKDF2_ITERATIONS)
    return f"pbkdf2$sha256${PBKDF2_ITERATIONS}${salt.hex()}${dk.hex()}"


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except (TypeError, ValueError):
        return _resp(400, {"error": "request body must be valid JSON"})

    filename = str(body.get("filename", "file"))
    lifetime = int(body.get("expiresInSeconds", DEFAULT_FILE_LIFETIME))
    lifetime = max(MIN_FILE_LIFETIME, min(lifetime, MAX_FILE_LIFETIME))

    # Enforce a size cap. The client declares the byte count; we reject anything
    # over the max, then sign the PUT bound to exactly that length so S3 refuses
    # a larger body. Stops the open endpoint being used as unbounded free storage.
    try:
        content_length = int(body.get("contentLength", 0))
    except (TypeError, ValueError):
        return _resp(400, {"error": "contentLength must be an integer"})
    if content_length <= 0:
        return _resp(400, {"error": "contentLength (file size in bytes) is required"})
    if content_length > MAX_UPLOAD_BYTES:
        return _resp(413, {"error": f"file too large (max {MAX_UPLOAD_BYTES} bytes)"})

    file_id = str(uuid.uuid4())
    key = f"files/{file_id}/{filename}"
    now = int(time.time())
    expires_at = now + lifetime  # epoch seconds — DynamoDB TTL attribute

    item = {
        "fileId": {"S": file_id},
        "objectKey": {"S": key},
        "filename": {"S": filename},
        "createdAt": {"N": str(now)},
        "expiresAt": {"N": str(expires_at)},
        "downloadCount": {"N": "0"},
    }

    # --- optional Phase-1 controls -----------------------------------------
    password = body.get("password")
    if password not in (None, ""):
        item["passwordHash"] = {"S": _hash_password(str(password))}

    max_downloads = body.get("maxDownloads")
    if max_downloads not in (None, "", 0, "0"):
        try:
            md = int(max_downloads)
        except (TypeError, ValueError):
            return _resp(400, {"error": "maxDownloads must be an integer"})
        if md < 1:
            return _resp(400, {"error": "maxDownloads must be at least 1"})
        item["maxDownloads"] = {"N": str(min(md, MAX_DOWNLOADS_CAP))}

    notify_email = str(body.get("notifyEmail") or "").strip()
    if notify_email:
        if not EMAIL_RE.match(notify_email):
            return _resp(400, {"error": "notifyEmail is not a valid email address"})
        item["notifyEmail"] = {"S": notify_email}

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key, "ContentLength": content_length},
        ExpiresIn=UPLOAD_URL_TTL,
    )

    ddb.put_item(TableName=TABLE, Item=item)

    return _resp(201, {
        "fileId": file_id,
        "uploadUrl": upload_url,
        "objectKey": key,
        "expiresAt": expires_at,
        "uploadExpiresInSeconds": UPLOAD_URL_TTL,
        "passwordProtected": "passwordHash" in item,
        "maxDownloads": int(item["maxDownloads"]["N"]) if "maxDownloads" in item else None,
        "notify": bool(notify_email),
    })


def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
