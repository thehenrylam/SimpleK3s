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

ONE IMPLEMENTATION, HERE. The digest and the stamp path used to exist twice —
once here, once in lib/common.sh — and the two copies never agreed on either:

  * DIGEST. bash captured the listing through $( ), which strips trailing
    newlines, and hashed that; this module hashed the CLI's stdout verbatim,
    newline included. One unchanged bucket measured 7167d2800a11 from bash and
    01245e9fa49e from here.
  * PATH. bash wrote the stamp to BOOTSTRAP_DIR — /opt/simplek3s/, the sync
    root — while this module read it from the keyroot subdirectory one level
    down.

So the feature never once reported "current" on any node: the stamp was written
somewhere nothing looked, and had it been found the two digests would still have
compared unequal forever. lib/common.sh now shims into this module.
"""

import hashlib
import os
import subprocess

# Node-local state, deliberately OUTSIDE the S3 sync destination. Everything
# under /opt/simplek3s/ is a mirror of the bucket, so state kept there lives at
# the mercy of the sync — #158 cannot enable `aws s3 sync --delete` while the
# stamp sits inside the tree that flag prunes.
DEFAULT_STATE_DIR = "/var/lib/simplek3s"

# Where the bucket's keyroot lands on the node: the scripts and simplek3s.env.
DEFAULT_SCRIPT_DIR = "/opt/simplek3s/bootstrap/default"

STAMP_NAME = ".simplek3s-generation"

# Where the pre-standardisation bash wrote the stamp: BOOTSTRAP_DIR, the sync
# root. A node upgraded in place keeps that file forever — the sync never
# deletes anything (#158) — leaving two files that answer the same question and
# will diverge the moment either side changes. Removed on the next record().
LEGACY_STAMP = "/opt/simplek3s/.simplek3s-generation"


def state_dir():
    return os.environ.get("SK3S_STATE_DIR") or DEFAULT_STATE_DIR


def script_dir():
    """Where simplek3s.env lives.

    Deliberately NOT read from BOOTSTRAP_DIR. That name already exists in the
    node's shell environment meaning something else — the sync ROOT, one level
    up — so honouring it here pointed this module at a directory containing
    neither the stamp nor simplek3s.env, but only when Python happened to be
    launched from a shell that had exported it. A clean SSM environment hid it.
    """
    return os.environ.get("SK3S_SCRIPT_DIR") or DEFAULT_SCRIPT_DIR


def stamp_path():
    return os.path.join(state_dir(), STAMP_NAME)


def node_env(directory=None):
    """Read simplek3s.env, the node's own config, as a plain dict."""
    path = os.path.join(directory or script_dir(), "simplek3s.env")
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


def recorded(path=None):
    """The generation this node last synced, or None if it has never stamped."""
    path = path or stamp_path()
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
    # Stripped BEFORE hashing so the digest cannot depend on whether the CLI
    # emitted a trailing newline. That single character was the whole reason the
    # bash and Python digests disagreed, and normalising here means a caller
    # cannot reintroduce the difference by capturing stdout a different way.
    listing = proc.stdout.decode(errors="replace").strip()
    # An empty listing is a failure, not a generation: a bucket that answers with
    # nothing must never compare equal to a node that synced real content.
    if not listing:
        return None
    return hashlib.sha256(listing.encode()).hexdigest()[:12]


def record(value=None):
    """Stamp the generation S3 holds now as this node's. Returns it, or None.

    Call ONLY when the node's files are known to match the bucket — after a
    successful sync, or at boot where cloud-init has just downloaded them.

    Returns None without touching the stamp if the bucket is unreadable: a stale
    stamp beats a wrong one, and both sides report "unknown" either way.
    """
    value = current() if value is None else value
    if not value:
        return None
    try:
        os.makedirs(state_dir(), exist_ok=True)
        with open(stamp_path(), "w") as handle:
            handle.write(f"{value}\n")
        # World-readable: an operator running the on-box copy is not root, but
        # k3s's kubeconfig already forces sudo for the checks, so only this file
        # needs to be reachable without it.
        os.chmod(stamp_path(), 0o644)
    except OSError:
        return None
    _drop_legacy_stamp()
    return value


def _drop_legacy_stamp():
    """Remove the stamp the old bash left in the sync root, if any.

    Guarded on the default state dir so a test or an operator pointing
    SK3S_STATE_DIR elsewhere never triggers a delete outside its own sandbox.
    Failure is ignored: an orphan file is untidy, not harmful, and must never
    turn a successful record into a failed one.
    """
    if state_dir() != DEFAULT_STATE_DIR:
        return
    try:
        os.remove(LEGACY_STAMP)
    except OSError:
        pass


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
