"""download Lambda — resolves a share link to a short-lived download.

Two verbs on the same resource:

  GET  /files/{fileId}  -> metadata only (does NOT hand out the file):
       {filename, expiresAt, passwordProtected, downloadsLeft, gone}. The
       download page uses this to render (and to prompt for a password).

  POST /files/{fileId}  -> the actual fetch. Validates the optional password,
       atomically enforces + increments the download-count limit, fires an
       optional SES notification to the uploader, then returns a short-lived
       presigned GET URL: {downloadUrl}. The browser navigates to it to
       download (S3 serves it as an attachment).

If the item is missing or past its expiry it's 410 Gone. A count-capped link is
410 Gone once the cap is hit — the object itself is still cleaned up by the TTL
reaper. See docs/stage3.md.
"""

import hashlib
import hmac
import json
import os
import time

import boto3
from botocore.config import Config

# SigV4 required for SSE-KMS objects (see docs/stage3.md).
s3 = boto3.client("s3", config=Config(signature_version="s3v4"))
ddb = boto3.client("dynamodb")
ses = boto3.client("ses")

BUCKET = os.environ["BUCKET"]
TABLE = os.environ["TABLE"]
SES_SENDER = os.environ.get("SES_SENDER", "")
DOWNLOAD_URL_TTL = 300  # the redirect target lives 5 minutes


def handler(event, context):
    method = (event.get("requestContext", {}).get("http", {}) or {}).get("method", "GET")
    file_id = (event.get("pathParameters") or {}).get("fileId")
    if not file_id:
        return _json(400, {"error": "missing fileId"})

    item = ddb.get_item(TableName=TABLE, Key={"fileId": {"S": file_id}}).get("Item")
    now = int(time.time())
    gone = (not item) or int(item["expiresAt"]["N"]) <= now

    if method == "GET":
        return _info(item, gone)
    return _fetch(event, file_id, item, gone)


def _info(item, gone):
    if gone:
        return _json(410, {"gone": True, "error": "this link has expired or does not exist"})
    left = _downloads_left(item)
    if left == 0:
        return _json(410, {"gone": True, "error": "this link has hit its download limit"})
    return _json(200, {
        "filename": item.get("filename", {}).get("S", "download"),
        "expiresAt": int(item["expiresAt"]["N"]),
        "passwordProtected": "passwordHash" in item,
        "downloadsLeft": left,
    })


def _fetch(event, file_id, item, gone):
    if gone:
        return _json(410, {"error": "this link has expired or does not exist"})

    try:
        body = json.loads(event.get("body") or "{}")
    except (TypeError, ValueError):
        body = {}

    # 1. password gate
    if "passwordHash" in item:
        supplied = str(body.get("password") or "")
        if not supplied or not _verify_password(supplied, item["passwordHash"]["S"]):
            return _json(401, {"error": "incorrect password"})

    # 2. download-count limit — atomic check-and-increment so concurrent fetches
    #    can't slip past the cap (the condition is evaluated on the stored value).
    if "maxDownloads" in item:
        try:
            ddb.update_item(
                TableName=TABLE, Key={"fileId": {"S": file_id}},
                # downloadCount is always seeded to 0 at creation, so a bare
                # reference is safe here (if_not_exists is not allowed in a
                # ConditionExpression — only in the UpdateExpression).
                UpdateExpression="SET downloadCount = if_not_exists(downloadCount, :z) + :one",
                ConditionExpression="downloadCount < maxDownloads",
                ExpressionAttributeValues={":one": {"N": "1"}, ":z": {"N": "0"}},
            )
        except ddb.exceptions.ConditionalCheckFailedException:
            return _json(410, {"error": "this link has hit its download limit"})
    else:
        ddb.update_item(
            TableName=TABLE, Key={"fileId": {"S": file_id}},
            UpdateExpression="SET downloadCount = if_not_exists(downloadCount, :z) + :one",
            ExpressionAttributeValues={":one": {"N": "1"}, ":z": {"N": "0"}},
        )

    # 3. best-effort notification (never blocks the download)
    notify = item.get("notifyEmail", {}).get("S")
    if notify and SES_SENDER:
        _notify(notify, item)

    # 4. hand out a short-lived presigned GET
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
    return _json(200, {"downloadUrl": url})


def _downloads_left(item):
    """Remaining downloads, or None if the link is uncapped."""
    if "maxDownloads" not in item:
        return None
    cap = int(item["maxDownloads"]["N"])
    used = int(item.get("downloadCount", {}).get("N", "0"))
    return max(0, cap - used)


def _verify_password(supplied, stored):
    try:
        _scheme, _algo, iters, salt_hex, hash_hex = stored.split("$")
        dk = hashlib.pbkdf2_hmac("sha256", supplied.encode("utf-8"), bytes.fromhex(salt_hex), int(iters))
        return hmac.compare_digest(dk.hex(), hash_hex)
    except Exception:  # noqa: BLE001 - any parse failure is a non-match
        return False


def _notify(to_addr, item):
    filename = item.get("filename", {}).get("S", "your file")
    left = _downloads_left(item)
    tail = f" ({left - 1} download(s) left)" if left is not None else ""
    try:
        resp = ses.send_email(
            Source=SES_SENDER,
            Destination={"ToAddresses": [to_addr]},
            Message={
                "Subject": {"Data": f'📥 Your file "{filename}" was just downloaded'},
                "Body": {"Text": {"Data": (
                    f'Someone just downloaded "{filename}" through your share link{tail}.\n\n'
                    f"Shared via share.abheenash.com — the self-destructing file service."
                )}},
            },
        )
        print(f"notify sent to {to_addr}: {resp.get('MessageId')}")
    except Exception as e:  # noqa: BLE001 - SES sandbox only sends to verified addrs
        print(f"notify skipped ({type(e).__name__}): {e}")


def _json(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
