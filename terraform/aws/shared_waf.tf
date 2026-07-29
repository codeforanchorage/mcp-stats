# ─────────────────────────────────────────────────────────────────────────────
# Fleet-wide WAFv2 web ACL — one ACL fronting every MCP's API Gateway stage.
#
# WHY THIS EXISTS
# Each MCP repo used to create its OWN web ACL (see each repo's waf.tf). WAF
# bills $5.00/mo per web ACL + $1.00/mo per rule + $0.60 per MILLION requests,
# so cost scales with how many ACLs are DEPLOYED, not with traffic. At 12 ACLs
# x 3 rules that is ~$94/mo of fixed fees to inspect ~24k requests/mo (~$0.015
# of request charges). Consolidating to one ACL costs $5 + one rule per MCP +
# two shared managed rule groups.
#
# WHAT IS PRESERVED
# Per-MCP rate limits are NOT uniform and are deliberately tuned (eBird 50/5min
# for denial-of-wallet reasons, Anchorage GIS 600, Census 2000, the rest 300).
# A naive single shared rate rule would pool every MCP's traffic into one
# counter under one limit — breaking eBird's tight cap and loosening Anchorage
# GIS's. Both properties are preserved here without one-rule-per-MCP:
#
#   * ONE RULE PER DISTINCT LIMIT, not per MCP. AWS caps a web ACL at 10
#     rate-based statements (quota "Maximum number of rate-based statements per
#     web ACL", value 10, NOT adjustable — a per-MCP design hits this at 12 and
#     cannot be raised). Four distinct limits + the catch-all is 5 statements,
#     and onboarding another 300/5min MCP adds ZERO new statements.
#
#   * CUSTOM AGGREGATION KEYS keep the counters separate. Each tier rule
#     aggregates on (IP, Host) rather than IP alone, so every MCP in a tier gets
#     its own independent counter — two MCPs sharing the 300 limit do not add
#     into each other. This is what makes tiering safe rather than a tightening.
#
# Aggregating on a client-supplied header would normally invite evasion by
# rotating the value, but each tier's scope-down admits only an exact list of
# known Hosts, so the key can only take one of a few fixed values. The catch-all
# deliberately does NOT use custom keys — see below.
#
# THE CATCH-ALL RULE
# Scope-down matching on Host only fires for requests carrying the MCP's custom
# domain. No MCP sets `disable_execute_api_endpoint`, so every stage is ALSO
# reachable at <api-id>.execute-api.<region>.amazonaws.com — traffic that would
# match no member rule and therefore be rate-limited by nothing. The catch-all
# rate rule applies the default limit to any Host that is not a known member,
# closing that bypass. Do not remove it without first disabling the default
# execute-api endpoints.
#
# MIGRATION: this ACL must exist and be applied BEFORE any MCP repo flips
# `use_shared_waf = true`. See docs/waf-consolidation.md for the ordering.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Sorted so rule priorities are stable across plans — Terraform maps are
  # unordered, and reshuffling priorities would show a diff on every apply.
  fleet_waf_member_keys = sort(keys(var.fleet_waf_members))

  fleet_waf_hosts = [for k in local.fleet_waf_member_keys : var.fleet_waf_members[k].host]

  # Distinct limits as sorted STRINGS: sort() is string-only, and we only need a
  # deterministic order for priority assignment, not a numeric one.
  fleet_waf_limits = sort(distinct([
    for k in local.fleet_waf_member_keys : tostring(var.fleet_waf_members[k].rate_limit_per_5min)
  ]))

  # One rule per distinct limit; each carries every host that shares that limit.
  fleet_waf_tiers = [
    for i, lim in local.fleet_waf_limits : {
      limit = tonumber(lim)
      hosts = [
        for k in local.fleet_waf_member_keys :
        var.fleet_waf_members[k].host
        if tostring(var.fleet_waf_members[k].rate_limit_per_5min) == lim
      ]
      # 1..N for tiers; the catch-all and managed groups sit at 100/200+ so
      # adding a tier never renumbers them.
      priority = i + 1
    }
  ]
}

