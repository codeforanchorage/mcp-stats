# ─────────────────────────────────────────────────────────────────────────────
# Tag-based discovery of MCP fleet log groups.
#
# This is the single reusable discovery layer for the whole project. Phase 1
# (the dashboard + saved queries in dashboard.tf / queries.tf) consumes the
# locals defined here. Phase 2 (CloudWatch subscription filters → Firehose →
# S3 → Athena) will consume the EXACT SAME locals — so keep all discovery
# logic here and never re-derive the log group list anywhere else.
#
# Mechanism note: the `aws_cloudwatch_log_groups` data source filters by name
# prefix only, NOT by tag. Tag-based discovery therefore must go through the
# Resource Groups Tagging API. Every MCP repo tags both its Lambda log group
# and its API Gateway access log group with `Project = mcp-server`; that is
# the only coupling between this project and the MCP repos.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_resourcegroupstaggingapi_resources" "mcp_log_groups" {
  resource_type_filters = ["logs:log-group"]

  tag_filter {
    key    = "Project"
    values = [var.project_tag]
  }
}

locals {
  # Resource ARNs returned by the tagging API, e.g.
  #   arn:aws:logs:<region>:<account-id>:log-group:/aws/lambda/ebird-mcp
  # Log group ARNs sometimes carry a trailing ":*" — strip it so the values
  # are usable as plain log group names by query definitions and dashboards.
  _mcp_log_group_arns = [
    for r in data.aws_resourcegroupstaggingapi_resources.mcp_log_groups.resource_tag_mapping_list :
    r.resource_arn
  ]

  _mcp_log_group_names = [
    for arn in local._mcp_log_group_arns :
    trimsuffix(split(":log-group:", arn)[1], ":*")
  ]

  # Split the discovered groups by the fleet's naming convention:
  #   /aws/lambda/<name>            — JSON Lambda logs (mcp_session_id,
  #                                   jsonrpc_method, jsonrpc_params.*)
  #   /aws/apigateway/<name>-access — API Gateway access logs (sourceIp/ip,
  #                                   userAgent where present)
  # Sorted so plan output is stable regardless of tagging-API ordering.
  mcp_lambda_log_groups = sort([
    for n in local._mcp_log_group_names : n if startswith(n, "/aws/lambda/")
  ])

  mcp_apigw_log_groups = sort([
    for n in local._mcp_log_group_names : n if startswith(n, "/aws/apigateway/")
  ])
}
