#!/usr/bin/env python3
"""Cluster health, merged across control-plane nodes.

Replaces ssm_verify_cluster.sh. The verifier is shipped inline with every run
(see sk3slib.payload), so the node cannot be running a different version than
the host expects.

Exit codes: 0 healthy, 1 unhealthy or unreadable, 2 bad usage.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sk3slib import payload, ssm  # noqa: E402

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEPLOYMENT_DIR = os.path.dirname(SCRIPT_DIR)
REPO_ROOT = os.path.abspath(os.path.join(DEPLOYMENT_DIR, "..", ".."))

EXIT_OK, EXIT_FAIL, EXIT_USAGE = 0, 1, 2

RESULT_ORDER = {"failed": 0, "skipped": 1, "passed": 2}

# Tunables the node's checks read. Forwarded from this process's environment so
# cluster_verify.yml can still narrow the restart window right after an apply.
# A knob that silently stopped reaching the node would be worse than no knob.
FORWARDED_ENV = ("STABILITY_WINDOW_SECONDS", "KARPENTER_NODECLAIM_STUCK_MINUTES")


def forwarded_env():
    out = {}
    for name in FORWARDED_ENV:
        value = os.environ.get(name, "").strip()
        if value:
            out[name] = value
    return out


# ─── Context ─────────────────────────────────────────────────────────────────


def infer_tfvar(path, name):
    """Read a scalar out of terraform.tfvars, matching common.sh's rule."""
    try:
        with open(path) as handle:
            for line in handle:
                stripped = line.strip()
                if stripped.startswith(name) and "=" in stripped:
                    parts = stripped.split('"')
                    if len(parts) >= 2:
                        return parts[1]
    except OSError:
        return None
    return None


def resolve_context(args):
    tfvars = os.path.join(DEPLOYMENT_DIR, "terraform", "standard_cluster", "terraform.tfvars")
    nickname = args.nickname or infer_tfvar(tfvars, "nickname")
    region = args.region or infer_tfvar(tfvars, "aws_region")
    if not nickname or not region:
        raise SystemExit(
            f"Error: could not infer nickname/region from {tfvars}.\n"
            "       Pass them explicitly: <profile> <nickname> <region>"
        )
    return nickname, region


# ─── Colour ──────────────────────────────────────────────────────────────────


class Palette:
    def __init__(self, enabled):
        self.red = "\033[31m" if enabled else ""
        self.green = "\033[32m" if enabled else ""
        self.yellow = "\033[33m" if enabled else ""
        self.reset = "\033[0m" if enabled else ""

    def for_result(self, result):
        return {"passed": self.green, "failed": self.red, "skipped": self.yellow}.get(result, "")


# ─── Merge ───────────────────────────────────────────────────────────────────


def collect(results):
    """Turn raw SSM results into per-node documents.

    A node whose output cannot be decoded becomes an ERROR entry rather than
    being dropped. A node we could not read has not passed.
    """
    nodes = {}
    for instance_id, raw in sorted(results.items()):
        if raw["truncated"]:
            nodes[instance_id] = {
                "error": (f"output hit the SSM cap of {ssm.STDOUT_LIMIT} characters and was cut")
            }
            continue
        try:
            document = payload.decode(raw["stdout"])
        except ValueError as exc:
            stderr = (raw["stderr"] or "").strip().splitlines()
            hint = stderr[-1] if stderr else raw["status"]
            nodes[instance_id] = {"error": f"{exc} (SSM status: {hint})"}
            continue
        if document.get("schema") != 2:
            nodes[instance_id] = {"error": f"unrecognised report schema {document.get('schema')!r}"}
            continue
        nodes[instance_id] = {"document": document}
    return nodes


# Worst verdict wins when collapsing a section: one failure makes the section
# failed no matter how many checks in it passed.
VERDICT_RANK = {"passed": 0, "skipped": 1, "failed": 2}

ABSENT = "absent"


def section_verdicts(document):
    """Collapse one node's checks into a single verdict per section."""
    out = {}
    for check in document["checks"]:
        section, result = check["section"], check["result"]
        if section not in out or VERDICT_RANK[result] > VERDICT_RANK[out[section]]:
            out[section] = result
    return out


def disagreements(nodes):
    """Sections where nodes reached different verdicts.

    These checks are cluster-scoped, so every control-plane node should see the
    same thing. When they do not, that is itself a finding — one node cannot be
    picked as right without saying why.

    Compared per section VERDICT, deliberately not per message. Messages carry
    live readings — "renewed its lease 0s ago", "across 61 pods" — that
    legitimately differ by the fraction of a second between one node being
    queried and the next. Keying on the message text reported a disagreement
    whenever that wording drifted, so a run in which all three nodes passed
    still came back FAIL.
    """
    per_node = {
        instance_id: section_verdicts(entry["document"])
        for instance_id, entry in nodes.items()
        if entry.get("document")
    }

    out = []
    sections = {section for verdicts in per_node.values() for section in verdicts}
    for section in sorted(sections):
        # A section one node never reported is still a disagreement: it means
        # that node ran a different set of checks than its peers.
        verdicts = {node: found.get(section, ABSENT) for node, found in per_node.items()}
        if len(set(verdicts.values())) > 1:
            out.append(
                {
                    "section": section,
                    "message": "nodes reached different verdicts",
                    "verdicts": verdicts,
                }
            )
    return out


