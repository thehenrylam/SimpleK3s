"""CLI entry point.

Shipped INLINE by the host rather than read from disk, so the node always runs
exactly the version the caller expects. That removes version skew during a
rollout, and with it the dual-schema handling a staged deploy would need.
"""

import argparse
import base64
import gzip
import json
import socket
import sys

from . import SCHEMA, checks, registry  # noqa: F401 - importing checks registers them


def build_document(depth):
    rec = registry.run_all(depth)
    counts = rec.counts
    document = {
        "schema": SCHEMA,
        "node": socket.gethostname(),
        "depth": depth,
        "result": registry.FAILED if counts[registry.FAILED] else registry.PASSED,
        "summary": {
            "passed": counts[registry.PASSED],
            "failed": counts[registry.FAILED],
            "skipped": counts[registry.SKIPPED],
            "total": len(rec.checks),
        },
        "checks": rec.checks,
    }
    if rec.facts:
        document["facts"] = rec.facts
    return document


def main(argv=None):
    parser = argparse.ArgumentParser(prog="sk3s_verify")
    parser.add_argument("--depth", choices=registry.DEPTHS, default=registry.STANDARD)
    parser.add_argument(
        "--compress",
        action="store_true",
        help="emit gzip+base64. SSM caps stdout at 24000 chars and full depth "
        "is 94%% of that raw, so compression is required, not an optimisation.",
    )
    args = parser.parse_args(argv)

    document = build_document(args.depth)
    payload = json.dumps(document, separators=(",", ":"))
    if args.compress:
        payload = base64.b64encode(gzip.compress(payload.encode())).decode()
    print(payload)
    return 1 if document["result"] == registry.FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
