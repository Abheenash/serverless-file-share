# Stage 2 — API layer

**Goal:** turn the manual Stage 1 mechanic into a real service. A client asks an HTTP endpoint for an upload link; a Lambda mints the presigned URL and records the file's metadata (with a TTL) in DynamoDB.

## What was built

```
client ──POST /files──> API Gateway (HTTP API) ──> Lambda "issue-url"
                                                       │  ├─ s3:PutObject (presign)
                                                       │  └─ dynamodb:PutItem (metadata + TTL)
                        client ──PUT (presigned)──────────> S3 files bucket (encrypted)
```

| Resource | Name | Notes |
|---|---|---|
| DynamoDB table | `sfs-metadata` | On-demand billing; PK `fileId`; **TTL on `expiresAt`** (drives Stage 3 self-destruct) |
| Lambda | `sfs-issue-url` | Python 3.12; env `BUCKET`, `TABLE`; source in [`src/issue_url/`](../src/issue_url/lambda_function.py) |
| IAM role | `sfs-issue-url-role` | Least privilege — see below |
| HTTP API | `sfs-api` | Route `POST /files`; `$default` auto-deploy stage; throttled (burst 5, 2 rps) |

## The request flow

1. `POST /files` with `{"filename": "...", "expiresInSeconds": N}`.
2. Lambda generates a UUID `fileId`, builds key `files/<fileId>/<filename>`, and presigns a **PUT** URL (valid 15 min).
3. Lambda writes a metadata item: `fileId`, `objectKey`, `filename`, `createdAt`, `expiresAt` (epoch seconds — the TTL).
4. Response: `201` with `fileId`, `uploadUrl`, `objectKey`, `expiresAt`.
5. Client `PUT`s the file bytes straight to S3 with the presigned URL — the API never touches file data.

## Security decisions

- **Least privilege per function.** The role can do exactly two things: `s3:PutObject` on `files/*` and `dynamodb:PutItem` on the table ([`iam/issue-url-policy.json`](../iam/issue-url-policy.json)). Because a presigned URL is signed with the role's credentials, **the URL can never grant more than the role holds** — the IAM policy *is* the blast radius.
- **File never flows through the API.** The client uploads directly to S3; API Gateway and Lambda only handle a small JSON control message. Cheaper, and no 6 MB Lambda payload limit.
- **Bounded lifetimes.** Upload URL fixed at 15 min; file lifetime clamped to 1 min–7 days server-side, so a client can't request an unbounded TTL.
- **Throttling** on the stage caps abuse of the (currently unauthenticated) endpoint. Real auth is a later roadmap item.

## Verified

```
POST /files                 -> 201 + uploadUrl
PUT (presigned) upload      -> 200
head-object                 -> ServerSideEncryption: AES256
dynamodb scan               -> metadata item present with expiresAt
```

## Deploy / test

```bash
./scripts/stage2_deploy.sh   # create table, role, lambda, API (idempotent)
./scripts/stage2_test.sh     # POST -> presign -> upload -> verify
```

## Next (Stage 3 — self-destruct)

- Enable **DynamoDB Streams**; a **reaper Lambda** deletes the S3 object + metadata item when the TTL fires.
- S3 **lifecycle rule** as a backstop if the reaper ever fails.
- Swap SSE-S3 for a **customer-managed KMS key** with a key policy scoped to the two Lambda roles.
