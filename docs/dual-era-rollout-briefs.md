# Dual-era (MCP 2026-07-28) rollout briefs

Paste the brief for the fork you are in. Both are written against the state
measured on 2026-10-21. Reference implementation for every step is the
Anchorage GIS fork (`C:\projects\gis_mcp\OpenContext`), with the Anchorage
Parcels fork (`C:\projects\anchorage-parcels-mcp`, done 2026-10-21) as the
worked example of adapting rather than cherry-picking.

---

## BRIEF 1 — Anchorage Open Checkbook MCP (`C:\projects\anchorage-checkbook-mcp`)

Bring this server up to the MCP 2026-07-28 revision (dual-era) and carry the
follow-up fixes, mirroring what landed on Anchorage GIS (2026-09-17 and
2026-10-21) and Anchorage Parcels (2026-10-21). Also finish the alarm
retirement that is already sitting uncommitted in this working tree.

REFERENCE IMPLEMENTATION
========================
`C:\projects\gis_mcp\OpenContext` is a sibling fork of this same codebase.
This fork's `core/mcp_server.py` uses the SAME exception classes as the
reference (`MethodNotFoundError`, `InvalidToolParamsError`,
`UnknownToolError`) and the same `DEFAULT_PROTOCOL_VERSION = "2025-03-26"`,
so the reference commits should cherry-pick nearly clean. Read each commit
body before applying -- the reasoning is in the messages:

    git -C /c/projects/gis_mcp/OpenContext show <sha>

  ef8425a  Serve MCP 2026-07-28 (dual-era): server/discover, per-request
           _meta, no more 400 on the probe                (PART 1)
  5520d7e  fix(mcp): echo request id on -32022; log OTel trace context;
           dual-era smoke                                 (PART 2)

If a hunk conflicts, resolve by hand; the Parcels fork's versions of the
same two commits (74b7bff, ad59fb7 in `C:\projects\anchorage-parcels-mcp`)
show what "adapt, don't blind-copy" looked like on a fork whose core
differed. In particular: Parcels already parsed the body BEFORE the
version check, so Part 2's "hoist the parse" did not apply there -- check
which shape this fork has (`server/http_handler.py` line ~399 parses the
body AFTER the version check at line ~368, i.e. the reference shape, so
the hoist DOES apply here).

Spec pages, if you need to check a rule:
  https://modelcontextprotocol.io/specification/2026-07-28/changelog
  https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
  https://modelcontextprotocol.io/specification/2026-07-28/server/discover

GROUND RULES
============
- One concern per branch, merged --no-ff into main, message body says WHY.
- Every behaviour change gets a test that fails without it.
- `ruff check` is the bar. CI (`.github/workflows/ci.yml`) ALSO runs
  `ruff format --check core/ plugins/ server/ tests/` with no exclusions,
  and ruff is pinned to 0.15.11 (pyproject + pre-commit). So: run
  `ruff format --check` on the files you touched and format ONLY those if
  they drift; never a wholesale format pass. `scripts/` is outside the gate
  and hand-wrapped -- leave it that way.
- `terraform/aws/cloudwatch_alarms.tf` is ALREADY DIRTY (21-line deletion
  of `apigw_4xx_probing`). That is the alarm retirement; see PART 0. Until
  it is committed, every full `terraform plan` shows 0/1/1.
- Verify against PROD with real MCP calls before and after, not just unit
  tests.

THIS FORK'S STARTING STATE (measured 2026-10-21 -- do not rediscover)
=====================================================================
- Prod: https://checkbook.codeforanchorage.org/mcp
  Lambda `anchorage-checkbook-mcp-prod`, workspace `anchorage-checkbook-prod`.
  Staging workspace `anchorage-checkbook-staging` (API id 0c06sbm1vf). Both
  are on the shared fleet WAF already. The S3 backend is shared fleet-wide;
  `terraform workspace list` shows every fork's workspaces -- confirm the
  starred one before every plan.
- server_name "Anchorage Open Checkbook MCP", server_version "1.1.0",
  8 tools, prefix `anchorage_checkbook__`. Cheap read-only tool for the
  modern tools/call smoke check: `list_tables` with `{}`.
- `scripts/smoke_prod.py` ALREADY targets this server (DEFAULT_URL is the
  checkbook domain, takes a URL arg, asserts the right serverInfo name and
  `pv == "2025-11-25"`); it has no modern-era block. 503 tests collected.
- Live before-state: `server/discover` under `MCP-Protocol-Version:
  2026-07-28` -> HTTP 400, `-32600`, `"id": null`. `ping` -> `{}`.
  `initialize` with 2026-07-28 -> 2025-03-26. Bad Origin -> 403.
