"""Subsystem health: Traefik, Kyverno, Longhorn, External-Secrets, Karpenter,
Descheduler, Tailscale."""

import datetime
import os

from .. import kube, workloads

DEFAULT_NODECLAIM_STUCK_MINUTES = 20


def _crds(rec, names):
    for crd in names:
        exists = kube.exists(["get", "crd", crd])
        rec.verdict(exists, f"CRD {crd} {'exists' if exists else 'is missing'}")


# ─── Traefik ─────────────────────────────────────────────────────────────────


def traefik(rec):
    if not workloads.present("deployment", "kube-system", "traefik"):
        rec.skipped("kube-system/traefik not present (subsystem not enabled)")
        return
    rec.verdict(*workloads.state("deployment", "kube-system", "traefik"))

    for ref in ("middleware/https-redirect", "ingressroute/web-http-catchall-redirect"):
        kind, name = ref.split("/")
        exists = kube.exists(["-n", "kube-system", "get", kind, name])
        rec.verdict(exists, f"kube-system/{ref} {'exists' if exists else 'is missing'}")


# ─── Kyverno ─────────────────────────────────────────────────────────────────

_KYVERNO_DEPLOYS = (
    "kyverno-admission-controller",
    "kyverno-background-controller",
    "kyverno-cleanup-controller",
)


def kyverno(rec):
    if not kube.exists(["get", "ns", "kyverno"]):
        rec.skipped("namespace 'kyverno' not present (subsystem not enabled)")
        return
    for name in _KYVERNO_DEPLOYS:
        rec.verdict(*workloads.state("deployment", "kyverno", name))
    _crds(rec, ("clusterpolicies.kyverno.io", "policies.kyverno.io"))


# ─── Longhorn ────────────────────────────────────────────────────────────────


def longhorn(rec):
    if not kube.exists(["get", "ns", "longhorn-system"]):
        rec.skipped("namespace 'longhorn-system' not present (subsystem not enabled)")
        return
    for name in ("longhorn-manager", "longhorn-csi-plugin"):
        rec.verdict(*workloads.state("daemonset", "longhorn-system", name))

    nodes = kube.run_json(["get", "nodes"]).get("items") or []
    if not nodes:
        # Zero iterations would record no assertions at all, which reads as a
        # section with less to say rather than one that never ran (#156).
        rec.failed("No nodes returned; CSI registration not verified")
        return

    for node in nodes:
        name = node.get("metadata", {}).get("name", "<unknown>")
        csinode = kube.run_json(["get", "csinode", name])
        drivers = [d.get("name") for d in (csinode.get("spec", {}).get("drivers") or [])]
        registered = "driver.longhorn.io" in drivers
        state = "registered" if registered else "not registered"
        rec.verdict(registered, f"Node {name}: driver.longhorn.io CSI {state}")


# ─── External Secrets ────────────────────────────────────────────────────────

_ESO_CRDS = (
    "externalsecrets.external-secrets.io",
    "secretstores.external-secrets.io",
    "clustersecretstores.external-secrets.io",
)


def external_secrets(rec):
    if not kube.exists(["get", "ns", "external-secrets"]):
        rec.skipped("namespace 'external-secrets' not present (subsystem not enabled)")
        return
    rec.verdict(*workloads.state("deployment", "external-secrets", "external-secrets"))
    _crds(rec, _ESO_CRDS)


# ─── Karpenter ───────────────────────────────────────────────────────────────

_KARPENTER_CRDS = (
    "ec2nodeclasses.karpenter.k8s.aws",
    "nodepools.karpenter.sh",
    "nodeclaims.karpenter.sh",
)


def stuck_minutes():
    raw = os.environ.get("KARPENTER_NODECLAIM_STUCK_MINUTES", "")
    if not raw:
        return DEFAULT_NODECLAIM_STUCK_MINUTES
    if not raw.isdigit() or int(raw) < 1:
        raise ValueError(
            f"KARPENTER_NODECLAIM_STUCK_MINUTES must be a positive integer (got {raw!r})"
        )
    return int(raw)


def _parsed(timestamp):
    if not timestamp:
        return None
    try:
        return datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return None


