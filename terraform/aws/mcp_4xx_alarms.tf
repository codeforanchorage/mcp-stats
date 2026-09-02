# ─────────────────────────────────────────────────────────────────────────────
# Fleet-wide "MCP endpoint 4xx" alarms — one per discovered API Gateway access
# log group, built from a metric filter that counts ONLY 4xx responses on
# `POST /mcp`.
#
# WHY THIS EXISTS
# Each MCP repo ships an `<mcp>-<env>-apigw-4xx-probing` alarm on the raw
# `AWS/ApiGateway 4XXError` metric (>= 100 per 5 min). That metric counts every
# 4xx the gateway emits, and the overwhelming majority are web-vulnerability
# scanners walking `/.env`, `/.git/config`, `/wp-json`, ... against the
# hostname. API Gateway answers those with 403 at the edge — nothing but
# `POST /mcp` is routed to Lambda — so every one of those alarm firings
# (11 in Aug 2026, ~277 requests each from a fresh cloud IP) was noise that
# never touched MCP code. Only a 4xx on the MCP route itself says anything
# about a client misusing, probing, or being rate-limited on a server.
#
# Two further reasons this lives here rather than in the MCP repos:
#   * A metric filter attaches to the LOG GROUP, which discovery.tf already
#     enumerates for the whole fleet. One apply covers every MCP, and a newly
#     onboarded MCP is picked up on the next plan with no repo change — the
#     same zero-coupling model as the dashboard and saved queries.
#   * Only ONE of the per-repo alarms (anchorage-gis) actually has an SNS
#     action wired; the rest fire silently. The fleet topic below gives every
#     MCP the same delivery path.
#
# WHAT IS COUNTED
# Access-log lines are JSON with `status` logged as a STRING ("403"), so the
# pattern matches on the "4*" prefix rather than a numeric range. Boston and
# Census log `ip` instead of `sourceIp` and omit `userAgent`, but every MCP
# emits `httpMethod`, `resourcePath` and `status`, so one pattern covers all.
# 429s (WAF/usage-plan throttles that reach the gateway) count too — a burst
# of those is exactly the "abusive client" signal the old alarm wanted.
#
# Metric filters only see log events written AFTER the filter is created;
# there is no backfill. Verify a new filter with `aws logs test-metric-filter`
# rather than by waiting for the metric to appear.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # `/aws/apigateway/<mcp>-<env>-access` -> `<mcp>-<env>`, matching the
  # `local.lambda_name` each repo uses to name its own alarms.
  mcp_4xx_alarm_targets = var.enable_mcp_4xx_alarms ? {
    for n in local.mcp_apigw_log_groups :
    regex("^/aws/apigateway/(.+)-access$", n)[0] => n
  } : {}

  mcp_4xx_metric_namespace = "MCPFleet/ApiGateway"

  # Either the caller-supplied topic or the one created below.
  fleet_alarm_topic_arn = var.fleet_alarm_sns_topic_arn != "" ? var.fleet_alarm_sns_topic_arn : one(aws_sns_topic.fleet_alarms[*].arn)
}

# ─── Delivery ───────────────────────────────────────────────────────────────

resource "aws_sns_topic" "fleet_alarms" {
  count = var.fleet_alarm_sns_topic_arn == "" ? 1 : 0

  name = var.fleet_alarm_sns_topic_name

  tags = {
    Project = var.project_tag
  }
}

# Email subscriptions must be confirmed by clicking the link SNS sends; until
# then the subscription sits in PendingConfirmation and delivers nothing.
resource "aws_sns_topic_subscription" "fleet_alarm_email" {
  count = var.fleet_alarm_sns_topic_arn == "" && var.fleet_alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.fleet_alarms[0].arn
  protocol  = "email"
  endpoint  = var.fleet_alarm_email
}

# ─── Metric filters + alarms ────────────────────────────────────────────────

resource "aws_cloudwatch_log_metric_filter" "mcp_post_4xx" {
  for_each = local.mcp_4xx_alarm_targets

  name           = "${each.key}-mcp-post-4xx"
  log_group_name = each.value
  pattern        = "{ ($.httpMethod = \"POST\") && ($.resourcePath = \"/mcp\") && ($.status = \"4*\") }"

  metric_transformation {
    name          = "${each.key}-mcp-post-4xx"
    namespace     = local.mcp_4xx_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "mcp_post_4xx" {
  for_each = local.mcp_4xx_alarm_targets

  alarm_name        = "${each.key}-mcp-post-4xx"
  alarm_description = "Elevated 4xx on POST /mcp for ${each.key} — client misuse, probing of the MCP route, or rate limiting. Edge 403s from path scanners are excluded."

  namespace           = local.mcp_4xx_metric_namespace
  metric_name         = aws_cloudwatch_log_metric_filter.mcp_post_4xx[each.key].metric_transformation[0].name
  statistic           = "Sum"
  period              = var.mcp_4xx_alarm_period_seconds
  evaluation_periods  = 1
  threshold           = var.mcp_4xx_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [local.fleet_alarm_topic_arn]
  ok_actions    = [local.fleet_alarm_topic_arn]

  tags = {
    Project = var.project_tag
  }
}
