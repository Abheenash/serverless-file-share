# Serverless File Share — Engineering Case Study

## Context

Serverless File Share is a small, real product: you share a file through a link
that expires. Files are encrypted at rest, links die on a timer, and the file
itself is destroyed after expiry — nothing lingers. The problem it solves is
the everyday "send someone a file, but don't leave it sitting somewhere
forever" case, with a security-first posture rather than a "drop it in a public
bucket" one.

The defining constraint is **self-destruct**. Because the product's promise is
that nothing is left behind, the design deliberately rules out anything that
would preserve remnants:

- **No versioning, by design.** Versioning would keep old object versions and
  delete-markers even after the reaper deletes the file — directly against the
  product's promise. So versioning is intentionally off.
- **Bounded lifetimes everywhere.** Upload URLs are short-lived, download URLs
  are short-lived, and the file's own lifetime is clamped server-side (1 minute
  floor, 7-day cap) so a client can't request an unbounded TTL.
- **Nothing public.** The only way to touch a file is a presigned URL; Block
  Public Access is on and the buckets are private.

It's built to live in the free tier — S3, Lambda, DynamoDB on-demand, and an
HTTP API at hobby volume — with a small budget alarm guarding the account.

## My role

I designed, built, debugged, and documented the whole thing myself, end to end,
in public. I built it in stages (a manual CLI MVP first, then the API, then
self-destruct, then a web UI, then a full Terraform rebuild with CI/CD), wrote
the per-stage docs and the architecture diagram, wrote the three Lambdas and the
IAM policies, and diagnosed the two production-style bugs described below.

## Architecture

The system is four planes: edge, API, data, and self-destruct.

- **Edge** — A browser hits **CloudFront** over HTTPS (`redirect-to-https`),
  which serves a private **S3 site bucket** through Origin Access Control (OAC).
  The site bucket is not public; CloudFront is the only reader, trusted via a
  scoped bucket policy.
- **API** — An **API Gateway HTTP API** (throttled) fronts two Lambdas:
  - `issue-url` — on `POST /files`, mints a short-lived presigned **PUT** URL for
    a unique object key and writes a metadata item to DynamoDB with a TTL.
  - `download` — on `GET /files/{fileId}`, looks up the metadata and either
    returns `410 Gone` (missing or expired) or `302`-redirects to a short-lived
    presigned **GET** URL.
- **Data** — A private, **SSE-KMS**-encrypted **S3 files bucket**; a **DynamoDB**
  table (`sfs-metadata`, on-demand, PK `fileId`) whose `expiresAt` attribute is
  the **TTL**; and a customer-managed **KMS CMK** (`alias/sfs-key`) that encrypts
  everything at rest.
- **Self-destruct** — When the TTL fires, DynamoDB removes the item, which emits
  a **DynamoDB Streams** `REMOVE` record carrying the item's `OldImage`. An
  event-source mapping filtered to `REMOVE` events triggers the **`reaper`**
  Lambda, which reads `objectKey` from the old image and deletes the S3 object.
  An **S3 lifecycle rule** (expire `files/` after 8 days, just beyond the 7-day
  max TTL) is the backstop if the reaper ever fails.

The file bytes never flow through the API — the browser uploads directly to S3
with the presigned PUT and downloads via the presigned GET redirect. The API and
Lambdas only handle small JSON control messages. See
[`docs/architecture.md`](docs/architecture.md) for the rendered diagram.

## Problems I had to solve

- **Temporary, signed access to a private object** — the one mechanic the whole
  product rests on. I proved it first with nothing but the AWS CLI before adding
  any automation.
- **Issuing those URLs at scale** — presigning by hand doesn't scale, so an API
  Gateway + Lambda mints them.
- **Reclaiming files automatically** — a self-destruct product needs the file to
  leave S3 on its own when the timer fires, reliably, with a backstop for when
  the primary path fails.
- **Encrypting with a key I control** — moving from AWS-managed encryption to a
  customer-managed KMS key with a tight key policy, without breaking uploads.
- **Letting a human (not just `curl`) use it** — a browser UI, which forced me to
  earn CORS on both the API and the S3 bucket.
- **Making the whole thing reproducible** — rebuilding the imperative CLI stack as
  declarative Terraform with a CI/CD pipeline.

## Implementation

The technical decisions that shaped the build:

- **The IAM role *is* the blast radius.** A presigned URL can never grant more
  than its signer holds. The `issue-url` role can do exactly two things
  (`s3:PutObject` on `files/*` and `dynamodb:PutItem` on the table), so any URL
  it mints is automatically bounded. This is the security model of the whole
  product.