- The transport-level unknown-version error is -32600 with `"id": null`
  (both things Parts 1 and 2 change).

PART 0. ALARM RETIREMENT  (ref: GIS 03fc5e5, Parcels 7c64df1)
=============================================================
Branch: retire-4xx-probing-alarm. Commit the dirty file as-is (`git add
terraform/aws/cloudwatch_alarms.tf` by path). Message: the per-MCP 4XX
alarm was tripped by legitimate claude.ai probe traffic and the fleet
POST /mcp alarm in mcp-stats replaces it. Both prod and staging hold the
alarm in state, so each needs an apply -- fold that into the DEPLOY step
below (the plans will be 0/1/1: Lambda code + alarm destroy).

PART 1. DUAL-ERA CORE  (ref: ef8425a)
=====================================
Branch: modern-protocol-2026-07-28. Cherry-pick ef8425a; expected
conflicts are in tests/test_http_handler.py (CORS header assertions --
check whether this fork already lists `mcp-method, mcp-name`) and in the
`-32600 -> -32022` test. After it lands the server must:

1. Classify era per request (`MCPServer.request_era`): initialize =>
   legacy; `params._meta` with `io.modelcontextprotocol/protocolVersion` =>
   modern; a modern `MCP-Protocol-Version` header with no `_meta` => modern
   (then rejected as malformed, NOT quietly served as legacy).
2. `MODERN_PROTOCOL_VERSIONS = ("2026-07-28",)`, `LEGACY_PROTOCOL_VERSIONS`
   = the existing four, `SUPPORTED` = modern + legacy, newest first.
   `initialize` negotiates ONLY legacy versions (2026-07-28 on initialize
   falls back to the default 2025-03-26).
