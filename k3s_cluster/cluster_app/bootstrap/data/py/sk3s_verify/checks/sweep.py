"""Cluster-wide sweeps: every workload, every pod, every claim.

WHY THESE EXIST. Every other check asserts against a hard-coded list of names —
traefik, coredns, argocd-server, and so on. That grades what somebody
remembered to list and silently grades nothing else, so a workload introduced by
a chart bump, an ArgoCD application, or a subsystem nobody wired a check for is
invisible no matter how broken it is. The named checks answer "is the thing we
require present and healthy"; these answer "is anything at all unhealthy". Both
are needed, and neither replaces the other — a sweep cannot tell a subsystem
that is absent on purpose from one that is missing, which is exactly what a
named check knows.

The gap was measured, not guessed: the e2e answer sheet asserts
workloads_not_ready = 0 and unhealthy_pods = 0 across all namespaces, and
nothing in the check set answered either question.
"""

from .. import kube

# (singular label, kubectl plural, desired-count path, ready-count path)
KINDS = (
    ("deployment", "deployments", "spec.replicas", "status.readyReplicas"),
    ("statefulset", "statefulsets", "spec.replicas", "status.readyReplicas"),
    ("daemonset", "daemonsets", "status.desiredNumberScheduled", "status.numberReady"),
)

# A container waiting on one of these is not "still starting" — the kubelet has
# given a reason it cannot run. ContainerCreating, PodInitializing and a Pending
# phase are deliberately absent: they are ordinary mid-rollout states, and
# grading them would make this sweep fail the very deploys it exists to gate.
BLOCKED_REASONS = frozenset(
    {
        "CrashLoopBackOff",
        "ImagePullBackOff",
        "ErrImagePull",
        "InvalidImageName",
        "CreateContainerConfigError",
        "CreateContainerError",
        "RunContainerError",
    }
)


def _ref(meta, kind=None):
    namespace = meta.get("namespace") or "?"
    name = meta.get("name") or "?"
    return f"{namespace}/{kind}/{name}" if kind else f"{namespace}/{name}"


def survey(items, kind, want_path, have_path):
    """Split one kind's objects into (under-delivered, scaled-to-zero).

    Under-delivered means the controller was asked for replicas it has not
    produced. Scaled-to-zero is kept separate because nobody asked those to run,
    so failing on them cluster-wide would be noise — but calling them healthy
    would be the #111 blind spot, so they are not passed either.
    """
    under, zeroed = [], []
    for obj in items:
        ref = _ref(obj.get("metadata", {}), kind)
        want = kube.dig(obj, want_path)
        have = kube.dig(obj, have_path) or 0
        if want is None:
            under.append(f"{ref} did not report a replica count")
        elif want < 1:
            zeroed.append(ref)
        elif have < want:
            under.append(f"{ref} has {have}/{want} ready")
    return under, zeroed


def workloads(rec):
    under, zeroed, total = [], [], 0
    for kind, plural, want_path, have_path in KINDS:
        items = kube.run_json(["get", plural, "--all-namespaces"]).get("items") or []
        total += len(items)
        found_under, found_zeroed = survey(items, kind, want_path, have_path)
        under += found_under
        zeroed += found_zeroed

    if not total:
        # The query succeeded and returned nothing. A K3s cluster always runs
        # CoreDNS at minimum, so this is its own anomaly, not a clean bill (#156).
        rec.failed("The cluster reported no workloads at all")
        return

    if under:
        rec.failed(
            f"{len(under)} of {total} workloads have not reached their desired replicas",
            "\n".join(sorted(under)),
        )
    else:
        rec.passed(f"All {total - len(zeroed)} scheduled workloads have their desired replicas")

    if zeroed:
        rec.skipped(
            f"{len(zeroed)} workload(s) scaled to 0, not graded: {', '.join(sorted(zeroed))}"
        )


def unhealthy(items):
    """Pods that cannot run, as human-readable findings."""
    findings = []
    for pod in items:
        ref = _ref(pod.get("metadata", {}))
        status = pod.get("status", {})
        phase = status.get("phase", "")
        if phase == "Succeeded":
            # A completed Job or CronJob pod. Terminal by design, not a fault.
            continue
        if phase == "Failed":
            findings.append(f"{ref} phase=Failed reason={status.get('reason') or 'unknown'}")
            continue
        containers = (status.get("containerStatuses") or []) + (
            status.get("initContainerStatuses") or []
        )
        for container in containers:
            waiting = (container.get("state") or {}).get("waiting") or {}
            reason = waiting.get("reason")
            if reason in BLOCKED_REASONS:
                findings.append(f"{ref} container {container.get('name') or '?'}: {reason}")
    return findings


def pod_health(rec):
    items = kube.run_json(["get", "pods", "--all-namespaces"]).get("items") or []
    if not items:
        rec.failed("The cluster reported no pods at all")
        return

    findings = unhealthy(items)
    if findings:
        rec.failed(f"{len(findings)} pod(s) cannot run", "\n".join(sorted(findings)))
    else:
        rec.passed(f"No pod is failed or blocked, across {len(items)} pods")


def storage(rec):
    items = kube.run_json(["get", "pvc", "--all-namespaces"]).get("items") or []
    if not items:
        # Nothing to verify is not the same as verified. A cluster with no
        # claims is legitimate; saying its storage is healthy would not be.
        rec.skipped("No PersistentVolumeClaims exist")
        return

    unbound = []
    for obj in items:
        phase = obj.get("status", {}).get("phase") or "unknown"
        if phase != "Bound":
            unbound.append(f"{_ref(obj.get('metadata', {}))} is {phase}")

    if unbound:
        rec.failed(f"{len(unbound)} of {len(items)} PVCs are not Bound", "\n".join(sorted(unbound)))
    else:
        rec.passed(f"All {len(items)} PVCs are Bound")
