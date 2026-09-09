"""Cluster-level health: the API, the nodes, kube-system, and pod stability."""

import datetime
import os

from .. import kube, workloads

DEFAULT_STABILITY_WINDOW_SECONDS = 300


def k3s_api(rec):
    kube.run(["get", "--raw=/readyz"])
    rec.passed("K3s API is reachable")


def nodes_ready(rec):
    items = kube.run_json(["get", "nodes"]).get("items") or []
    if not items:
        # Reaching here means the query SUCCEEDED and still returned nothing.
        # That is its own anomaly, not a healthy cluster (#156).
        rec.failed("The cluster reported no nodes at all")
        return

    not_ready = []
    for node in items:
        name = node.get("metadata", {}).get("name", "<unknown>")
        conds = node.get("status", {}).get("conditions") or []
        ready = next((c.get("status") for c in conds if c.get("type") == "Ready"), None)
        if ready != "True":
            not_ready.append(f"{name} (Ready={ready})")

    if not_ready:
        rec.failed(f"{len(not_ready)} of {len(items)} nodes are not Ready", "\n".join(not_ready))
    else:
        rec.passed(f"All {len(items)} nodes are Ready")


def kube_system(rec):
    for name in ("coredns", "local-path-provisioner"):
        rec.verdict(*workloads.state("deployment", "kube-system", name))


# ─── Pod stability ───────────────────────────────────────────────────────────


def stability_window():
    """Restart lookback, in seconds.

    A malformed value is rejected rather than defaulted. #110 was exactly this:
    a bad window silently skipped the check and the run still reported PASS.
    """
    raw = os.environ.get("STABILITY_WINDOW_SECONDS", "")
    if not raw:
        return DEFAULT_STABILITY_WINDOW_SECONDS
    if not raw.isdigit() or int(raw) < 1:
        raise ValueError(f"STABILITY_WINDOW_SECONDS must be a positive integer (got {raw!r})")
    return int(raw)


def _parsed(timestamp):
    if not timestamp:
        return None
    try:
        return datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return False  # present but unreadable — distinct from absent


def _describe(term, kind, cutoff):
    """Describe a termination record if it lands inside the window, else None."""
    finished_at = term.get("finishedAt", "")
    if not finished_at:
        return None
    when = _parsed(finished_at)
    if when is False:
        # Reported, not skipped: a timestamp we cannot read must not pass as healthy.
        return f"{kind} with unreadable timestamp {finished_at}"
    if when > cutoff:
        return f"{kind} at {finished_at}"
    return None


def _finding(container, count_restarts, cutoff):
    """Why this container looks unstable inside the window, or None."""
    if count_restarts and container.get("restartCount"):
        # lastState is a PREVIOUS incarnation: evidence of a restart, any exit code.
        found = _describe(container.get("lastState", {}).get("terminated", {}), "restarted", cutoff)
        if found:
            return found
    # state is the CURRENT incarnation. Exit 0 is a normal completion, not instability.
    current = container.get("state", {}).get("terminated", {})
    if current.get("exitCode", 0) != 0:
        return _describe(current, "terminated", cutoff)
    return None


def recent_restarts(pods, window, now=None):
    """Pods whose containers restarted inside the window.

    Note this reports IN-PLACE container restarts (lastState.terminated), not
    pod replacement. A rolling update produces new pods with no lastState, so a
    `sk3s refresh` does not register here — verified live.

    `now` is injectable so the window can be tested deterministically, matching
    stuck_nodeclaims. A function that reads the clock itself cannot be asserted
    against a fixed set of timestamps.
    """
    now = now or datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(seconds=window)

    output = []
    for pod in pods:
        meta = pod.get("metadata", {})
        status = pod.get("status", {})
        if status.get("phase") == "Succeeded":
            continue

        candidates = [(c, False) for c in (status.get("initContainerStatuses") or [])]
        candidates += [(c, True) for c in (status.get("containerStatuses") or [])]

        for container, count_restarts in candidates:
            found = _finding(container, count_restarts, cutoff)
            if found:
                ns, pod_name = meta.get("namespace"), meta.get("name")
                output.append(f"{ns}/{pod_name} (container: {container.get('name')}, {found})")
                break
    return output


def pod_stability(rec):
    window = stability_window()
    pods = kube.run_json(["get", "pods", "-A"]).get("items") or []
    unstable = recent_restarts(pods, window)
    if unstable:
        rec.failed(f"Pods with recent restarts (within {window}s)", "\n".join(unstable))
    else:
        rec.passed(f"No pod restarts in the last {window}s")
