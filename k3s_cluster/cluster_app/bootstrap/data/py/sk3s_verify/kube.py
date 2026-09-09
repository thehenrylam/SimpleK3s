"""The one place a cluster query can fail.

WHY THIS EXISTS. Issue #156: three separate checks read an empty result as good
news, because a failed query and a genuinely empty answer were indistinguishable
by the time the caller saw them:

    NOT_READY="$(kubectl get nodes 2>/dev/null | grep -v ' Ready' || true)"
    [[ -z "$NOT_READY" ]] && pass "All nodes are Ready"

Discipline did not prevent that — the same shape appeared three times, and once
inside a python blob that caught the parse error and exited 0, so a guard one
layer up could not have caught it either.

So the distinction is made STRUCTURAL rather than remembered. A query that fails
raises Unavailable. It does not return a value the caller can accidentally read
as healthy, because it does not return at all.
"""

import json
import os
import subprocess


class Unavailable(Exception):
    """A question could not be asked. Never a synonym for a healthy answer."""


def _argv(args):
    """kubectl, elevated only when we are not already root.

    Under SSM the command already runs as root, so sudo is unnecessary there.
    An operator running the S3-shipped copy by hand is not root, and k3s's
    kubeconfig at /etc/rancher/k3s/k3s.yaml is root-readable only — so both
    paths have to work.
    """
    prefix = [] if os.geteuid() == 0 else ["sudo"]
    return [*prefix, "kubectl", *args]


def run(args, timeout=30):
    """Run kubectl and return stdout. Raises Unavailable if the query failed."""
    try:
        proc = subprocess.run(
            _argv(args),
            capture_output=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise Unavailable("kubectl is not installed") from exc
    except subprocess.TimeoutExpired as exc:
        raise Unavailable(f"kubectl timed out after {timeout}s") from exc

    if proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip().splitlines()
        raise Unavailable(detail[-1] if detail else f"kubectl exited {proc.returncode}")
    return proc.stdout.decode(errors="replace")


def run_json(args, timeout=30):
    """Run kubectl -o json and parse it. Raises Unavailable on either failure.

    The parse is inside the same guard as the query on purpose: an unparseable
    payload is not an empty one, and #156's worst instance was a probe that
    caught JSONDecodeError and reported success.
    """
    raw = run([*args, "-o", "json"], timeout=timeout)
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise Unavailable(f"response was not valid JSON: {exc}") from exc


def exists(args, timeout=30):
    """True/False for presence. Only for questions where absence is a real answer.

    Absence of a namespace legitimately means "subsystem not deployed". Absence
    of an ANSWER does not, which is why this still raises Unavailable when
    kubectl itself cannot run.
    """
    try:
        run(args, timeout=timeout)
        return True
    except Unavailable as exc:
        # kubectl ran and said "not found" — a real answer. Anything else is not.
        if "not found" in str(exc).lower() or "NotFound" in str(exc):
            return False
        raise
