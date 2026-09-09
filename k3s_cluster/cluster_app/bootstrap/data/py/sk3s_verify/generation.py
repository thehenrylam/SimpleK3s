"""Bootstrap generation: what this node last synced versus what S3 holds now.

REPORTED, NOT PASS/FAIL — and deliberately still so after #118 phase 4.

The bash this replaces predicted it would become a hard failure "once pull fans
out to every node". Phase 4 did make sync fan out, but that is not sufficient:
`tofu apply` rewrites S3 objects without touching any node, and
cluster_apply.yml verifies immediately afterwards. Every node is legitimately
stale in that window, so failing on it would break the deploy gate for a
condition the tooling itself creates.

It is surfaced prominently instead, which is what lets an operator tell "this
node is behind" from "this node is broken".

Note the verifier ITSELF is never stale — the host ships it inline with every
run. This tracks the S3-synced bootstrap files (bts_*.sh, converge_actions.sh,
the staged manifests), which can still drift.
"""

import hashlib
import os
import subprocess

DEFAULT_BOOTSTRAP_DIR = "/opt/simplek3s/bootstrap/default"
STAMP_NAME = ".simplek3s-generation"


def bootstrap_dir():
    return os.environ.get("BOOTSTRAP_DIR") or DEFAULT_BOOTSTRAP_DIR


def node_env(directory=None):
    """Read simplek3s.env, the node's own config, as a plain dict."""
    path = os.path.join(directory or bootstrap_dir(), "simplek3s.env")
    values = {}
    try:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        return {}
    return values


def recorded(directory=None):
    """The generation this node last synced, or None if it has never stamped."""
    path = os.path.join(directory or bootstrap_dir(), STAMP_NAME)
    try:
        with open(path) as handle:
            value = handle.readline().strip()
    except OSError:
        return None
    return value or None


def current(env=None):
    """The generation of the bucket right now, or None if it cannot be read."""
    env = node_env() if env is None else env
    bucket, region = env.get("S3_BUCKET_NAME"), env.get("AWS_REGION")
    if not bucket or not region:
        return None
    try:
        proc = subprocess.run(
            [
                "aws",
                "s3api",
                "list-objects-v2",
                "--bucket",
                bucket,
                "--region",
                region,
                "--query",
                "sort_by(Contents, &Key)[].[Key,ETag,Size]",
                "--output",
                "text",
            ],
            capture_output=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    listing = proc.stdout.decode(errors="replace")
    # An empty listing is a failure, not a generation: a bucket that answers with
    # nothing must never compare equal to a node that synced real content.
    if not listing.strip():
        return None
    return hashlib.sha256(listing.encode()).hexdigest()[:12]


def state(synced=None, live=None):
    """Report both sides and whether they differ.

    `stale` stays None unless BOTH are known, so an unreadable bucket can never
    make a current node look stale or a stale node look current.
    """
    synced = recorded() if synced is None else synced
    live = current() if live is None else live
    return {
        "synced": synced or None,
        "current": live or None,
        "stale": (synced != live) if (synced and live) else None,
    }
