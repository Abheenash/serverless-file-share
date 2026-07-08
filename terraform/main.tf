data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  files_bucket = "${var.name_prefix}-files-${local.account_id}"
  site_bucket  = "${var.name_prefix}-site-${local.account_id}"
  table_name   = "${var.name_prefix}-metadata"
}
