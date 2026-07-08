output "api_endpoint" {
  description = "Base URL of the HTTP API."
  value       = aws_apigatewayv2_api.sfs.api_endpoint
}

output "cloudfront_url" {
  description = "Public HTTPS URL of the web UI."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "files_bucket" {
  value = aws_s3_bucket.files.id
}

output "metadata_table" {
  value = aws_dynamodb_table.metadata.name
}

output "kms_key_arn" {
  value = aws_kms_key.sfs.arn
}
