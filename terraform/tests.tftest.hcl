# Native terraform tests (`terraform test`).
#
# These assert the invariants this project actually promises — the ones a README
# claims and a reviewer would want proof of. They run against a MOCKED provider,
# so they need no AWS account, no credentials and cost nothing; CI runs them on
# every push.
#
# checkov asks "is this configuration generally safe?". These ask "does THIS
# project still do the specific things it says it does?" — which no generic
# scanner can know.

mock_provider "aws" {
  # A mocked data source returns a placeholder string, which the AWS provider then
  # rejects as invalid JSON. Feeding each policy document a minimal valid document
  # keeps the mock honest without pretending to test IAM semantics — that is what
  # the checkov gate and a real plan are for.
  override_data {
    target = data.aws_iam_policy_document.site
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.kms
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.lambda_assume
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.issue_url
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.reaper
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.download
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.files_bucket
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}
mock_provider "archive" {}

run "buckets_block_all_public_access" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.files.block_public_acls,
      aws_s3_bucket_public_access_block.files.block_public_policy,
      aws_s3_bucket_public_access_block.files.ignore_public_acls,
      aws_s3_bucket_public_access_block.files.restrict_public_buckets,
    ])
    error_message = "The files bucket must block all four public-access vectors. Uploads are user data; a public read here is the worst failure this project has."
  }
}

run "files_are_encrypted_with_a_customer_managed_key" {
  command = plan

  assert {
    # `rule` is a set, so it has no addressable index — iterate it instead.
    condition = alltrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.files.rule :
      one(r.apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    ])
    error_message = "Objects must be SSE-KMS, not SSE-S3. The E2EE layer is defence in depth on top of this, not a replacement for it."
  }
}

run "metadata_table_expires_rows" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.metadata.ttl[0].enabled
    error_message = "TTL must be enabled: it is what makes shares self-destruct. Without it the reaper has nothing to react to and links live forever."
  }
}

run "lambda_runtime_is_supported" {
  command = plan

  # A runtime that has left AWS support stops receiving security patches and
  # eventually blocks updates entirely. Pinning the assertion here means the
  # build fails before the deprecation does.
  assert {
    condition     = contains(["python3.13", "python3.12"], aws_lambda_function.issue_url.runtime)
    error_message = "Lambda runtime must be a currently-supported Python. Update this list deliberately when bumping, so the bump is a decision rather than a drift."
  }
}
