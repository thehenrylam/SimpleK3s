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

Verification runs once by default, which is what you want for a cluster that is already up. Straight after a `cluster_apply.yml`, a single check will report failure on a perfectly good deploy — the apply only creates the infrastructure, while ArgoCD, Grafana and Prometheus are still starting and are not yet serving. Retry instead of guessing at a fixed wait:

``` sh
# Try up to 10 times, 30s apart, until the cluster comes up healthy
ansible-playbook ./playbooks/cluster_verify.yml -e verify_attempts=10 -e verify_delay=30
```

| Variable | Default | Purpose |
|---|---|---|
| `verify_attempts` | `1` | Total attempts before the play fails |
| `verify_delay` | `30` | Seconds between attempts |
| `verify_stability_window` | *(unset — script uses 300)* | `STABILITY_WINDOW_SECONDS` for the remote pod-restart check |

`verify_attempts` counts **total attempts**, not Ansible's `retries` (which means "extra tries after the first"). `verify_attempts=1` runs the check exactly once. Budget roughly **20s per attempt** plus `verify_delay` between them.

One caveat when verifying a freshly-applied cluster: the pod-stability check looks *backwards* over the last `STABILITY_WINDOW_SECONDS` (default 300) for pod restarts. Restarts during boot — pods waiting on External-Secrets to sync, for example — stay inside that window, so verification keeps failing for up to five minutes after every rollout is already ready. Either budget retries past that window, or narrow it:

``` sh
ansible-playbook ./playbooks/cluster_verify.yml \
  -e verify_attempts=10 -e verify_delay=30 -e verify_stability_window=60
```

Measured on a real cold start: a cluster verified ~15-30s after `cluster_apply.yml`
reached PASS in about **2 minutes**, on the third attempt, with the stability window at
its 300s default. Pod *restarts* are what that window catches, and a clean boot has
none — initial container starts do not count — so the window only bites when something
crash-loops on the way up. `verify_attempts=10 -e verify_delay=30` gives roughly five
minutes of headroom over the measured time.

### Post-apply verification

`cluster_apply.yml` runs `cluster_verify.yml` automatically once the apply finishes,
with `verify_attempts=10` and `verify_delay=30` (roughly an 8-minute budget against the
~2 minutes measured above).

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
