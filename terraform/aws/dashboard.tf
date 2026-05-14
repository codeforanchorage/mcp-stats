# ─────────────────────────────────────────────────────────────────────────────
# Account-wide CloudWatch dashboard spanning the whole MCP fleet.
#
# This is ADDITIVE — it does not touch any MCP's existing per-MCP dashboard.
# Every log widget re-runs its Logs Insights query on load (no stored data,
# no infrastructure in any request path), scanning the tag-discovered log
# groups from discovery.tf. As MCPs join or leave the fleet, the widgets
# widen/narrow on the next `terraform apply`.
#
# A Logs Insights `SOURCE` directive accepts multiple space-separated quoted
# log group names; the locals below build those clauses from discovery.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # `SOURCE 'lg1' 'lg2' ...` clauses for log widgets.
  lambda_source = "SOURCE ${join(" ", [for g in local.mcp_lambda_log_groups : "'${g}'"])}"
  apigw_source  = "SOURCE ${join(" ", [for g in local.mcp_apigw_log_groups : "'${g}'"])}"
}

resource "aws_cloudwatch_dashboard" "fleet_usage" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      # ── Row 1: fleet sessions + fleet unique clients ────────────────────
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Sessions per day — whole fleet (distinct mcp_session_id on initialize)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          query = join("\n", [
            local.lambda_source,
            "| fields @timestamp, mcp_session_id, jsonrpc_method",
            "| filter jsonrpc_method = \"initialize\" and ispresent(mcp_session_id)",
            "| stats count_distinct(mcp_session_id) as sessions by bin(1d)",
            "| sort @timestamp asc",
          ])
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Unique clients per day — fleet (sourceIp/ip; userAgent where present)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          query = join("\n", [
            local.apigw_source,
            "| fields @timestamp, coalesce(sourceIp, ip) as client_ip, concat(coalesce(sourceIp, ip), \"|\", coalesce(userAgent, \"\")) as client_key",
            "| filter ispresent(client_ip)",
            "| stats count_distinct(client_key) as unique_clients, count_distinct(client_ip) as unique_ips by bin(1d)",
            "| sort @timestamp asc",
          ])
        }
      },

      # ── Row 2: per-MCP sessions + per-MCP request volume ────────────────
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Sessions per day, broken down by MCP"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          query = join("\n", [
            local.lambda_source,
            "| fields @timestamp, @log, mcp_session_id, jsonrpc_method",
            "| filter jsonrpc_method = \"initialize\" and ispresent(mcp_session_id)",
            "| stats count_distinct(mcp_session_id) as sessions by bin(1d), @log",
            "| sort @timestamp asc",
          ])
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Request volume by MCP (API Gateway access log lines)"
          region = var.aws_region
          view   = "bar"
          query = join("\n", [
            local.apigw_source,
            "| stats count(*) as requests by @log",
            "| sort requests desc",
          ])
        }
      },

      # ── Row 3: tool popularity by MCP + client family ───────────────────
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Tool popularity by MCP (tools/call by tool name)"
          region = var.aws_region
          view   = "table"
          query = join("\n", [
            local.lambda_source,
            "| fields @log, jsonrpc_params.name as tool",
            "| filter jsonrpc_method = \"tools/call\" and ispresent(tool)",
            "| stats count(*) as calls by @log, tool",
            "| sort calls desc",
          ])
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "MCP client family — whole fleet (clientInfo.name on initialize)"
          region = var.aws_region
          view   = "bar"
          query = join("\n", [
            local.lambda_source,
            "| fields jsonrpc_params.clientInfo.name as client",
            "| filter jsonrpc_method = \"initialize\"",
            "| stats count(*) as initializes by client",
            "| sort initializes desc",
          ])
        }
      },

      # ── Row 4: top source IPs across the fleet ──────────────────────────
      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          title  = "Top source IPs across the fleet (last selected window) — watch for abuse"
          region = var.aws_region
          view   = "table"
          query = join("\n", [
            local.apigw_source,
            "| fields @log, coalesce(sourceIp, ip) as client_ip, userAgent",
            "| filter ispresent(client_ip)",
            "| stats count(*) as requests, count_distinct(userAgent) as distinct_uas, count_distinct(@log) as mcps_hit by client_ip",
            "| sort requests desc",
            "| limit 50",
          ])
        }
      },
    ]
  })

  # Fail fast with a clear message if tag-based discovery comes back empty —
  # otherwise the dashboard would apply with empty SOURCE clauses and show
  # nothing.
  lifecycle {
    precondition {
      condition     = length(local.mcp_lambda_log_groups) > 0 || length(local.mcp_apigw_log_groups) > 0
      error_message = "Tag-based discovery found no log groups tagged Project=${var.project_tag}. Confirm the MCP repos have been applied and their log groups carry the tag."
    }
  }
}
