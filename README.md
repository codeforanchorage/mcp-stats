# mcp-observability (mcp-stats)

An **infrastructure-only** Terraform project that aggregates usage telemetry —
sessions, unique clients, tool-call data — across the whole fleet of hosted
MCP (Model Context Protocol) servers, each of which runs as its own AWS
Lambda behind API Gateway.

It has its own git repo and its own Terraform state. It has **zero code
coupling** to the MCP servers — it only reads the CloudWatch log groups they
already produce.

All MCPs run in a single AWS account and region (`us-west-2`).

## Phase 1 — what this builds (an in-place query layer)

No new infrastructure sits in any request path. Everything here reads log
groups the MCPs already emit:

1. **Tag-based discovery** (`discovery.tf`) — finds every MCP log group via
   the Resource Groups Tagging API, filtered on `Project = mcp-server`.
2. **Account-wide CloudWatch dashboard** (`dashboard.tf`) — one dashboard
   spanning all discovered MCPs: sessions/day (fleet and per-MCP), unique
   clients/day, tool popularity by MCP, per-MCP request volume, client
   family, top source IPs.
3. **Saved Logs Insights queries** (`queries.tf`) — the cross-MCP versions
   of each MCP repo's per-MCP "Tier 1 usage tracking" queries.

## How discovery works

Each MCP repo tags **both** its Lambda log group (`/aws/lambda/<mcp>-<env>`)
and its API Gateway access log group (`/aws/apigateway/<mcp>-<env>-access`)
with `Project = mcp-server`. This project reads that tag through the Resource
Groups Tagging API — note the `aws_cloudwatch_log_groups` data source filters
by name prefix only, *not* by tag, so tag discovery must go through the
tagging API.

The fleet runs **both staging and prod** under the same tag, so `discovery.tf`
scopes to one environment via `var.environment` (default `prod`) by matching
the trailing `-<env>` name segment. Set `environment = ""` to include every
environment.

`discovery.tf` is the **single reusable discovery layer**. Phase 2 (below)
will consume the exact same `local.mcp_lambda_log_groups` /
`local.mcp_apigw_log_groups` lists — never re-derive the log group list
elsewhere.

### Fleet as of last review

All MCP repos carry the `Project = mcp-server` tag. With the default
`environment = prod`, discovery resolves to:

| MCP                    | Lambda log group                           | Access-log client fields   |
| ---------------------- | ------------------------------------------ | -------------------------- |
| eBird                  | `/aws/lambda/ebird-mcp-prod`               | `sourceIp`, `userAgent`    |
| Anchorage GIS          | `/aws/lambda/anchorage-gis-mcp-prod`       | `sourceIp`, `userAgent`    |
| Anchorage Parcels      | `/aws/lambda/anchorage-parcels-mcp-prod`   | `sourceIp`, `userAgent`    |
| Anchorage eCode        | `/aws/lambda/anchorage-ecode-mcp-prod`     | `sourceIp`, `userAgent`    |
| Audubon IBA            | `/aws/lambda/audubon-iba-mcp-prod`         | `sourceIp`, `userAgent`    |
| San Diego Regional GIS | `/aws/lambda/sandiego-gis-mcp-prod`        | `sourceIp`, `userAgent`    |
| San Diego City GIS     | `/aws/lambda/sandiego-city-gis-mcp-prod`   | `sourceIp`, `userAgent`    |
| Worcester GIS          | `/aws/lambda/worcester-gis-mcp-prod`       | `sourceIp`, `userAgent`    |
| Boston OpenData        | `/aws/lambda/boston-opencontext-mcp-prod`  | `ip` only (no `userAgent`) |
| Census                 | `/aws/lambda/census-mcp-prod`              | `ip` only (no `userAgent`) |

The five servers added 2026-07-13 (Anchorage Parcels, Anchorage eCode,
Audubon IBA, both San Diego GIS servers) all run the shared Python `core/`
codebase: their Lambda logs carry the full `jsonrpc_*` fields and their
access logs emit `sourceIp` + `userAgent`, so every widget and saved query
covers them with no schema gaps.

Known gaps / variances:

- **Discovery is eventually consistent.** The Resource Groups Tagging API
  indexes tags asynchronously, so `get-resources` can return slightly different
  result sets between calls — and a freshly tagged (or freshly destroyed) log
  group may take a while to appear or drop out. Each `terraform plan`/`apply`
  re-reads the API, so the discovered list can momentarily flap if a run catches
  an in-between view; the next run self-corrects. This is inherent to tag-based
  discovery, not a bug in this project.
- **Access-log schema is not uniform.** eBird and Anchorage GIS emit
  `sourceIp` + `userAgent`; Boston and Census emit `ip` and no `userAgent`.
  Queries normalise with `coalesce(sourceIp, ip)`; the userAgent-based
  "unique client" proxy degrades to IP-only for MCPs that omit it.
- **Census runs a different codebase** (Node.js, not the shared Python
  `core/`). If its Lambda logs do not carry identical `jsonrpc_*` field
  names, the Lambda-log widgets simply show no Census rows — non-fatal.
- **Staging groups exist for several MCPs** (`ebird-mcp-staging`,
  `boston-ckan-mcp-staging`, …) and are excluded by the default `prod` scope.
- **Per-MCP cost attribution is forward-only.** The `Project` tag was
  activated as a cost-allocation tag on 2026-05-30, so Cost Explorer can now
  break Lambda / API Gateway / CloudWatch spend down per MCP — but only for
  usage from that date forward; AWS does not backfill tag-based cost data, so
  earlier spend is unattributable. Note also that the AWS account is **shared
  with unrelated infrastructure** (RDS, VPC, WAF, …), so account-level totals
  are not a proxy for fleet cost. The fleet's own serverless footprint is
  tiny — Lambda + API Gateway run at fractions of a cent/week at current
  traffic; CloudWatch logs are the only material line item.

## Usage

```bash
# 1. Bootstrap the (separate) S3 + DynamoDB backend.
./scripts/setup-backend.sh
cp terraform/aws/backend.tf.example terraform/aws/backend.tf   # if not auto-written

# 2. Plan and apply.
cd terraform/aws
terraform init
terraform plan
terraform apply
```

`terraform output dashboard_url` prints the console link once applied.

## Guardrails

- **Separate Terraform state** from every MCP repo — see
  `scripts/setup-backend.sh` and `backend.tf.example`.
- **Additive only.** This project does not modify or remove any MCP's
  existing per-MCP dashboard.
- The only change this project's design ever pushes into an MCP repo is the
  `Project = mcp-server` tag on its log groups — and that rollout is already
  complete across the fleet, so Phase 1 touches no MCP repo at all.

## Phase 2 (designed for, NOT built here)

Later this project will add CloudWatch subscription filters on each
discovered log group → Kinesis Firehose → S3 → Athena, for durable history
and SQL. It is intentionally not built yet. When it is, it consumes the same
`discovery.tf` locals the dashboard and queries already use.
