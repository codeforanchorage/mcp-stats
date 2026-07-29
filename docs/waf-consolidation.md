# WAF consolidation runbook

Migrating the fleet from **one WAFv2 web ACL per MCP** to **one shared ACL**
fronting every MCP's API Gateway stage.

## Why

AWS WAF bills on *deployed objects*, not traffic:

| Component | Price |
| --- | --- |
| Web ACL | $5.00 / month each |
| Rule | $1.00 / month each |
| Requests inspected | $0.60 per **million** |

In July 2026 the fleet ran 12 web ACLs with 34 rules — about **$94/month** at
full run-rate — to inspect ~24,000 requests, which is **$0.015** of request
charges. Over 99.9% of the WAF bill was fixed fees for having the ACLs, not for
anyone using the MCPs.

Consolidated: **$5** (one ACL) + **$11** (one Host-scoped rate rule per MCP) +
**$2** (two shared managed rule groups) = **~$18/month**. Saving ≈ **$76/month**.

## What is preserved, and what changes

**Preserved — per-MCP rate limits.** They are not uniform and were tuned
deliberately: eBird 50/5min (documented denial-of-wallet rationale), Anchorage
GIS 600, Census 2000, everything else 300. Each MCP keeps its own rate-based
rule in the shared ACL, narrowed by a `scope_down_statement` matching its Host
header, so counters stay independent. That is why the design uses one rule per
MCP ($11/mo) rather than a single shared rule ($1/mo) — $10/mo to avoid both
breaking eBird's tight cap and loosening Anchorage GIS's.

**Changed — Census gains the AWS managed rule groups.** Census's own ACL had
only the rate rule. Under the shared ACL it also gets KnownBadInputs and
CommonRuleSet. This is added coverage, but watch
`mcp-fleet-waf-CommonRuleSet` for false positives after cutover; Census is the
only Node.js MCP, so its request shape was never observed under those rules.

**Changed — WAF CloudWatch metrics move.** Per-MCP WAF metrics were dimensioned
by web ACL name (`ebird-mcp-prod-waf`). They now come from the shared ACL
dimensioned by *rule* (`mcp-fleet-waf-rate-ebird`). Any alarm or dashboard
pointing at a per-MCP ACL dimension needs repointing.

**Not affected — the mcp-stats usage dashboard and saved queries.** They read
CloudWatch **Logs** (tag-discovered Lambda and API Gateway log groups), never
WAF metrics. Usage stats are untouched by this migration.

### The catch-all rule

Host-scoped rules only fire for requests carrying the MCP's custom domain. No
MCP sets `disable_execute_api_endpoint`, so every stage is *also* reachable at
`<api-id>.execute-api.us-west-2.amazonaws.com` — traffic that matches no member
rule. The `rate-limit-unmatched-host` rule applies the default limit (300) to
any unrecognised Host, closing that bypass. **Do not remove it** without first
disabling the default execute-api endpoints.

## Migration order

The shared ACL must exist before any MCP points at it.

### 1. Create the shared ACL (mcp-stats)

```bash
cd C:/projects/mcp-stats/terraform/aws
terraform apply
```

Creates `aws_wafv2_web_acl.fleet` and publishes its ARN to
`/mcp-fleet/waf/web_acl_arn`. Confirm:

```bash
aws ssm get-parameter --name /mcp-fleet/waf/web_acl_arn --region us-west-2
```

At this point nothing is associated with it and nothing has changed for users —
the old per-MCP ACLs are still doing the work. Cost is temporarily *higher*
(~$18/mo extra) until the per-MCP ACLs are torn down.

### 2. Cut over one MCP and watch it

Start with a low-traffic MCP, **not** eBird (the public, most-used one).
Worcester is a good first candidate.

```bash
cd C:/projects/worcester-gis-mcp/terraform/aws
terraform plan -var-file=prod.tfvars -var use_shared_waf=true
```

Expect exactly: the association updated to the shared ARN, and this repo's own
`aws_wafv2_web_acl` destroyed. If the plan wants to destroy the *association*
and recreate it, that is fine; a brief window where the stage is unprotected is
possible, so avoid cutting over during an incident.

Once the plan looks right, set `use_shared_waf = true` in that repo's
`prod.tfvars` (so the setting is committed, not a one-off `-var`), then apply.

Verify the stage is attached to the shared ACL:

```bash
aws wafv2 get-web-acl-for-resource \
  --resource-arn arn:aws:apigateway:us-west-2::/restapis/<api-id>/stages/prod \
  --region us-west-2 --query 'WebACL.Name'
```

Then exercise the MCP and confirm normal traffic still succeeds and
`mcp-fleet-waf-rate-worcester` is receiving requests.

### 3. Roll through the rest

Same two steps per repo. Leave **eBird last** — it has the tightest limit (50)
and the most real users, so it is the one most likely to surface a scope-down
mistake.

Repos, and the `fleet_waf_members` key each maps to:

| Repo | Member key |
| --- | --- |
| `worcester-gis-mcp` | `worcester` |
| `sandiego-city-mcp` | `sandiego-city` |
| `sandiego-gis-mcp` | `sandiego-regional` |
| `esri-uc-mcp` | `esri-uc` |
| `esri-living-atlas-mcp` | `living-atlas` |
| `audubon-iba-mcp` | `audubon-iba` |
| `anchorage-parcels-mcp` | `anchorage-parcels` |
| `ecode/OpenContext` | `anchorage-ecode` |
| `gis_mcp/OpenContext` | `anchorage-gis` |
| `census-mcp-lambda` | `census` |
| `ebird_aws` | `ebird` |

## Rollback

Set `use_shared_waf = false` and apply. That recreates the MCP's own ACL from
the unchanged code in its `waf.tf` and repoints the association back. Nothing
about the per-MCP path was deleted — it is behind the flag, not removed.

## Onboarding a new MCP afterwards

1. Add it to `fleet_waf_members` in `mcp-stats/terraform/aws/variables.tf` with
   its custom domain and rate limit, and `terraform apply` mcp-stats **first**.
2. In the new MCP's repo, set `use_shared_waf = true`.

Getting the order wrong means the new MCP is covered only by the catch-all
rule at 300/5min rather than its intended limit — and a `host` typo fails the
same silent way, since a non-matching Host simply falls through to the
catch-all. After onboarding, confirm the member's own rule is seeing traffic.

## Staging endpoints — a separate saving

`living-atlas-mcp-staging-waf` exists and costs ~$8/month. eBird's
`staging.tfvars` sets `waf_rate_limit_per_5min = 0` with the rationale that
staging is *"unpublicized dev infra"* and prod is the public-facing target.
`esri-living-atlas-mcp/terraform/aws/staging.tfvars` instead sets `300`, so it
builds a full ACL.

Adopting eBird's convention there would save another ~$8/month. This is left as
a deliberate decision rather than folded into the migration, because it removes
WAF protection from that endpoint rather than relocating it. Note that
`use_shared_waf` defaults to `false`, so staging workspaces keep their own ACLs
and are unaffected by this migration either way.
