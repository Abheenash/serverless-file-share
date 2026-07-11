# Package each function straight from src/ at plan time.

data "archive_file" "issue_url" {
  type        = "zip"
  source_file = "${path.module}/../src/issue_url/lambda_function.py"
  output_path = "${path.module}/build/issue_url.zip"
}

data "archive_file" "reaper" {
  type        = "zip"
  source_file = "${path.module}/../src/reaper/lambda_function.py"
  output_path = "${path.module}/build/reaper.zip"
}

data "archive_file" "download" {
  type        = "zip"
  source_file = "${path.module}/../src/download/lambda_function.py"
  output_path = "${path.module}/build/download.zip"
}

resource "aws_lambda_function" "issue_url" {
  function_name    = "${var.name_prefix}-issue-url"
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  role             = aws_iam_role.issue_url.arn
  filename         = data.archive_file.issue_url.output_path
  source_code_hash = data.archive_file.issue_url.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      BUCKET = aws_s3_bucket.files.id
      TABLE  = aws_dynamodb_table.metadata.name
    }
  }
}

resource "aws_lambda_function" "reaper" {
  function_name    = "${var.name_prefix}-reaper"
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  role             = aws_iam_role.reaper.arn
  filename         = data.archive_file.reaper.output_path
  source_code_hash = data.archive_file.reaper.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      BUCKET = aws_s3_bucket.files.id
    }
  }
}

resource "aws_lambda_function" "download" {
  function_name    = "${var.name_prefix}-download"
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  role             = aws_iam_role.download.arn
  filename         = data.archive_file.download.output_path
  source_code_hash = data.archive_file.download.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      BUCKET     = aws_s3_bucket.files.id
      TABLE      = aws_dynamodb_table.metadata.name
      SES_SENDER = var.notify_sender
    }
  }
}

# Stream -> reaper, filtered to REMOVE events only.
resource "aws_lambda_event_source_mapping" "reaper" {
  event_source_arn       = aws_dynamodb_table.metadata.stream_arn
  function_name          = aws_lambda_function.reaper.arn
  starting_position      = "LATEST"
  batch_size             = 10
  maximum_retry_attempts = 3

  filter_criteria {
    filter {
      pattern = jsonencode({ eventName = ["REMOVE"] })
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.reaper_dlq.arn
    }
  }
}

# Let API Gateway invoke the two HTTP-facing functions.
resource "aws_lambda_permission" "issue_url_api" {
  statement_id  = "apigw-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.issue_url.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.sfs.execution_arn}/*/*/files"
}

resource "aws_lambda_permission" "download_api" {
  statement_id  = "apigw-invoke-download"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.download.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.sfs.execution_arn}/*/*/files/*"
}
