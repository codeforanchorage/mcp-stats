# ─────────────────────────────────────────────────────────────────────────────
# Account-wide CloudWatch dashboard spanning the whole MCP fleet.
#
# This is ADDITIVE — it does not touch any MCP's existing per-MCP dashboard.
# Every log widget re-runs its Logs Insights query on load (no stored data,
# no infrastructure in any request path), scanning the tag-discovered log
# groups from discovery.tf. As MCPs join or leave the fleet, the widgets
# widen/narrow on the next `terraform apply`.
#
# Log groups are passed inline in each widget's query as a pipe-chain of
# `SOURCE 'name'` clauses, with one more `|` separating the SOURCE list from
# the rest of the Logs Insights query:
#   SOURCE 'lg1' | SOURCE 'lg2' | … | fields …
# This is the AWS-documented format for dashboard log widgets (see
# "Dashboard Body Structure and Syntax" → log widget properties). The
# `logGroupNames` widget property is NOT a documented log-widget property
# and the renderer ignores it for routing — without inline SOURCE the
# StartQuery call goes out empty and the parser errors at `<EOF>`. The
# advanced `SOURCE logGroups(namePrefix: [...])` function form works via the
# raw StartQuery API but is rejected by the dashboard renderer's older
# parser, so don't use it here.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Pipe-chained `SOURCE 'lg1' | SOURCE 'lg2' | ...` prefix for log widgets.
  lambda_source = join(" | ", [for g in local.mcp_lambda_log_groups : "SOURCE '${g}'"])
  apigw_source  = join(" | ", [for g in local.mcp_apigw_log_groups : "SOURCE '${g}'"])

  # eBird is the one MCP with a hard UPSTREAM quota (see README "known gaps"):
  # it soft-gates at 900/day under eBird's 1000/day hard limit, per warm
  # container, resetting at UTC midnight. That ceiling — not AWS cost — is the
  # fleet's binding constraint, and eBird is the publicly-advertised server, so
  # it gets a dedicated "quota burn" widget. Scope it to just eBird's Lambda log
  # group, derived from the tag-discovered list so it still honours
  # var.environment. tools/call count is a PROXY for upstream eBird API calls
  # (one tool call ≈ one-or-more eBird requests; cached hits don't burn quota),
  # and the per-container reset means the fleet-wide daily total is an
  # approximation, not an exact remaining-quota gauge. If eBird isn't in the
  # discovered scope, ebird_quota_widgets is empty and the widget is omitted.
  ebird_lambda_log_groups = [for g in local.mcp_lambda_log_groups : g if length(regexall("ebird", g)) > 0]
  ebird_lambda_source     = join(" | ", [for g in local.ebird_lambda_log_groups : "SOURCE '${g}'"])

  ebird_quota_widgets = local.ebird_lambda_source == "" ? [] : [
    {
      type   = "log"
      x      = 0
      y      = 30
      width  = 24
      height = 6
      properties = {
        title   = "eBird upstream quota burn — tools/call per day (proxy for eBird API calls; soft-gate 900/day, hard limit 1000/day, per warm container, resets UTC midnight)"
        region  = var.aws_region
        view    = "timeSeries"
        stacked = false
        query = join("\n", [
          "${local.ebird_lambda_source}",
          "| filter jsonrpc_method = 'tools/call'",
          "| stats count(*) as ebird_api_calls by bin(1d)",
          "| sort @timestamp asc",
        ])
      }
    }
  ]
}

