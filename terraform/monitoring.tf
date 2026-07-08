# Reaper reliability: a dead-letter queue for stream records the reaper fails to
# process, plus an alarm so a failed self-destruct can't vanish silently.

resource "aws_sqs_queue" "reaper_dlq" {
  name                      = "${var.name_prefix}-reaper-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"
}

# Email subscription requires manual confirmation, so it's opt-in via a variable.
resource "aws_sns_topic_subscription" "alarms_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "reaper_errors" {
  alarm_name          = "${var.name_prefix}-reaper-errors"
  alarm_description   = "reaper Lambda failed to delete an expired file"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.reaper.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}
