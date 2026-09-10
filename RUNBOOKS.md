# SimpleK3s Runbooks

Recovery procedures for failures the cluster cannot fix on its own.

**Most of these are one command now.** `./sk3s repair` handles the control-plane
cases that used to need a dozen manual steps. Each runbook leads with that, then
explains what it actually does — so you can tell when it will not help.

Run everything from `examples/standard_deployment/`. `./sk3s` lists the verbs;
`./sk3s <verb> --help` documents each one.

> **Two things to know before running anything on a node.**
>
> 1. **SSM executes commands with `/bin/sh` (dash), not bash.** The bootstrap
>    libraries are bash-specific and fail with `Bad substitution` or
>    `source: not found` unless you wrap the command in `bash -c "…"`.
> 2. **`CONTROLLER_HOST` is node-0's own IP.** `cluster_ec2.tf` assigns the
>    static `.100` address only when `count.index == 0`, so anything node-0 runs
>    that defaults to `CONTROLLER_HOST` — including `--recreate` — points at
>    itself. A join performed *from* node-0 must name a surviving peer.

---

## Replacing a terminated control-plane node-0

**Status: verified end to end 2026-09-09 via `./sk3s repair`; by hand 2026-08-02.**

### Symptoms

- `./sk3s status` reports the old node `NotReady`, and — once the replacement
  exists — a second node that fails every check it attempts.
- The replacement's bootstrap log ends with
  `Ambiguous cluster state — refusing to guess.`
- `systemctl is-active k3s` on the replacement is `inactive`. K3s was never
  installed, so there is no service to inspect.

### Repair

**Step 1 — wait for the instance to be gone, then rebuild it.**

```sh
aws ec2 wait instance-terminated --instance-ids <dead-id> --profile <profile> --region <region>
./sk3s infra cluster apply -e verify_after_apply=false
```

Both halves matter.

*Wait first.* While the instance is `shutting-down`, Terraform's refresh still
sees it and plans **nothing** — the apply returns in ~13s reporting success
having created no replacement. Measured: about **4 minutes** between the
terminate call and Terraform detecting the deletion. Skipping the wait cost 3m29s
and a wasted repair cycle in the drill this runbook is based on.

*Skip the verification.* `cluster apply` normally verifies afterwards with 15
attempts 30s apart. It cannot pass until the repair runs, so it burns ~7 minutes
on a foregone conclusion. `sk3s status` gives the verdict when you want it.

**Step 2 — repair.**

```sh
./sk3s repair            # preview — the default. Changes nothing.
./sk3s repair --apply
./sk3s status
```

The preview prints EC2 instances as ground truth beside the cluster's node
objects, then names what it would change:

```
--- diagnosis ---
  stale member   : ip-10-0-1-100  (instance at 10.0.1.100 is not running k3s (state: inactive))
  unjoined node  : i-00928428a785b6749 (10.0.1.100)

--- plan (preview, nothing changed) ---
  would remove stale member : ip-10-0-1-100
  would join node           : i-00928428a785b6749 via 10.0.3.127
```

Note `via 10.0.3.127` — the **survivor**, not `CONTROLLER_HOST`. That
indirection is the whole point; see warning 2 above.

### How long it takes

Measured end to end on a 3-node cluster, 2026-09-10:

| Phase | Wall clock |
| --- | --- |
| `instance-terminated` wait | **2m 47s** |
| `infra cluster apply` (creates the replacement) | 32 s |
| instance boots, SSM registers, `repair` diagnoses | ~1–2 min |
| `repair --apply` (remove member + join + Ready) | 59 s |
| workloads converge, `status` passes | ~2–3 min |
| **total** | **~9m 45s** |

Roughly a third of that is AWS taking the instance from `shutting-down` to
`terminated`, which nothing can shorten. The wait is not overhead — skipping it
does not save the time, it just moves it somewhere more confusing.

A drill run *without* the wait took 9m 35s and needed **two** repair cycles: the
first apply no-opped, so the stale member and the unjoined node were fixed in
separate passes. Same wall clock, twice the steps, and a middle state that looks
like the tooling is broken. The wait buys clarity, not speed.

