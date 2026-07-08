# Stage 1 — Manual MVP

**Goal:** learn the one mechanic the whole product rests on — temporary, signed access to a private object — with nothing but the AWS CLI. No Lambda, no API, no automation yet.

## What was built

A single S3 bucket, `sfs-files-<account-id>`, hardened four ways:

| Control | Why |
|---|---|
| **Block Public Access** (all four flags) | The only path to a file is a presigned URL. Nothing is ever world-readable. |
| **Default encryption (SSE-S3, bucket key)** | Encrypted at rest by default. Upgrades to a customer-managed KMS key in Stage 3. |
| **HTTPS-only bucket policy** | Denies any request where `aws:SecureTransport` is false. |
| **No versioning (deliberate)** | A self-destruct product must leave nothing behind. Versioning would keep old versions and delete-markers after the reaper runs — directly against the product's promise. |

Setup lives in [`scripts/stage1_setup.sh`](../scripts/stage1_setup.sh); the demo in [`scripts/stage1_demo.sh`](../scripts/stage1_demo.sh).

## The mechanic

```
Unsigned request  -> HTTP 403   # bucket is private; the world is locked out
Signed request    -> HTTP 200   # a presigned URL grants access to one object
5s link, T+0s     -> HTTP 200   # fresh signed link works
5s link, T+8s     -> HTTP 403   # same URL, now expired — access is gone
```

A **presigned URL** is a normal S3 URL with a signature, an expiry (`X-Amz-Expires`), and the signer's credentials baked into the query string. S3 verifies the signature and the clock on every request. No signature or an expired one → `403`. Access is temporary by construction, not by a background job that might fail.

Key property carried into later stages: **a presigned URL can never grant more than its signer already holds.** In Stage 2 the signer becomes a least-privilege Lambda role, so the URLs it mints are automatically bounded.

## Try it yourself

```bash
./scripts/stage1_setup.sh   # create + harden the bucket (once)
./scripts/stage1_demo.sh    # upload, prove private, presign, watch it expire
```

## What Stage 1 does NOT solve (and Stage 2+ will)

- Presigning by hand doesn't scale → **Lambda + API Gateway** issue URLs (Stage 2).
- Nothing tracks or reclaims files → **DynamoDB metadata + TTL + reaper Lambda** (Stages 2–3).
- SSE-S3 is AWS-managed → **customer-managed KMS key** with a tight key policy (Stage 3).
