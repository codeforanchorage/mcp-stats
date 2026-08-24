variable "aws_region" {
  description = "AWS region the MCP fleet runs in. Every MCP is deployed in this one account/region."
  type        = string
  default     = "us-west-2"
}

variable "project_tag" {
  description = <<-EOT
    Tag VALUE used to discover MCP log groups via the Resource Groups Tagging
    API. Every MCP repo tags both its Lambda log group and its API Gateway
    access log group with `Project = <this value>`. Changing this only makes
    sense if the fleet-wide tag convention changes.
  EOT
  type        = string
  default     = "mcp-server"
}

variable "dashboard_name" {
  description = "Name of the account-wide CloudWatch dashboard this project creates."
  type        = string
  default     = "mcp-fleet-usage"
}

variable "environment" {
  description = <<-EOT
    Deployment environment to scope the dashboard to. MCP log groups are named
    `/aws/lambda/<mcp>-<env>` and `/aws/apigateway/<mcp>-<env>-access`, and the
    fleet runs both staging and prod under the same `Project` tag. Discovery
    keeps only the groups whose name matches this environment.

    Set to "" to include EVERY discovered environment (staging + prod commingled).
  EOT
  type        = string
  default     = "prod"
}

# ─── Account-level API Gateway logging role (see apigw_account.tf) ──────────

variable "apigw_account_role_name" {
  description = <<-EOT
    Name of the fleet-owned IAM role that API Gateway assumes to write access
    logs to CloudWatch. This is set on the account+region-level singleton
    `aws_api_gateway_account`, so it applies to EVERY API Gateway in the region,
    not just the MCP fleet.
  EOT
  type        = string
  default     = "mcp-fleet-apigw-cloudwatch"
}

# ─── Shared fleet WAF (see shared_waf.tf) ───────────────────────────────────

variable "enable_fleet_waf" {
  description = <<-EOT
    Create the shared fleet-wide WAFv2 web ACL. This must be applied (and the
    SSM parameter populated) BEFORE any MCP repo sets `use_shared_waf = true`,
    or those repos' data lookups will fail.
  EOT
  type        = bool
  default     = true
}

variable "fleet_waf_name" {
  description = "Name of the shared fleet web ACL. Also the prefix for its CloudWatch metric names."
  type        = string
  default     = "mcp-fleet-waf"
}

variable "fleet_waf_ssm_parameter" {
  description = <<-EOT
    SSM Parameter Store path where the shared web ACL's ARN is published. Each
    MCP repo reads this path to associate its API Gateway stage. Changing it
    means changing `shared_waf_ssm_parameter` in every MCP repo too.
  EOT
  type        = string
  default     = "/mcp-fleet/waf/web_acl_arn"
}

variable "fleet_waf_default_rate_limit_per_5min" {
  description = <<-EOT
    Per-IP limit applied by the catch-all rule to requests whose Host matches no
    member — chiefly the default `execute-api` endpoints, which no MCP disables.
    Defaults to 300, the value most of the fleet already uses.
  EOT
  type        = number
  default     = 300
}

variable "fleet_waf_members" {
  description = <<-EOT
    The MCPs fronted by the shared web ACL: map of short key -> custom domain
    and per-IP 5-minute rate limit. Each entry becomes one rate-based rule
    scoped to that Host, preserving the limit that MCP's own ACL enforced.

    The key is used in rule and CloudWatch metric names, so keep it short and
    limited to [A-Za-z0-9_-]. `host` must be the custom domain the MCP actually
    serves on — a mismatch silently means that MCP is only covered by the
    catch-all rule.

    Defaults mirror each repo's prod.tfvars as of 2026-08-23. When onboarding a
    new MCP, add it here and apply BEFORE flipping the repo to the shared WAF.
  EOT
  type = map(object({
    host                = string
    rate_limit_per_5min = number
  }))
  default = {
    ebird               = { host = "ebird.codeforanchorage.org", rate_limit_per_5min = 50 }
    census              = { host = "us-census.codeforanchorage.org", rate_limit_per_5min = 2000 }
    anchorage-gis       = { host = "anchorage-gis.codeforanchorage.org", rate_limit_per_5min = 300 }
    anchorage-checkbook = { host = "checkbook.codeforanchorage.org", rate_limit_per_5min = 300 }
    anchorage-ecode     = { host = "anchorage-ecode.codeforanchorage.org", rate_limit_per_5min = 300 }
    anchorage-parcels   = { host = "anchorage-parcels.codeforanchorage.org", rate_limit_per_5min = 300 }
    audubon-iba         = { host = "audubon-iba.codeforanchorage.org", rate_limit_per_5min = 300 }
    esri-uc             = { host = "esri-uc.codeforanchorage.org", rate_limit_per_5min = 300 }
    living-atlas        = { host = "living-atlas.codeforanchorage.org", rate_limit_per_5min = 300 }
    sandiego-city       = { host = "sandiego-city-gis.codeforanchorage.org", rate_limit_per_5min = 300 }
    sandiego-regional   = { host = "sandiego-regional-gis.codeforanchorage.org", rate_limit_per_5min = 300 }
    worcester           = { host = "worcester-gis.codeforanchorage.org", rate_limit_per_5min = 300 }
  }

  validation {
    condition     = alltrue([for k in keys(var.fleet_waf_members) : can(regex("^[A-Za-z0-9_-]+$", k))])
    error_message = "fleet_waf_members keys must match [A-Za-z0-9_-]+ (they become WAF rule and CloudWatch metric names)."
  }
}