**A node reporting `Ready` is not a cluster reporting `PASS`.** The node was
`Ready` at T+3s and `sk3s status` still failed for another ~2 minutes on
`prometheus-...-prometheus 0/1` — the StatefulSet had to reschedule and reattach
its Longhorn volume. That gap is the phase-1 asymmetry below, not an incomplete
repair.

Expect Karpenter to provision a worker during the incident to absorb displaced
load. It consolidates away afterwards, and it will add a node to the per-node
checks while it exists (48 checks becomes 49).

### Why the replacement cannot rejoin unaided

Two independent obstacles, both of which `repair` clears:

- Its join target is its own address, so it has nothing to join.
- The terminated node's etcd member still holds the same hostname. The
  replacement inherits the static IP and therefore the name, and etcd rejects
  it: `etcd cluster join failed: duplicate node name found`.

The bootstrap refuses to proceed rather than found a second cluster. That
refusal is the guard working — see the split-cluster runbook for what it
prevents.

### When repair will refuse

Both refusals are deliberate. Neither is a bug to work around.

- **It only treats a node as stale when nothing is serving from its address** —
  no instance holds it, or the instance that does is not running k3s. `NotReady`
  alone is never enough: a partitioned node still has a live etcd member, and
  removing it turns a recoverable blip into an irreversible membership change.
- **It refuses to drop the cluster below quorum.** Three members survive one
  loss; two survive none. If too few nodes are `Ready` to survive the removal,
  it stops and says so.

### Doing it by hand

Only needed if `repair` refuses and you have decided its reasoning does not
apply. `<new-id>` is the replacement, `<survivor-id>` a healthy control-plane
instance, `<survivor-ip>` its private IP.

```sh
# 1. Confirm a survivor is genuinely healthy — never join to a struggling node.
./sk3s exec --instance-id <survivor-id> --exec-cmd 'systemctl is-active k3s; kubectl get nodes'

# 2. Remove the stale etcd member. This is the step that unblocks the join:
#    deleting the Node object makes K3s drop the corresponding etcd member.
./sk3s exec --instance-id <survivor-id> --exec-cmd 'kubectl delete node ip-10-0-1-100'

# 3. Clear partial state on the replacement, if a join already failed.
./sk3s exec --instance-id <new-id> \
  --exec-cmd 'systemctl stop k3s 2>/dev/null; rm -rf /var/lib/rancher/k3s/server/db'

# 4. Join, aimed at the survivor. The node fetches the token itself, so no
#    secret passes through your shell.
./sk3s exec --instance-id <new-id> --exec-cmd 'bash -c "cd /opt/simplek3s/bootstrap/default;
    . ./lib/common.sh; . ./lib/providers/aws.sh;
    TOKEN=\$(get_ssm k3s-token decrypt);
    install_k3s_server \"\$TOKEN\" <survivor-ip>"'
```

If K3s was already installed by a failed attempt, `systemctl start k3s` after
step 3 is enough — its config already points at the right server.

### Expect verification to fail for a while — in two distinct phases

Different causes, different remedies. Do not read the second as an incomplete
recovery.

**Phase 1 — while a node is missing (~5 minutes).** Pods on an unreachable node
are not evicted immediately: the `node.kubernetes.io/unreachable:NoExecute`
taint carries a default `tolerationSeconds: 300`, so Kubernetes waits five
minutes in case the node comes back. Until then those pods still read `Running`
while their Deployments report `0/1 ready`, which is accurate — the ready
replica is on a node that no longer exists.

What recovers by itself, and what does not:

- **Deployments self-heal.** CoreDNS, Traefik, ArgoCD's servers, Kyverno, the
  Longhorn CSI deployments all reschedule once the toleration expires.
- **StatefulSets and volume-attached pods do not.** A StatefulSet will not
  create a replacement while the old pod object exists (at-most-one semantics),
  and a Longhorn volume stays attached to the dead node. `argocd-application-
  controller` and Grafana both wait for the Node object to go — which is what
  `repair` removes.

Karpenter may provision a worker to absorb displaced load. That is expected, and
it consolidates away afterwards.

