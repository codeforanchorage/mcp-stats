"""Scheduled health + conformance probe for every MCP in the fleet.

Runs as a Lambda on an EventBridge schedule (terraform/aws/fleet_probe.tf).
For each target it sends a handful of MCP requests and checks the answers,
then publishes per-MCP CloudWatch metrics that the fleet alarms watch:

  MCPFleet/Probe  FailedChecks  (dimension MCP=<name>)  -- 0 when healthy
  MCPFleet/Probe  ProbeRuns                             -- heartbeat, 1/run

Every failed check is also logged as one JSON line (level=ERROR) with the
status and a response excerpt, so an alarm can be traced to the exact check
in CloudWatch Logs.

Deliberately NEVER calls tools/call: the fleet dashboard's "real usage"
widgets count tools/call as genuine adoption, and a probe calling tools would
both inflate them and put load on the upstream data APIs. tools/list proves
the plugin loaded; that is the health signal.

Checks run SEQUENTIALLY per target (targets run in parallel) so the probe
never holds more than one of a server's reserved-concurrency slots.

Run locally (no metrics published):
    python probe/fleet_probe.py                      # uses PROBE_TARGETS
    python probe/fleet_probe.py https://host/mcp     # one ad-hoc target
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

MODERN = "2026-07-28"
LEGACY = "2025-06-18"
CLIENT = {"name": "mcp-fleet-probe", "version": "1.0"}
NAMESPACE = "MCPFleet/Probe"
TIMEOUT_S = 25  # under the 29s API Gateway ceiling


def _post(url, body, headers=None, raw=None):
    """POST and return (status, parsed_json_or_text). Never raises."""
    data = raw if raw is not None else json.dumps(body).encode()
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "User-Agent": "mcp-fleet-probe/1.0",
        **(headers or {}),
    }
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            status, text = resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # timeout, DNS, TLS, connection reset
        return 0, f"{type(e).__name__}: {e}"
    try:
        return status, json.loads(text) if text else None
    except json.JSONDecodeError:
        return status, text


def _modern_meta():
    return {
        "io.modelcontextprotocol/protocolVersion": MODERN,
        "io.modelcontextprotocol/clientInfo": CLIENT,
        "io.modelcontextprotocol/clientCapabilities": {},
    }


def _result(r):
    return r.get("result") if isinstance(r, dict) else None


def _err_code(r):
    if isinstance(r, dict) and isinstance(r.get("error"), dict):
        return r["error"].get("code")
    return None


# Each check: (name, conformance_only, fn(url) -> (ok, status, response)).
# "Core" checks answer "is it up and serving tools?"; conformance checks
# answer "does it still speak current MCP correctly?". Targets with
# modern=false (a server not yet on 2026-07-28) run core checks only.

def check_legacy_initialize(url):
    s, r = _post(url, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": LEGACY, "capabilities": {},
                   "clientInfo": CLIENT},
    })
    res = _result(r) or {}
    return s == 200 and bool(res.get("protocolVersion")), s, r


def check_tools_list(url):
    s, r = _post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                 {"MCP-Protocol-Version": LEGACY})
    tools = (_result(r) or {}).get("tools") or []
    return s == 200 and len(tools) > 0, s, r


def check_empty_post_not_5xx(url):
    s, r = _post(url, None, raw=b"")
    return 0 < s < 500, s, r


def check_server_discover(url):
    s, r = _post(url, {
        "jsonrpc": "2.0", "id": 3, "method": "server/discover",
        "params": {"_meta": _modern_meta()},
    }, {"MCP-Protocol-Version": MODERN, "Mcp-Method": "server/discover"})
    versions = (_result(r) or {}).get("supportedVersions") or []
    return s == 200 and versions[:1] == [MODERN], s, r


def check_unknown_method(url):
    s, r = _post(url, {"jsonrpc": "2.0", "id": 4, "method": "probe/no-such"},
                 {"MCP-Protocol-Version": LEGACY})
    return _err_code(r) == -32601, s, r


def check_ping(url):
    s, r = _post(url, {"jsonrpc": "2.0", "id": 5, "method": "ping"},
                 {"MCP-Protocol-Version": LEGACY})
    return s == 200 and _result(r) == {}, s, r


def check_bad_version_echoes_id(url):
    s, r = _post(url, {"jsonrpc": "2.0", "id": 4242, "method": "tools/list"},
                 {"MCP-Protocol-Version": "1999-01-01"})
    return (_err_code(r) == -32022 and isinstance(r, dict)
            and r.get("id") == 4242), s, r


def check_empty_post_is_400(url):
    s, r = _post(url, None, raw=b"")
    return s == 400 and _err_code(r) == -32700, s, r


CHECKS = [
    ("legacy_initialize", False, check_legacy_initialize),
    ("tools_list", False, check_tools_list),
    ("empty_post_not_5xx", False, check_empty_post_not_5xx),
    ("server_discover", True, check_server_discover),
    ("unknown_method_32601", True, check_unknown_method),
    ("ping_empty_object", True, check_ping),
    ("bad_version_32022_id", True, check_bad_version_echoes_id),
    ("empty_post_400_32700", True, check_empty_post_is_400),
]


def probe_target(name, target):
    url, modern = target["url"], target.get("modern", True)
    failures, started = [], time.monotonic()
    for check_name, conformance, fn in CHECKS:
        if conformance and not modern:
            continue
        try:
            ok, status, resp = fn(url)
        except Exception as e:  # a bug in a check must not hide the rest
            ok, status, resp = False, 0, f"{type(e).__name__}: {e}"
        if not ok:
            failures.append({
                "check": check_name,
                "status": status,
                "response": (resp if isinstance(resp, str)
                             else json.dumps(resp))[:400],
            })
    return {
        "mcp": name,
        "url": url,
        "failed": len(failures),
        "failures": failures,
        "duration_ms": round((time.monotonic() - started) * 1000),
    }


def run(targets):
    with ThreadPoolExecutor(max_workers=max(1, len(targets))) as pool:
        return list(pool.map(lambda kv: probe_target(*kv), targets.items()))


def publish(results):
    import boto3  # in the Lambda runtime; not needed for local runs

    cw = boto3.client("cloudwatch")
    data = [{"MetricName": "ProbeRuns", "Value": 1, "Unit": "Count"}]
    for r in results:
        dims = [{"Name": "MCP", "Value": r["mcp"]}]
        data.append({"MetricName": "FailedChecks", "Dimensions": dims,
                     "Value": r["failed"], "Unit": "Count"})
        data.append({"MetricName": "ProbeDurationMs", "Dimensions": dims,
                     "Value": r["duration_ms"], "Unit": "Milliseconds"})
    for i in range(0, len(data), 20):  # stay well under the per-call limit
        cw.put_metric_data(Namespace=NAMESPACE, MetricData=data[i:i + 20])


def log_results(results):
    for r in results:
        line = {"level": "ERROR" if r["failed"] else "INFO",
                "message": "probe failed" if r["failed"] else "probe ok", **r}
        print(json.dumps(line))


def lambda_handler(event, context):
    targets = json.loads(os.environ["PROBE_TARGETS"])
    results = run(targets)
    log_results(results)
    publish(results)
    return {"failed_mcps": [r["mcp"] for r in results if r["failed"]]}


if __name__ == "__main__":
    if len(sys.argv) > 1:
        tgts = {"adhoc": {"url": sys.argv[1], "modern": True}}
    else:
        tgts = json.loads(os.environ["PROBE_TARGETS"])
    res = run(tgts)
    for r in sorted(res, key=lambda x: x["mcp"]):
        mark = "OK  " if not r["failed"] else "FAIL"
        print(f"{mark} {r['mcp']:20} {r['duration_ms']:>6}ms  "
              + ", ".join(f"{f['check']}({f['status']})" for f in r["failures"]))
    sys.exit(1 if any(r["failed"] for r in res) else 0)
