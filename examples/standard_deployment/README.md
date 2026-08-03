# Example: Standard Deployment

## First Time Setup

### A. Configure the master configuration file

- Configure `./group_vars/all.yml`: Replace `__CONFIGURE_THIS__` with the appropriate values

### B. Perform a first time template

``` sh
# Template values from all.yml -> terraform.tfvars to be used by the IaC modules
# The .j2 template files can be found within `./roles/tfvars/templates/`
ansible-playbook ./playbooks/tfvars_template.yml
```

### C. Deploy the supporting infrastructure

``` sh
# Deploy support elements, such as PVC, IDP, and Tailscale functionality
ansible-playbook ./playbooks/support_apply.yml
```

### D. Deploy the cluster infrastructure

``` sh
# Deploys the actual K3s cluster (along with a few extras like S3 to allow it to operate)
ansible-playbook ./playbooks/cluster_apply.yml
```

### E. Verify cluster health

``` sh
# Performs basic checks to make sure that the cluster is running OK
ansible-playbook ./playbooks/cluster_verify.yml
```

## How to Interact with the Cluster

### Playbooks

#### Cluster Actions

- `./playbooks/cluster_template.yml`
    - Templates the `terraform.tfvars` for `cluster` IaC modules (*Will stop in place if `__CONFIGURE_THIS__` string is detected*)
- `./playbooks/cluster_plan.yml`
    - Executes `tofu plan` for `cluster` IaC modules
- `./playbooks/cluster_apply.yml`
    - Executes `tofu apply` for `cluster` IaC modules, then runs `cluster_verify.yml` — a deploy is not "done" until the cluster passes
    - Skip the post-apply check with `-e verify_after_apply=false` (see below)
- `./playbooks/cluster_destroy.yml`
    - Executes `tofu destroy` for `cluster` IaC modules
- `./playbooks/cluster_update.yml`
    - Executes `tofu apply` + `./scripts/ssm_update_services.sh` to ask the cluster to pull from S3, pull new files, and redoing the node setup to update services
    - **Fails the play** when the service update does not succeed
- `./playbooks/cluster_verify.yml`
    - Executes `./scripts/ssm_verify_cluster.sh` to get the health status of the cluster
    - **Fails the play** when the cluster does not pass. A node that cannot be reached counts as a failure, not a pass.
- `./playbooks/cluster_repair.yml`
    - Rejoins a control-plane node that cannot rejoin on its own — the node-0 replacement case
    - **Previews by default**; applies only with `-e repair_apply=true` (see below)

Verification runs once by default, which is what you want for a cluster that is already up. Straight after a `cluster_apply.yml`, a single check will report failure on a perfectly good deploy — the apply only creates the infrastructure, while ArgoCD, Grafana and Prometheus are still starting and are not yet serving. Retry instead of guessing at a fixed wait:

``` sh
# Try up to 15 times, 30s apart, until the cluster comes up healthy
ansible-playbook ./playbooks/cluster_verify.yml -e verify_attempts=15 -e verify_delay=30
```

| Variable | Default | Purpose |
|---|---|---|
| `verify_attempts` | `1` | Total attempts before the play fails |
| `verify_delay` | `30` | Seconds between attempts |
| `verify_stability_window` | *(unset — script uses 300)* | `STABILITY_WINDOW_SECONDS` for the remote pod-restart check |

`verify_attempts` counts **total attempts**, not Ansible's `retries` (which means "extra
tries after the first"), so `verify_attempts=1` runs the check exactly once.

Measured on two real cold starts, both with the stability window left at its default:

| Run | Passed on | Elapsed |
|---|---|---|
| Verified ~15-30s after apply | attempt 3 | ~2 min |
| Chained straight off `cluster_apply.yml` | attempt 6 | ~4.5 min |

Budget roughly **20s per attempt** plus `verify_delay` between them, so `k` attempts
costs about `20k + 30(k-1)` seconds.

The pod-stability check looks *backwards* over the last `STABILITY_WINDOW_SECONDS`
(default 300) for pod restarts, which sounds like it would block a fresh cluster for five
minutes — but it counts container *restarts*, and a clean boot has none. Initial starts
do not count, and in both runs above it was a non-issue.

It does bite in two cases. One is a pod crash-looping on the way up, e.g. waiting on
External-Secrets to sync. The other is any **single** restart in the preceding five
minutes: the check reports only that a restart happened, not how many or whether the pod
has since stabilised, so one restart from a transient disruption fails the run even
though the cluster is completely healthy. That makes verification lag recovery by up to
`STABILITY_WINDOW_SECONDS` — see [RUNBOOKS.md](../../RUNBOOKS.md) for how this shows up
after a node replacement.

In either case, narrow the window rather than waiting it out:

``` sh
ansible-playbook ./playbooks/cluster_verify.yml \
  -e verify_attempts=15 -e verify_delay=30 -e verify_stability_window=60
```

### Repairing a control-plane node

A replaced node-0 cannot rejoin unaided: its join target (`CONTROLLER_HOST`) is its own
address, and the terminated node's etcd member still holds its hostname. `cluster_repair.yml`
automates the recovery that `RUNBOOKS.md` documents by hand.

