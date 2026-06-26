# ─────────────────────────────────────────────────────────────────────────────
# Cross-MCP saved CloudWatch Logs Insights queries.
#
# These are the fleet-wide versions of the per-MCP queries in the eBird repo's
# "Tier 1 usage tracking" commit. Each one points at the tag-discovered log
# group list from discovery.tf, so the query set automatically widens as MCPs
# are added to / removed from the fleet.
#
# No new data is captured — every query reads log groups the MCPs already
# produce. Logs Insights scans against the existing (14–30 day) retention.
#
# Caveats baked in:
#   - Access-log schema is NOT uniform across the fleet. eBird and Anchorage
#     GIS emit `sourceIp` + `userAgent`; Boston and Census emit `ip` and no
#     `userAgent`. Queries normalise the IP with `coalesce(sourceIp, ip)`. The
#     userAgent-based "client" proxy degrades to IP-only for MCPs that omit it.
#   - "sessions" is per-connection (mcp_session_id minted on `initialize`),
#     not per-conversation. Clients reconnect routinely; expect overcounting.
#   - Census MCP runs a different (Node.js) codebase from the shared Python
#     `core/`. If its Lambda logs do not carry identical `jsonrpc_*` field
#     names, the Lambda-log queries simply return no rows for it — non-fatal.
#   - `@log` is CloudWatch's per-result log group identifier; it is how every
#     query below attributes a row to a specific MCP.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_query_definition" "sessions_per_day" {
  name            = "mcp-fleet/usage/sessions-per-day"
  log_group_names = local.mcp_lambda_log_groups

  # `mcp_session_id` is minted DURING the `initialize` handshake, so the
  # initialize log line itself doesn't carry one. We instead count distinct
  # session IDs across ALL log lines per day — i.e. "active sessions per
  # day", which is the load metric anyone glancing at this actually wants.
  query_string = <<-EOT
    filter ispresent(mcp_session_id)
    | stats count_distinct(mcp_session_id) as sessions by bin(1d), @log
    | sort @timestamp asc
  EOT
}

resource "aws_cloudwatch_query_definition" "unique_clients_per_day" {
  name            = "mcp-fleet/usage/unique-clients-per-day"
  log_group_names = local.mcp_apigw_log_groups

  # `userAgent` is absent on some MCPs' access logs, so client_key collapses
  # to the IP there; unique_ips is the schema-independent lower bound.
  query_string = <<-EOT
    fields @timestamp,
           coalesce(sourceIp, ip) as client_ip,
           concat(coalesce(sourceIp, ip), '|', coalesce(userAgent, '')) as client_key
    | filter ispresent(client_ip)
    | stats count_distinct(client_key) as unique_clients,
            count_distinct(client_ip) as unique_ips
            by bin(1d)
    | sort @timestamp asc
  EOT
}

resource "aws_cloudwatch_query_definition" "client_family_breakdown" {
  name            = "mcp-fleet/usage/client-family-breakdown"
  log_group_names = local.mcp_lambda_log_groups

  # The `mcpregistry` crawler accounts for ~40%+ of all initialize handshakes
  # (it connects, enumerates tools/list, and disconnects without ever calling a
  # tool), drowning out real human clients — so it is filtered out here to match
  # the dashboard's client-family widget. 'mcpregistry' is single-quoted = a
  # literal string; double quotes would be read as a FIELD reference and
  # silently match nothing.
  query_string = <<-EOT
    fields @timestamp,
           jsonrpc_params.clientInfo.name as client,
           jsonrpc_params.clientInfo.version as version
    | filter jsonrpc_method = 'initialize'
    | filter client != 'mcpregistry'
    | stats count(*) as initializes by client, version
    | sort initializes desc
  EOT
}

# "Real usage" — probes/handshakes stripped. The fleet's sessions/clients/
# request widgets are dominated by discovery traffic (the `mcpregistry` crawler
# and anonymous scanners run initialize + tools/list and leave without invoking
# a tool — ~95% of Lambda activity at current volume). These two queries keep
# ONLY `tools/call`, which only a real client driving the server ever emits, so
# they isolate genuine adoption from crawler noise. They mirror the dashboard's
# "Row 5" real-usage widgets.
resource "aws_cloudwatch_query_definition" "real_tool_calls_per_day" {
  name            = "mcp-fleet/usage/real-tool-calls-per-day"
  log_group_names = local.mcp_lambda_log_groups

  query_string = <<-EOT
    filter jsonrpc_method = 'tools/call'
    | stats count(*) as tool_calls by bin(1d), @log
    | sort @timestamp asc
  EOT
}

resource "aws_cloudwatch_query_definition" "real_user_sessions_per_day" {
  name            = "mcp-fleet/usage/real-user-sessions-per-day"
  log_group_names = local.mcp_lambda_log_groups

  # A "real user session" is a session that actually invoked a tool — i.e. a
  # distinct mcp_session_id appearing on at least one tools/call line. Requires
  # the session id to be present, so Boston (doesn't propagate mcp_session_id)
  # and Census (Node.js codebase, no jsonrpc_* fields) under-count here, the
  # same gaps as the other Lambda-log queries.
  query_string = <<-EOT
    filter jsonrpc_method = 'tools/call' and ispresent(mcp_session_id)
    | stats count_distinct(mcp_session_id) as real_sessions by bin(1d), @log
    | sort @timestamp asc
  EOT
}

resource "aws_cloudwatch_query_definition" "tool_popularity_by_mcp" {
  name            = "mcp-fleet/usage/tool-popularity-by-mcp"
  log_group_names = local.mcp_lambda_log_groups

  query_string = <<-EOT
    fields @timestamp, @log, jsonrpc_params.name as tool
    | filter jsonrpc_method = 'tools/call' and ispresent(tool)
    | stats count(*) as calls by @log, tool
    | sort calls desc
  EOT
}

resource "aws_cloudwatch_query_definition" "top_source_ips" {
  name            = "mcp-fleet/usage/top-source-ips"
  log_group_names = local.mcp_apigw_log_groups

  query_string = <<-EOT
    fields @log, coalesce(sourceIp, ip) as client_ip, userAgent
    | filter ispresent(client_ip)
    | stats count(*) as requests,
            count_distinct(userAgent) as distinct_uas,
            count_distinct(@log) as mcps_hit
            by client_ip
    | sort requests desc
    | limit 50
  EOT
}