def stuck_nodeclaims(items, minutes, now=None):
    """NodeClaims that have not finished within the threshold.

    Why this is checked at all (#123): Karpenter asks to remove a node,
    something refuses to release it, and the instance bills indefinitely.
    Nothing errors — Karpenter simply retries forever — so without an explicit
    check the only symptom is the AWS invoice.

    Two stuck states are reported:
      deleting  - deletionTimestamp set but the NodeClaim is still here. Drain
                  is blocked, most likely by a PDB that never releases.
      launching - never reached Ready. The instance exists but never joined,
                  which is what a broken bootstrap entry point looks like (#121).
    """
    now = now or datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(minutes=minutes)

    stuck = []
    for claim in items:
        meta = claim.get("metadata", {})
        name = meta.get("name", "<unknown>")

        deleting = _parsed(meta.get("deletionTimestamp"))
        if deleting is not None:
            if deleting < cutoff:
                mins = int((now - deleting).total_seconds() // 60)
                stuck.append(f"{name}: deleting for {mins}m — drain is blocked (check PDBs)")
            continue

        conds = claim.get("status", {}).get("conditions") or []
        ready = next((c.get("status") for c in conds if c.get("type") == "Ready"), "")
        if ready == "True":
            continue

        created = _parsed(meta.get("creationTimestamp"))
        if created is not None and created < cutoff:
            mins = int((now - created).total_seconds() // 60)
            stuck.append(f"{name}: not Ready after {mins}m — node never joined")
    return stuck


def karpenter(rec):
    if not kube.exists(["get", "crd", "nodepools.karpenter.sh"]):
        rec.skipped("CRD nodepools.karpenter.sh not present (subsystem not enabled)")
        return
    rec.verdict(*workloads.state("deployment", "kube-system", "karpenter"))
    _crds(rec, _KARPENTER_CRDS)

    minutes = stuck_minutes()
    items = kube.run_json(["get", "nodeclaims"]).get("items") or []
    stuck = stuck_nodeclaims(items, minutes)
    if stuck:
        rec.failed(f"NodeClaims stuck longer than {minutes}m", "\n".join(stuck))
    else:
        rec.passed(f"No NodeClaims stuck longer than {minutes}m")


# ─── Descheduler ─────────────────────────────────────────────────────────────


DESCHEDULER_CRONJOB = "descheduler"


def job_state(job):
    """complete / failed / active for one CronJob-spawned Job."""
    conditions = job.get("status", {}).get("conditions") or []
    seen = {c.get("type"): c.get("status") for c in conditions}
    if seen.get("Complete") == "True":
        return "complete"
    if seen.get("Failed") == "True":
        return "failed"
    return "active"


def latest_finished_job(items, cronjob):
    """The newest finished Job owned by `cronjob`, as (created, name, state).

    Ownership is filtered on rather than the namespace, because kube-system also
    holds unrelated helm-install-* Jobs whose failures are not the descheduler's.
    """
    finished = []
    for obj in items:
        meta = obj.get("metadata", {})
        owners = meta.get("ownerReferences") or []
        if not any(o.get("kind") == "CronJob" and o.get("name") == cronjob for o in owners):
            continue
        state = job_state(obj)
        if state != "active":
            finished.append((meta.get("creationTimestamp") or "", meta.get("name") or "?", state))
    return sorted(finished)[-1] if finished else None


def descheduler(rec):
    """Whether the descheduler is actually rebalancing pods.

    This check previously recorded one assertion — that the CronJob object
    exists. A suspended CronJob exists, looks entirely healthy, and never evicts
    anything again; so does one whose every run has been failing. Presence was
    never the question.
    """
    if not kube.exists(["-n", "kube-system", "get", "cronjob", DESCHEDULER_CRONJOB]):
        rec.skipped("cronjob kube-system/descheduler not present (subsystem not enabled)")
        return

    cronjob = kube.run_json(["-n", "kube-system", "get", "cronjob", DESCHEDULER_CRONJOB])
    suspended = bool(cronjob.get("spec", {}).get("suspend"))
    if suspended:
        rec.failed("kube-system/descheduler is SUSPENDED — it will never run")
    else:
        rec.passed("kube-system/descheduler is active")

    jobs = kube.run_json(["-n", "kube-system", "get", "jobs"]).get("items") or []
    latest = latest_finished_job(jobs, DESCHEDULER_CRONJOB)
    if latest is None:
        # A cluster younger than the schedule has not run yet. Unverified, which
        # is neither a pass nor a failure.
        rec.skipped("descheduler has not completed a run yet")
        return
    _, name, state = latest
    rec.verdict(state == "complete", f"latest descheduler Job {name} is {state}")


# ─── Tailscale ───────────────────────────────────────────────────────────────

_TS_PROXY_SELECTOR = (
    "tailscale.com/parent-resource=tailnet-entrypoint,tailscale.com/parent-resource-type=ingress"
)


def tailscale(rec):
    if not kube.exists(["get", "ns", "tailscale"]):
        rec.skipped("namespace 'tailscale' not present (subsystem not enabled)")
        return
    rec.verdict(*workloads.state("deployment", "tailscale", "operator"))

    has_class = kube.exists(["get", "ingressclass", "tailscale"])
    rec.verdict(has_class, f"IngressClass 'tailscale' {'exists' if has_class else 'is missing'}")

    proxyclasses = kube.run_json(["get", "proxyclass"]).get("items") or []
    if not proxyclasses:
        rec.failed("No Tailscale ProxyClass exists")
    else:
        unready = [
            p.get("metadata", {}).get("name", "<unknown>")
            for p in proxyclasses
            if not any(
                c.get("type") == "ProxyClassReady" and c.get("status") == "True"
                for c in (p.get("status", {}).get("conditions") or [])
            )
        ]
        rec.verdict(
            not unready,
            "Tailscale ProxyClass is Ready"
            if not unready
            else f"Tailscale ProxyClass not Ready: {', '.join(unready)}",
        )

    proxies = kube.run_json(["-n", "tailscale", "get", "statefulset", "-l", _TS_PROXY_SELECTOR])
    count = len(proxies.get("items") or [])
    rec.verdict(
        count > 0,
        "Tailscale proxy StatefulSet for tailnet-entrypoint exists"
        if count
        else "Tailscale proxy StatefulSet for tailnet-entrypoint is missing",
    )
