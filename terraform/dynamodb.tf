resource "aws_dynamodb_table" "metadata" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "fileId"

  attribute {
    name = "fileId"
    type = "S"
  }

  # TTL drives self-destruct; its expiry produces the stream REMOVE event.
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
}