# ─── Render ──────────────────────────────────────────────────────────────────


def hardware_line(facts):
    """One-line host summary. The only facts that legitimately differ per node."""
    cpu = facts.get("hardware.cpu") or {}
    memory = facts.get("hardware.memory") or {}
    disk = facts.get("hardware.disk") or {}
    load = (cpu.get("load") or {}).get("1 min")
    ram = (memory.get("ram") or {}).get("usage")
    used = disk.get("usage")
    if load is None and ram is None and used is None:
        return None
    return f"host: load {load}%  ram {ram}%  disk {used}%"


def fact_errors(facts):
    """Facts that report they could not be collected.

    Surfaced prominently because a collector recording {"error": ...} is the
    normal path for an unreachable endpoint — it is not a failed check, and it
    would otherwise be visible only by reading the JSON.
    """
    found = []
    for key, value in sorted(facts.items()):
        if not isinstance(value, dict):
            continue
        if value.get("error"):
            found.append((key, value["error"]))
            continue
        for name, inner in sorted(value.items()):
            if isinstance(inner, dict) and inner.get("error"):
                found.append((f"{key}.{name}", inner["error"]))
    return found


def render(nodes, instances, disagree, pal, depth, verbose):
    names = {i["id"]: i["name"] for i in instances}
    lines = []

    readable = [e for e in nodes.values() if e.get("document")]
    for instance_id, entry in sorted(nodes.items()):
        label = f"{instance_id}  {names.get(instance_id, '')}"
        if entry.get("error"):
            lines.append(f"  {pal.red}[ERROR]{pal.reset} {label}")
            lines.append(f"          {entry['error']}")
            continue
        document = entry["document"]
        summary = document["summary"]
        tint = pal.green if document["result"] == "passed" else pal.red
        lines.append(
            f"  {tint}[{document['result'].upper()}]{pal.reset} {label}  "
            f"({summary['passed']} passed, {summary['failed']} failed, "
            f"{summary['skipped']} skipped)"
        )
        # Staleness is reported, never fatal: `tofu apply` rewrites S3 without
        # touching a node, and the deploy gate verifies straight afterwards, so
        # every node is legitimately behind in that window.
        gen = document.get("generation") or {}
        if gen.get("stale") is True:
            lines.append(
                f"          {pal.yellow}STALE{pal.reset}: synced {gen['synced']}, "
                f"S3 has {gen['current']} — run 'sk3s sync'"
            )
        elif gen.get("stale") is None:
            known = gen.get("synced") or gen.get("current")
            reason = "node has no stamp" if not gen.get("synced") else "S3 unreadable"
            lines.append(
                f"          {pal.yellow}generation unknown{pal.reset} ({reason}"
                + (f", have {known}" if known else "")
                + ")"
            )

        summary_line = hardware_line(document.get("facts") or {})
        if summary_line:
            lines.append(f"          {summary_line}")

    if readable:
        # Checks are cluster-scoped, so one node's view is the cluster's view.
        # The first readable document is the reference; disagreements are
        # reported separately rather than silently averaged away.
        reference = readable[0]["document"]
        shown = [c for c in reference["checks"] if verbose or c["result"] != "passed"]
        if shown:
            lines.append("")
            for check in sorted(shown, key=lambda c: RESULT_ORDER.get(c["result"], 3)):
                tint = pal.for_result(check["result"])
                lines.append(
                    f"  {tint}[{check['result'].upper():^7}]{pal.reset} "
                    f"{check['section']:<18} {check['message']}"
                )
                if check.get("detail"):
                    for detail_line in check["detail"].strip().splitlines():
                        lines.append(f"           | {detail_line}")

        collected = reference.get("facts") or {}
        if collected:
            problems = fact_errors(collected)
            lines.append("")
            lines.append(f"  {len(collected)} fact(s) recorded — full structure in --json")
            for key, reason in problems:
                lines.append(f"    {pal.yellow}[unavailable]{pal.reset} {key:<28} {reason}")

    if disagree:
        lines.append("")
        lines.append(f"  {pal.yellow}Nodes disagree on {len(disagree)} check(s):{pal.reset}")
        for item in disagree:
            verdicts = ", ".join(f"{k}={v}" for k, v in sorted(item["verdicts"].items()))
            lines.append(f"    {item['section']:<18} {item['message']}")
            lines.append(f"           | {verdicts}")

    return "\n".join(lines)


