# Terraform — serverless-file-share

Declarative definition of the entire stack that Stages 1–4 built imperatively via the
AWS CLI. `terraform plan` shows the whole product as **38 resources**.

## Layout

| File | Contents |
|---|---|
| `versions.tf` | Provider + Terraform version pins; commented S3 remote-backend block |
| `variables.tf` | `region`, `name_prefix`, `max_file_lifetime_days` |
| `main.tf` | Caller identity + name locals |
| `kms.tf` | Customer-managed key + scoped key policy |
| `s3.tf` | Files bucket (hardened) + private site bucket |
| `dynamodb.tf` | Metadata table (TTL + streams) |
| `iam.tf` | Three least-privilege roles (issue-url, reaper, download) |
| `lambda.tf` | Three functions (zipped from `../src`) + event-source mapping + permissions |
| `apigw.tf` | HTTP API, routes, CORS, throttled stage |
| `cloudfront.tf` | OAC + distribution + site bucket policy + UI objects |
| `outputs.tf` | API endpoint, CloudFront URL, bucket/table/key |

## Usage

```bash
cd terraform
terraform init
terraform plan          # default name_prefix "sfs-tf" -> isolated from the CLI stack
terraform apply
terraform destroy       # tear the whole environment down
```

`name_prefix` keeps a Terraform-managed environment separate from the CLI-built one,
so the two never collide on globally-unique S3 bucket names.

## Remote state (recommended before CI)

One-time bootstrap, then uncomment the `backend "s3"` block in `versions.tf`:

```bash
aws s3api create-bucket --bucket sfs-tfstate-<account_id> --region us-east-1
aws s3api put-bucket-versioning --bucket sfs-tfstate-<account_id> \
  --versioning-configuration Status=Enabled
terraform init -migrate-state
```

## CI/CD (GitHub Actions)

`.github/workflows/terraform.yml`:
- **validate** — `fmt -check` + `init -backend=false` + `validate` on every PR (no credentials).
- **plan** — on PRs, if repo variable `AWS_ROLE_ARN` is set (GitHub OIDC role).
- **apply** — on merge to `main`, gated behind a protected `production` environment.

Set up keyless auth (no long-lived keys in GitHub):

```bash
# 1. GitHub OIDC provider (once per account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# 2. An IAM role trusting this repo, then set repo variable AWS_ROLE_ARN to its ARN.
```

## Adopting the existing CLI-built stack (optional import)

To make Terraform manage the live stack instead of a parallel one, set
`name_prefix = "sfs"` and import each resource, e.g.:

```bash
terraform import aws_s3_bucket.files              sfs-files-<account_id>
terraform import aws_dynamodb_table.metadata      sfs-metadata
terraform import aws_kms_key.sfs                   <key-id>
terraform import aws_lambda_function.issue_url     sfs-issue-url
# ...continue for every resource, then `terraform plan` until it shows no changes.
```

Importing is fiddly (every attribute must match to reach a zero-diff plan); the
default parallel-environment approach avoids it entirely.