resource "aws_wafv2_web_acl" "fleet" {
  count = var.enable_fleet_waf ? 1 : 0

  name        = var.fleet_waf_name
  description = "Shared per-IP rate limiting + AWS managed rules for the whole MCP fleet"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # One rate-based rule per DISTINCT limit, scoped to the hosts that share it,
  # aggregating on (IP, Host) so each MCP keeps an independent counter.
  # Priority 1..N.
  dynamic "rule" {
    for_each = local.fleet_waf_tiers
    content {
      name     = "rate-limit-${rule.value.limit}-per-5min"
      priority = rule.value.priority

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = rule.value.limit
          aggregate_key_type = "CUSTOM_KEYS"

          # (IP, Host) — without the Host key, every MCP in this tier would
          # share one counter and the tiering would silently tighten limits.
          custom_key {
            ip {}
          }

          custom_key {
            header {
              name = "host"

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }

          scope_down_statement {
            # or_statement requires >= 2 branches, so a single-host tier (eBird,
            # Anchorage GIS, Census) must use a bare byte_match instead.
            dynamic "byte_match_statement" {
              for_each = length(rule.value.hosts) == 1 ? rule.value.hosts : []
              content {
                positional_constraint = "EXACTLY"
                search_string         = byte_match_statement.value

                field_to_match {
                  # WAF requires the header name lowercased here.
                  single_header {
                    name = "host"
                  }
                }

                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }

            dynamic "or_statement" {
              for_each = length(rule.value.hosts) > 1 ? [rule.value.hosts] : []
              content {
                dynamic "statement" {
                  for_each = or_statement.value
                  content {
                    byte_match_statement {
                      positional_constraint = "EXACTLY"
                      search_string         = statement.value

                      field_to_match {
                        single_header {
                          name = "host"
                        }
                      }

                      text_transformation {
                        priority = 0
                        type     = "LOWERCASE"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.fleet_waf_name}-rate-${rule.value.limit}"
        sampled_requests_enabled   = true
      }
    }
  }

  # Anything whose Host is not a known member — most importantly the default
  # execute-api endpoints — still gets rate limited. See header comment.
  rule {
    name     = "rate-limit-unmatched-host"
    priority = 100

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit = var.fleet_waf_default_rate_limit_per_5min

        # IP only — deliberately NOT (IP, Host) like the tier rules. This rule
        # matches Hosts that are by definition unrecognised, so aggregating on
        # the Host header would let a caller mint a fresh counter per forged
        # value and never trip the limit. Pooling all unmatched traffic from an
        # IP into one counter is the point.
        aggregate_key_type = "IP"

        scope_down_statement {
          not_statement {
            statement {
              or_statement {
                dynamic "statement" {
                  for_each = local.fleet_waf_hosts
                  content {
                    byte_match_statement {
                      positional_constraint = "EXACTLY"
                      search_string         = statement.value

                      field_to_match {
                        single_header {
                          name = "host"
                        }
                      }

                      text_transformation {
                        priority = 0
                        type     = "LOWERCASE"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.fleet_waf_name}-rate-unmatched-host"
      sampled_requests_enabled   = true
    }
  }

  # Shared managed rule groups. These were duplicated into 10 of the 11 per-MCP
  # ACLs ($1/mo each, every time); here they are bought once for the fleet.
  # Census was the one MCP without them — it gains this coverage on migration.
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 200

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.fleet_waf_name}-KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 201

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.fleet_waf_name}-CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.fleet_waf_name
    sampled_requests_enabled   = true
  }

  lifecycle {
    create_before_destroy = true

    # `or_statement` requires at least two nested statements, so the catch-all
    # rule cannot be built for a single member.
    precondition {
      condition     = length(var.fleet_waf_members) >= 2
      error_message = "fleet_waf_members needs >= 2 entries (the catch-all rule's or_statement requires at least two host matches)."
    }
  }

  tags = {
    Project = var.project_tag
    Name    = var.fleet_waf_name
  }
}

# Published so each MCP repo — which has its own Terraform state and cannot
# read this one — can look the ARN up with a `data "aws_ssm_parameter"` rather
# than hardcoding it or wiring up cross-state remote reads.
resource "aws_ssm_parameter" "fleet_waf_arn" {
  count = var.enable_fleet_waf ? 1 : 0

  name        = var.fleet_waf_ssm_parameter
  description = "ARN of the shared fleet WAFv2 web ACL (consumed by each MCP repo's waf.tf)"
  type        = "String"
  value       = aws_wafv2_web_acl.fleet[0].arn

  tags = {
    Project = var.project_tag
  }
}
