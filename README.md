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

Each MCP repo tags **both** its Lambda log group (`/aws/lambda/<name>`) and
its API Gateway access log group (`/aws/apigateway/<name>-access`) with
`Project = mcp-server`. This project reads that tag through the Resource
Groups Tagging API — note the `aws_cloudwatch_log_groups` data source filters
by name prefix only, *not* by tag, so tag discovery must go through the
tagging API.

`discovery.tf` is the **single reusable discovery layer**. Phase 2 (below)
will consume the exact same `local.mcp_lambda_log_groups` /
`local.mcp_apigw_log_groups` lists — never re-derive the log group list
elsewhere.

### Fleet as of last review

All five MCP repos already carry the `Project = mcp-server` tag (committed):

| MCP             | Lambda log group                          | Access-log client fields      |
| --------------- | ------------------------------------------ | ----------------------------- |
| eBird           | `/aws/lambda/ebird-mcp`                    | `sourceIp`, `userAgent`       |
| Anchorage GIS   | `/aws/lambda/anchorage-gis-mcp-staging`    | `sourceIp`, `userAgent`       |
| Boston OpenData | `/aws/lambda/boston-ckan-mcp-staging`      | `ip` only (no `userAgent`)    |
| Census          | `/aws/lambda/census-mcp-prod`              | `ip` only (no `userAgent`)    |

Two known schema variances the queries account for:

- **Access-log schema is not uniform.** eBird and Anchorage GIS emit
  `sourceIp` + `userAgent`; Boston and Census emit `ip` and no `userAgent`.
  Queries normalise with `coalesce(sourceIp, ip)`; the userAgent-based
  "unique client" proxy degrades to IP-only for MCPs that omit it.
- **Census runs a different codebase** (Node.js, not the shared Python
  `core/`). If its Lambda logs do not carry identical `jsonrpc_*` field
  names, the Lambda-log widgets simply show no Census rows — non-fatal.

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
  complete across all five repos, so Phase 1 touches no MCP repo at all.

## Phase 2 (designed for, NOT built here)

Later this project will add CloudWatch subscription filters on each
discovered log group → Kinesis Firehose → S3 → Athena, for durable history
and SQL. It is intentionally not built yet. When it is, it consumes the same
`discovery.tf` locals the dashboard and queries already use.
