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


# ─── Control-plane components ────────────────────────────────────────────────
#
# k3s_api above asks only whether /readyz answers, which is the liveness floor.
# It says nothing about the scheduler or the controller-manager, and a cluster
# whose scheduler has stopped still serves a perfectly healthy /readyz while no
# pod is ever placed again.
#
# The heartbeat is the lease, not the object. K3s creates the kube-scheduler and
# kube-controller-manager leases at startup and they are never garbage-collected,
# so "the lease exists" stays true long after the holder has died — the same
# presence-implies-health shape this rewrite exists to remove. What actually
# moves is spec.renewTime, refreshed every few seconds by a live holder.

DEFAULT_LEASE_STALE_SECONDS = 60

COMPONENT_LEASES = ("kube-scheduler", "kube-controller-manager")

API_ENDPOINTS = ("/livez", "/healthz")


def lease_stale_seconds():
    """How long a lease may go unrenewed before its holder is presumed dead."""
    raw = os.environ.get("LEASE_STALE_SECONDS", "")
    if not raw:
        return DEFAULT_LEASE_STALE_SECONDS
    if not raw.isdigit() or int(raw) < 1:
        raise ValueError(f"LEASE_STALE_SECONDS must be a positive integer (got {raw!r})")
    return int(raw)


def lease_age(obj, now=None):
    """Seconds since the holder last renewed, None if never, False if unreadable."""
    renewed = _parsed(obj.get("spec", {}).get("renewTime"))
    if renewed is None or renewed is False:
        return renewed
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return (now - renewed).total_seconds()


def controlplane(rec, now=None):
    for path in API_ENDPOINTS:
        try:
            body = kube.run(["get", f"--raw={path}"]).strip()
        except kube.Unavailable as exc:
            # Non-2xx makes kubectl exit non-zero, so an unhealthy endpoint
            # arrives here rather than as a body we can compare.
            rec.failed(f"API {path} did not answer", str(exc))
            continue
        if body == "ok":
            rec.passed(f"API {path} is ok")
        else:
            rec.failed(f"API {path} returned {body!r} instead of 'ok'")

    stale_after = lease_stale_seconds()
    for name in COMPONENT_LEASES:
        try:
            obj = kube.run_json(["-n", "kube-system", "get", "lease", name])
        except kube.Unavailable as exc:
            rec.failed(f"{name} lease could not be read", str(exc))
            continue
        age = lease_age(obj, now)
        if age is None:
            rec.failed(f"{name} has never renewed its lease")
        elif age is False:
            rec.failed(f"{name} lease has an unreadable renewTime")
        elif age > stale_after:
            rec.failed(f"{name} last renewed its lease {int(age)}s ago (limit {stale_after}s)")
        else:
            # The exact age is deliberately left out of the passing message.
            # It changes every second, and the host compares nodes to each other
            # — a reading that differs by a fraction of a second between nodes is
            # noise, not a disagreement. The failing branch above keeps the
            # number, where it is the whole point.
            rec.passed(f"{name} lease is fresh (renewed within {stale_after}s)")