- **File never flows through the API.** The client uploads directly to S3 with
  the presigned PUT and downloads via the presigned GET — cheaper, and it sidesteps
  the Lambda payload limit. The API only moves a small JSON control message.
- **The share link is our API URL, not a raw presigned URL.** `GET /files/{id}`
  302-redirects to a fresh short-lived presigned GET. The link is clean, hides
  the bucket, and dies the moment the metadata TTL reaps the item (→ `410 Gone`).
- **TTL drives self-destruction.** DynamoDB TTL removes the metadata item, which
  is what produces the `REMOVE` stream event. By the time the reaper runs, the
  item is already gone — the reaper's only job is to delete the matching S3 object.
- **Bounded, clamped lifetimes in code.** Upload URLs are fixed at 15 minutes;
  file lifetime is clamped 1 minute–7 days server-side; download redirects live 5
  minutes. A hard file-size cap is enforced by signing the PUT bound to the
  declared content length, so S3 itself refuses a larger body — stopping the open
  endpoint being abused as unbounded free storage.
- **Reaper reliability is defended in depth.** Beyond the S3 lifecycle backstop,
  the Terraform stack adds a dead-letter queue for stream records the reaper fails
  to process and a CloudWatch alarm on reaper errors (wired to an SNS topic), so a
  failed self-destruct can't vanish silently.
- **Terraform as a parallel, non-destructive rebuild.** A `name_prefix` (default
  `sfs-tf`) stands up an isolated stack rather than colliding with the live
  CLI-built one on globally-unique bucket names, so the IaC is proven independently
  while the live app keeps running. Policies are built with
  `aws_iam_policy_document` referencing real ARNs — no hardcoded account IDs.

## Debugging war stories

**1. The SigV2-vs-SigV4 presigned-PUT bug.** After switching the bucket's default
encryption from SSE-S3 to the customer-managed KMS key, uploads started failing
with `400 InvalidArgument: "...require AWS Signature Version 4."` Root cause:
**SSE-KMS requires SigV4-signed requests**, but the presigned URLs were being
signed with legacy **SigV2** — the default for the global `s3.amazonaws.com`
endpoint. The KMS-encrypted bucket rejected them. Fix: force SigV4 when
constructing the S3 client in the Lambda —
`boto3.client("s3", config=Config(signature_version="s3v4"))`. Both the
`issue-url` and `download` Lambdas now pin SigV4 for exactly this reason.

**2. The DynamoDB Streams `LATEST` race.** The very first self-destruct test failed
*silently* — the event-source mapping reported "No records processed," and the
file was never deleted. Root cause: with `--starting-position LATEST`, the mapping
only sees records that arrive **after** it has actually begun polling the shard.
Records that land during that startup window are skipped — and my test's delete
landed in exactly that window, so the `REMOVE` event was dropped before the reaper
ever woke. Once the mapping is warm and polling, `REMOVE` events fire the reaper
reliably. The lesson: `LATEST` has a cold-start gap, and a self-destruct path needs
the backstop (S3 lifecycle) precisely because the primary trigger can miss an event.

## Level-up: zero-knowledge encryption (Phase 2)

Phase 1 made the product useful. Phase 2 raised the security ceiling from
"encrypted with a key **I** control" to **"encrypted with a key I never see."**

Every share is now **end-to-end encrypted in the browser** before upload. A fresh
**AES-256-GCM** key is generated with WebCrypto, the file *and its filename* are
sealed into ciphertext, and only ciphertext is PUT to S3. The key is carried in the
share link's **`#fragment`** — which browsers never transmit — so the API, the
Lambdas, S3, DynamoDB, and I only ever hold ciphertext. **The service cannot read
the file, or even its name.** SSE-KMS stays underneath as defense-in-depth.

**Why this design and not accounts + server-side keys.** The whole product
constraint is *frictionless* — a recruiter won't sign up to test it. Fragment-key
E2EE (the Firefox Send / Bitwarden Send model) keeps the click-and-try flow while
making the trust boundary the browser, not my IAM policy. The best key-management
story is not holding the key at all.