3. Modern dispatch: required `_meta` protocolVersion (string) and
   clientCapabilities (object) else -32602/400; version not in MODERN
   (including our own legacy ones) => -32022/400 with
   `data: {supported, requested}`; `server/discover` =>
   `{supportedVersions, capabilities: {"tools": {}}, ttlMs: 3_600_000,
   cacheScope: "public", instructions?}`; `tools/list` => + `ttlMs:
   300_000`, `cacheScope: "public"`; every modern result gets
   `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`;
   ping/initialize/resources/*/subscriptions/listen => -32601 on HTTP 404
   (legacy stays 200); client notifications => accept, drop, 202.
4. Streamable HTTP validation (`_modern_header_mismatch`):
   MCP-Protocol-Version present and == `_meta.protocolVersion`; Mcp-Method
   present and == method; tools/call Mcp-Name present and == params.name
   after decoding `=?base64?...?=`. Failure => -32020 "Header mismatch:
   <what>", HTTP 400. `Mcp-Session-Id` on a modern request is ignored.
5. Logging: `mcp_client_name`, `mcp_client_version`, `mcp_protocol_version`,
   `mcp_era` on BOTH eras' request log line (mcp-stats widget 0ed103f
   already reads these).
6. http_handler: transport-level unknown version answers -32022 (not
   -32600) for anything outside SUPPORTED; `is_modern` suppresses
   session-id echo; notifications 202; Origin 403 stays first.
7. Tests: port tests/test_modern_protocol.py (44 tests in the Parcels
   version, which added legacy-vs-modern contrast tests and a
   caller-errors-log-at-WARNING test for the new error classes; copy the
   fuller one). Set the fixture's server name / tool name to this fork's.
8. CLAUDE.md: update the core/mcp_server.py line and the protocol
   invariants bullet (Parcels 74b7bff shows the wording).
9. `scripts/smoke_prod.py`: it asserts `pv == "2025-11-25"` on initialize
   -- still true after Part 1 (legacy versions are echoed). Check for any
   `-32600` / "NOT -32022" assertion and flip it.

Verify locally before committing: `python scripts/local_server.py` (port
8000 is hardcoded; if another fork's server holds it, write a 15-line
launcher that imports `scripts/local_server.py` and binds 8765 -- Parcels
did), then `python scripts/smoke_prod.py http://localhost:8000/mcp`.

PART 2. ID ECHO + TRACE CONTEXT + DUAL-ERA SMOKE  (ref: 5520d7e)
================================================================
Same branch, second commit. Cherry-pick 5520d7e:
A. http_handler: hoist the "parse JSON to detect initialize" block ABOVE
   the version check, capture `body_request_id = request_json.get("id")`
   (None on parse failure or notification), use it in the -32022 body.
   403 Origin / 404 path keep `id: null`.
   Tests: `assert error_body["id"] == 1`; notification + unparseable body
   keep null.
B. core: copy `_meta["traceparent"]` / `_meta["tracestate"]` (strings only)
   onto the request log record as `otel_traceparent` / `otel_tracestate`
   right before "JSON-RPC request received". NOT `baggage`. caplog tests.
C. smoke_prod.py: add the modern block (checks 20-27) with
   server_name "Anchorage Open Checkbook MCP", `N_TOOLS = 8`, URL as above,
   tools/call on `anchorage_checkbook__list_tables` with `{}` and
   Mcp-Name mirrored. Needs a POST helper that returns (status, body)
   without raising on 4xx (`urllib.error.HTTPError` -> `e.code`,
   `e.read()`); `import urllib.error` at the top (E402). Pace 0.4s.
   Checks: 20 discover (supportedVersions[0] == "2026-07-28", contains
   "2025-03-26", resultType, cacheScope, int ttlMs, serverInfo.name,
   instructions non-empty); 21 tools/list (200, 8 tools, ttlMs 300000,
   every tool has title + annotations, second call same order); 22
   tools/call (200, resultType, not isError, serverInfo in _meta); 23
   modern ping -> 404/-32601; 24 version "2099-01-01" id 4242 -> 400/
   -32022, data.requested, "2026-07-28" in data.supported, body id ==
   4242; 25 Mcp-Method "ping" with body tools/list -> 400/-32020; 26
   protocolVersion-only _meta -> 400/-32602; 27 GET -> 405, bad Origin
   -> 403.

DEPLOY + VERIFY
===============
- Full suite + `ruff check core/ plugins/ server/ tests/ scripts/` +
  `ruff format --check core/ plugins/ server/ tests/` before merging.
- `printf 'no\n' | bash ./scripts/deploy.sh -e prod` is NOT blocked by the
  classifier (it ran fine on Parcels 2026-10-21). It builds the zip, copies
  config, plans, then deletes tfplan on the "no" path, so re-run the exact
  plan in terraform/aws:
    terraform plan -out=tfplan -var-file=prod.tfvars \
      -var=aws_region=us-west-2 -var=config_file=config.yaml
  Expect 0 add / 1 change (source_code_hash) / 1 destroy (the alarm).
  Then `terraform apply tfplan && rm -f tfplan`. No -auto-approve.
- Repeat for staging (`-e staging`, `staging.tfvars`); same 0/1/1. deploy.sh
  leaves the workspace on whichever env ran last -- switch back to prod.
- `aws lambda get-function-configuration --function-name <lambda> --region
  us-west-2`: LastModified must move and CodeSha256 must equal the plan's
  new hash, for each env. `aws cloudwatch describe-alarms --alarm-names
  <lambda>-apigw-4xx-probing` must return empty.
- `python scripts/smoke_prod.py` (prod) all green; the first call after a
  deploy can cold-start-fail an upstream-heavy tool -- re-run first.
- Push main; watch the CI run to success. Then update the fleet-status
  bullet in `C:\projects\mcp-stats\README.md` ("Newer-core MCPs reject
  ...") to move Checkbook into the dual-era list, and commit + push that.

---

## BRIEF 2 — ESRI Living Atlas MCP (`C:\projects\esri-living-atlas-mcp`)

This fork is on an OLDER core than the dual-era reference assumes. The
reference commit ef8425a "applied cleanly to a fork that already has the
Aug-2026 MCP-standard upgrade"; this fork does NOT have that upgrade, so
there is a prerequisite tier before the dual-era work. Measured live on
2026-10-21 at https://living-atlas.codeforanchorage.org/mcp:

  ping                                   -> {"status": "ok"}  (spec says {})
  initialize serverInfo.name             -> "opencontext"      (config says
                                            "ESRI Living Atlas MCP")
  unknown method (server/discover)       -> -32603 Internal error, HTTP 200
                                            (should be -32601; and it will
                                            have logged a traceback)
  POST with Origin https://evil.example  -> 200  (no Origin enforcement)
  MCP-Protocol-Version header            -> not validated at all
  core/mcp_server.py                     -> 288 lines, no error classes, no
                                            SUPPORTED_PROTOCOL_VERSIONS,
                                            protocolVersion hardcoded
                                            "2025-03-26"
  core/interfaces.py                     -> no ToolInputError, no title /
                                            output_schema on ToolDefinition
  .github/workflows                      -> none. ruff unpinned (>=0.1.0).
  tests                                  -> 553 collected
  scripts/smoke_prod.py                  -> is the SAN DIEGO GIS script
                                            (City Hall at 202 C St, arcgis
                                            tools), defaults to localhost
  config.yaml                            -> TRACKED in git here (ee4c0ea),
                                            unlike the other forks; it is
                                            the source of truth
  timeout ladder                         -> plugin 25s < lambda_timeout 120s,
                                            but API Gateway's hard ceiling
                                            is 29s, so a hung upstream kills
                                            the Lambda mid-flight. WRONG.
  terraform/aws/cloudwatch_alarms.tf     -> ALREADY DIRTY (same 21-line
                                            alarm deletion as every fork)
  workspaces                             -> living-atlas-prod,
                                            living-atlas-staging (API id
                                            kcj6gkp5gj); currently STARRED
                                            is staging -- select prod
                                            before any prod plan
  tools                                  -> 7 in plugins/living_atlas,
                                            prefix `living_atlas__`;
                                            plugins/anchorage_gis, arcgis,
                                            ckan, socrata are templates
                                            that also live here

Reference for the prerequisite tier is the Anchorage GIS fork's August
2026 series (`git -C /c/projects/gis_mcp/OpenContext show <sha>`), in
this order:

  c86ba18  feat(core): align HTTP transport with current MCP protocol
           revisions   (SUPPORTED_PROTOCOL_VERSIONS + negotiation,
           MCP-Protocol-Version header check, Origin allowlist)
  16d5e98  test(smoke): ping asserts the spec's empty-object result
  e290def  feat(mcp): advertise a display title on every tool
  e359aa1  fix(mcp): unknown tool returns -32602, not -32603
  081fc9e  fix(mcp): malformed tools/call returns -32602, not -32603
  c636fe1  fix(logging): caller mistakes no longer log as server faults
           (introduces the caller-error classes the dual-era commit
           builds on)
  4d43009  fix(aws): cap Lambda timeout below the API Gateway ceiling
  7598b3f  fix(config): plugin HTTP timeout must sit under the Lambda
           timeout
  e066612  fix(dev): route the local server through UniversalHTTPHandler
  a0056b9  test: stop http_handler globals leaking between test files

Structured output (c96c498 / 17932fd / 23062c9 there) is plugin-specific
and OPTIONAL for this job -- skip unless the Living Atlas tools already
return structured data. Parcels' CLAUDE.md "MCP conformance invariants"
section is the checked-in statement of what the tier must guarantee; use
it as the acceptance list.

GROUND RULES
============
- One concern per branch, merged --no-ff into main, message body says WHY.
- Every behaviour change gets a test that fails without it. Baseline the
  suite first (553 collected) and keep it green at every commit.
- `ruff check` is the bar. There is no CI here yet; ruff is unpinned. Do
  NOT run a wholesale `ruff format` (hand-wrapped tree); format only files
  you create. If you add a CI workflow (recommended, copy Parcels'
  `.github/workflows/ci.yml`), pin ruff to the version the hook uses and
  make the format step cover only files that are already clean, or clean
  them in their own `style:` commit first.
- `terraform/aws/cloudwatch_alarms.tf` is ALREADY DIRTY: that is the alarm
  retirement (PART 0). Do not sweep it into other commits, do not revert.
- Verify against PROD with real MCP calls before and after.

PART 0. ALARM RETIREMENT  (ref: GIS 03fc5e5, Parcels 7c64df1)
=============================================================
Branch: retire-4xx-probing-alarm. Commit the dirty file as-is, by path.
Both workspaces hold the alarm; each needs an apply (fold into DEPLOY).

PART 0.5. TIMEOUT LADDER  (ref: 4d43009, 7598b3f)
=================================================
Branch: timeout-ladder. REST API Gateway's integration timeout is a hard
29s. Set `aws.lambda_timeout` to 28 (in config.yaml -- note that
`aws.lambda_timeout` in config OVERRIDES prod.tfvars, so change config,
and keep `lambda_timeout = 120` out of the tfvars or make them agree) and
the plugin HTTP timeout to 20 (currently 25, which would be fine under 28
but leave headroom like the other forks). Add the config-validation test
that asserts plugin < lambda < 29. This changes a Terraform attribute, so
the first plan will show `timeout: 120 -> 28` on the Lambda.

PART 1. AUG-2026 CONFORMANCE TIER  (prerequisite)
=================================================
Branch: mcp-spec-tier1-conformance. Port the reference series above,
adapting to this fork's 288-line core. End state, all tested:
- `MCPServer.SUPPORTED_PROTOCOL_VERSIONS` = 2025-11-25, 2025-06-18,
  2025-03-26, 2024-11-05; `initialize` echoes a recognised version, else
  answers the newest; `serverInfo` and `instructions` come from config
  (server_name "ESRI Living Atlas MCP"), NOT a hardcoded "opencontext".
- `ping` -> `{}`. Unknown method -> -32601. Unknown tool and malformed
  tools/call (non-object params, missing name, non-object arguments) ->
  -32602. All logged at WARNING with no traceback; -32603 + ERROR +
  exc_info reserved for genuine faults. Add `ToolInputError(ValueError)`
  to core/interfaces.py and route plugin input errors through it.
- Origin allowlist enforced with 403 BEFORE routing; no-Origin requests
  allowed. Allow-Headers includes mcp-protocol-version, mcp-method,
  mcp-name.
- `MCP-Protocol-Version` header: absent = assume 2025-03-26, not an error;
  unsupported = HTTP 400 (use -32022 straight away -- the only reason the
  other forks ever used -32600 was that they were legacy-only at the time,
  and Part 2 flips it to -32022 anyway); `initialize` exempt.
- Top-level `title` on every tool, `readOnlyHint` annotations, no
  `idempotentHint` on read-only tools (e290def).
- Local server routes through UniversalHTTPHandler (e066612) so the Origin
  and version checks are exercised locally; conftest restores the handler
  globals between tests (a0056b9).
- Rewrite `scripts/smoke_prod.py` for THIS server: URL default
  https://living-atlas.codeforanchorage.org/mcp (keep the argv/env
  override), server_name "ESRI Living Atlas MCP", `N_TOOLS = 7`, prefix
  `living_atlas__`, and checks built on this plugin's own tools (read
  `plugins/living_atlas/plugin.py` get_tools() for names and a cheap
  read-only one; `scripts/smoke_living_atlas_live.py` already has live
  fixtures to borrow). Expect the first honest run to surface drift, as
  it did on Parcels (its copied script was 0/11 against the real server).
- Add CLAUDE.md "MCP conformance invariants" (copy Parcels' section and
  trim to what this fork guarantees).

Deploy and verify this tier on its own before starting Part 2 -- it is
the larger behaviour change and the one legacy clients can actually see
(ping body, error codes, Origin 403).

PART 2. DUAL-ERA CORE + FOLLOW-UPS  (ref: ef8425a then 5520d7e)
===============================================================
Branch: modern-protocol-2026-07-28, two commits. Once Part 1 is in, this
is the same job as BRIEF 1's Parts 1 and 2 -- follow those sections
verbatim, with these substitutions:
  server_name   "ESRI Living Atlas MCP"
  N_TOOLS       7
  prefix        living_atlas__
  prod URL      https://living-atlas.codeforanchorage.org/mcp
  lambda        living-atlas-mcp-prod / living-atlas-mcp-staging
  cheap tool    pick the discovery/search tool from plugin.get_tools()
The cherry-picks will NOT apply cleanly here because the core was
rewritten in Part 1 by hand; use Parcels' 74b7bff / ad59fb7 as the
worked example of writing the dual-era core onto a fork whose error
classes differ (Parcels put an `http_status` on its single
`JsonRpcError` carrier rather than adding four exception classes).

DEPLOY + VERIFY
===============
Same as BRIEF 1's DEPLOY + VERIFY, with: `terraform workspace select
living-atlas-prod` FIRST (staging is currently starred); the Part 0.5
plan additionally shows the Lambda `timeout` change; and after the final
deploy move Living Atlas into the dual-era list in
`C:\projects\mcp-stats\README.md`.

---

## NOTE — the "legacy 4-tool moa_parcels connector" (checked 2026-10-21)

Recorded in August as "broken since April, still shadows the parcels server
in tool search". It no longer exists anywhere reachable:

- claude.ai Customize > Connectors > Yours: no entry named moa_parcels. The
  one "Anchorage Parcels" connector (id 21a77910-…) points at
  https://anchorage-parcels.codeforanchorage.org/mcp and lists the current
  7 read-only tools (Find Parcel by Number … Search Parcels by Owner).
- Claude Code (`claude mcp list`), Claude Desktop config, `~/.claude.json`:
  no moa / moa_parcels server.
- AWS us-west-2: no Lambda or REST API with "moa" in its name.

Nothing to retire. If `moa_parcels__*` tools ever show up again in a
claude.ai tool search, the place to look is a claude.ai Project's or a
shared/organisation connector list, not the personal one.
