---
name: cluster-ops
description: Run shell commands on a deployed SimpleK3s cluster node via SSM. Used to troubleshoot, inspect, or make changes in the cluster. Examples; Execute a command in the cluster, check the statuses of pods/nodes/services and investigate, "go into a node" and do "X".
---

# Cluster Ops

Run commands on a **deployed** SimpleK3s cluster through `ssm_execute.sh`.

**Never call `aws ssm` directly.** The script validates the instance against the target
cluster, escapes the command safely, reports output truncation, and returns meaningful
exit codes. Going around it loses all of that and can target the wrong cluster.

## 1. Find the script

Each deployment under `examples/` carries its own toolkit and points at its **own
cluster**:

```bash
ls examples/*/scripts/ssm_execute.sh
```

Never hardcode a path. There may be several deployments (`standard_deployment`,
`cheap_deployment`, `barebones_deployment`, …) and they are different clusters.

## 2. Gather the inputs — ask when unknown

| Input | How to resolve |
|---|---|
| Deployment | From the conversation. **If more than one exists and the user has not named one, ask. Never guess.** |
| AWS profile | From the conversation, or ask. |
| Instance id | List the cluster's instances first (below). |
| Command | From the user's intent. |

```bash
DEP=examples/<deployment>/scripts
./$DEP/ssm_execute.sh --help                      # interface, --json fields, exit codes
./$DEP/ssm_list_instances.sh <profile> --json compact
```

Every `ssm_*.sh` shares one argument convention: `<profile> [<nickname> <region>]`.
Nickname and region are inferred from that deployment's `terraform.tfvars`, so usually
the profile is all you need.

`ssm_list_instances.sh --json` returns `nickname`, `region`, `profile`, and `instances[]`
(`instance_id, name, role, state, instance_type, az, private_ip, public_ip, launched`).
**Use its `nickname`/`region` to confirm you are on the intended cluster before acting.**
Any control-plane node can run `kubectl`; only `running` instances accept commands.

## 3. Confirm before changing anything

**Read-only** — `get`, `describe`, `logs`, `top`, `events`, `cat`, `ls`, `journalctl`,
`systemctl status`: just run it, no confirmation.

**Mutating** — `delete`, `apply`, `patch`, `scale`, `restart`, `drain`, `cordon`, `rm`,
`systemctl start/stop/restart`, `helm`, anything writing files: show this block and wait
for approval.

```
Deployment : <deployment dir>
Cluster    : nickname=<n>  region=<r>  profile=<p>
Instance   : i-...  (<node name>)
Command    : <exact command to run>
```

Commands run **as root** — SSM's `AWS-RunShellScript` already does, so never add `sudo`.
Confirming reads as well as writes trains the user to rubber-stamp; keep the prompt rare
so it stays meaningful.

### Multi-step changes: agree a plan, then execute it

A goal that needs **more than one mutation** (clear caches, scale to 0, delete pods,
scale back up) is **one** decision by the user, not four. Do not ask four times — that
fragments the decision so the shape cannot be reviewed, and trains the user to approve
without reading.

Instead: investigate read-only first, then put the whole thing up for one approval.

```
GOAL       : restart ArgoCD cleanly to clear stale certs
DEPLOYMENT : examples/standard_deployment
CLUSTER    : nickname=prod  region=us-west-2  profile=deployer
TARGET     : i-0abc… (k3s_controlplane-a1)

STEPS
  1. kubectl -n argocd scale deploy/argocd-server --replicas=0
  2. rm -rf /var/lib/rancher/k3s/server/tls/argocd-*
  3. kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server
  4. kubectl -n argocd scale deploy/argocd-server --replicas=1

OUT OF SCOPE : monitoring namespace, production workloads, node reboots
STOP IF      : any step exits non-zero, or a pod outside argocd goes NotReady
VERIFY AFTER : kubectl -n argocd get pods
```

Once approved, run the steps without asking again. While executing:

- **The plan is a ceiling, not a script.** Doing fewer steps is fine. Anything *not* in
  the plan — including a command that seemed obviously needed once you saw the output —
  requires going back for approval. Never improvise inside an approved scope.
- **Stop on the first failing step.** Check the exit code and `response_code` after each
  one; do not run step N+1 because step N "probably worked".
- **Verify between mutations** with a read-only command when a step's success is not
  obvious from its own output.
- **Keep a short running log** of what actually ran, so the user can audit afterwards.
- If the plan turns out not to solve the problem, **report that** — do not extend it.

Note this is an agreement, not a sandbox: nothing here mechanically prevents an
out-of-scope command. For constraints that must hold regardless ("monitoring must never
be stopped"), the durable control is an IAM policy or a restricted AWS profile, and the
plan should name which profile to use.

## 4. Execute

**Default: synchronous.** It already polls internally for up to 10 minutes.

```bash
./$DEP/ssm_execute.sh <profile> --instance-id <id> --exec-cmd "<command>" --json compact
```

Always prefer `--json compact`: stable field names, single line, no colour.

**When parsing `--json`, capture stdout only — use `2>/dev/null`, never `2>&1`.**
Progress ("Command ID: …", poll ticks) is written to stderr by design so stdout stays
pure JSON. Merging the two prepends non-JSON text and the parse fails.

**Use async only when the command may outlive your tool timeout** — helm upgrades, image
pulls, node reboots, re-running bootstrap:

```bash
./$DEP/ssm_execute.sh <profile> --instance-id <id> --exec-async "<command>" --json compact
# -> {"instance_id":"…","command_id":"<uuid>","status":"Pending"}
./$DEP/ssm_execute.sh <profile> --instance-id <id> --exec-get "<uuid>" --json compact
```

`--exec-get` exits **3** while the command is still running. Poll about every 10s for the
first minute, then every 30s. Do not busy-loop, and do not re-send the command — that
would run it twice.

## 5. Interpret the result

Exit codes: `0` succeeded · `1` failed · `2` bad usage · `3` still running.

- `nickname` and `region` report the cluster the script **actually** resolved. Check them
  against what the user asked for — this is what catches running in the wrong deployment.
- `response_code` is the **remote command's** exit code, not the script's.
- **Always check `stdout_truncated` before drawing conclusions from `stdout`.** SSM caps
  stdout at 24000 characters (stderr at 8000) and cuts mid-stream; the remainder is
  unrecoverable for that command id. When true, a `truncation_note` explains it — treat
  the output as partial and re-run with the result narrowed **on the node**.
- Pre-empt truncation on broad queries: append `| tail -n 200`, `| grep PATTERN`, or
  `| head -c 20000` rather than discovering the cut afterwards.

## Stop and ask the user

- More than one deployment exists and the user has not said which.
- The command would affect production workloads without explicit authorisation.
- The same command fails repeatedly — report findings instead of retrying blindly.
- Anything destructive that was not part of what the user asked for.
