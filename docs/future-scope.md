# Future scope

Enhancements beyond the shipped Stages 0–5. The direction is captured with trade-offs
thought through; the items under "Planned" are designs, not yet built.

---

## Shipped since — Phase 1 level-up (2026-07)

Delivered and live on share.abheenash.com (see [`CASE_STUDY.md`](../CASE_STUDY.md) →
*Level-up*):

- ✅ **Password-protected links** — PBKDF2-SHA256 hash (per-file salt, 120k iters),
  constant-time verify; plaintext never stored.
- ✅ **Download-count limits** — atomic DynamoDB conditional update; `410 Gone` once
  the cap is hit.
- ✅ **Download notifications** — SES email (DKIM-signed `no-reply@abheenash.com`) to
  the uploader on each download, best-effort.
- ✅ **Two-verb download** — `GET /files/{id}` returns metadata only; `POST /files/{id}`
  validates + resolves. New `web/get.html` download page.

Also already done outside this doc's original scope: **custom domain**
(share.abheenash.com) and **observability** (handled by the sibling
[cloud-observability-sre](https://github.com/Abheenash/cloud-observability-sre) project).

---

## Shipped since — Phase 2 level-up (2026-07): zero-knowledge E2EE

Delivered and live (see [`docs/e2ee.md`](e2ee.md) + [`CASE_STUDY.md`](../CASE_STUDY.md)):

- ✅ **Client-side (zero-knowledge) encryption** — AES-256-GCM in the browser
  (WebCrypto) *before* upload; the key rides in the link `#fragment` and never
  reaches a server; the filename is sealed inside the ciphertext too. SSE-KMS
  stays as defense-in-depth. **This was the "strongest differentiator left" — now done.**
- ✅ **Secret-note mode**, 🔥 **burn-after-reading**, drag-and-drop, QR code.
- ✅ **Abuse control (free WAF alternative)** — hard per-route API Gateway throttle on
  `POST /files` (1 rps / burst 3).

---

## Stage 6 (planned) — API authentication + "My Files" dashboard

> ⚠️ **Constraint (user, 2026-07):** login must stay **optional** — mandatory sign-in
> kills the click-and-try demo that makes this recruiter-friendly. Auth gates the
> *upload* side for real use, but the anonymous flow must remain the default.

### Problem

The API is currently **open + throttled only**. `POST /files` lets anyone mint an upload
URL against the bucket, and there's no notion of "who" created a share. Fine for a demo;
not fine for anything real.

### Key design insight

Only the **upload** side needs auth. The **download** side (`GET /files/{fileId}`) is
*intentionally* public — the whole point of a share link is that a recipient with no
account can open it. Its safety already comes from being unguessable (UUID) and
short-lived (TTL + `410` on expiry). So:

- `POST /files` → **require authentication**
- `GET /files/{fileId}` → **stays public by design**

### Options considered

| Option | Mechanism | Verdict |
|---|---|---|
| API keys + usage plans | REST API feature | ❌ Not supported on HTTP APIs (apigatewayv2) — would force a REST API rewrite |
| Lambda authorizer | Custom function validates a token/header | ✅ Simplest; good if we just want a shared secret |
| **Cognito JWT authorizer** | User pool issues JWTs; API Gateway validates natively | ✅ **Recommended** — real user accounts, no custom auth code, first-class HTTP API support |
| IAM (SigV4) auth | Signed requests | ❌ Wrong fit for browser end-users |

### Recommended approach — Cognito + JWT authorizer

1. **Cognito user pool** + app client (hosted UI for sign-up/sign-in).
2. **JWT authorizer** on the API, attached to `POST /files` only.
3. **UI**: add a minimal login (Cognito Hosted UI or Amplify Auth) to obtain a JWT, then
   send `Authorization: Bearer <jwt>` on the upload request.
4. **CORS**: add `authorization` to `AllowHeaders`.
5. **Terraform**: `aws_cognito_user_pool`, `aws_cognito_user_pool_client`,
   `aws_apigatewayv2_authorizer` (type `JWT`), and wire `authorization_type = "JWT"` +
   `authorizer_id` onto the `POST /files` route.

### Verification plan

```
POST /files  (no token)      -> 401 Unauthorized
POST /files  (valid JWT)     -> 201
GET  /files/{id} (no token)  -> 302 / 410   (still public, by design)
```

### Effort

~half to one evening. Additive — no existing resource is destroyed.

---

## Other planned enhancements

| Idea | Notes |
|---|---|
| **Upload malware scan** | S3 event → **GuardDuty Malware Protection for S3** (managed — no ClamAV to run) → quarantine on a hit; publish the link only once the scan is clean. Note: works on ciphertext only for E2EE uploads, so it's most useful if/when a non-E2EE path exists. |
| **WAF** | Attach AWS WAF to CloudFront/API for rate-based rules once uploads are authenticated and the surface widens. |
| **Terraform as canonical** | Import the live CLI-built `sfs-*` stack into Terraform state (guide in `terraform/README.md`) so IaC is the single source of truth — a real brownfield-import exercise. |
| **Abuse controls** | Per-IP upload caps, max active links per user (needs Stage 6 auth), CAPTCHA on upload. |

> Done in Phase 1 and removed from this list: download-count limits, password
> protection, notifications. Custom domain and observability are also live (above).
