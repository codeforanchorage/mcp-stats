# ─────────────────────────────────────────────────────────────────────────────
# Fleet probe: a scheduled Lambda that sends real MCP requests to every
# server in the fleet and alarms when one stops answering correctly.
#
# Why: every fleet bug found on 2026-11-07 (empty-POST 500s on 11 servers,
# -32603 on unknown methods, servers rejecting the 2026-07-28 probe) was found
# by hand-probing, after it had been live for weeks. The access-log 4xx
# alarms can't see these: a wrong JSON-RPC error inside an HTTP 200 looks
# healthy to them. This probe checks the answers, not just the status codes.
#
# Code: probe/fleet_probe.py (stdlib only; also runnable locally). It never
# calls tools/call, so it does not inflate the dashboard's "real usage"
# widgets or load upstream data APIs. Its log group is deliberately NOT
# tagged Project=mcp-server, so discovery.tf never folds it into the fleet.
#
# Targets: every fleet_waf_members host, plus fleet_probe_extra_targets
# (MCPs with no custom domain, e.g. Boston). Names in
# fleet_probe_legacy_only get the core checks only (up + serving tools) --
# for a server not yet on the 2026-07-28 revision.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  fleet_probe_targets = var.enable_fleet_probe ? merge(
    {
      for name, m in var.fleet_waf_members : name => {
        url    = "https://${m.host}/mcp"
        modern = !contains(var.fleet_probe_legacy_only, name)
      }
    },
    var.fleet_probe_extra_targets,
  ) : {}

  fleet_probe_name      = "mcp-fleet-probe"
  fleet_probe_namespace = "MCPFleet/Probe"
  fleet_probe_actions   = var.fleet_probe_notify ? [local.fleet_alarm_topic_arn] : []
}

data "archive_file" "fleet_probe" {
  count       = var.enable_fleet_probe ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/../../probe/fleet_probe.py"
  output_path = "${path.module}/.build/fleet_probe.zip"
}

resource "aws_iam_role" "fleet_probe" {
  count = var.enable_fleet_probe ? 1 : 0
  name  = "${local.fleet_probe_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fleet_probe" {
  count = var.enable_fleet_probe ? 1 : 0
  name  = "${local.fleet_probe_name}-policy"
  role  = aws_iam_role.fleet_probe[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.fleet_probe[0].arn}:*"
      },
      {
        # PutMetricData has no resource-level ARNs; pin it to our namespace.
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = local.fleet_probe_namespace } }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "fleet_probe" {
  count             = var.enable_fleet_probe ? 1 : 0
  name              = "/aws/lambda/${local.fleet_probe_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "fleet_probe" {
  count            = var.enable_fleet_probe ? 1 : 0
  function_name    = local.fleet_probe_name
  description      = "Probes every fleet MCP for health + MCP conformance; feeds MCPFleet/Probe alarms"
  role             = aws_iam_role.fleet_probe[0].arn
  runtime          = "python3.12"
  handler          = "fleet_probe.lambda_handler"
  filename         = data.archive_file.fleet_probe[0].output_path
  source_code_hash = data.archive_file.fleet_probe[0].output_base64sha256
  memory_size      = 128
  # Targets run in parallel, checks sequentially per target: worst case is
  # one target timing out on every check (8 x 25s). Typical run is ~6s.
  timeout = 240

  environment {
    variables = { PROBE_TARGETS = jsonencode(local.fleet_probe_targets) }
  }

  depends_on = [aws_cloudwatch_log_group.fleet_probe]
}

resource "aws_cloudwatch_event_rule" "fleet_probe" {
  count               = var.enable_fleet_probe ? 1 : 0
  name                = "${local.fleet_probe_name}-schedule"
  schedule_expression = var.fleet_probe_schedule
}

resource "aws_cloudwatch_event_target" "fleet_probe" {
  count = var.enable_fleet_probe ? 1 : 0
  rule  = aws_cloudwatch_event_rule.fleet_probe[0].name
  arn   = aws_lambda_function.fleet_probe[0].arn
}

resource "aws_lambda_permission" "fleet_probe" {
  count         = var.enable_fleet_probe ? 1 : 0
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fleet_probe[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.fleet_probe[0].arn
}

# One alarm per MCP. Two consecutive failing runs (~30 min at the default
# schedule) before it fires, so a single cold-start blip or transient
# upstream hiccup doesn't page. Missing data is NOT breaching here -- the
# heartbeat alarm below owns "the probe itself stopped running".
resource "aws_cloudwatch_metric_alarm" "fleet_probe_mcp" {
  for_each = local.fleet_probe_targets

  alarm_name          = "${each.key}-probe-failing"
  alarm_description   = "Fleet probe: ${each.key} (${each.value.url}) failed MCP checks on 2 consecutive runs. Failing check names + responses are in /aws/lambda/${local.fleet_probe_name} (filter level = 'ERROR' and mcp = '${each.key}')."
  namespace           = local.fleet_probe_namespace
  metric_name         = "FailedChecks"
  dimensions          = { MCP = each.key }
  statistic           = "Maximum"
  period              = var.fleet_probe_period_seconds
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.fleet_probe_actions
  ok_actions          = local.fleet_probe_actions
}

resource "aws_cloudwatch_metric_alarm" "fleet_probe_heartbeat" {
  count = var.enable_fleet_probe ? 1 : 0

  alarm_name          = "${local.fleet_probe_name}-not-running"
  alarm_description   = "The fleet probe Lambda has not completed a run in 2 periods -- it is erroring, timing out, or its schedule is disabled. Per-MCP probe alarms are blind until this clears."
  namespace           = local.fleet_probe_namespace
  metric_name         = "ProbeRuns"
  statistic           = "Sum"
  period              = var.fleet_probe_period_seconds
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.fleet_probe_actions
  ok_actions          = local.fleet_probe_actions
}
