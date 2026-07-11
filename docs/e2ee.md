# Zero-knowledge, end-to-end encryption (Level-up Phase 2)

## Goal

Turn "encrypted at rest with a key **I** control (SSE-KMS)" into **"encrypted with a
key I never see."** After this change the service is *zero-knowledge*: the API,
the Lambdas, S3, DynamoDB, and the operator only ever hold ciphertext. Even the
**filename** is sealed. This is the same model as Firefox Send / Bitwarden Send —
and it needs **no account**, so a recruiter can still click a link and try it.

## Design

Encryption happens in the browser with the **WebCrypto** API (`crypto.subtle`),
so there is no crypto library to trust or ship — it's the platform's.

### Key custody — the whole trick

A fresh random **AES-256-GCM** key is generated per share and placed in the share
link's **fragment**:

```
https://share.abheenash.com/get.html?id=<fileId>#<base64url-key>
                                              └── the URL #fragment ──┘
```

By the URL spec, the fragment is **never included in an HTTP request** — browsers
strip everything from `#` onward before sending. So the key reaches the
recipient's browser but never any server, CDN log, or access log. The recipient's
browser reads it from `location.hash` and decrypts locally.

### On-disk (S3) blob format

```
[ 1 byte version=0x01 ][ 12-byte IV/nonce ][ AES-256-GCM ciphertext + 16-byte tag ]
```

The encrypted plaintext is itself framed so the **filename and content-type are
also secret**:

```
[ 4-byte big-endian header length ][ UTF-8 JSON header ][ file / note bytes ]
header = { "n": <name>, "t": <mime>, "k": "file" | "note" }
```

GCM gives **authenticated** encryption: a tampered blob or a wrong key fails the
tag check and decryption throws — it can't silently return garbage.

### Flow

**Upload** (`web/app.js` + `web/sfs-crypto.js`)
1. Browser generates the key, frames `{header + bytes}`, and AES-GCM-encrypts it.
2. Browser asks the API for a presigned PUT, sending **only** the *ciphertext
   length* and a generic name (`encrypted.bin`) + `encrypted: true`.
3. Browser PUTs the **ciphertext** straight to S3.
4. Browser builds the link and appends `#<key>` locally.

**Download** (`web/get.js`)
1. `GET /files/{id}` → metadata (`encrypted: true`, `passwordProtected`, downloads left).
2. `POST /files/{id}` (with password if set) spends a download, returns a
   short-lived presigned GET.
3. Browser `fetch()`es the ciphertext, reads the key from `location.hash`,
   decrypts, and either saves the file or shows the decrypted note.

### Backend changes (deliberately tiny)

Zero-knowledge is a *client* property, so the backend barely moved:
- `issue_url`: records `encrypted: true` (a boolean — never the key) and echoes it.
- `download`: surfaces `encrypted` in the metadata response; the download
  notification stays generic because the server genuinely doesn't know the name.

No table migration (DynamoDB is schemaless past its key), no new IAM, no new cost.

## Threat model

| Threat | Mitigation |
|---|---|
| Operator / insider reads shared files | **Can't** — server only holds ciphertext; the key never leaves the browser. |
| S3 bucket misconfig / leak | Leaked objects are AES-256-GCM ciphertext with no key. |
| CloudWatch / access logs leak the URL path | The key is in the `#fragment`, which is never sent or logged. |
| Tampering with stored bytes | GCM auth tag fails → decryption throws; no silent corruption. |
| Brute-force / guessing the link id | 122-bit random UUID + short TTL + optional download cap + optional password. |
| Abuse of the open upload endpoint (free storage) | 100 MB size cap bound into the presigned PUT; API Gateway per-route throttle on `POST /files` (1 rps / burst 3). |
| Weak or reused password | Password is a *second factor* only; the AES key is the real secret. Stored as PBKDF2-SHA256 (120k iters, per-file salt). |

### Honest limitations (what this does **not** claim)

- **Anyone with the full link can decrypt.** The link *is* the credential — that's
  the design (no accounts). Password + download-limit + TTL narrow the window.
- **The key sits in browser history / clipboard.** Standard for fragment-key
  designs (Firefox Send worked the same way). Burn-after-reading + short TTLs help.
- **No forward secrecy / no recipient public keys.** This is symmetric,
  link-based sharing, not PGP-style addressed encryption.
- **Metadata the server still sees:** ciphertext size, timestamps, TTL, whether a
  password is set, and download counts. The *content and filename* are not visible.

## Why it's the same cost ($0)

Encryption runs in the browser; S3/Lambda/DynamoDB paths are unchanged; the abuse
control is API Gateway throttling (free), not AWS WAF (~$5/mo). The QR generator
is a vendored MIT library served from S3 — no runtime third-party dependency.