**The insight that made the backend almost free to change.** Zero-knowledge is a
*client-side* property. The Lambdas didn't need to learn cryptography — they only
needed to *stop knowing things*. So `issue_url` records a single `encrypted: true`
boolean (never the key) and the client sends a generic `encrypted.bin` name instead
of the real one. The filename travels *inside* the ciphertext, framed ahead of the
bytes as `[4-byte length][JSON header][data]`, so it decrypts out on the other side
with zero server involvement. Total backend delta: ~3 lines, no table migration
(DynamoDB is schemaless past its key), no new IAM, **no new cost**.

**Design choices worth calling out:**
- **Authenticated encryption (GCM).** A tampered blob or wrong key fails the auth
  tag and decryption *throws* — it can never silently return corrupted bytes.
- **Client-side fetch-then-decrypt.** The download page changed from *navigating*
  to the presigned URL (S3 serves the file) to *fetching* the ciphertext and
  decrypting in memory. This worked with zero infra change because the files bucket
  CORS already allowed cross-origin `GET` from the site origin.
- **Secret-note mode reuses the same envelope.** A note is just `kind:"note"` in the
  header — same encrypt/upload path, rendered inline instead of downloaded. Sharing
  a password or API key became a five-second demo.
- **Abuse control without WAF.** An open upload endpoint is a free-storage magnet.
  Rather than pay ~$5/mo for AWS WAF on a portfolio demo, I throttled the write route
  hard at the API Gateway layer (1 rps / burst 3) — same "ran an open endpoint
  responsibly" story, $0.

Full design + threat model (including the honest limitations — anyone with the link
can decrypt; the key lives in browser history) is in [`docs/e2ee.md`](docs/e2ee.md).

## Level-up: from demo to product (Phase 1)

The first version proved the security architecture. The level-up turns it into
something you'd actually use, with three optional, **no-login** controls on every
share link — all enforced server-side, never in the browser:

- **Password protection.** The uploader can require a password. It's stored *only*
  as a **PBKDF2-SHA256 hash** (random per-file salt, 120k iterations); the plaintext
  never reaches the backend and is never stored. Verification is constant-time
  (`hmac.compare_digest`), so a wrong guess can't be timed to leak the hash.
- **Download limits.** A link can be capped at *N* downloads. The count is enforced
  with an **atomic DynamoDB conditional update** (`SET downloadCount = downloadCount + 1`
  guarded by `ConditionExpression: downloadCount < maxDownloads`), so two people
  clicking at once can't both slip through the last slot — the database, not the
  Lambda, is the source of truth. Once the cap is hit the link is `410 Gone`.
- **Download notifications.** The uploader can opt to be emailed (via **SES**, from a
  DKIM-signed `no-reply@abheenash.com`) each time the file is fetched — best-effort,
  so a notification failure never blocks the download.

**The architectural change this forced.** The original download was a single
`GET /files/{id}` that 302-redirected straight to the file. A password prompt can't
live in a redirect, so I split the resource into two verbs:

- `GET /files/{id}` → **metadata only** (`filename`, expiry, `passwordProtected`,
  `downloadsLeft`) so the new download page can render and prompt for a password
  *without* the API ever handing out the file to an unauthenticated request.
- `POST /files/{id}` → validates the password, atomically enforces + increments the
  limit, fires the notification, and only then returns a short-lived presigned URL.

The share link is now a real download page (`/get.html?id=…`) instead of a raw API
URL. A subtle bug I hit and fixed along the way: DynamoDB's `if_not_exists()` is
allowed in an *UpdateExpression* but **not** in a *ConditionExpression* — so the
counter is seeded to `0` at creation and the condition references it directly.

## Security decisions

- **SSE-KMS with a customer-managed CMK** (`alias/sfs-key`). The key policy grants
  *use* only to the Lambda roles that need it; the `issue-url` role's IAM policy
  narrows that further with a `kms:ViaService = s3.us-east-1.amazonaws.com`
  condition, so the role can only touch the key *through S3*, never directly.
  `BucketKeyEnabled` cuts KMS request cost.
- **One least-privilege role per Lambda.** `issue-url` can only put objects on the
  files prefix and put metadata items; `download` can only get items, get objects
  on `files/*`, and decrypt via S3; `reaper` can only delete objects and delete
  items (plus stream-read + logs). A presigned URL can never grant more than its
  signing role holds.
- **HTTPS-only.** The files bucket policy denies any request where
  `aws:SecureTransport` is false; CloudFront enforces `redirect-to-https`.
- **Block Public Access** across the account — the only access paths are presigned
  URLs and CloudFront OAC. The site bucket is private and readable only by the one
  CloudFront distribution.
- **No versioning, deliberately** — a self-destruct product must leave nothing
  behind, so no old versions or delete-markers are retained.
