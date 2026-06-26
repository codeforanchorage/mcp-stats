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
  ]
}
