# Stage 4 — web UI

**Goal:** a human can share a file from a browser — drag a file, pick a lifetime, get a link — instead of using `curl`. Static site on S3, served through CloudFront, talking to the Stage 2/3 API.

## What was built

```
browser ──HTTPS──> CloudFront ──OAC──> S3 site bucket (private: index.html, app.js, config.js)
   │
   ├─ POST /files ─────────> API ─> issue-url ─> presigned PUT + metadata
   ├─ PUT file ────────────> S3 files bucket (direct, CORS-allowed)
   └─ GET /files/{id} ─────> API ─> download ─> 302 to presigned GET
```

| Resource | Name | Notes |
|---|---|---|
| Site bucket | `sfs-site-<acct>` | **Private**; readable only by the CloudFront distribution (OAC + scoped bucket policy) |
| CloudFront | `d24l9txysmtn7c.cloudfront.net` | HTTPS, `redirect-to-https`, default root `index.html` |
| Download Lambda | `sfs-download` | `GET /files/{id}` → 410 if gone, else 302 to a 5-min presigned GET |
| Download role | `sfs-download-role` | `dynamodb:GetItem` + `s3:GetObject files/*` + `kms:Decrypt` (via S3 only) |
| UI | `web/` | `index.html` + `app.js`; `config.js` (git-ignored) holds the API base |

## Two design decisions

- **Share link = our API URL, not a raw presigned URL.** `GET /files/{id}` 302-redirects to a fresh short-lived presigned GET. The link is clean, hides the bucket, and dies automatically the moment the metadata TTL reaps the item (→ `410 Gone`).
- **The site bucket stays private.** CloudFront reads it through Origin Access Control; the bucket policy trusts only this one distribution's ARN. Consistent with the account-wide "nothing is public" stance.

## CORS — the part browsers make you earn

`curl` ignores CORS; browsers don't. Two separate configs were needed:

1. **API Gateway CORS** — `AllowOrigins` = the CloudFront domain, `AllowMethods` = GET/POST/OPTIONS, `AllowHeaders` = content-type. Without it the browser's preflight `OPTIONS` fails before the real request.
2. **S3 files-bucket CORS** — allows `PUT` from the CloudFront origin, so the browser can upload directly to S3 with the presigned URL.

## Verified

```
GET https://<dist>.cloudfront.net/        -> 200, serves index.html
OPTIONS /files (preflight)                -> access-control-allow-origin present
GET /files/{id}                           -> 302 to presigned GET (backend, curl-tested)
GET /files/does-not-exist                 -> 410 Gone
```

## Deploy

```bash
./scripts/stage4_deploy.sh   # download path, site bucket, CloudFront, CORS, upload UI
```

## Not done on purpose

- **Custom domain** — deferred. The UI runs on the CloudFront default HTTPS URL; adding a domain is an isolated follow-up (register domain → ACM cert in us-east-1 → CloudFront alias + Route 53 record).
- **Auth** — the API is still open (throttled). A future stage can add Cognito or an API key.

## Next (Stage 5)

Rebuild all of this in Terraform with a GitHub Actions pipeline.
