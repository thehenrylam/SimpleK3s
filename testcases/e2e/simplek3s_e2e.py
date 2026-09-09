#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13, <3.14"
# dependencies = []
# ///
"""End-to-end grading for a deployed SimpleK3s cluster.

This script collects nothing. `sk3s status --depth full --json` already
discovers the nodes, ships the verifier inline over SSM, decodes the replies and
reconciles them across nodes; this reads that one document and grades it against
an answer sheet, then prints a report card.

WHY THE SPLIT. sk3s status reports what is honestly present and refuses to
decide whether a reading is acceptable — a disk at 86% is a number, not a
verdict. Deciding is policy, policy belongs in a test, and it is versioned in
answersheet.default.json rather than compiled into the tool every deploy
depends on.

That division deleted this file's entire first half. The AWS CLI wrapper, the
per-instance rate limiter, node discovery, the batched SSM probe runner, the
stdout splitter, the single-probe retry path and the cross-node reconciler were
all a second implementation of what the host tool does, kept in step by hand.
Two implementations of "ask every node the same question" is exactly the
duplication that let the bash and Python generation digests disagree for a whole
release (#160). What remains here is the matcher, the report card and the sheet.

Run it through uv so Python is version-pinned:

    uv run simplek3s_e2e.py --region us-east-1 --profile PROFILE --nickname NAME
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

# --- constants -------------------------------------------------------------

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEFAULT_STATUS_TOOL = os.path.join(
    REPO_ROOT, "examples", "standard_deployment", "scripts", "sk3s_status.py"
)

# Bumped when the graded snapshot's shape changes, so a stale answer sheet says
# so instead of failing every leaf with "missing key".
SNAPSHOT_SCHEMA = 1

# Worst verdict wins when a section's checks are collapsed to one value.
VERDICT_RANK = {"passed": 0, "skipped": 1, "failed": 2}

# Keys whose values are per-deploy identifiers rather than health: cluster IPs
# in probe URLs, the tailnet hostname, chart versions. Marked $ignore by
# --capture so a sheet taken from one cluster still grades the next.
NOISE_KEYS = {"url", "hostnames", "version", "names", "node", "service"}

# Keys that are live measurements. Marked $ignore wholesale so a sheet captured
# from a healthy cluster does not fail on the next reading's natural drift.
CAPTURE_IGNORE_KEYS = {"usage", "load", "free (MB)", "used (MB)"}

GREEN, YELLOW, RED = "GREEN", "YELLOW", "RED"
EMOJI = {GREEN: "🟢", YELLOW: "🟡", RED: "🟥"}

SECTION_ORDER = ["Cluster Checks", "Nodes / Hardware", "Facts", "Other"]


# --- collection ------------------------------------------------------------


def status_argv(tool, profile, nickname, region):
    """Build the sk3s status invocation.

    The positionals are ordered profile, nickname, region and each defaults from
    config when omitted — so a later one cannot be supplied without the earlier
    ones, and saying so here beats letting argparse bind region to nickname.
    """
    given = [("profile", profile), ("nickname", nickname), ("region", region)]
    argv = [sys.executable, tool]
    for index, (name, value) in enumerate(given):
        if not value:
            missing = [n for n, v in given[index:] if v]
            if missing:
                raise SystemExit(f"--{missing[0]} requires --{name} to be given as well")
            break
        argv.append(value)
    return [*argv, "--depth", "full", "--json"]


def collect(tool, profile, nickname, region, timeout=900):
    """Run sk3s status and return its report."""
    done = subprocess.run(
        status_argv(tool, profile, nickname, region),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    # An unhealthy cluster still produces a document, and grading it is the
    # entire point — so a non-zero exit is expected, not fatal. Only output we
    # cannot parse is fatal, because a report we cannot read is not an empty
    # one and must never grade as a cluster with nothing wrong.
    try:
        return json.loads(done.stdout)
    except ValueError as exc:
        detail = (done.stderr or "").strip()
        raise SystemExit(
            f"sk3s status did not return JSON (exit {done.returncode}): {exc}\n{detail[:2000]}"
        ) from exc


# --- snapshot --------------------------------------------------------------


GATE_SECTION = "k3s_api"


def observed_cluster(document):
    """Whether this node reached the cluster at all."""
    return not any(
        check["section"] == GATE_SECTION and check["result"] == "failed"
        for check in document.get("checks", [])
    )


def section_verdicts(checks):
    """One verdict per section, worst wins.

    Deliberately not keyed on the check message. Messages carry live readings
    ("renewed its lease 0s ago"), so grading them would fail on wording drift
    rather than on health — the same defect the host's cross-node comparison had.
    """
    out = {}
    for check in checks:
        section, result = check["section"], check["result"]
        if section not in out or VERDICT_RANK[result] > VERDICT_RANK[out[section]]:
            out[section] = result
    return out


def build_snapshot(report):
    """Project a sk3s status report into the shape the answer sheet grades.

    Hardware is the only fact that legitimately differs between nodes, so it
    lands per node; everything else is cluster-scoped and read from the first
    readable document. Nodes disagreeing is reported by the tool itself and
    graded here as a count.
    """
    nodes = {}
    reference = None
    fallback = None
    for instance_id, entry in sorted(report.get("nodes", {}).items()):
        document = entry.get("document")
        if document is None:
            # A node we could not read is a node we did not check. __error__
            # makes the matcher fail the whole subtree rather than treat the
            # absent readings as satisfied.
            nodes[instance_id] = {"__error__": entry.get("error") or "no document returned"}
            continue
        # Prefer a node that actually reached the cluster. One that did not
        # stops at the liveness gate and carries two entries, which as a
        # reference would read as a cluster with nothing to report.
        if fallback is None:
            fallback = document
        if reference is None and observed_cluster(document):
            reference = document
        facts = document.get("facts") or {}
        nodes[instance_id] = {
            "result": document["result"],
            "generation_stale": (document.get("generation") or {}).get("stale"),
            "hardware": {
                key.split(".", 1)[1]: value
                for key, value in facts.items()
                if key.startswith("hardware.")
            },
        }

    snapshot = {
        "schema": SNAPSHOT_SCHEMA,
        "cluster": report.get("cluster"),
        "verdict": report.get("result"),
        "disagreements": len(report.get("disagreements") or []),
        "nodes": nodes,
    }
    reference = reference or fallback
    if reference is None:
        snapshot["checks"] = {"__error__": "no node returned a readable document"}
        snapshot["facts"] = {"__error__": "no node returned a readable document"}
        return snapshot

    snapshot["checks"] = section_verdicts(reference["checks"])
    snapshot["facts"] = {
        key: value
        for key, value in (reference.get("facts") or {}).items()
        if not key.startswith("hardware.")
    }
    return snapshot


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
        return GREEN if ok else RED, f"{_fmt(actual)} {'in' if ok else 'out of'} [{lo}, {hi}]"
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
        return GREEN if ok else RED, f"{_fmt(actual)} {'in' if ok else 'not in'} {rule['$in']}"
    return RED, f"unsupported directive {list(rule)}"


def evaluate(expected, actual, path: list[str], checks: list[dict], force_warn: bool = False):
    """Walk the expected (answer-sheet) tree against the actual snapshot."""
    # A subtree we could not collect surfaces as one finding, never as silence.
    if (
        isinstance(actual, dict)
        and "__error__" in actual
        and not (isinstance(expected, dict) and "$ignore" in expected)
    ):
        checks.append(
            _check(path, YELLOW if force_warn else RED, f"not collected: {actual['__error__']}")
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
                    _check(path, RED, f"expected object for $each, got {type(actual).__name__}")
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
                _check(path, RED, f"expected object, got {type(actual).__name__}: {_fmt(actual)}")
            )
            return
        for key, sub in expected.items():
            if key not in actual:
                # An $ignore'd key is optional — its absence is fine (a field a
                # newer collector adds that an older deployed one omits).
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
    if not path:
        return "Other"
    if path[0] == "nodes":
        return "Nodes / Hardware"
    if path[0] == "checks":
        return "Cluster Checks"
    if path[0] == "facts":
        return "Facts"
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
    noisy leaves $ignore. A starting point meant to be edited, not a spec."""

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

    sheet = {
        "schema": snapshot.get("schema", SNAPSHOT_SCHEMA),
        "verdict": snapshot.get("verdict"),
        "disagreements": snapshot.get("disagreements", 0),
        "checks": gen(snapshot.get("checks", {})),
        "facts": gen(snapshot.get("facts", {})),
    }
    node_values = [v for v in snapshot.get("nodes", {}).values() if "__error__" not in v]
    sheet["nodes"] = {"$each": gen(node_values[0])} if node_values else {}
    return sheet


