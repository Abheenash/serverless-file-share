# Stage 5 — Terraform + CI/CD

**Goal:** replace the imperative CLI build (Stages 1–4, captured in `scripts/`) with a single declarative source of truth, and wire a pipeline that checks it automatically.

## What was built

- **`terraform/`** — the entire stack as ~38 resources: KMS key, both S3 buckets (hardened), DynamoDB (TTL + streams), three least-privilege IAM roles, three Lambdas (zipped from `src/` via `archive_file`), the HTTP API (routes + CORS + throttle), CloudFront + OAC, and the UI objects. `config.js` is generated from the Terraform-managed API endpoint, so the front end is wired automatically.
- **`.github/workflows/terraform.yml`** — CI/CD:
  - `validate` — `fmt -check`, `init -backend=false`, `validate` on every PR (no credentials).
  - `plan` — on PRs, via GitHub OIDC (keyless), if `AWS_ROLE_ARN` is configured.
  - `apply` — on merge to `main`, gated behind a protected `production` environment.
- **`docs/architecture.md`** — a Mermaid diagram that renders on GitHub.

## Design decisions

- **Parallel environment, not a destructive rebuild.** `name_prefix` (default `sfs-tf`) means Terraform stands up its own isolated stack rather than colliding with the live CLI-built one on globally-unique bucket names. The live app keeps running; the IaC is proven independently. An import path to adopt the existing stack is documented in `terraform/README.md`.
- **Policies as data sources, not static JSON.** IAM/KMS policies are built with `aws_iam_policy_document` referencing real resource ARNs — no hardcoded account IDs, unlike the Stage 1–4 `iam/*.json` files.
- **Keyless CI.** GitHub Actions authenticates to AWS via OIDC role assumption — no long-lived access keys stored in the repo.

## Verified

```
terraform fmt -check     -> clean
terraform validate       -> Success! The configuration is valid.
terraform plan           -> Plan: 38 to add, 0 to change, 0 to destroy.
```

## CLI stack vs. Terraform

The `scripts/stageN_*.sh` files remain in the repo on purpose — they're the learning
record of how each piece was built by hand. `terraform/` is how the same architecture
is expressed as infrastructure-as-code. In a real project you'd keep only the IaC; here
both are kept to show the progression from imperative to declarative.

## Remaining follow-ups (documented, not hidden)

- Custom domain (ACM + Route 53 + CloudFront alias).
- API authentication (currently open + throttled).
- Screenshots of the live UI added to the repo.