**Phase 2 — for up to 5 minutes AFTER the cluster is fully healthy.** This is
the one that looks like a failed recovery and is not. The pod-stability check
looks *backwards* over `STABILITY_WINDOW_SECONDS` (default 300). Any restart
inside that window fails the run **no matter how healthy the cluster now is**,
so a cluster that recovered 60 seconds ago cannot pass yet, and there is nothing
to fix.

Observed on a real recovery: every functional check passed, and the single
failure was a `node-exporter` pod on a *surviving* node whose liveness probe
timed out while the control plane was unavailable. The kubelet restarted it
once; it had been healthy since. Re-running after the window elapsed returned
`PASS (3/3 nodes passed)` with no intervention.

Either wait it out, or narrow the window:

```sh
STABILITY_WINDOW_SECONDS=60 ./sk3s status
```

**Telling a stale restart from an active crash-loop.** The check reports only
*that* a restart happened. Inspect the pod:

```sh
./sk3s exec --instance-id <survivor-id> \
  --exec-cmd 'kubectl -n <namespace> describe pod <pod> | grep -A6 -iE "last state|restart count"'
```

`RESTARTS: 1` with the pod `Running` and `Ready` is a one-off that has already
recovered. A count that climbs between two checks is a real crash-loop. Exit
code `143` is SIGTERM — the kubelet killing a container that failed a probe,
typical of control-plane unavailability rather than a fault in the pod.

---

## Split cluster (two clusters behind one load balancer)

**Status: not reproduced since the detection guard landed. Steps below are
reasoned, not tested.**

### What happened

Before the guard, `bts_03_install_k3s.sh` chose "found a new cluster" from the
node's index alone. A replaced node-0 would run `--cluster-init` on its blank
disk and then **overwrite the join token in Parameter Store**, leaving the
survivors on the original cluster while the new node served an empty one.

The automatic path no longer does this — it probes first and refuses when the
evidence is ambiguous. This runbook covers clusters split before that fix, or by
a deliberate `--force-cluster-init`.

### Symptoms

- `kubectl get nodes` returns different answers depending on which node you ask.
- Workloads appear and disappear as the load balancer rotates backends.
- New agents join the wrong cluster, or fail to join.

### Confirm before changing anything

Ask each control-plane node what it sees:

```sh
./sk3s exec --instance-id <id> --exec-cmd 'kubectl get nodes -o wide'
```

Two disjoint answers confirm the split. Identify **which side holds the real
data** — almost always the surviving majority, not the rebuilt node-0.

`./sk3s repair` does **not** handle this. It reasons about one cluster's
membership; here there are two, and which one is authoritative is a judgement it
cannot make.

### Repair

```sh
# 1. Stop the impostor serving and accepting joins.
./sk3s exec --instance-id <impostor-id> --exec-cmd 'systemctl stop k3s'

# 2. Recover the real token from a survivor. This is the same file the
#    bootstrap reads, so it is exactly what belongs in Parameter Store.
./sk3s exec --instance-id <survivor-id> --exec-cmd 'cat /var/lib/rancher/k3s/server/token'

# 3. Restore it, overwriting the impostor's.
aws ssm put-parameter --name "/simplek3s/<nickname>/k3s-token" \
  --type SecureString --value "<token-from-step-2>" --overwrite \
  --region <region> --profile <profile>

# 4. Discard the false cluster's state on the impostor.
./sk3s exec --instance-id <impostor-id> \
  --exec-cmd 'systemctl stop k3s; rm -rf /var/lib/rancher/k3s/server/db'
```

Then rejoin the impostor as a normal replacement: `./sk3s repair --apply`, or
the manual steps above from step 2. The same two obstacles apply — the stale
etcd member goes first, and the join names a surviving peer.

### If workloads were written to the empty cluster

Anything written while the impostor served traffic exists **only** in the
cluster you are about to discard. Decide which side is authoritative *before*
step 4: recovering from the impostor means extracting from its etcd or
re-applying manifests by hand, and there is no merge path. In practice the
surviving majority wins, because it holds everything from before the incident.

### Prevention

- Keep the detection guard. Never wire `--force-cluster-init` into an
  unattended boot path.
- Treat a boot halting with *"Ambiguous cluster state — refusing to guess"* as
  working as intended. Investigate which half of the evidence is missing rather
  than reaching for a flag to silence it.
