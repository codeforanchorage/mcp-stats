output "dashboard_name" {
  description = "Name of the account-wide MCP fleet dashboard."
  value       = aws_cloudwatch_dashboard.fleet_usage.dashboard_name
}

output "dashboard_url" {
  description = "Console URL for the account-wide MCP fleet usage dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.fleet_usage.dashboard_name}"
}

output "discovered_lambda_log_groups" {
  description = "Lambda log groups discovered via the Project tag — the fleet's MCP servers."
  value       = local.mcp_lambda_log_groups
}

output "discovered_apigw_log_groups" {
  description = "API Gateway access log groups discovered via the Project tag."
  value       = local.mcp_apigw_log_groups
}

output "discovered_mcp_count" {
  description = "Number of MCPs discovered (by Lambda log group count)."
  value       = length(local.mcp_lambda_log_groups)
}

output "fleet_waf_arn" {
  description = "ARN of the shared fleet WAFv2 web ACL, or null when enable_fleet_waf is false."
  value       = one(aws_wafv2_web_acl.fleet[*].arn)
}

output "fleet_waf_ssm_parameter" {
  description = "SSM path where the shared web ACL ARN is published for the MCP repos to read."
  value       = one(aws_ssm_parameter.fleet_waf_arn[*].name)
}

output "fleet_waf_members" {
  description = "MCPs covered by a dedicated Host-scoped rate rule in the shared web ACL, with their limits."
  value       = { for k, v in var.fleet_waf_members : k => v.rate_limit_per_5min }
}

output "saved_query_names" {
  description = "Names of the cross-MCP saved Logs Insights queries created by this project."
  value = [
    aws_cloudwatch_query_definition.sessions_per_day.name,
    aws_cloudwatch_query_definition.unique_clients_per_day.name,
    aws_cloudwatch_query_definition.client_family_breakdown.name,
    aws_cloudwatch_query_definition.tool_popularity_by_mcp.name,
    aws_cloudwatch_query_definition.top_source_ips.name,
    aws_cloudwatch_query_definition.real_tool_calls_per_day.name,
    aws_cloudwatch_query_definition.real_user_sessions_per_day.name,
    aws_cloudwatch_query_definition.real_server_errors.name,
    aws_cloudwatch_query_definition.real_server_errors_per_day.name,
    aws_cloudwatch_query_definition.protocol_rejections.name,
  ]
}

output "fleet_alarm_topic_arn" {
  description = "SNS topic the fleet MCP-route 4xx alarms notify (created here unless fleet_alarm_sns_topic_arn was supplied)."
  value       = local.fleet_alarm_topic_arn
}

output "mcp_4xx_alarm_names" {
  description = "Names of the per-MCP `POST /mcp` 4xx alarms, one per discovered access log group."
  value       = sort([for a in aws_cloudwatch_metric_alarm.mcp_post_4xx : a.alarm_name])
}
