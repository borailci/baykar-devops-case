# CloudWatch log group for cluster + app logs
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/eks/${var.cluster_name}/mern"
  retention_in_days = 14
}

# Fluent Bit to CloudWatch via the official EKS chart
resource "helm_release" "fluent_bit" {
  name             = "aws-for-fluent-bit"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-for-fluent-bit"
  namespace        = "amazon-cloudwatch"
  create_namespace = true
  version          = "0.1.34"

  set {
    name  = "cloudWatchLogs.enabled"
    value = "true"
  }
  set {
    name  = "cloudWatchLogs.region"
    value = var.region
  }
  set {
    name  = "cloudWatchLogs.logGroupName"
    value = aws_cloudwatch_log_group.eks.name
  }
  set {
    name  = "cloudWatchLogs.autoCreateGroup"
    value = "false"
  }

  depends_on = [module.eks]
}

# SNS topic for critical alarms
resource "aws_sns_topic" "alarms" {
  name = "${var.cluster_name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Alarm: high ALB 5xx rate (set after ALB exists; threshold tuned for low-traffic demo)
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.cluster_name}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 60
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALB returned >5 5xx in 2 consecutive minutes"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# Alarm: pod restart spike via container insights metric
resource "aws_cloudwatch_metric_alarm" "pod_restarts" {
  alarm_name          = "${var.cluster_name}-pod-restarts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  statistic           = "Maximum"
  threshold           = 3
  treat_missing_data  = "notBreaching"
  alarm_description   = "A pod restarted more than 3 times in 5 minutes"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  dimensions = {
    ClusterName = module.eks.cluster_name
  }
}
