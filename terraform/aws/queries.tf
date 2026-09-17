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
#     The opposite bias applies on dual-era cores (Anchorage GIS since
#     2026-09-17): the stateless MCP 2026-07-28 revision has NO session id,
#     and claude.ai / claude-code use it whenever the server offers it, so
#     every mcp_session_id-based query silently drops those sessions. Use
#     tools/call counts and `client-family-breakdown` (which counts session
#     opens in both eras) for those MCPs.
#   - Census MCP runs a different (Node.js) codebase from the shared Python
#     `core/`. If its Lambda logs do not carry identical `jsonrpc_*` field
#     names, the Lambda-log queries simply return no rows for it — non-fatal.
#   - `@log` is CloudWatch's per-result log group identifier; it is how every
#     query below attributes a row to a specific MCP.
#   - The shared Python `core/` logs TWO lines per JSON-RPC call — "request
#     received" (has jsonrpc_params) and "request processed" (has
#     jsonrpc_result). Any count(*) over a jsonrpc_method filter doubles
#     unless it also requires ispresent(jsonrpc_params.name) (tools/call) or
#     another request-only field. count_distinct() is immune.
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

  # Counts SESSION OPENS in both protocol eras: `initialize` (legacy
  # handshake, revisions <= 2025-11-25) and `server/discover` (the stateless
  # 2026-07-28 revision, no handshake). Dual-era cores (Anchorage GIS since
  # 2026-09-17) serve both, and claude.ai / claude-code open with
  # server/discover against them and never send initialize again — an
  # initialize-only query loses those clients MCP by MCP as the core rolls out.
  # Client identity comes from the flattened `mcp_client_name` /
  # `mcp_client_version` fields (stamped on every "request received" line by
  # dual-era cores, both eras) with a fallback to jsonrpc_params.clientInfo.*
  # for older cores that only carry it inside the initialize params. The
  # message filter keeps the request line of each request/response pair.
  # The `mcpregistry` crawler accounts for ~40%+ of all handshakes (it
  # connects, enumerates tools/list, and disconnects without ever calling a
  # tool), drowning out real human clients — so it is filtered out here to match
  # the dashboard's client-family widget. 'mcpregistry' is single-quoted = a
  # literal string; double quotes would be read as a FIELD reference and
  # silently match nothing.
  query_string = <<-EOT
    fields @timestamp,
           coalesce(mcp_client_name, jsonrpc_params.clientInfo.name) as client,
           coalesce(mcp_client_version, jsonrpc_params.clientInfo.version) as version
    | filter jsonrpc_method in ['initialize', 'server/discover']
    | filter message = 'JSON-RPC request received' and ispresent(client)
    | filter client != 'mcpregistry'
    | stats count(*) as session_opens by client, version
    | sort session_opens desc
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

  # The shared Python core logs TWO lines per JSON-RPC call (request +
  # response), both carrying jsonrpc_method — a bare count(*) doubles. Only
  # the request line has jsonrpc_params.name, so filtering on it counts each
  # call once. (Census logs a single line that also carries the field, so the
  # filter is a no-op there.)
  query_string = <<-EOT
    filter jsonrpc_method = 'tools/call' and ispresent(jsonrpc_params.name)
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
  # same gaps as the other Lambda-log queries. So do dual-era cores (Anchorage
  # GIS since 2026-09-17): 2026-07-28-era sessions carry no session id at all.
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

