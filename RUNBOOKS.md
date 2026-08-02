# SimpleK3s Runbooks

Manual recovery procedures for failures that automation cannot fix on its own.

Each runbook states what the failure looks like, how to confirm it, and how to repair
it. Commands run over SSM — see `examples/standard_deployment/README.md` for the helper
scripts, or the `cluster-ops` Claude skill.

> **Two things to know before running anything on a node.**
>
> 1. **SSM executes commands with `/bin/sh` (dash), not bash.** The bootstrap libraries
>    are bash-specific and fail with `Bad substitution` / `source: not found` unless you
>    wrap the command in `bash -c "…"`.
> 2. **`CONTROLLER_HOST` is node-0's own IP** (`cluster_ec2.tf:126` pins the `.100`
>    address to `count.index == 0`). Anything node-0 runs that defaults to
>    `CONTROLLER_HOST` — including `--recreate` — points at itself. Joins performed
>    *from* node-0 must name a surviving peer explicitly.

---

## Replacing a terminated control-plane node-0

**Status: tested end to end on 2026-08-02.**

### What happened

Node-0 was terminated and Terraform rebuilt it. The replacement boots blank and cannot
rejoin on its own, for two independent reasons:

- Its join target (`CONTROLLER_HOST`) is its own address, so it has nothing to join.
- The terminated node's etcd member is still registered under the same hostname. The
  replacement gets the same static IP, therefore the same name, and etcd rejects it:
  `etcd cluster join failed: duplicate node name found`.

The bootstrap will refuse to proceed rather than found a second cluster — expected, and
what protects the join token. This runbook completes the rejoin by hand.

### Symptoms

- The replacement's bootstrap log contains:
  `Cluster detection: token_in_pstore=true server_on_6443=false` followed by
  `Ambiguous cluster state — refusing to guess.`
- `systemctl is-active k3s` on the replacement is `inactive`, or crash-loops through
  `activating`.
- A surviving node shows the old entry as `NotReady`:

  ```
  ip-10-0-1-100   NotReady   control-plane,etcd
  ```

### Repair

Throughout: `<new-id>` is the replacement instance, `<survivor-id>` a healthy
control-plane instance, and `<survivor-ip>` its private IP (e.g. `10.0.2.53`).

**Step 1 — Confirm a survivor is healthy.** Never join to a node that is itself
struggling:

```bash
./scripts/ssm_execute.sh <profile> --instance-id <survivor-id> \
  --exec-cmd 'systemctl is-active k3s; kubectl get nodes'
```

Expect `active` and at least one `Ready` node besides the dead one. If the survivors are
`activating`, wait — a cluster that just lost a member thrashes for a few minutes while
etcd settles.

**Step 2 — Remove the stale etcd member.** This is the step that actually unblocks the
join. Deleting the Node object on a surviving node makes K3s drop the corresponding etcd
member:

```bash
./scripts/ssm_execute.sh <profile> --instance-id <survivor-id> \
  --exec-cmd 'kubectl delete node ip-10-0-1-100; kubectl get nodes'
```

The dead entry should disappear, leaving only healthy nodes.

**Step 3 — Clear any partial state on the replacement.** If a join was already attempted
and failed, it left an unusable etcd directory behind:

```bash
./scripts/ssm_execute.sh <profile> --instance-id <new-id> \
  --exec-cmd 'systemctl stop k3s 2>/dev/null; rm -rf /var/lib/rancher/k3s/server/db'
```

**Step 4 — Join, aimed at the survivor.** Use the repo's own installer rather than
hand-rolling it; its second argument overrides `CONTROLLER_HOST`, which is the whole
point here. The node fetches the token itself, so no secret passes through your shell:

```bash
./scripts/ssm_execute.sh <profile> --instance-id <new-id> \
  --exec-cmd 'bash -c "cd /opt/simplek3s/bootstrap/default;
    . ./lib/common.sh; . ./lib/providers/aws.sh;
    TOKEN=\$(get_ssm k3s-token decrypt);
    install_k3s_server \"\$TOKEN\" <survivor-ip>"'
```

If K3s was already installed by a failed attempt, `systemctl start k3s` after step 3 is
enough — the service config already points at the right server.

**Step 5 — Verify.** From a survivor:

```bash
./scripts/ssm_execute.sh <profile> --instance-id <survivor-id> \
  --exec-cmd 'kubectl get nodes -o wide'
```

All control-plane nodes `Ready`, the replacement with a small `AGE`. Expect etcd
`apply request took too long` warnings for a few minutes while the new member catches
up — those are normal and subside.

Then run the full check:

```bash
ansible-playbook ./playbooks/cluster_verify.yml -e verify_attempts=15 -e verify_delay=30
```

### Expect transient failures during recovery

While a control-plane node is missing, verification legitimately reports failures for
workloads that were running on it — commonly `coredns`, `local-path-provisioner`, and
the `kyverno` controllers — plus the `NotReady` node itself and any pod restarts caught
by the 300s stability window. These clear once pods reschedule. Karpenter may also
provision a worker to absorb the displaced load; that is expected, and it will scale
back down.

---

## Split cluster (two clusters behind one load balancer)

**Status: not reproduced since the detection guard landed. Steps below are reasoned, not
tested.**

### What happened

Before the detection guard, `bts_03_install_k3s.sh` chose "found a new cluster" from the
node's index alone. A replaced node-0 would run `--cluster-init` on its blank disk and
then **overwrite the join token in Parameter Store**, leaving the survivors running the
original cluster while the new node served an empty one.

The automatic path no longer does this — it probes first and refuses when the evidence is
ambiguous. This runbook covers clusters split before that fix, or by a mistaken
`--force-cluster-init`.

### Symptoms

- `kubectl get nodes` returns different answers depending on which node you ask.
- Workloads appear and disappear as the load balancer rotates backends.
- New agents join the wrong cluster, or fail to join.

### Confirm before changing anything

Ask each control-plane node what it sees:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods
```

Two disjoint answers confirm the split. Identify **which nodes hold the real data** —
almost always the surviving majority, not the freshly rebuilt node-0.

### Repair

**Step 1 — Stop the impostor** so it stops serving and stops accepting joins:

```bash
systemctl stop k3s
```

**Step 2 — Recover the real token** from a surviving node:

```bash
cat /var/lib/rancher/k3s/server/token
```

This is the same file the bootstrap reads, so it is exactly what belongs in Parameter
Store.

**Step 3 — Restore it**, overwriting the impostor's:

```bash
aws ssm put-parameter --name "/simplek3s/<nickname>/k3s-token" \
  --type SecureString --value "<token-from-step-2>" --overwrite \
  --region <region> --profile <profile>
```

**Step 4 — Discard the false cluster's state** on the impostor:

```bash
systemctl stop k3s
rm -rf /var/lib/rancher/k3s/server/db
```

**Step 5 — Rejoin it** using the node-0 replacement runbook above, starting at its
step 2. The same two obstacles apply: the stale etcd member must go first, and the join
must name a surviving peer rather than `CONTROLLER_HOST`.

### If workloads were written to the empty cluster

Anything written while the impostor served traffic exists **only** in the cluster you are
about to discard. Decide deliberately which side is authoritative before step 4 —
recovering from the impostor means extracting from its etcd or re-applying manifests by
hand, and there is no merge path. In practice the surviving majority wins, because it
holds everything from before the incident.

### Prevention

- Keep the detection guard in place; never wire `--force-cluster-init` into an
  unattended boot path.
- Treat a boot halting with *"Ambiguous cluster state — refusing to guess"* as working
  as intended. Investigate which half of the evidence is missing rather than reaching for
  a flag to silence it.
