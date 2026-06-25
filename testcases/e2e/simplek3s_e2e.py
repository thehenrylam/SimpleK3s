#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13, <3.14"
# dependencies = []
# ///
"""End-to-end health check for an already-deployed SimpleK3s cluster.

Discovers every running EC2 node tagged with a given ``Nickname``, runs the
on-node ``fetch_*.py`` probes over SSM (in parallel, but globally rate-limited),
cross-checks the results between nodes, stitches them into one cluster snapshot,
compares that snapshot against a JSON "answer sheet", and prints a 🟢/🟡/🟥
report card.

This script is stdlib-only on purpose (so the standard toolchain needs no extra
dependencies); it shells out to the pinned ``aws`` CLI for all AWS access. Run it
through ``uv`` so Python is version-pinned: ``uv run simplek3s_e2e.py ...``.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- constants -------------------------------------------------------------

# Where the cluster's fetch_*.py probes live on each node (see cloudinit / the
# bootstrap layer). Overridable via --remote-py-dir for non-default layouts.
REMOTE_PY_DIR = "/opt/simplek3s/bootstrap/default/py"

# Per-node probe. Reports the host's own CPU/memory/disk.
HARDWARE_PROBE = ("hardware", "fetch_hardware.py")

# Cluster-wide probes. These query the cluster via kubectl, so they only run
# reliably on control-plane nodes and their results must agree across nodes.
# (snapshot key, script filename)
CLUSTER_PROBES = [
    ("k3s_platform", "fetch_k3s-platform.py"),
    ("k3s_apps", "fetch_k3s-apps.py"),
]
# Cluster-wide subsystem/app probes, nested under cluster.apps.<key>.
APP_PROBES = [
    ("traefik", "fetch_app-traefik.py"),
    ("karpenter", "fetch_app-karpenter.py"),
    ("kyverno", "fetch_app-kyverno.py"),
    ("external_secrets", "fetch_app-external-secrets.py"),
    ("longhorn", "fetch_app-longhorn.py"),
    ("argocd", "fetch_app-argocd.py"),
    ("grafana", "fetch_app-grafana.py"),
    ("grafana_pvc", "fetch_app-grafana-pvc.py"),
    ("prometheus", "fetch_app-prometheus.py"),
    ("prometheus_pvc", "fetch_app-prometheus-pvc.py"),
    ("descheduler", "fetch_app-descheduler.py"),
]

# probe_key -> script, used to rerun a single probe during reconciliation. App
# probes are keyed "app:<name>" to match where they land in the snapshot.
# To add/remove a probe, edit the lists above — this registry follows along.
_SCRIPT_BY_KEY = {HARDWARE_PROBE[0]: HARDWARE_PROBE[1]}
_SCRIPT_BY_KEY.update(dict(CLUSTER_PROBES))
_SCRIPT_BY_KEY.update({f"app:{k}": s for k, s in APP_PROBES})

# Keys whose values are inherently noisy (timestamps, per-node identifiers, free
# text). Stripped before cross-node comparison and marked $ignore by --capture.
NOISE_KEYS = {
    "waited_seconds",
    "refresh_time",
    "refreshTime",
    "last_schedule_time",
    "last_successful_time",
    "lastScheduleTime",
    "lastSuccessfulTime",
    "response",
    "message",
    "node_name",
    "provider_id",
}

# Keys whose values are live/per-node measurements (CPU + memory + disk usage).
# --capture marks these $ignore wholesale so a sheet captured from one healthy
# cluster doesn't fail on the next reading's natural fluctuation.
CAPTURE_IGNORE_KEYS = {"usage", "load", "free (MB)", "used (MB)"}

# Report card statuses.
GREEN, YELLOW, RED = "GREEN", "YELLOW", "RED"
EMOJI = {GREEN: "🟢", YELLOW: "🟡", RED: "🟥"}

SECTION_ORDER = ["Nodes / Hardware", "K3s Platform", "K3s Apps", "Subsystems", "Other"]

# --- per-instance AWS-call rate limiter ------------------------------------
#
# Each rate "key" — an instance id, or "global" for account-wide calls such as
# describe-instances — is throttled to at most one call per _RATE_INTERVAL
# seconds. Different keys are independent, so with N nodes the cluster is polled
# at up to ~N AWS calls/second total while no single node (and the discovery
# call) is ever hit faster than 1/interval. This matches "poll every node ~once
# a second, concurrently" rather than one global call per second.

_RATE_INTERVAL = 1.0  # seconds between consecutive calls *for a given key*
_RATE_STATE_LOCK = threading.Lock()
_rate_locks: dict[str, threading.Lock] = {}
_last_call_at: dict[str, float] = {}


def _rate_lock_for(key: str) -> threading.Lock:
    with _RATE_STATE_LOCK:
        lock = _rate_locks.get(key)
        if lock is None:
            lock = _rate_locks[key] = threading.Lock()
        return lock


def aws(
    args: list[str],
    region: str,
    profile: str,
    timeout: int = 90,
    rate_key: str = "global",
) -> subprocess.CompletedProcess:
    """Run an ``aws`` CLI call, throttled per ``rate_key``.

    The per-key lock is held across the sleep, so only *this key's* calls are
    serialized; calls for other keys (other instances) run concurrently. That
    yields ~N calls/second for N nodes, never more than one call per interval
    against any single node."""
    lock = _rate_lock_for(rate_key)
    with lock:
        wait = _last_call_at.get(rate_key, 0.0) + _RATE_INTERVAL - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        _last_call_at[rate_key] = time.monotonic()

    cmd = ["aws", *args, "--region", region, "--profile", profile, "--output", "json"]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# --- node discovery --------------------------------------------------------


def _role_from_name(name: str) -> str:
    # cluster_ec2.tf names nodes "<...>_controlplane-<suffix>" / "<...>_agentplane-<suffix>".
    if "controlplane" in name:
        return "controlplane"
    if "agentplane" in name:
        return "agentplane"
    return "unknown"


def discover_nodes(region: str, profile: str, nickname: str) -> list[dict]:
    """Return running instances tagged Nickname=<nickname> as {id, name, role}."""
    result = aws(
        [
            "ec2",
            "describe-instances",
            "--filters",
            f"Name=tag:Nickname,Values={nickname}",
            "Name=instance-state-name,Values=running",
        ],
        region,
        profile,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"describe-instances failed: {result.stderr.strip() or result.stdout.strip()}"
        )

    nodes = []
    data = json.loads(result.stdout or "{}")
    for reservation in data.get("Reservations", []):
        for inst in reservation.get("Instances", []):
            name = next(
                (t["Value"] for t in inst.get("Tags", []) if t.get("Key") == "Name"),
                "",
            )
            nodes.append(
                {
                    "id": inst["InstanceId"],
                    "name": name,
                    "role": _role_from_name(name),
                }
            )
    nodes.sort(key=lambda n: (n["role"], n["name"], n["id"]))
    return nodes


# --- SSM probe execution ---------------------------------------------------
#
# All probes for a node run inside ONE SSM command. Each probe's output is framed
# by BEGIN/END markers so the combined stdout can be split back into per-probe
# JSON. Probes are newline-separated (not "&&"/";"-chained): the fetch_*.py
# scripts exit non-zero when "not ready", and we never want one not-ready probe
# to skip the rest. The END marker also records each probe's exit code.

_MARKER_BEGIN = "@@SK3S_BEGIN"
_MARKER_END = "@@SK3S_END"
_MARKER_RE = re.compile(
    rf"{re.escape(_MARKER_BEGIN)} (?P<key>\S+)@@\s*(?P<body>.*?)\s*"
    rf"{re.escape(_MARKER_END)} (?P=key) (?P<code>-?\d+)@@",
    re.DOTALL,
)


def _extract_json(text: str):
    # A probe's segment may carry a non-JSON preamble (e.g. fetch_hardware prints
    # the raw disk tuple before its JSON). Decode from the first '{'.
    start = text.find("{")
    if start < 0:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
        return obj
    except json.JSONDecodeError:
        return None


def _build_batch_command(probes: list[tuple[str, str]], remote_dir: str) -> list[str]:
    # Build the AWS-RunShellScript "commands" list. Every element runs in the
    # same shell in order, so the leading `cd` persists for all probes.
    lines = [f"cd {remote_dir}"]
    for key, script in probes:
        lines.append(f"echo '{_MARKER_BEGIN} {key}@@'")
        # --compact: every probe emits compact JSON here so the combined stdout of
        # all probes stays under SSM's ~24KB get-command-invocation truncation
        # limit (a manual run without the flag still prints indented JSON).
        lines.append(f'sudo uv run ./{script} --compact; echo "{_MARKER_END} {key} $?@@"')
    return lines


def _parse_batch_output(stdout: str, expected_keys: list[str]) -> dict:
    # Split combined stdout into one result per probe key. A key whose segment
    # has no parseable JSON (probe crashed, or output exceeded SSM's ~24KB inline
    # limit and got truncated) becomes an explicit error rather than vanishing.
    results: dict[str, dict] = {}
    for m in _MARKER_RE.finditer(stdout):
        key, body, code = m.group("key"), m.group("body"), int(m.group("code"))
        parsed = _extract_json(body)
        results[key] = (
            parsed
            if parsed is not None
            else {
                "__error__": f"no JSON output (exit {code})",
                "__raw__": body.strip()[:500],
            }
        )
    for key in expected_keys:
        results.setdefault(
            key,
            {"__error__": "no output marker (probe crashed, or SSM output truncated?)"},
        )
    return results


def run_batch(
    instance_id: str,
    probes: list[tuple[str, str]],
    region: str,
    profile: str,
    remote_dir: str,
    probe_timeout: int,
) -> dict:
    """Run every probe for one node in a single SSM command. Returns
    {probe_key: parsed-JSON-or-error} — one send + one poll-loop per node."""
    expected = [key for key, _ in probes]

    def fail_all(msg: str) -> dict:
        return {key: {"__error__": msg} for key in expected}

    params = json.dumps({"commands": _build_batch_command(probes, remote_dir)})
    send = aws(
        [
            "ssm",
            "send-command",
            "--instance-ids",
            instance_id,
            "--document-name",
            "AWS-RunShellScript",
            "--parameters",
            params,
        ],
        region,
        profile,
        rate_key=instance_id,
    )
    if send.returncode != 0:
        return fail_all(f"send-command failed: {send.stderr.strip() or send.stdout.strip()}")
    try:
        command_id = json.loads(send.stdout)["Command"]["CommandId"]
    except (json.JSONDecodeError, KeyError) as exc:
        return fail_all(f"could not read CommandId: {exc}")

    deadline = time.monotonic() + probe_timeout
    data = {}
    while True:
        inv = aws(
            [
                "ssm",
                "get-command-invocation",
                "--command-id",
                command_id,
                "--instance-id",
                instance_id,
            ],
            region,
            profile,
            rate_key=instance_id,
        )
        if inv.returncode != 0:
            # Right after send-command the invocation may not be registered yet
            # (InvocationDoesNotExist). Retry until the deadline; the rate limiter
            # already spaces these out so this is not a busy-loop.
            if time.monotonic() > deadline:
                return fail_all(f"get-command-invocation failed: {inv.stderr.strip()}")
            continue
        try:
            data = json.loads(inv.stdout)
        except json.JSONDecodeError as exc:
            return fail_all(f"could not parse invocation: {exc}")
        status = data.get("Status", "")
        if status not in ("Pending", "InProgress", "Delayed", "Cancelling"):
            break
        if time.monotonic() > deadline:
            return fail_all(f"probe timed out (last status {status})")

    # An individual probe's non-zero exit does NOT fail the whole command (no
    # chaining), so a Failed/TimedOut overall status points at an infra problem.
    # Still, partial stdout may exist — parse it; per-probe markers fill the gaps.
    parsed = _parse_batch_output(data.get("StandardOutputContent", ""), expected)
    if data.get("Status") != "Success" and all("__error__" in r for r in parsed.values()):
        stderr = (data.get("StandardErrorContent") or "").strip()
        return fail_all(f"command status {data.get('Status')}: {stderr[:300]}")
    return parsed


def run_probe(
    instance_id: str,
    probe_key: str,
    script: str,
    region: str,
    profile: str,
    remote_dir: str,
    probe_timeout: int,
) -> dict:
    """Run a single probe (used for reconciliation reruns), via run_batch."""
    return run_batch(
        instance_id, [(probe_key, script)], region, profile, remote_dir, probe_timeout
    ).get(probe_key, {"__error__": "rerun produced no result"})


# --- collection ------------------------------------------------------------


def collect(
    nodes: list[dict],
    region: str,
    profile: str,
    remote_dir: str,
    probe_timeout: int,
    max_workers: int,
) -> dict:
    """Run all probes across all nodes in parallel. Returns a nested map:
    raw[instance_id][probe_key] = parsed-result-or-error."""
    control_planes = [n for n in nodes if n["role"] == "controlplane"]
    if not control_planes:
        raise RuntimeError("no control-plane nodes discovered; cannot run cluster-wide probes")

    # Per node: hardware on every node; cluster + app probes on control-plane
    # nodes. All of a node's probes run in one SSM command (see run_batch).
    probes_by_node: dict[str, list[tuple[str, str]]] = {n["id"]: [] for n in nodes}
    for node in nodes:
        probes_by_node[node["id"]].append(HARDWARE_PROBE)
    for node in control_planes:
        probes_by_node[node["id"]].extend(CLUSTER_PROBES)
        probes_by_node[node["id"]].extend((f"app:{k}", s) for k, s in APP_PROBES)

    raw: dict[str, dict] = {n["id"]: {} for n in nodes}

    def _do(instance_id: str):
        return instance_id, run_batch(
            instance_id,
            probes_by_node[instance_id],
            region,
            profile,
            remote_dir,
            probe_timeout,
        )

    # One worker per node so all nodes run concurrently (each is throttled
    # independently to ≤1 call/interval).
    workers = max(max_workers, len(nodes))
    total_probes = sum(len(p) for p in probes_by_node.values())
    print(
        f"  Running {total_probes} probe(s) across {len(nodes)} node(s) — "
        f"one SSM command per node, nodes polled concurrently "
        f"(≤1 call/{_RATE_INTERVAL:.1f}s each)...",
        file=sys.stderr,
    )
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for future in as_completed(pool.submit(_do, n["id"]) for n in nodes):
            instance_id, node_results = future.result()
            raw[instance_id] = node_results
    return raw


def rerun_probe(
    instance_id: str,
    probe_key: str,
    region: str,
    profile: str,
    remote_dir: str,
    probe_timeout: int,
) -> dict:
    script = _SCRIPT_BY_KEY.get(probe_key)
    if script is None:
        return {"__error__": f"unknown probe key {probe_key}"}
    return run_probe(instance_id, probe_key, script, region, profile, remote_dir, probe_timeout)


# --- cross-node comparison + stitching -------------------------------------


def normalize(obj):
    """Strip noisy keys and sort lists so equivalent results compare equal."""
    if isinstance(obj, dict):
        return {k: normalize(v) for k, v in sorted(obj.items()) if k not in NOISE_KEYS}
    if isinstance(obj, list):
        norm = [normalize(x) for x in obj]
        return sorted(norm, key=lambda x: json.dumps(x, sort_keys=True))
    return obj


def _canonical_key(obj) -> str:
    return json.dumps(normalize(obj), sort_keys=True)


def reconcile_cluster_probe(
    probe_key: str,
    raw: dict,
    control_planes: list[dict],
    region: str,
    profile: str,
    remote_dir: str,
    probe_timeout: int,
    agreement_path: list[str],
):
    """Stringently reconcile one cluster-wide probe across control-plane nodes.

    Returns (canonical_result, agreement_check). On disagreement the minority
    node(s) are rerun once to absorb flukes; persistent disagreement is RED."""

    def results():
        return {
            n["id"]: raw[n["id"]].get(probe_key, {"__error__": "not collected"})
            for n in control_planes
        }

    current = results()
    errored = {i: r for i, r in current.items() if isinstance(r, dict) and "__error__" in r}
    good = {i: r for i, r in current.items() if i not in errored}

    if not good:
        msgs = "; ".join(f"{i[:19]}: {r['__error__']}" for i, r in errored.items())
        return (
            {"__error__": f"all control-plane probes failed ({msgs})"},
            _check(agreement_path, RED, f"all {len(errored)} CP node(s) failed this probe"),
        )

    def grouped(d):
        groups: dict[str, list[str]] = {}
        for inst, res in d.items():
            groups.setdefault(_canonical_key(res), []).append(inst)
        return groups

    groups = grouped(good)
    rerun_note = ""
    if len(groups) > 1:
        # Rerun the minority node(s) once — disagreement is often a transient race.
        majority = max(groups.values(), key=len)
        minority = [i for ids in groups.values() if ids is not majority for i in ids]
        for inst in minority:
            good[inst] = rerun_probe(inst, probe_key, region, profile, remote_dir, probe_timeout)
        good = {i: r for i, r in good.items() if not (isinstance(r, dict) and "__error__" in r)}
        groups = grouped(good)
        rerun_note = " (after rerunning minority node(s))"

    canonical = good[max(groups.values(), key=len)[0]]

    if len(groups) > 1:
        sizes = ", ".join(f"{len(ids)}×" for ids in groups.values())
        check = _check(
            agreement_path,
            RED,
            f"control-plane nodes disagree{rerun_note}: {len(groups)} variants ({sizes})",
        )
    elif errored:
        check = _check(
            agreement_path,
            YELLOW,
            f"{len(good)} CP node(s) agree{rerun_note}; {len(errored)} node(s) errored",
        )
    elif rerun_note:
        check = _check(agreement_path, GREEN, f"control-plane nodes agree{rerun_note}")
    else:
        check = _check(agreement_path, GREEN, f"all {len(good)} control-plane node(s) agree")
    return canonical, check


def hardware_agreement(raw: dict, nodes: list[dict]) -> list[dict]:
    """Lax cross-node hardware sanity. Warns (never fails) on structural drift."""
    checks = []
    good = {
        n["id"]: raw[n["id"]].get("hardware")
        for n in nodes
        if isinstance(raw[n["id"]].get("hardware"), dict)
        and "__error__" not in raw[n["id"]]["hardware"]
    }
    if len(good) < 2:
        return checks

    path = ["nodes", "__agreement__"]
    core_counts = {len(r.get("cpu", {}).get("usage", {})) for r in good.values()}
    if len(core_counts) > 1:
        checks.append(
            _check(
                path + ["cpu_cores"],
                YELLOW,
                f"CPU core counts differ across nodes: {sorted(core_counts)}",
            )
        )

    # Total RAM / disk should be uniform within a node pool; warn (don't fail) on drift.
    ram_totals = [
        r["memory"]["ram"]["total (MB)"]
        for r in good.values()
        if r.get("memory", {}).get("ram", {}).get("total (MB)") is not None
    ]
    disk_totals = [
        r["disk"]["total (MB)"]
        for r in good.values()
        if r.get("disk", {}).get("total (MB)") is not None
    ]
    for label, vals in (
        ("RAM total (MB)", ram_totals),
        ("disk total (MB)", disk_totals),
    ):
        if len(vals) >= 2 and min(vals) > 0 and (max(vals) - min(vals)) / max(vals) > 0.10:
            checks.append(
                _check(
                    path + [label],
                    YELLOW,
                    f"{label} varies >10% across nodes: {min(vals)}–{max(vals)}",
                )
            )
    return checks


def stitch(
    raw: dict,
    nodes: list[dict],
    region: str,
    profile: str,
    remote_dir: str,
    probe_timeout: int,
) -> tuple[dict, list[dict]]:
    """Build the deduplicated cluster snapshot and the cross-node agreement checks."""
    control_planes = [n for n in nodes if n["role"] == "controlplane"]
    snapshot = {"nodes": {}, "cluster": {"apps": {}}}
    agreement_checks: list[dict] = []

    for node in nodes:
        snapshot["nodes"][node["id"]] = {
            "role": node["role"],
            "name": node["name"],
            "hardware": raw[node["id"]].get("hardware", {"__error__": "not collected"}),
        }
    agreement_checks += hardware_agreement(raw, nodes)

    for key, _ in CLUSTER_PROBES:
        canonical, check = reconcile_cluster_probe(
            key,
            raw,
            control_planes,
            region,
            profile,
            remote_dir,
            probe_timeout,
            ["cluster", key, "__agreement__"],
        )
        snapshot["cluster"][key] = canonical
        agreement_checks.append(check)

    for key, _ in APP_PROBES:
        canonical, check = reconcile_cluster_probe(
            f"app:{key}",
            raw,
            control_planes,
            region,
            profile,
            remote_dir,
            probe_timeout,
            ["cluster", "apps", key, "__agreement__"],
        )
        snapshot["cluster"]["apps"][key] = canonical
        agreement_checks.append(check)

    return snapshot, agreement_checks


# --- answer-sheet matcher --------------------------------------------------


def _check(path: list[str], status: str, message: str) -> dict:
    return {"path": list(path), "status": status, "message": message}


def _fmt(value) -> str:
    s = value if isinstance(value, str) else json.dumps(value)
    return s if len(s) <= 80 else s[:77] + "..."


def _is_directive(d) -> bool:
    return isinstance(d, dict) and any(k.startswith("$") for k in d)


def _match_value(rule: dict, actual) -> tuple[str, str]:
    if "$regex" in rule:
        ok = re.fullmatch(rule["$regex"], str(actual)) is not None
        return (
            GREEN if ok else RED,
            f"{'matches' if ok else 'no match'} /{rule['$regex']}/ (got {_fmt(actual)})",
        )
    if "$range" in rule:
        lo, hi = rule["$range"]
        try:
            n = float(actual)
        except (TypeError, ValueError):
            return RED, f"not numeric: {_fmt(actual)}"
        ok = lo <= n <= hi
        return (
            GREEN if ok else RED,
            f"{_fmt(actual)} {'in' if ok else 'out of'} [{lo}, {hi}]",
        )
    if "$gte" in rule or "$lte" in rule:
        try:
            n = float(actual)
        except (TypeError, ValueError):
            return RED, f"not numeric: {_fmt(actual)}"
        ok, parts = True, []
        if "$gte" in rule:
            ok = ok and n >= rule["$gte"]
            parts.append(f">= {rule['$gte']}")
        if "$lte" in rule:
            ok = ok and n <= rule["$lte"]
            parts.append(f"<= {rule['$lte']}")
        return (
            GREEN if ok else RED,
            f"{_fmt(actual)} {'satisfies' if ok else 'violates'} {' and '.join(parts)}",
        )
    if "$in" in rule:
        ok = actual in rule["$in"]
        return (
            GREEN if ok else RED,
            f"{_fmt(actual)} {'in' if ok else 'not in'} {rule['$in']}",
        )
    return RED, f"unsupported directive {list(rule)}"


def evaluate(expected, actual, path: list[str], checks: list[dict], force_warn: bool = False):
    """Walk the expected (answer-sheet) tree against the actual snapshot."""
    # A failed probe surfaces as one finding for the whole subtree.
    if (
        isinstance(actual, dict)
        and "__error__" in actual
        and not (isinstance(expected, dict) and "$ignore" in expected)
    ):
        checks.append(
            _check(
                path,
                YELLOW if force_warn else RED,
                f"probe error: {actual['__error__']}",
            )
        )
        return

    if isinstance(expected, dict) and _is_directive(expected):
        if "$ignore" in expected:
            checks.append(_check(path, GREEN, "ignored"))
            return
        if "$warn" in expected:
            evaluate(expected["$warn"], actual, path, checks, force_warn=True)
            return
        if "$each" in expected:
            if not isinstance(actual, dict):
                checks.append(
                    _check(
                        path,
                        RED,
                        f"expected object for $each, got {type(actual).__name__}",
                    )
                )
                return
            if not actual:
                checks.append(_check(path, YELLOW, "no entries to match"))
            for key, value in actual.items():
                evaluate(expected["$each"], value, path + [key], checks, force_warn)
            return
        status, message = _match_value(expected, actual)
        if status == RED and force_warn:
            status = YELLOW
        checks.append(_check(path, status, message))
        return

    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            checks.append(
                _check(
                    path,
                    RED,
                    f"expected object, got {type(actual).__name__}: {_fmt(actual)}",
                )
            )
            return
        for key, sub in expected.items():
            if key not in actual:
                # An $ignore'd key is optional — its absence is fine (e.g. a
                # field a newer probe adds that an older deployed probe omits).
                if isinstance(sub, dict) and sub.get("$ignore") is True:
                    checks.append(_check(path + [key], GREEN, "ignored (absent)"))
                else:
                    checks.append(_check(path + [key], RED, "missing key"))
            else:
                evaluate(sub, actual[key], path + [key], checks, force_warn)
        return

    # literal
    if expected == actual:
        checks.append(_check(path, GREEN, f"= {_fmt(actual)}"))
    else:
        checks.append(
            _check(
                path,
                YELLOW if force_warn else RED,
                f"expected {_fmt(expected)}, got {_fmt(actual)}",
            )
        )


# --- report card -----------------------------------------------------------


def _section_for(path: list[str]) -> str:
    if path and path[0] == "nodes":
        return "Nodes / Hardware"
    if path[:2] == ["cluster", "k3s_platform"]:
        return "K3s Platform"
    if path[:2] == ["cluster", "k3s_apps"]:
        return "K3s Apps"
    if path[:2] == ["cluster", "apps"]:
        return "Subsystems"
    return "Other"


def print_report(checks: list[dict], failures_only: bool) -> int:
    by_section: dict[str, list[dict]] = {}
    for c in checks:
        by_section.setdefault(_section_for(c["path"]), []).append(c)

    print("\n=== SimpleK3s E2E Report Card ===\n")
    for section in SECTION_ORDER:
        section_checks = by_section.get(section, [])
        shown = [c for c in section_checks if not failures_only or c["status"] in (YELLOW, RED)]
        if not section_checks:
            continue
        if not shown:
            print(f"{section}: 🟢 all {len(section_checks)} checks passed")
            continue
        print(f"{section}:")
        for c in shown:
            print(f"  {EMOJI[c['status']]} {'.'.join(c['path'])}  —  {c['message']}")
        print()

    greens = sum(1 for c in checks if c["status"] == GREEN)
    yellows = sum(1 for c in checks if c["status"] == YELLOW)
    reds = sum(1 for c in checks if c["status"] == RED)
    print(
        f"Summary: {EMOJI[GREEN]} {greens} passed   "
        f"{EMOJI[YELLOW]} {yellows} warnings   {EMOJI[RED]} {reds} failures"
    )
    return 1 if reds else 0


# --- capture mode ----------------------------------------------------------


def generate_sheet(snapshot: dict) -> dict:
    """Turn a snapshot from a known-good cluster into an answer sheet, marking
    noisy leaves $ignore. The result is a starting point meant to be edited."""

    def gen(obj, key=None):
        if key in NOISE_KEYS or key in CAPTURE_IGNORE_KEYS:
            return {"$ignore": True}
        if isinstance(obj, bool):
            return obj
        if isinstance(obj, int):
            return obj
        if isinstance(obj, float):
            return {"$ignore": True}
        if isinstance(obj, str):
            return obj
        if isinstance(obj, list):
            return {"$ignore": True}
        if isinstance(obj, dict):
            return {k: gen(v, k) for k, v in obj.items()}
        return {"$ignore": True}

    sheet = {"cluster": gen(snapshot.get("cluster", {}))}
    node_values = list(snapshot.get("nodes", {}).values())
    if node_values:
        template = gen(node_values[0])
        # Per-node identity is not portable across nodes.
        template["name"] = {"$ignore": True}
        template["role"] = {"$regex": "controlplane|agentplane"}
        sheet = {"nodes": {"$each": template}, **sheet}
    else:
        sheet = {"nodes": {}, **sheet}
    return sheet


# --- main ------------------------------------------------------------------


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--region", help="AWS region")
    p.add_argument("--profile", help="AWS profile")
    p.add_argument("--nickname", help="cluster Nickname tag to discover nodes by")
    default_sheet = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "answersheet.default.json"
    )
    p.add_argument(
        "-a",
        "--answersheet",
        default=default_sheet,
        help="answer sheet to compare against (default: %(default)s)",
    )
    p.add_argument(
        "--failures-only",
        action="store_true",
        help="show only warnings and failures in the report",
    )
    p.add_argument(
        "--capture",
        action="store_true",
        help="generate an answer sheet from the current cluster instead of grading",
    )
    p.add_argument("-o", "--out", help="where --capture writes the sheet (default: stdout)")
    p.add_argument(
        "--rate-interval",
        type=float,
        default=1.0,
        help="min seconds between AWS call starts (default: %(default)s)",
    )
    p.add_argument(
        "--probe-timeout",
        type=int,
        default=300,
        help="per-probe timeout in seconds (default: %(default)s)",
    )
    p.add_argument(
        "--max-workers",
        type=int,
        default=8,
        help="parallel probe workers (default: %(default)s)",
    )
    p.add_argument(
        "--remote-py-dir",
        default=REMOTE_PY_DIR,
        help="on-node directory holding the fetch_*.py probes",
    )
    # Debug / offline hooks.
    p.add_argument(
        "--snapshot-file",
        help="grade a saved snapshot JSON instead of collecting via AWS",
    )
    p.add_argument("--dump-snapshot", help="write the collected snapshot to this path")
    return p.parse_args(argv)


def main(argv=None) -> int:
    global _RATE_INTERVAL
    args = parse_args(argv)
    _RATE_INTERVAL = args.rate_interval

    # Offline path: grade a pre-collected snapshot (used for tests).
    if args.snapshot_file:
        with open(args.snapshot_file) as fh:
            snapshot = json.load(fh)
        agreement_checks = []
    else:
        for required in ("region", "profile", "nickname"):
            if not getattr(args, required):
                print(
                    f"error: --{required} is required (or pass --snapshot-file)",
                    file=sys.stderr,
                )
                return 2
        print(
            f"Discovering nodes for Nickname={args.nickname} in {args.region}...",
            file=sys.stderr,
        )
        nodes = discover_nodes(args.region, args.profile, args.nickname)
        if not nodes:
            print(
                f"error: no running instances tagged Nickname={args.nickname}",
                file=sys.stderr,
            )
            return 2
        for n in nodes:
            print(f"  - {n['id']}  {n['role']:<13} {n['name']}", file=sys.stderr)

        raw = collect(
            nodes,
            args.region,
            args.profile,
            args.remote_py_dir,
            args.probe_timeout,
            args.max_workers,
        )
        snapshot, agreement_checks = stitch(
            raw,
            nodes,
            args.region,
            args.profile,
            args.remote_py_dir,
            args.probe_timeout,
        )

    if args.dump_snapshot:
        with open(args.dump_snapshot, "w") as fh:
            json.dump(snapshot, fh, indent=2)
        print(f"Wrote snapshot to {args.dump_snapshot}", file=sys.stderr)

    if args.capture:
        sheet = generate_sheet(snapshot)
        text = json.dumps(sheet, indent=2)
        if args.out:
            with open(args.out, "w") as fh:
                fh.write(text + "\n")
            print(f"Wrote captured answer sheet to {args.out}", file=sys.stderr)
        else:
            print(text)
        return 0

    with open(args.answersheet) as fh:
        expected = json.load(fh)

    checks: list[dict] = list(agreement_checks)
    evaluate(expected, snapshot, [], checks)
    return print_report(checks, args.failures_only)


if __name__ == "__main__":
    sys.exit(main())
