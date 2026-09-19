"""reaper Lambda — the self-destruct.

Triggered by DynamoDB Streams. When a metadata item leaves the table — because
its TTL fired — a REMOVE record arrives here carrying the item's OldImage. We
read the object key from it and delete the file from S3. Nothing lingers.

TTL note: DynamoDB TTL deletes the metadata item itself, which is what produces
the REMOVE event. So by the time we run, the item is already gone — the reaper's
only job is to delete the matching S3 object. (The role also holds
dynamodb:DeleteItem for defensive/manual-cleanup paths.)
"""

import json
import os

import boto3
from botocore.exceptions import BotoCoreError, ClientError

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]


def log(**fields):
    print(json.dumps({"fn": "reaper", **fields}, default=str))


def handler(event, context):
    """Partial-batch semantics: a delete that fails is reported back by its
    sequence number so the stream retries ONLY that record, instead of failing
    the whole batch and re-deleting nine objects that were already gone."""
    deleted, skipped, failures = 0, 0, []
    for record in event.get("Records", []):
        if record.get("eventName") != "REMOVE":
            skipped += 1
            continue
        dyn = record.get("dynamodb", {})
        object_key = dyn.get("OldImage", {}).get("objectKey", {}).get("S")
        if not object_key:
            skipped += 1
            continue
        try:
            s3.delete_object(Bucket=BUCKET, Key=object_key)
            deleted += 1
            log(event="reaped", key=object_key)
        except (ClientError, BotoCoreError) as e:
            seq = dyn.get("SequenceNumber")
            log(event="reap_failed", key=object_key, error=f"{type(e).__name__}: {e}", sequence=seq)
            if seq:
                failures.append({"itemIdentifier": seq})
    log(event="batch", deleted=deleted, skipped=skipped, failed=len(failures))
    return {"deleted": deleted, "batchItemFailures": failures}
