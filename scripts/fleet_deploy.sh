#!/usr/bin/env bash
# fleet_deploy.sh -- package, plan, (optionally) apply, and smoke-test every
# OpenContext fork's PROD stack, one repo at a time.
#
# Each fork deploys from its own repo (own code, own config.yaml, own
# Terraform workspace in the shared S3 backend), so a fleet-wide fix means
# N separate deploys. This loop runs the same guarded sequence for each:
#
#   1. preflight  - repo on main, clean, in sync with origin (prod == origin)
#   2. package    - the fork's own `scripts/deploy.sh -e prod`, answered "no"
#                   at its confirm gate (builds the zip + copies config)
#   3. plan       - re-plan in terraform/aws against that zip, then check:
#                     * workspace is the one expected for this fork
#                     * every changed resource is on the allowlist
#                       (default: only aws_lambda_function.mcp_server updates)
#                     * nothing is destroyed unless --allow-destroy
#   4. apply      - only with --apply, only if step 3 passed; applies the
#                   exact saved plan (never -auto-approve on a fresh plan)
#   5. verify     - Lambda LastModified must move; empty POST must be 400
#                   (-32700); tools/list must return at least one tool
#
# Default is a DRY RUN (steps 1-3 + read-only smoke). Nothing changes in AWS
# without --apply.
#
# Usage:
#   scripts/fleet_deploy.sh                         # dry run, whole fleet
#   scripts/fleet_deploy.sh --only boston           # dry run, one fork
#   scripts/fleet_deploy.sh --apply --only boston   # testbed first ...
#   scripts/fleet_deploy.sh --apply --skip boston   # ... then the rest
#   scripts/fleet_deploy.sh --apply --allow alarm   # also allow changes to
#                                                   # resources matching "alarm"
#   scripts/fleet_deploy.sh --apply --allow-destroy --only ecode
#
# Before --apply: make sure no other Claude session / terminal is running
# terraform against these workspaces (shared state; the backend lock catches
# simultaneous applies but not interleaved plan->apply sequences).
#
# Windows/git-bash note baked in: some deploy.sh copies call `python3`,
# which may not exist on PATH -- a shim is added when it's missing.

set -uo pipefail
# Do NOT export MSYS_NO_PATHCONV here: native git.exe/terraform.exe then
# receive /c/projects/... untranslated and fail with "cannot change to".

PROJECTS="${PROJECTS:-/c/projects}"
REGION="us-west-2"

# name | repo dir (under $PROJECTS) | terraform workspace | MCP URL
FLEET=$(cat <<'EOF'
anchorage-gis|gis_mcp/OpenContext|anchorage-gis-prod|https://anchorage-gis.codeforanchorage.org/mcp
alaska-geoportal|alaska-gis-mcp|alaska-geoportal-prod|https://alaska-geoportal.codeforanchorage.org/mcp
checkbook|anchorage-checkbook-mcp|anchorage-checkbook-prod|https://checkbook.codeforanchorage.org/mcp
parcels|anchorage-parcels-mcp|anchorage-parcels-prod|https://anchorage-parcels.codeforanchorage.org/mcp
ecode|ecode/OpenContext|anchorage-ecode-prod|https://anchorage-ecode.codeforanchorage.org/mcp
audubon-iba|audubon-iba-mcp|audubon-iba-prod|https://audubon-iba.codeforanchorage.org/mcp
ebird|ebird_aws|ebird-mcp-prod|https://ebird.codeforanchorage.org/mcp
living-atlas|esri-living-atlas-mcp|living-atlas-prod|https://living-atlas.codeforanchorage.org/mcp
sandiego-city|sandiego-city-mcp|sandiego-city-prod|https://sandiego-city-gis.codeforanchorage.org/mcp
sandiego-regional|sandiego-gis-mcp|sandiego-prod|https://sandiego-regional-gis.codeforanchorage.org/mcp
worcester|worcester-gis-mcp|worcester-prod|https://worcester-gis.codeforanchorage.org/mcp
boston|boston/OpenContext|boston-prod|https://c3xrp8nzdf.execute-api.us-west-2.amazonaws.com/prod/mcp
EOF
)

