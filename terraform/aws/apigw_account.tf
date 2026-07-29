# ─────────────────────────────────────────────────────────────────────────────
# Account-level API Gateway CloudWatch logging role, owned by the fleet.
#
# `aws_api_gateway_account` is an ACCOUNT+REGION-LEVEL SINGLETON: AWS stores
# exactly one CloudWatch role ARN for all of API Gateway in us-west-2. Every MCP
# repo used to declare it and point it at its own `<mcp>-prod-apigw-cloudwatch`
# role, which created two problems:
#
#   1. Whichever repo applied last won. Nine of the eleven repos had
#      `ignore_changes = [cloudwatch_role_arn]` to stop the churn, but eBird and
#      Census did not, so those two flipped the account back and forth and
#      showed a spurious diff on every plan.
#
#   2. More seriously, the account pointed at ONE MCP's role — Census's, as of
#      the WAF migration. Deleting that single MCP's IAM role would have
#      silently broken API Gateway access logging for the ENTIRE fleet,
#      including the log groups the mcp-stats dashboard reads.
#
# Owning it here fixes both: the role belongs to the fleet rather than to any
# one MCP, and exactly one Terraform state manages the singleton. Note there is
# deliberately NO `ignore_changes` here — this config is the authority, so a
# drift should be corrected, not ignored.
#
# ORDERING: a brand-new MCP's API Gateway stage needs the account-level role to
# already exist before it can write access logs. That is satisfied as long as
# this stack is applied before a new MCP's first deploy — same prerequisite the
# shared WAF has (see shared_waf.tf and docs/waf-consolidation.md).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "apigw_cloudwatch" {
  name = var.apigw_account_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = var.project_tag
  }
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "fleet" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn

  # The attachment must land before API Gateway will accept the role — it
  # validates that the role is assumable and has the push-to-logs policy.
  depends_on = [aws_iam_role_policy_attachment.apigw_cloudwatch]
}
