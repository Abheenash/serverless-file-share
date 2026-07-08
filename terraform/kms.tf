data "aws_iam_policy_document" "kms" {
  # Account admin manages the key (keeps IAM-based delegation working, avoids lockout).
  statement {
    sid     = "AccountAdminManagesKey"
    effect  = "Allow"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    resources = ["*"]
  }

  # issue-url may create data keys to encrypt uploads.
  statement {
    sid     = "IssueUrlRoleMayEncrypt"
    effect  = "Allow"
    actions = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.issue_url.arn]
    }
    resources = ["*"]
  }

  # download may decrypt for presigned GETs.
  statement {
    sid     = "DownloadRoleMayDecrypt"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:DescribeKey"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.download.arn]
    }
    resources = ["*"]
  }
}

resource "aws_kms_key" "sfs" {
  description             = "SSE-KMS key for serverless-file-share (terraform)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "sfs" {
  name          = "alias/${var.name_prefix}-key"
  target_key_id = aws_kms_key.sfs.key_id
}