APPLY=0
ALLOW_DESTROY=0
ONLY=""
SKIP=""
ALLOW_EXTRA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --allow-destroy) ALLOW_DESTROY=1 ;;
        --only) ONLY="$2"; shift ;;
        --skip) SKIP="$2"; shift ;;
        --allow) ALLOW_EXTRA="$2"; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

in_list() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Pick a Python for JSON parsing, and shim python3 for deploy.sh if absent.
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "no python on PATH" >&2; exit 2; }
SHIM_DIR="$(mktemp -d)"
trap 'rm -rf "$SHIM_DIR"' EXIT
if ! command -v python3 >/dev/null 2>&1; then
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$PY" > "$SHIM_DIR/python3"
    chmod +x "$SHIM_DIR/python3"
fi
export PATH="$SHIM_DIR:$PATH"   # mktemp gives a /tmp path -- no "C:" to split PATH on

LOG_DIR="${LOG_DIR:-$PROJECTS/mcp-stats/.fleet-deploy-logs}"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%dT%H%M%S)"
echo "mode: $([ $APPLY = 1 ] && echo APPLY || echo dry-run)  logs: $LOG_DIR/$STAMP-*.log"
echo

SUMMARY=()
record() { SUMMARY+=("$(printf '%-18s %-9s %s' "$1" "$2" "$3")"); echo "  => $2 $3"; }

smoke() {   # $1 = url; prints "empty=<code> tools=<n>"
    local empty tools
    empty=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$1" \
        -H 'Content-Type: application/json')
    tools=$(curl -s -m 25 -X POST "$1" -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H 'MCP-Protocol-Version: 2025-06-18' \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
        | grep -o '"inputSchema"' | wc -l | tr -d ' ')
    echo "empty=$empty tools=$tools"
}

