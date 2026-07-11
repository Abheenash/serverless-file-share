data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------- issue-url: presign PUT + write metadata ----------

resource "aws_iam_role" "issue_url" {
  name               = "${var.name_prefix}-issue-url-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "issue_url_logs" {
  role       = aws_iam_role.issue_url.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "issue_url" {
  statement {
    sid       = "PutFilesOnly"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.files.arn}/files/*"]
  }
  statement {
    sid       = "WriteMetadataOnly"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.metadata.arn]
  }
  statement {
    sid       = "UseKmsViaS3Only"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "issue_url" {
  name   = "${var.name_prefix}-issue-url-inline"
  role   = aws_iam_role.issue_url.id
  policy = data.aws_iam_policy_document.issue_url.json
}

# ---------- reaper: delete object on TTL expiry ----------

resource "aws_iam_role" "reaper" {
  name               = "${var.name_prefix}-reaper-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "reaper_stream" {
  role       = aws_iam_role.reaper.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole"
}

data "aws_iam_policy_document" "reaper" {
  statement {
    sid       = "DeleteFilesOnly"
    actions   = ["s3:DeleteObject"]
    resources = ["${aws_s3_bucket.files.arn}/files/*"]
  }
  statement {
    sid       = "DeleteMetadataOnly"
    actions   = ["dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.metadata.arn]
  }
  statement {
    sid       = "SendToDLQ"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.reaper_dlq.arn]
  }
}

resource "aws_iam_role_policy" "reaper" {
  name   = "${var.name_prefix}-reaper-inline"
  role   = aws_iam_role.reaper.id
  policy = data.aws_iam_policy_document.reaper.json
}

# ---------- download: presign GET behind the API ----------

resource "aws_iam_role" "download" {
  name               = "${var.name_prefix}-download-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "download_logs" {
  role       = aws_iam_role.download.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "download" {
  statement {
    sid       = "ReadMetadataOnly"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.metadata.arn]
  }
  # Atomic check-and-increment of the download-count limit (Phase-1 level-up).
  statement {
    sid       = "CountDownloads"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.metadata.arn]
  }
  statement {
    sid       = "ReadFilesOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.files.arn}/files/*"]
  }
  statement {
    sid       = "DecryptViaS3Only"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
  # Best-effort "you were downloaded" notification, scoped to the one sender identity.
  statement {
    sid       = "NotifyUploader"
    actions   = ["ses:SendEmail"]
    resources = ["arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/${var.notify_sender}"]
  }
}

resource "aws_iam_role_policy" "download" {
  name   = "${var.name_prefix}-download-inline"
  role   = aws_iam_role.download.id
  policy = data.aws_iam_policy_document.download.json
}