``` sh
# Preview — discovers the real state and changes nothing
ansible-playbook ./playbooks/cluster_repair.yml

# Apply
ansible-playbook ./playbooks/cluster_repair.yml -e repair_apply=true
```

Two safety properties worth knowing, because they decide when it will refuse:

- **A node is only treated as stale when nothing is serving from its address** — either
  no instance holds it, or the instance that does is not running k3s. `NotReady` alone is
  never enough: a node that is partitioned or briefly wedged still has a live etcd member,
  and removing it would turn a recoverable blip into an irreversible membership change.
- **It refuses to remove members that would drop the cluster below quorum.** Removing a
  member lowers the member count and with it the failures the cluster tolerates — three
  members survive one loss, two survive none. If too few nodes are Ready to survive the
  removal, it stops and says so.

The preview is the script's own `--dry-run`, not Ansible's `--check`. Check mode skips
`shell` tasks, so it would report "skipped" instead of a diagnosis; `--dry-run` performs
the discovery for real and changes nothing.

### Post-apply verification

`cluster_apply.yml` runs `cluster_verify.yml` automatically once the apply finishes,
with `verify_attempts=15` and `verify_delay=30` — roughly a 12-minute ceiling, about
2.5x the slowest cold start measured above.

That number is sized off observed variance across two samples, not a computed bound.
Two cold starts spanned a 2x range (attempt 3 and attempt 6), so if you ever see a boot
land near attempt 12, the real spread is wider than those samples suggested and the
budget should go up.

This cannot block a deploy. Verification runs *after* `tofu apply` has already
completed, so a failure reports that the cluster came up unhealthy — it never prevents
the infrastructure change or rolls anything back. If the apply itself fails, Ansible
aborts and verification never runs at all.

When you are iterating on a broken deploy, waiting out a multi-minute verify between
attempts is pure friction. Skip it:

``` sh
ansible-playbook ./playbooks/cluster_apply.yml -e verify_after_apply=false
```

Then run `cluster_verify.yml` by hand when you want the verdict.

#### Support Actions

- `./playbooks/support_template.yml`
    - Templates the `terraform.tfvars` for `support` IaC modules (*Will stop in place if `__CONFIGURE_THIS__` string is detected*)
- `./playbooks/support_plan.yml`
    - Executes `tofu plan` for `support` IaC modules
- `./playbooks/support_apply.yml`
    - Executes `tofu apply` for `support` IaC modules
- `./playbooks/support_destroy.yml`
    - Executes `tofu destroy` for `support` IaC modules

Any playbook accepts Ansible's `--limit` to narrow which IaC modules it acts on — useful for spinning down the costly modules while keeping `idp` (recreating a Cognito pool means re-adding users and burning monthly active users):

``` sh
# Only pvc and tailscale (prefer this: a module added later is not destroyed unless you name it)
ansible-playbook ./playbooks/support_destroy.yml --limit pvc,tailscale

# Everything except idp (quotes required — bare '!' is history expansion in bash/zsh)
ansible-playbook ./playbooks/support_destroy.yml --limit '!idp'
```

#### General Actions

- `./playbooks/tfvars_template.yml`
    - Templates the `terraform.tfvars` for IaC modules (*Will stop in place if `__CONFIGURE_THIS__` string is detected*)

### Scripts

- `./scripts/ssm_connect.sh <aws_profile>`
    - Connects to an EC2 environment in the cluster (Pick the instance to connect to via a GUI)
        - If `--instance-id <instance-id>` is used, then it will automatically connect to that instance id
- `./scripts/ssm_pick_instance.py <aws_profile>`
    - Lists a GUI to display and allow you to select an instance in the cluster (*Outputs the selected instance id*)
- `./scripts/ssm_execute.sh <aws_profile> --instance-id <instance-id> --exec-cmd <command>`
    - Executes any command on a given `instance-id` in the cluster
- `./scripts/ssm_list_instances.sh <aws_profile>`
    - Outputs a list of EC2 instances in the cluster
- `./scripts/ssm_update_services.sh <aws_profile>`
    - In an EC2 node, execute a script to pull files from `S3 bootstrap` and redoing the node setup to update services
- `./scripts/ssm_verify_cluster.sh <aws_profile> [--no-color] [--per-node]`
    - On **every** controlplane node, execute a script to verify the health of the cluster, then merge the results into one report (a check every node agrees on is printed once; divergent lines are attributed to the nodes that produced them)
    - Passes only if every node passes — a node that cannot be reached is not a pass
    - `--no-color` never emits colour (already off when piped); `--per-node` prints each node's log in full instead of the merged report

### AI Skills

- `cluster-ops`
    - Invoke directly or ask Claude Code (or equivalent) to perform actions for you within the cluster.
        - Read-type actions will be executed without need for approval
        - Mutation actions will require approval (in individual commands or batch commands)
    - DISCLAIMER: Use at your own risk (*Try it on test environment to get a feel for it and then experiment on PROD once you have properly vetted and understood the process*)
