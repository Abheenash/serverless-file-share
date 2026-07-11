resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name_prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "serverless-file-share UI (terraform)"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "site-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "site-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Only this distribution may read the private site bucket.
data "aws_iam_policy_document" "site" {
  statement {
    sid     = "AllowCloudFrontOAC"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.site.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}

# UI objects. config.js is generated from the Terraform-managed API endpoint.
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  source       = "${path.module}/../web/index.html"
  etag         = filemd5("${path.module}/../web/index.html")
  content_type = "text/html"
}

resource "aws_s3_object" "app" {
  bucket       = aws_s3_bucket.site.id
  key          = "app.js"
  source       = "${path.module}/../web/app.js"
  etag         = filemd5("${path.module}/../web/app.js")
  content_type = "application/javascript"
}

resource "aws_s3_object" "config" {
  bucket       = aws_s3_bucket.site.id
  key          = "config.js"
  content      = "window.SFS_CONFIG = { apiBase: \"${aws_apigatewayv2_api.sfs.api_endpoint}\" };\n"
  content_type = "application/javascript"
}

# Client-side zero-knowledge crypto module (AES-256-GCM in the browser).
resource "aws_s3_object" "crypto" {
  bucket       = aws_s3_bucket.site.id
  key          = "sfs-crypto.js"
  source       = "${path.module}/../web/sfs-crypto.js"
  etag         = filemd5("${path.module}/../web/sfs-crypto.js")
  content_type = "application/javascript"
}

# Download landing page: fetches ciphertext + decrypts in the recipient's browser.
resource "aws_s3_object" "get_html" {
  bucket       = aws_s3_bucket.site.id
  key          = "get.html"
  source       = "${path.module}/../web/get.html"
  etag         = filemd5("${path.module}/../web/get.html")
  content_type = "text/html"
}

resource "aws_s3_object" "get_js" {
  bucket       = aws_s3_bucket.site.id
  key          = "get.js"
  source       = "${path.module}/../web/get.js"
  etag         = filemd5("${path.module}/../web/get.js")
  content_type = "application/javascript"
}

# Vendored QR-code generator (MIT) — served locally, no runtime CDN dependency.
resource "aws_s3_object" "qrcode" {
  bucket       = aws_s3_bucket.site.id
  key          = "vendor/qrcode.min.js"
  source       = "${path.module}/../web/vendor/qrcode.min.js"
  etag         = filemd5("${path.module}/../web/vendor/qrcode.min.js")
  content_type = "application/javascript"
}