while IFS='|' read -r NAME DIR WS URL; do
    [ -n "$NAME" ] || continue
    [ -n "$ONLY" ] && ! in_list "$NAME" "$ONLY" && continue
    [ -n "$SKIP" ] && in_list "$NAME" "$SKIP" && continue

    REPO="$PROJECTS/$DIR"
    LOG="$LOG_DIR/$STAMP-$NAME.log"
    echo "=== $NAME ($DIR)"

    # 1. preflight ---------------------------------------------------------
    if [ ! -d "$REPO/.git" ]; then record "$NAME" SKIP "repo not found"; continue; fi
    BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
    if [ "$BRANCH" != main ]; then
        record "$NAME" SKIP "on branch '$BRANCH', prod deploys from main"; continue
    fi
    if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
        record "$NAME" SKIP "uncommitted changes"; continue
    fi
    git -C "$REPO" fetch -q origin main 2>/dev/null
    if [ "$(git -C "$REPO" rev-parse HEAD)" != "$(git -C "$REPO" rev-parse origin/main)" ]; then
        record "$NAME" SKIP "main != origin/main (push or pull first)"; continue
    fi

    LAMBDA=$(sed -nE 's/^[[:space:]]*lambda_name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        "$REPO/terraform/aws/prod.tfvars" | head -1)
    BEFORE=$(aws lambda get-function-configuration --function-name "$LAMBDA" \
        --region "$REGION" --query LastModified --output text 2>/dev/null)

    # 2. package via the fork's own deploy.sh (answers "no" at the gate) ---
    ZIP="$REPO/terraform/aws/lambda-deployment.zip"
    MARK="$SHIM_DIR/mark-$NAME"; touch "$MARK"
    (cd "$REPO" && printf 'no\n' | ./scripts/deploy.sh -e prod) > "$LOG" 2>&1
    if [ ! -f "$ZIP" ] || [ ! "$ZIP" -nt "$MARK" ]; then
        record "$NAME" FAIL "deploy.sh did not produce a fresh zip (see $LOG)"; continue
    fi

    # 3. plan + guard ------------------------------------------------------
    TF="$REPO/terraform/aws"
    GOT_WS=$(cd "$TF" && terraform workspace show)
    if [ "$GOT_WS" != "$WS" ]; then
        record "$NAME" FAIL "workspace is '$GOT_WS', expected '$WS'"; continue
    fi
    if ! (cd "$TF" && terraform plan -no-color -input=false -out=tfplan \
            -var-file=prod.tfvars -var="aws_region=$REGION" \
            -var=config_file=config.yaml) >> "$LOG" 2>&1; then
        rm -f "$TF/tfplan"; record "$NAME" FAIL "terraform plan failed (see $LOG)"; continue
    fi
    VERDICT=$(cd "$TF" && terraform show -json tfplan | ALLOW_EXTRA="$ALLOW_EXTRA" \
        ALLOW_DESTROY="$ALLOW_DESTROY" "$PY" -c '
import json, os, sys
plan = json.load(sys.stdin)
extra = os.environ["ALLOW_EXTRA"]
allow_destroy = os.environ["ALLOW_DESTROY"] == "1"
changes, bad = [], []
for rc in plan.get("resource_changes", []):
    acts = rc["change"]["actions"]
    if acts in (["no-op"], ["read"]):
        continue
    addr = rc["address"]
    act = "/".join(acts)
    changes.append(act + ":" + addr)
    if "delete" in acts and not allow_destroy:
        bad.append("destroys " + addr)
    elif addr == "aws_lambda_function.mcp_server" and acts == ["update"]:
        pass
    elif extra and extra in addr:
        pass
    elif "delete" not in acts:
        bad.append("not allowlisted: " + act + " " + addr)
print(("BAD " + "; ".join(bad)) if bad else "OK " + (", ".join(changes) or "no changes"))
')
    echo "  plan: ${VERDICT#* }"
    if [ "${VERDICT%% *}" != OK ]; then
        rm -f "$TF/tfplan"; record "$NAME" HOLD "${VERDICT#BAD }"; continue
    fi

    # 4. apply (only with --apply) ----------------------------------------
    if [ $APPLY = 1 ]; then
        if ! (cd "$TF" && terraform apply -no-color -input=false tfplan) >> "$LOG" 2>&1; then
            rm -f "$TF/tfplan"; record "$NAME" FAIL "apply failed (see $LOG)"; continue
        fi
    fi
    rm -f "$TF/tfplan"

    # 5. verify ------------------------------------------------------------
    AFTER=$(aws lambda get-function-configuration --function-name "$LAMBDA" \
        --region "$REGION" --query LastModified --output text 2>/dev/null)
    SMOKE=$(smoke "$URL")
    case "$SMOKE" in
        "empty=400 tools="[1-9]*) SMOKE_OK=1 ;;
        *) SMOKE_OK=0 ;;
    esac
    if [ $APPLY = 1 ] && [ "$AFTER" = "$BEFORE" ]; then
        record "$NAME" FAIL "applied but Lambda LastModified did not move ($AFTER)"
    elif [ $SMOKE_OK = 0 ]; then
        record "$NAME" FAIL "smoke: $SMOKE"
    elif [ $APPLY = 1 ]; then
        record "$NAME" DEPLOYED "$SMOKE live=$AFTER"
    else
        record "$NAME" READY "$SMOKE (plan ok, not applied)"
    fi
done <<< "$FLEET"

echo
echo "=== summary ($([ $APPLY = 1 ] && echo APPLY || echo dry-run))"
printf '%s\n' "${SUMMARY[@]}"
printf '%s\n' "${SUMMARY[@]}" | grep -qE ' (FAIL|HOLD) ' && exit 1
exit 0