- **No secrets in code**, CloudTrail on for audit, and keyless CI via GitHub OIDC
  role assumption (no long-lived access keys in the repo).

## Trade-offs

- **The API is currently open (throttled only).** `POST /files` is unauthenticated;
  abuse is bounded by stage throttling and the server-side size/lifetime caps
  rather than by identity. Real auth is a designed-but-not-yet-built follow-up.
  Notably, only the upload side needs auth — the download link is *intentionally*
  public, since a recipient with no account must be able to open it; its safety
  comes from being an unguessable UUID that is short-lived and returns `410` on
  expiry.
- **Short download TTL (5 minutes).** The presigned GET the download Lambda
  redirects to is deliberately short-lived. It's a security-vs-convenience choice:
  a recipient must follow the link reasonably promptly.
- **A single customer-managed KMS key.** One CMK for the whole files bucket is
  simpler and cheaper (helped by `BucketKeyEnabled`) than per-file or per-tenant
  keys, at the cost of coarser key-level isolation.
- **Two stacks kept on purpose.** The imperative `scripts/stageN_*.sh` build and
  the declarative `terraform/` stack both live in the repo — the scripts as the
  learning record of how each piece was built by hand, Terraform as how the same
  architecture is expressed as IaC. In a real project you'd keep only the IaC.
- **Custom domain deferred.** The UI runs on the CloudFront default HTTPS URL;
  adding a domain (ACM cert in us-east-1 → CloudFront alias → Route 53 record) is
  an isolated, cosmetic follow-up.

## What I would improve next

**Shipped since the first cut** (see the Level-up section above): download-count
limits, password-protected links, and download notifications — plus **observability**,
which is handled by a sibling project ([cloud-observability-sre](https://github.com/Abheenash/cloud-observability-sre))
that watches this live stack with a golden-signals dashboard, alarms, X-Ray, and a
Synthetics canary.

Still designed, with trade-offs thought through, in
[`docs/future-scope.md`](docs/future-scope.md):

- **Add authentication to the upload side + a "My Files" dashboard.** Attach a
  Cognito JWT authorizer to `POST /files` only (HTTP APIs support JWT authorizers
  natively, so no custom auth code), keeping `GET /files/{id}` public by design, and
  give signed-in users a page to see and revoke their active links. Verification
  target: `POST /files` with no token → `401`, with a valid JWT → `201`, download
  still public.
- **Client-side (zero-knowledge) encryption** — encrypt the file *in the browser*
  with a key derived from the password (WebCrypto + PBKDF2) before upload, so the
  server never sees plaintext. Turns "encrypted at rest with KMS" into "we couldn't
  read it if we wanted to."
- **Upload malware scanning** — S3 event → **GuardDuty Malware Protection for S3** →
  quarantine on a hit, and only publish the link once the scan is clean.
- **WAF** on CloudFront/API for rate-based rules once the endpoint is authenticated
  and public-facing.
- **Make Terraform canonical** — import the live CLI-built stack into Terraform
  state so the IaC is the single source of truth.

## Evidence

- Overview and roadmap: [`README.md`](README.md)
- Architecture (Mermaid diagram + flow): [`docs/architecture.md`](docs/architecture.md)
- Per-stage build logs:
  [`docs/stage1.md`](docs/stage1.md) ·
  [`docs/stage2.md`](docs/stage2.md) ·
  [`docs/stage3.md`](docs/stage3.md) (both debugging war stories) ·
  [`docs/stage4.md`](docs/stage4.md) ·
  [`docs/stage5.md`](docs/stage5.md)
- Future designs: [`docs/future-scope.md`](docs/future-scope.md)
- Lambda source:
  [`src/issue_url/lambda_function.py`](src/issue_url/lambda_function.py) ·
  [`src/download/lambda_function.py`](src/download/lambda_function.py) ·
  [`src/reaper/lambda_function.py`](src/reaper/lambda_function.py)
- Infrastructure as code: [`terraform/`](terraform/) (KMS, S3, DynamoDB, IAM,
  Lambda, HTTP API, CloudFront, monitoring/DLQ) and
  [`terraform/README.md`](terraform/README.md)
- Hand-built IAM/KMS policies: [`iam/`](iam/)
- CI/CD pipeline: [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml)
- Live UI: **https://share.abheenash.com** (custom domain over CloudFront; also
  reachable on the CloudFront default `d24l9txysmtn7c.cloudfront.net`)
