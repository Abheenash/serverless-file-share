# Future scope

Planned enhancements beyond the shipped Stages 0–5. These are **designs, not yet built** —
captured so the direction is clear and the trade-offs are already thought through.

---

## Stage 6 (planned) — API authentication

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
| **Custom domain** | ACM cert (us-east-1) + Route 53 + CloudFront alias. Cosmetic. |
| **Observability** | CloudWatch dashboard + alarms (Lambda errors, 4xx/5xx), X-Ray tracing across API → Lambda → S3/DynamoDB. |
| **One-time / download-count limits** | Track a `downloads` counter in DynamoDB; the download Lambda decrements and refuses at zero. |
| **Upload malware scan** | S3 event → Lambda (ClamAV layer or GuardDuty Malware Protection) → quarantine on hit. |
| **WAF** | Attach AWS WAF to CloudFront/API for rate-based rules once the endpoint is public. |
| **Terraform as canonical** | Import the live CLI-built stack into Terraform state (guide in `terraform/README.md`) so IaC is the single source of truth. |
