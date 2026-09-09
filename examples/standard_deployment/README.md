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
    - Executes `tofu apply` + `./scripts/ssm_update_services.sh` (i.e. `sk3s pull`) to sync new files from S3 to every control-plane node, then stage manifests on the node that owns staging
    - **Fails the play** when the service update does not succeed
- `./playbooks/cluster_verify.yml`
    - Executes `./scripts/sk3s_status.py` to get the health status of the cluster
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

### Script Conventions

Everything under `./scripts/` follows one grammar, so a verb learned once
transfers to the rest. New tooling is expected to obey it.

Marked ⚠️ below means **target, not yet universal** — the gap is tracked in
[#118](https://github.com/thehenrylam/SimpleK3s/issues/118), which also plans a
single `sk3s` entry point over these same rules.

#### Command shape

```
./scripts/<script>.sh <profile> [<nickname> <region>] [flags]
```

- `profile` is required and always first. Through `./sk3s` it may be
  omitted, and `aws_profile_for_scripts` from `group_vars/all.yml` is used
  instead; called directly, the scripts still require it.
- `nickname` and `region` are **a pair** — supply both or neither. Omitted, they
  are inferred from `terraform/standard_cluster/terraform.tfvars`. Two
  positionals is always an error, and is rejected as one.
- Flags are parsed out *before* positionals are counted, so
  `<profile> --no-color` is not mistaken for the rejected two-positional form.
- `--` ends flag parsing. ⚠️

#### Context resolution

Every script prints what it resolved, before it does any work:

```
Cluster  : nickname=birch  region=us-east-1  profile=dev
Instance : i-0abc123def456789
```

This is what catches "wrong cluster" *before* the damage rather than after. A
script that cannot resolve nickname/region fails with an error naming the
tfvars file — it never guesses.

#### Standard flags

A flag means the same thing in every script, or it gets a different name.

| Flag | Meaning |
|---|---|
| `-h`, `--help` | Usage to **stdout**, exit **0** — asking for help is a request that succeeded |
| `--instance-id <id>` | Target one instance instead of the script's default scope ⚠️ |
| `--json [compact\|pretty]` | Machine-readable output on stdout ⚠️ |
| `--no-color` | Never emit colour ⚠️ |
| `--dry-run` | Preview; change nothing ⚠️ |

#### Exit codes

`ssm_execute.sh` is the reference implementation — it names them as constants.

| Code | Meaning |
|---|---|
| `0` | Succeeded — including an explicit `--help` |
| `1` | Ran correctly, and the answer is bad (checks failed, repair needed) |
| `2` | Usage error — bad arguments, missing profile, unresolvable context |
| `3` | Not finished (async command still running) |

`1` and `2` are kept apart on purpose: `1` means go and look at the cluster,
`2` means fix the command line. A wrapper can act on that difference.

Usage text is printed by `print_usage`, and `usage <code>` decides where it goes
— stdout on 0, stderr otherwise. Returning non-zero for a deliberate `--help`
would abort any caller running under `set -e`, and would put the text on the one
stream a pipeline cannot read.

**Absence is never success.** A script that could not reach the cluster, could
not parse a response, or never ran its checks exits non-zero. Reporting a green
result for a check that did not run is the bug class behind
[#110](https://github.com/thehenrylam/SimpleK3s/issues/110); do not reintroduce
it with a bare `|| true`.

#### Output

- **Human-readable is the default.** Colour is on for terminals, off when piped
  or redirected, and off entirely with `--no-color`.
- **`--json` is the contract for machines**: stable field names, stdout only.
- **Progress and diagnostics go to stderr.** Command IDs, poll ticks and
  warnings are stderr so that `2>/dev/null` always leaves clean, parseable
  stdout. Never merge them with `2>&1` when parsing.
- Colour is semantic, not decorative — green passed, yellow warning or unknown,
  red failed, cyan section header. Unknown is *not* green.

#### Safety

- **Mutating operations preview by default** and act only on an explicit flag.
  `ssm_repair_cluster.sh` is the reference: `--dry-run` does the discovery for
  real and changes nothing, and `cluster_repair.yml` requires
  `-e repair_apply=true` before anything is touched.
- Read-only operations never ask for confirmation. Confirming reads trains an
  operator to rubber-stamp, which is what makes the rare real prompt dangerous.
- Destructive operations name what they will touch before touching it.
- A multi-step change is **one** decision: show the whole plan, get one
  approval, then execute it — not a prompt per step.

#### Node-side scripts

Scripts shipped to nodes (`k3s_cluster/cluster_app/bootstrap/data/`) are
**stdlib-only Python and bash** — no virtualenv, no third-party packages. The
sync/repair path must never depend on an interpreter environment stored inside
the directory it repairs.

Node code reports **structured state rather than prose**, so the host reads
fields instead of grepping log lines. The verifier package is the reference:

```bash
# On a node, against the S3-shipped copy:
cd /opt/simplek3s/bootstrap/default/py
python3 -m sk3s_verify --depth standard             # JSON on stdout
python3 -m sk3s_verify --depth standard --compress  # gzip+base64, what the host asks for
```

**The host does not run that copy.** `sk3s status` zips the package and ships it
inline with every invocation, so the node always runs exactly the version the
caller expects — no version skew during a rollout, and no dual-schema handling
when the document format changes. The S3 copy exists so an operator can run it
by hand, and so `converge_actions.sh` can import the ArgoCD OIDC rule rather
than reimplementing it.

Compression is required rather than an optimisation: SSM caps returned stdout at
24,000 characters and cuts mid-stream, and the full probe set measures 22,552
characters raw — 94% of the ceiling — against 6,200 compressed.

- **An explicit result per check** — `passed` / `failed` / `skipped`, never
  absence. A subsystem that is not deployed reports `skipped`; it has not been
  verified, and letting that read as a pass is the defect class of
  [#110](https://github.com/thehenrylam/SimpleK3s/issues/110).
- **A `schema` field**, so a consumer refuses a document it cannot read rather
  than half-reading a future shape. It is bumped only when existing fields
  change meaning — adding an optional field is not a break, since a node that
  predates it simply omits it and the host reports it as unknown.
- **A generation stamp**, so the host can tell a stale node from a current one.
  `node_refresh-bootstrap-files.sh` records a digest of the bootstrap bucket's
  contents after a successful sync; verify recomputes it live and reports both.
  Staleness is `synced != current`.

```json
{ "schema": 1, "node": "ip-10-0-1-74", "result": "failed",
  "generation": {"synced": "e1cbb2338cc6", "current": "cc1dc98f09d7", "stale": true},
  "summary": {"passed": 37, "failed": 1, "skipped": 1, "total": 39},
  "checks": [{"section": "longhorn", "result": "failed",
              "message": "...", "detail": "..."}] }
```

Both sides of the generation comparison come from the same source — a digest of
the S3 object listing (key, ETag, size), computed by one shared function in
`lib/common.sh`. Hashing the node's local files instead would not work: the
bootstrap directory also holds node-generated logs, so every node would differ
from every other. `null` means unknown and never compares equal, so an
unreadable bucket cannot make a stale node look current.

Staleness is **reported, not voted on**. It stays a report rather than a hard
failure because a stale peer is not always the cluster's fault — a node that was
unreachable during a sync is behind through no fault of its own, and failing the
deploy gate on it would block shipping precisely when a node is already sick.
`sk3s sync` now reaches every control-plane node (`--all-nodes` for the rest), so
staleness is at least no longer something the tooling causes by design.

Two rules keep this workable in practice. The mode switch happens **before** the
checks run, not by appending a block after the prose — SSM truncates stdout at
24000 characters mid-stream, which would silently eat the tail of a trailing
block. And prose remains the default: the host falls back to grepping
`FAILED (N check` for a node that predates `--json`, so a partially-synced
cluster still reports correctly.

### Scripts

`./sk3s` is the single entry point. It sits at the deployment root, beside the
playbooks, so it is run as `./sk3s` from there; the scripts it dispatches to stay
under `./scripts/` and stay directly callable. `sk3s` adds no behaviour of its
own beyond supplying the profile.

```bash
./sk3s help             # every verb, with a one-line summary
./sk3s <verb> --help    # usage for that verb
./sk3s status dev       # same as ./scripts/sk3s_status.py dev
./sk3s status           # profile taken from group_vars/all.yml
```

Omit the profile and `sk3s` supplies `aws_profile_for_scripts` from
`group_vars/all.yml`, reporting it on stderr so the resolved value is still
visible. An explicit profile always wins. This is deliberately a *separate* key
from `aws_profile`, so day-to-day script access can use different credentials
from the ones that run `tofu apply`.

Nothing is injected when `all.yml` is absent, the key is missing, or the value
is still `__CONFIGURE_THIS__` — the verb then reports its own missing-profile
error rather than authenticating as a placeholder.

#### Every run is logged

`sk3s` writes a log per invocation to `logs/` (gitignored), whether or not anyone
asked for one. `--verbose` only helps the run you predicted would fail; a log
written unconditionally is the one that exists after the failure you did not
predict — and re-running a *mutating* command just to capture output is not an
option.

```
logs/sk3s_pull_20260905T194848Z.log
```

Each file records the command as invoked (including the injected profile), start
and finish times, the target script, and the exit code, around the run's full
output.

- Both streams are captured, but **teed separately**, so `sk3s nodes --json | jq`
  still receives clean JSON while progress goes to stderr and to the log.
- `connect` is **not** logged: it owns the terminal, and piping an interactive
  SSM session through `tee` would break it.
- `--help` is not logged either — no cluster interaction worth keeping.

#### `logs/history.log` — the sequence

One line per run, so a session's worth of activity reads in order without opening
50 files:

```
2026-09-05T20:24:13Z  exit=0     0s  nodes            sk3s_nodes_20260905T202413Z.log   sk3s nodes deployer
2026-09-05T20:24:16Z  exit=0     2s  pull             sk3s_pull_20260905T202414Z.log    sk3s pull deployer
2026-09-05T20:24:16Z  exit=1     0s  status           sk3s_status_20260905T202416Z.log  sk3s status deployer
2026-09-05T20:24:17Z  opened      -  connect[f76444]  -                                 sk3s connect deployer --instance-id i-0abc
2026-09-05T20:24:20Z  exit=0     3s  connect[f76444]  -                                 (session closed)
```

Timestamp, exit code, duration, verb, the detail file to open, and the command as
invoked.

- **It is not pruned with the per-run logs.** Detail is capped at
  `SK3S_LOG_KEEP` (50); the sequence outliving it is the point. `history.log` is
  capped separately at `SK3S_HISTORY_KEEP` (10000 lines) purely so it cannot grow
  forever.
- **`SK3S_NO_LOG=1` still writes here.** It is metadata, which is exactly what has
  to survive opting out.
- **`connect` appears, as a pair.** It has no per-run log — its output cannot be
  teed without breaking the session — but somebody opening an interactive shell on
  a node is the most audit-relevant event this tool produces, and it was
  previously invisible. A session gets an `opened` line immediately and a closed
  line with its duration on exit, tied by a short id. Writing only on close would
  put the entry out of order relative to everything done *during* the session.
- **An interrupted run is still recorded**, as `interrupted` with the elapsed
  time and exit 130. Ctrl-C signals the whole process group, so without a handler
  the run would vanish from the trail entirely — the case most worth keeping.
- **An `opened` line with no matching close** means the session died with its
  terminal. That is deliberately visible rather than tidied away.
- `--help` is not recorded — no cluster interaction.

| Variable | Effect |
|---|---|
| `SK3S_NO_LOG=1` | Withhold the **output**; the entry itself is still written |
| `SK3S_HISTORY_KEEP` | Lines kept in `history.log` (default 10000) |
| `SK3S_LOG_DIR` | Write logs somewhere else |
| `SK3S_LOG_KEEP` | How many to retain (default 50; older are pruned after each run) |

#### `SK3S_NO_LOG` withholds output, not the record

It is deliberately **not** an off switch. The runs an operator opts out of are the
ones handling sensitive output — which makes them the entries an audit trail most
needs. Erasing them would remove exactly the record worth keeping, so the command,
timings and exit code are still written and the body is replaced by a marker:

```
# sk3s exec deployer --instance-id i-0abc --exec-cmd "kubectl get secret argocd-oidc -o yaml"
# started : 2026-09-05T19:49:39Z
# target  : .../scripts/ssm_execute.sh
#
# (output withheld — SK3S_NO_LOG=1)
#
# exit    : 0
# finished: 2026-09-05T19:49:41Z
```

The directory therefore stays chronologically complete: it can answer "what was
run against this cluster, by whom, and when" even for runs whose output was not
kept — which is what makes it usable for review, or for replaying a window of
activity after an incident.

⚠️ **The command line itself is always recorded.** That is the point, but it means
a secret passed *as an argument* is written to the log. Note that such a secret is
already exposed in shell history, in `ps` output, and in the SSM command record
AWS keeps server-side — so withholding it locally would create a false sense of
privacy while the authoritative copy survives. Do not pass secrets as arguments;
reference them by name and let External-Secrets resolve them.

⚠️ **Logged output is unredacted.** No attempt is made to detect and mask secrets
in captured output: pattern-matching for sensitive data fails quietly and gives
false confidence. `SK3S_NO_LOG=1` is the honest control — it says what is missing
and why.

| Verb | Dispatches to | Scope |
|---|---|---|
| `status` | `sk3s_status.py` | every control-plane node (`--depth quick\|standard`) |
| `sync` | `ssm_update_services.sh --mode sync` | every control-plane node |
| `apply` | `ssm_update_services.sh --mode apply` | the staging owner |
| `pull` | `ssm_update_services.sh --mode pull` | sync everywhere, then stage on the owner |
| `nodes` | `ssm_list_instances.sh` | — |
| `connect` | `ssm_connect.sh` | one node |
| `exec` | `ssm_execute.sh` | one node |
| `refresh` | `ssm_refresh_services.sh` | one node |
| `repair` | `ssm_repair_cluster.sh` | one node |

#### What `refresh` is for

The three recovery verbs fix three different things, and reaching for the wrong
one wastes a cluster outage:

| Symptom | Verb |
|---|---|
| The cluster is running old manifests | `pull` / `apply` |
| A node cannot rejoin; a stale etcd member lingers | `repair` |
| Manifests are current, nodes are fine, a workload is wedged | `refresh` |

`refresh` is the actuator for what `status` observes. It shares one vocabulary
with it — the component names are exactly the section names in the health
report — so a failing check maps onto a refresh target with no translation in
between.

```bash
./sk3s refresh                       # preview: what is failing, what would be restarted
./sk3s refresh --auto                # restart whatever status reports as failing
./sk3s refresh --only argocd,traefik # restart named components, healthy or not
./sk3s refresh --hard                # delete pods instead of rolling the workload
```

**It previews by default.** Restarting live workloads is disruptive, so an
invocation that names no target set reports the plan and changes nothing,
following `cluster_repair.yml`. Acting requires `--auto` or `--only`.

**One node, because the effect is cluster-wide.** Every action goes through the
Kubernetes API, so restarting a workload from three nodes is three rollouts of
one deployment. Unlike staging there is no on-disk state, so no ownership lock
is involved — any healthy, reachable control-plane node will do.

**The escalation ladder.** The default is `kubectl rollout restart`, which
respects the update strategy and any PodDisruptionBudget. `--hard` deletes the
pods instead, and exists for the case the default cannot fix: a CrashLooping pod
blocks its own replacement from becoming ready, so the new revision never
progresses and a rollout restart is a no-op.

**What `refresh` is not.** It does not touch systemd. Restarting k3s itself
drops an etcd member, and that hazard already has one owner in
`ssm_repair_cluster.sh`, which knows about quorum; a second path to it behind a
flag on a different verb is how the two get out of step. For the systemd layer,
use `sk3s exec`. It also does not re-stage manifests (`apply`) or change node
membership (`repair`).

**Two sections it will not act on.** `k3s_api` and `nodes` are not workloads —
if either is failing, `refresh` refuses the whole run and points at `repair`,
because nothing else can be trusted while the API or node readiness is broken.
`pod_stability` is reported but never acted on: it says some container crashed
inside the stability window, spanning namespaces rather than naming a component,
so there is nothing for a component-keyed registry to map it onto. Name the
component yourself with `--only` once you know which one it is.

Running `node_refresh-services.sh --list` on a node prints the component
registry — which workloads each component maps to, and why the non-actionable
sections have none.

#### Why sync, apply and pull are separate

They were one operation, and the two halves have **opposite natural scopes**:

- **Files** (`/opt/simplek3s`) are per-node disk state. Every node needs them, or
  a repair run on a stale node executes old scripts.
- **Staging** (`/var/lib/rancher/k3s/server/manifests`) has a cluster-wide effect
  through the K3s deploy controller. One node suffices, and a second node staging
  the same files means two controllers reconciling the same Addons plus a stale
  copy nothing cleans up ([#144](https://github.com/thehenrylam/SimpleK3s/issues/144)).

Which node stages is **read from the cluster**, never inferred from a node's
index. Whichever node stages at boot claims a `simplek3s-staging-owner` ConfigMap
in `kube-system` (`kubectl create` is atomic, so the first writer wins), and the
tooling asks the cluster who holds it. Nothing in the host scripts knows that
"node 0" exists, so when ownership moves the tooling follows without a code
change.

If no owner is on record, `apply` and `pull` **refuse** rather than picking a
node. An unrecorded owner is not the same as "any node will do" — staging
somewhere arbitrary is the defect, not the fallback. Use `--instance-id` to
choose explicitly, or `--claim-ownership` to establish one; the latter takes the
first node by instance-id sort, which is arbitrary with respect to a node's role
(so it privileges nobody) yet stable across runs (so `--dry-run` can name the
node before anything changes).

- `./scripts/ssm_connect.sh <aws_profile>`
    - Connects to an EC2 environment in the cluster (Pick the instance to connect to via a GUI)
        - If `--instance-id <instance-id>` is used, then it will automatically connect to that instance id
- `./scripts/ssm_pick_instance.py <aws_profile>`
    - Lists a GUI to display and allow you to select an instance in the cluster (*Outputs the selected instance id*)
- `./scripts/ssm_execute.sh <aws_profile> --instance-id <instance-id> --exec-cmd <command>`
    - Executes any command on a given `instance-id` in the cluster
- `./scripts/ssm_list_instances.sh <aws_profile>`
    - Outputs a list of EC2 instances in the cluster
- `./scripts/ssm_update_services.sh <aws_profile> [--mode sync|apply|pull] [options]`
    - `--mode sync` syncs `/opt/simplek3s` from the S3 bootstrap bucket to every control-plane node (`--all-nodes` adds agent and Karpenter nodes)
    - `--mode apply` stages manifests on the node that owns staging, without re-syncing
    - `--mode pull` (default) does both, sequentially — every node syncs before anything stages
    - `--instance-id <id>` restricts **both** halves to one node, an escape hatch for repair; it warns when the node is not the recorded staging owner
    - `--strict-sync` fails the run if any node's sync fails. By default only the staging node's own failure blocks staging, so an unrelated unreachable node cannot stop a deploy
    - `--claim-ownership` makes the target the sole staging owner, clearing manifests other nodes are holding. Safe: removing a manifest file does not delete the resources it created ([#151](https://github.com/thehenrylam/SimpleK3s/issues/151))
    - `--dry-run` reports what would change and writes nothing
- `./scripts/sk3s_status.py <aws_profile> [<nickname> <region>] [--depth quick|standard] [--verbose] [--json] [--no-color]`
    - On **every** controlplane node, execute a script to verify the health of the cluster, then merge the results into one report (a check every node agrees on is printed once; divergent lines are attributed to the nodes that produced them)
    - Passes only if every node passes — a node that cannot be reached is not a pass
    - `--no-color` never emits colour (already off when piped); `--per-node` prints each node's own results instead of the merged report

### AI Skills

- `cluster-ops`
    - Invoke directly or ask Claude Code (or equivalent) to perform actions for you within the cluster.
        - Read-type actions will be executed without need for approval
        - Mutation actions will require approval (in individual commands or batch commands)
    - DISCLAIMER: Use at your own risk (*Try it on test environment to get a feel for it and then experiment on PROD once you have properly vetted and understood the process*)
