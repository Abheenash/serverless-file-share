resource "aws_apigatewayv2_api" "sfs" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.site.domain_name}"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 3000
  }
}

resource "aws_apigatewayv2_integration" "issue_url" {
  api_id                 = aws_apigatewayv2_api.sfs.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.issue_url.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_files" {
  api_id    = aws_apigatewayv2_api.sfs.id
  route_key = "POST /files"
  target    = "integrations/${aws_apigatewayv2_integration.issue_url.id}"
}

resource "aws_apigatewayv2_integration" "download" {
  api_id                 = aws_apigatewayv2_api.sfs.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.download.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_file" {
  api_id    = aws_apigatewayv2_api.sfs.id
  route_key = "GET /files/{fileId}"
  target    = "integrations/${aws_apigatewayv2_integration.download.id}"
}

# POST resolves the download: validates password + download-count limit, fires
# the optional notification, and returns a presigned URL. (Same download Lambda.)
resource "aws_apigatewayv2_route" "post_file" {
  api_id    = aws_apigatewayv2_api.sfs.id
  route_key = "POST /files/{fileId}"
  target    = "integrations/${aws_apigatewayv2_integration.download.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.sfs.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 5
    throttling_rate_limit  = 2
  }

  # Stage C hardening (the free alternative to AWS WAF): throttle the write
  # route hard — an open upload endpoint is the abuse vector for free storage —
  # while keeping the read/resolve routes comfortable for real recipients.
  route_settings {
    route_key              = "POST /files"
    throttling_rate_limit  = 1
    throttling_burst_limit = 3
  }
  route_settings {
    route_key              = "GET /files/{fileId}"
    throttling_rate_limit  = 5
    throttling_burst_limit = 10
  }
  route_settings {
    route_key              = "POST /files/{fileId}"
    throttling_rate_limit  = 5
    throttling_burst_limit = 10
  }
}
