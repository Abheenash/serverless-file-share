"""reaper Lambda — the self-destruct.

Triggered by DynamoDB Streams. When a metadata item leaves the table — because
its TTL fired — a REMOVE record arrives here carrying the item's OldImage. We
read the object key from it and delete the file from S3. Nothing lingers.

TTL note: DynamoDB TTL deletes the metadata item itself, which is what produces
the REMOVE event. So by the time we run, the item is already gone — the reaper's
only job is to delete the matching S3 object. (The role also holds
dynamodb:DeleteItem for defensive/manual-cleanup paths.)
"""

import os

import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]


def handler(event, context):
    deleted = 0
    for record in event.get("Records", []):
        if record.get("eventName") != "REMOVE":
            continue
        old_image = record.get("dynamodb", {}).get("OldImage", {})
        object_key = old_image.get("objectKey", {}).get("S")
        if not object_key:
            continue
        s3.delete_object(Bucket=BUCKET, Key=object_key)
        deleted += 1
        print(f"reaped s3://{BUCKET}/{object_key}")
    return {"deleted": deleted}