# --- main ------------------------------------------------------------------


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--region", help="AWS region (default: inferred by sk3s status)")
    p.add_argument("--profile", help="AWS profile (default: inferred by sk3s status)")
    p.add_argument("--nickname", help="cluster nickname (default: inferred by sk3s status)")
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
        "--status-tool",
        default=DEFAULT_STATUS_TOOL,
        help="sk3s_status.py to collect through (default: the standard deployment)",
    )
    p.add_argument(
        "--timeout",
        type=int,
        default=900,
        help="seconds to allow sk3s status (default: %(default)s)",
    )
    # Debug / offline hooks.
    p.add_argument(
        "--snapshot-file", help="grade a saved snapshot JSON instead of collecting from AWS"
    )
    p.add_argument("--dump-snapshot", help="write the collected snapshot to this path")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    if args.snapshot_file:
        with open(args.snapshot_file) as handle:
            snapshot = json.load(handle)
    else:
        report = collect(
            args.status_tool, args.profile, args.nickname, args.region, timeout=args.timeout
        )
        snapshot = build_snapshot(report)

    if args.dump_snapshot:
        with open(args.dump_snapshot, "w") as handle:
            json.dump(snapshot, handle, indent=2, sort_keys=True)
        print(f"snapshot written to {args.dump_snapshot}", file=sys.stderr)

    if args.capture:
        sheet = json.dumps(generate_sheet(snapshot), indent=2, sort_keys=True)
        if args.out:
            with open(args.out, "w") as handle:
                handle.write(sheet + "\n")
            print(f"answer sheet written to {args.out}", file=sys.stderr)
        else:
            print(sheet)
        return 0

    with open(args.answersheet) as handle:
        expected = json.load(handle)

    # A sheet written for a different snapshot shape would otherwise fail every
    # leaf with "missing key", which reads as a broken cluster.
    sheet_schema = expected.get("schema")
    if sheet_schema is not None and sheet_schema != snapshot.get("schema", SNAPSHOT_SCHEMA):
        print(
            f"answer sheet is schema {sheet_schema}, snapshot is "
            f"schema {snapshot.get('schema')} — regenerate it with --capture",
            file=sys.stderr,
        )
        return 2

    checks: list[dict] = []
    evaluate(expected, snapshot, [], checks)
    return print_report(checks, args.failures_only)


if __name__ == "__main__":
    sys.exit(main())