# ─── Main ────────────────────────────────────────────────────────────────────


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="sk3s_status.py",
        description="Cluster health, merged across control-plane nodes.",
    )
    parser.add_argument("profile", nargs="?", help="AWS CLI profile (required)")
    parser.add_argument("nickname", nargs="?", help="default: inferred from terraform.tfvars")
    parser.add_argument("region", nargs="?", help="default: inferred from terraform.tfvars")
    # "full" adds facts — observed state, recorded and never graded. It is a
    # superset of standard, so the verdict is unchanged by asking for it.
    parser.add_argument("--depth", choices=("quick", "standard", "full"), default="standard")
    parser.add_argument("--instance-id", help="check a single node instead of all")
    parser.add_argument("--verbose", action="store_true", help="show passing checks too")
    parser.add_argument("--json", action="store_true", help="emit the merged report as JSON")
    parser.add_argument("--no-color", action="store_true")
    parser.add_argument("--poll-max", type=int, default=180)
    parser.add_argument("--poll-interval", type=int, default=5)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    # sk3s pipes this through tee for logging, which makes stdout block-buffered
    # while stderr stays unbuffered — so progress ticks would otherwise appear
    # before the header they follow.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:  # pragma: no cover - very old interpreters
        pass
    if not args.profile:
        print("Error: <profile> is required.", file=sys.stderr)
        return EXIT_USAGE

    nickname, region = resolve_context(args)
    pal = Palette(not args.no_color and sys.stdout.isatty())

    instances = ssm.cluster_instances(args.profile, region, nickname, "controlplane")
    if args.instance_id:
        instances = [i for i in instances if i["id"] == args.instance_id]
        if not instances:
            print(
                f"Error: {args.instance_id} is not a running control-plane node of '{nickname}'.",
                file=sys.stderr,
            )
            return EXIT_FAIL
    if not instances:
        print(
            f"Error: no running control-plane node for '{nickname}' in {region}.", file=sys.stderr
        )
        return EXIT_FAIL

    ids = [i["id"] for i in instances]
    offline = ssm.unreachable(args.profile, region, ids)

    if not args.json:
        print(f"Cluster  : nickname={nickname}  region={region}  profile={args.profile}")
        print(f"Depth    : {args.depth}")
        print(f"Nodes    : {len(ids)} control-plane")
        for inst in instances:
            mark = (
                f"  {pal.red}(unreachable: {offline[inst['id']]}){pal.reset}"
                if inst["id"] in offline
                else ""
            )
            print(f"             {inst['id']}  {inst['name']}{mark}")
        print("")

    reachable = [i for i in ids if i not in offline]
    if not reachable:
        print("No control-plane node is reachable over SSM.", file=sys.stderr)
        return EXIT_FAIL

    encoded = payload.build(REPO_ROOT)
    node_env = forwarded_env()
    if node_env and not args.json:
        print("Tunables : " + "  ".join(f"{k}={v}" for k, v in sorted(node_env.items())))
        print("")
    command = payload.remote_command(encoded, args.depth, env=node_env)

    def tick(n, total, pending):
        if not args.json and pending:
            print(f"  ({n}/{total}) waiting on {len(pending)} node(s)...", file=sys.stderr)

    command_id = ssm.send_command(args.profile, region, reachable, command, "sk3s status")
    raw = ssm.await_all(
        args.profile,
        region,
        command_id,
        reachable,
        max_polls=args.poll_max,
        interval=args.poll_interval,
        on_tick=tick,
    )

    nodes = collect(raw)
    # An unreachable node is a node we did not check. It is reported, and it
    # counts against the verdict — absence is never success.
    for instance_id, status in offline.items():
        nodes[instance_id] = {"error": f"unreachable over SSM (ping status: {status})"}

    disagree = disagreements(nodes)
    healthy = (
        all(e.get("document") and e["document"]["result"] == "passed" for e in nodes.values())
        and not disagree
    )

    if args.json:
        print(
            json.dumps(
                {
                    "cluster": nickname,
                    "region": region,
                    "depth": args.depth,
                    "result": "passed" if healthy else "failed",
                    "nodes": nodes,
                    "disagreements": disagree,
                },
                indent=2,
            )
        )
        return EXIT_OK if healthy else EXIT_FAIL

    print(render(nodes, instances, disagree, pal, args.depth, args.verbose))
    print("")
    ok_nodes = sum(
        1 for e in nodes.values() if e.get("document") and e["document"]["result"] == "passed"
    )
    verdict = f"{pal.green}PASS{pal.reset}" if healthy else f"{pal.red}FAIL{pal.reset}"
    print(f"Result: {verdict}  ({ok_nodes}/{len(nodes)} nodes passed)")
    return EXIT_OK if healthy else EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