# ─────────────────────────────────────────────────────────────────────────────
# Error triage — client-fault rejections vs real server faults.
#
# Nearly all of the fleet's WARNING/ERROR volume is a well-behaved client
# being told "no", not the server breaking. Over a representative 7-day
# window: 363 WARNING/ERROR lines fleet-wide, of which 358 were protocol
# rejections and only 5 were genuine server faults. Anything that reads raw
# error level as a health signal is therefore reading ~99% noise.
#
# Two rejections dominate, and which one an MCP shows depends on its core:
#   - `400 unsupported MCP-Protocol-Version '2026-07-28'` — the newer shared
#     core (2026-08-24+) validates the protocol-version header and does not
#     list 2026-07-28, so the FIRST request of every Claude.ai / claude-code
#     session gets a 400, then the client retries with an older version ~1s
#     later and succeeds. ~636 of these fleet-wide over 2026-09-03..17, about
#     15% of all POST /mcp. Not user-breaking, but it is a core regression to
#     fix; `protocol_version_400s_per_day` below tracks it so the fix can be
#     confirmed as the count drops to zero MCP by MCP. The fix is the
#     dual-era core (serves 2026-07-28 statelessly alongside the legacy
#     handshake); Anchorage GIS deployed it 2026-09-17 and its count is now
#     zero, the other MCPs follow as they pick it up.
#   - `server/discover`, the 2026-07-28-era replacement for initialize.
#     Dual-era MCPs serve it (Anchorage GIS since 2026-09-17); the rest do
#     not. Older-core MCPs never validate the header, so they reach JSON-RPC
#     dispatch and log MethodNotFound for it instead of a 400.
# Both are expected client traffic and must never page anyone.
#
# Classification cannot key on `levelname` or `error_type` alone, because
# THREE logging eras coexist in the fleet at once:
#   - old shared core      → ERROR   + error_type=ValueError            (most MCPs)
#   - Boston's core        → ERROR   + error_type=MethodNotFoundError
#   - Anchorage GIS core   → WARNING + error_type=MethodNotFoundError   (2026-08-24+)
# As the rest of the fleet picks up the newer core these will migrate from
# ERROR to WARNING. Matching on the message as well as the type keeps these
# queries stable across that rollout instead of silently changing meaning.
#
# HTTP-level rejections are matched by the leading status code (written
# `/^4[0-9][0-9]/` rather than `/^4\d\d/`, so the identical string also works
# inside dashboard.tf's Terraform double-quoted widget queries, where a bare
# backslash-d is not a valid escape)
# rather than by wording, because the wording is NOT uniform: eBird's handler
# logs "400: Unsupported MCP-Protocol-Version" while the shared core logs
# "400 error: unsupported MCP-Protocol-Version". The prefix rule also picks
# up 403 (disallowed Origin), 404 (bad path) and 405 (bad HTTP verb) without
# needing a new clause for each.
#
# The two queries below partition the same input exactly — every WARNING/
# ERROR/CRITICAL line lands in precisely one of them, verified against live
# logs (358 + 5 = 363). If you add a new rejection path to any MCP, re-run
# both and confirm the totals still add up.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_query_definition" "real_server_errors" {
  name            = "mcp-fleet/errors/real-server-errors"
  log_group_names = local.mcp_lambda_log_groups

  # The actionable one: genuine faults, with every known client-fault
  # rejection subtracted. coalesce() guards the comparison because
  # `error_type` is absent on most lines, and a bare `!=` against a missing
  # field drops the row instead of keeping it.
  query_string = <<-EOT
    filter levelname in ['ERROR', 'CRITICAL']
    | filter coalesce(error_type, '') != 'MethodNotFoundError'
    | filter not (message like /Unknown method/)
    | filter not (message like /^4[0-9][0-9]/)
    | stats count(*) as errors
            by @log,
               coalesce(error_type, '(none)') as error_type,
               substr(message, 0, 80) as sample
    | sort errors desc
    | limit 100
  EOT
}

resource "aws_cloudwatch_query_definition" "real_server_errors_per_day" {
  name            = "mcp-fleet/errors/real-server-errors-per-day"
  log_group_names = local.mcp_lambda_log_groups

  # Same filter as above, as a per-MCP daily trend — this is the series worth
  # watching for a regression after a deploy. At current volume a normal day
  # is 0-2 fleet-wide, so any visible step change is real.
  query_string = <<-EOT
    filter levelname in ['ERROR', 'CRITICAL']
    | filter coalesce(error_type, '') != 'MethodNotFoundError'
    | filter not (message like /Unknown method/)
    | filter not (message like /^4[0-9][0-9]/)
    | stats count(*) as errors by bin(1d), @log
    | sort @timestamp asc
  EOT
}

resource "aws_cloudwatch_query_definition" "protocol_rejections" {
  name            = "mcp-fleet/errors/protocol-rejections"
  log_group_names = local.mcp_lambda_log_groups

  # The noise, kept visible rather than discarded: a spike here is a client
  # or crawler behaviour change worth knowing about, just never a server
  # fault. Labelled by `jsonrpc_method` where the line has one (so unknown
  # methods read as 'server/discover' rather than a truncated log message),
  # then by the protocol-version string the `parse` pulls out (so eBird's
  # "400: Unsupported MCP-Protocol-Version '…'" and the shared core's
  # "400 error: unsupported MCP-Protocol-Version '…'" collapse into ONE row
  # instead of two 18-character prefixes), and only then by the message
  # prefix for the remaining HTTP-level rejections (403 Origin, 405 GET).
  query_string = <<-EOT
    filter levelname in ['WARNING', 'ERROR', 'CRITICAL']
    | filter coalesce(error_type, '') = 'MethodNotFoundError'
          or message like /Unknown method/
          or message like /^4[0-9][0-9]/
    | parse message /(?<proto_version>MCP-Protocol-Version '[^']*')/
    | stats count(*) as rejections
            by coalesce(jsonrpc_method, proto_version, substr(message, 0, 18)) as rejection,
               @log
    | sort rejections desc
    | limit 100
  EOT
}

resource "aws_cloudwatch_query_definition" "protocol_version_400s_per_day" {
  name            = "mcp-fleet/errors/protocol-version-400s-per-day"
  log_group_names = local.mcp_lambda_log_groups

  # Tracks the newer-core regression described above: MCPs still rejecting
  # MCP-Protocol-Version 2026-07-28 show a steady daily count (one per
  # Claude.ai / claude-code session start); an MCP drops to zero the day its
  # core is fixed and redeployed. Once every MCP reads zero for a week this
  # query has done its job and can be deleted. Matches on the header name,
  # not the status wording, because eBird and the shared core phrase the 400
  # differently.
  query_string = <<-EOT
    filter message like /MCP-Protocol-Version/
    | stats count(*) as rejections by bin(1d), @log
    | sort @timestamp asc
  EOT
}
