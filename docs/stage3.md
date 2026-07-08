# Stage 3 — self-destruct

**Goal:** make the file actually destroy itself. When a metadata item's TTL fires, the file must leave S3 automatically — and everything must be encrypted with a key *we* control.

## What was built

```
DynamoDB item TTL fires
      │  (item removed → stream REMOVE record with OldImage)
      ▼
DynamoDB Streams ──filter: REMOVE only──> Lambda "reaper" ──s3:DeleteObject──> file gone
                                                                   ▲
S3 lifecycle rule (expire files/ after 8 days) ─── backstop if the reaper ever fails ┘

All objects encrypted at rest with a customer-managed KMS key (alias/sfs-key).
```

| Resource | Name | Notes |
|---|---|---|
| KMS key | `alias/sfs-key` | Customer-managed; key policy grants **use** only to `sfs-issue-url-role` (+ account admin for management) |
| Reaper Lambda | `sfs-reaper` | Triggered by the stream; deletes the S3 object named in the record's `OldImage` |
| Reaper role | `sfs-reaper-role` | `AWSLambdaDynamoDBExecutionRole` (stream read + logs) + inline `s3:DeleteObject` / `dynamodb:DeleteItem` only |
| Stream | on `sfs-metadata` | `NEW_AND_OLD_IMAGES`; event-source mapping filters to `REMOVE` events |
| Lifecycle rule | `reaper-backstop` | Expires `files/` after 8 days (just beyond the 7-day max TTL) |

## Encryption: SSE-S3 → customer-managed KMS

The bucket default flipped from AWS-managed AES256 to `aws:kms` with our CMK (`BucketKeyEnabled` to cut KMS costs). The key policy grants *usage* (`GenerateDataKey`, `Decrypt`) only to the issue-url role; the role's IAM policy scopes that further with a `kms:ViaService = s3.us-east-1.amazonaws.com` condition, so the role can only touch the key *through S3*, never directly.

## The self-destruct path

1. TTL removes the metadata item → a `REMOVE` record hits the stream, carrying the item's `OldImage` (including `objectKey`).
2. The event-source mapping filters to `REMOVE` only, so the reaper never wakes for writes.
3. The reaper reads `objectKey` from `OldImage` and calls `s3:DeleteObject`. The metadata item is already gone (TTL removed it), so the reaper only cleans the file.
4. If the reaper ever fails, the S3 **lifecycle rule** deletes the object within a day of its intended expiry — defence in depth.

## Two bugs worth remembering (both caught by testing)

- **SSE-KMS requires SigV4.** After switching to KMS, uploads returned `400 InvalidArgument: "...require AWS Signature Version 4."` The presigned URLs were SigV2 (the global `s3.amazonaws.com` endpoint's legacy default). Fix: `boto3.client("s3", config=Config(signature_version="s3v4"))` in the issue-url Lambda.
- **The `LATEST` race.** The first self-destruct test failed silently — mapping said *"No records processed."* With `--starting-position LATEST`, records that arrive before the mapping actually begins polling its shard are skipped. The delete landed in that startup window. Once the mapping is warm, `REMOVE` events fire the reaper reliably.

## Verified

```
upload via API           -> object in S3, encrypted aws:kms (our CMK)
delete metadata item     -> REMOVE stream event
~seconds later           -> S3 object deleted by the reaper (self-destruct)
```

*(Real TTL deletion produces the same `REMOVE` event, just on DynamoDB's own schedule — up to ~48h after expiry. The test deletes the item directly to exercise the identical path immediately.)*

## Deploy

```bash
./scripts/stage3_deploy.sh
```

## Next (Stage 4)

Minimal web UI on S3 + CloudFront with a custom domain, so a human — not just `curl` — can share a file.