resource "aws_cloudwatch_dashboard" "fleet_usage" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = concat([
      # ── Row 1: fleet sessions + fleet unique clients ────────────────────
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Sessions per day — whole fleet (distinct mcp_session_id seen each day)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          query = join("\n", [
            "${local.lambda_source}",
            "| filter ispresent(mcp_session_id)",
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
            "${local.apigw_source}",
            "| fields @timestamp, coalesce(sourceIp, ip) as client_ip, concat(coalesce(sourceIp, ip), '|', coalesce(userAgent, '')) as client_key",
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
            "${local.lambda_source}",
            "| filter ispresent(mcp_session_id)",
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
            "${local.apigw_source}",
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
            "${local.lambda_source}",
            "| fields @log, jsonrpc_params.name as tool",
            "| filter jsonrpc_method = 'tools/call' and ispresent(tool)",
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
          title  = "MCP client family — whole fleet (clientInfo.name on initialize; excludes mcpregistry crawler)"
          region = var.aws_region
          view   = "bar"
          # The `mcpregistry` crawler accounts for ~40%+ of all initialize
          # handshakes (it connects, enumerates tools/list, and disconnects
          # without ever calling a tool), which drowns out real human clients.
          # Filter it out so this widget reflects actual client families.
          # NOTE: 'mcpregistry' is single-quoted = a literal string; double
          # quotes would be read as a FIELD reference and silently match nothing.
          query = join("\n", [
            "${local.lambda_source}",
            "| fields jsonrpc_params.clientInfo.name as client",
            "| filter jsonrpc_method = 'initialize'",
            "| filter client != 'mcpregistry'",
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
            "${local.apigw_source}",
            "| fields @log, coalesce(sourceIp, ip) as client_ip, userAgent",
            "| filter ispresent(client_ip)",
            "| stats count(*) as requests, count_distinct(userAgent) as distinct_uas, count_distinct(@log) as mcps_hit by client_ip",
            "| sort requests desc",
            "| limit 50",
          ])
        }
      },

      # ── Row 5: REAL usage — probes/handshakes stripped ──────────────────
      # The fleet's request/session/client widgets above are dominated by
      # discovery traffic: the `mcpregistry` crawler and anonymous scanners
      # connect, run initialize + tools/list, and leave without invoking a
      # tool — ~95% of Lambda activity at current volume. These two widgets
      # isolate genuine usage by keeping ONLY `tools/call`, which only a real
      # client driving the server ever emits.
      {
        type   = "log"
        x      = 0
        y      = 24
        width  = 12
        height = 6
        properties = {
          title   = "Real tool calls per day by MCP (jsonrpc_method=tools/call only — strips initialize/tools/list/ping handshake & crawler traffic)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          query = join("\n", [
            "${local.lambda_source}",
            "| filter jsonrpc_method = 'tools/call'",
            "| stats count(*) as tool_calls by bin(1d), @log",
            "| sort @timestamp asc",
          ])
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 24
        width  = 12
        height = 6
        properties = {
          # "Real user session" = a session that actually invoked a tool, i.e.
          # a distinct mcp_session_id appearing on at least one tools/call line.
          # Requires the session id to be present, so Boston (doesn't propagate
          # mcp_session_id) and Census (Node.js codebase, no jsonrpc_* fields)
          # under-count here — same gaps as the other Lambda-log widgets.
          title   = "Real user sessions per day by MCP (distinct mcp_session_id with ≥1 tools/call; Boston/Census under-count)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          query = join("\n", [
            "${local.lambda_source}",
            "| filter jsonrpc_method = 'tools/call' and ispresent(mcp_session_id)",
            "| stats count_distinct(mcp_session_id) as real_sessions by bin(1d), @log",
            "| sort @timestamp asc",
          ])
        }
      },
    ], local.ebird_quota_widgets)
  })

  # Fail fast with a clear message if tag-based discovery comes back empty —
  # otherwise the dashboard would apply with empty SOURCE prefixes and show
  # nothing.
  lifecycle {
    precondition {
      condition     = length(local.mcp_lambda_log_groups) > 0 || length(local.mcp_apigw_log_groups) > 0
      error_message = "Tag-based discovery found no log groups tagged Project=${var.project_tag}. Confirm the MCP repos have been applied and their log groups carry the tag."
    }
  }
}
