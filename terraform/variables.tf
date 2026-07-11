variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name. Defaults to 'sfs-tf' so a Terraform-managed environment stays isolated from the CLI-built stack (Stages 1-4)."
  type        = string
  default     = "sfs-tf"
}

variable "max_file_lifetime_days" {
  description = "Cap on a file's lifetime; the S3 lifecycle backstop expires objects one day past this."
  type        = number
  default     = 7
}

variable "alarm_email" {
  description = "Email to subscribe to the alarms SNS topic. Empty = no subscription (confirmation is manual)."
  type        = string
  default     = ""
}

variable "notify_sender" {
  description = "From-address for 'your file was downloaded' notifications. Must belong to a verified SES identity (see notify_identity)."
  type        = string
  default     = "no-reply@abheenash.com"
}

variable "notify_identity" {
  description = "The verified SES identity (domain or email) that authorizes notify_sender. Domain identity lets you send from any address on it."
  type        = string
  default     = "abheenash.com"
}
