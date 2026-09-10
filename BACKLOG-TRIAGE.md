# Backlog Triage — toward SimpleK3s v2.0.0

Reviewed 2026-09-10, covering every open issue.

**Release scope: #118 and nothing else by default.** The only additions
considered are (a) stability defects that will reliably bite a production
cluster, and (b) security gaps. New features, quality-of-life work and
below-P1 fixes are deferred regardless of how cheap they look.

Tiers:

- **In scope** — ships in v2.0.0.
- **Candidate** — meets the stability bar; needs a yes/no. Listed with what
  it costs to include and what it costs to defer.
- **Deferred** — real, tracked, not this release.

---

## In scope

### #118 — Revamp cluster sync, update and verification tooling ✅ complete

All eight phases delivered across 19 PRs. Sync, apply, pull, status, refresh,
repair and the `infra` namespace are independently invocable behind one CLI;
verification runs at three depths and gates deploys; drift is detectable.

Six issues closed under it: #111, #144, #145, #153, #156, #176.

Test coverage went 70 → 339 across 20 files, and CI gained `ruff` and `pytest`.

One design decision recorded as **settled by omission**: the issue asked for a
spike on running cluster nodes as native Ansible hosts (`aws_ec2` inventory +
`community.aws.aws_ssm`) before committing, and called it "the decision the rest
hangs on". No spike was run — the existing bash+SSM chain was hardened instead.
The result is well covered, but the alternative was never measured.

---

## Candidates — meet the bar, need a decision

### #141 — k3s exits when the etcd leader shares a node with Prometheus

**The strongest case for inclusion.** Prometheus compacts its TSDB every ~2
hours; on a control-plane node with a Longhorn-backed PVC, that write burst
starves etcd's fsync. If that node is the etcd leader, heartbeats overshoot and
k3s exits 1.

Observed once in 24h on `sk3s-birch`, with all five links measured — compaction
counter, pod placement, PVC attachment, leader identity, and etcd's own "slow
disk" log line.

Why it clears the bar: **the triggering configuration is the default.**
Prometheus is scheduled wherever it fits, and control-plane nodes are where it
usually fits. This is not an exotic combination a user opts into.

Blast radius is not a crash but a stall: nine leader-elected controllers exited
within 12 seconds, and for ~6 minutes nothing could be scheduled, no rollout
could progress, no volume could attach, and Karpenter could not provision.
Workloads kept serving — containerd shims survived — but a rollout in flight
would sit at reduced capacity.

Cost to include: needs a placement or storage decision (keep Prometheus off
control-plane nodes, or take its PVC off Longhorn), then a soak to confirm.
Cost to defer: a self-healing but real control-plane outage on a recurring
schedule, with no operator signal beyond a k3s restart.

### #136 — Longhorn instance-manager PDB pins Karpenter nodes

Deterministic, not probabilistic. Any pod using a Longhorn volume puts an engine
on its node; that instance-manager gets a PDB with `disruptionsAllowed=0`; the
PDB blocks eviction; the node can never be reclaimed.

#123 fixed this for **replicas** and the rationale recorded in the template says
a Karpenter node "never holds replicas". True — and engines follow the *pod*, so
`createDefaultDiskLabeledNodes` cannot prevent them.

Why it clears the bar: autoscaling that cannot scale **down** is a cost defect
that compounds silently. Nodes accumulate and bill indefinitely.

Cost to include: scoped, in one template. Cost to defer: users who put
persistent workloads on autoscaled capacity pay for nodes forever.

### #128 — Karpenter nodes survive `tofu destroy` and block VPC teardown

Observed four times. Karpenter's nodes are created by the in-cluster controller,
never enter Terraform state, and outlive the control plane that would reap them.
The destroy then fails on the VPC with `DependencyViolation`, pointing at the
VPC rather than the cause.

**Judgement call.** It is 100% reproducible under its condition, but that
condition is teardown, not production runtime — so it does not strictly meet the
"fails in production" bar. Weighing against that: it strands billable instances
holding public IPs, and it fails *most often exactly when the cluster is already
unhealthy*, which is the worst moment to need manual cleanup.

The 2026-09-10 teardown did **not** reproduce it, because the drill's Karpenter
node had consolidated away ~40 minutes earlier. That avoided the condition rather
than disproving the bug.

Cost to include: the cleanest remedy is a destroy-time cleanup Lambda, the same
shape as `standard_tailscale`'s, which already solves this exact class. Not
trivial. A pre-destroy check that fails loudly with the real cause is much
cheaper and covers the "operator does not know to look" half.

---

## Deferred — real, tracked, not this release

### Correctness gaps that do not cause outages

| | | |
|---|---|---|
| **#133** | Five subsystems always deploy despite `optional()` | Interface lies about itself |
| **#151** | Nothing prunes: a removed component keeps running | IaC does not converge |
| **#158** | Bootstrap sync never deletes files removed from S3 | Retired scripts stay executable |
| **#114** | Tailscale cleanup Lambda no-ops when `hostname_prefix` is overridden | Silent no-op; leaks tailnet devices |
| **#132** | `vpc_cloud` derives subnet count from `node_count` | Confusing plan-time failure |

**#133 deserves a note.** It is not a stability issue, so it is out — but the
root README now advertises that interface, and passing `null` for Kyverno,
Karpenter, External-Secrets, Traefik or Descheduler silently does nothing. There
is a **cheap honest fix** available without touching behaviour: stop declaring
them `optional()`. That converts a broken promise into an accurate one for the
cost of a type change, and leaves the real guards for later.

**#114 and #158 share a shape** this project has repeatedly been bitten by —
something silently does nothing and nothing reports it. Neither causes an outage,
so both defer, but they are the same family as #156 and #176.

### Availability hardening

| | | |
|---|---|---|
| **#134** | Traefik: 2 replicas, no anti-affinity | Both can land on one node |

Does not meet the bar: the scheduler's default spreading usually separates them,
so this is "unlikely" rather than "certain". The fix is small and low-risk
(`topologySpreadConstraints` with `ScheduleAnyway`), so it is a reasonable
opportunistic include if anything else touches Traefik.

### Security and audit

| | | |
|---|---|---|
| **#119** | S3 bucket ownership controls not declared | Tidiness, per the issue itself |
| **#148** | `connect` sessions are recorded as opened/closed, not by content | Audit depth |

**No security gaps found that meet the bar.** #118 changed how operators reach
the cluster, not what they can reach — access is still SSM-only, still IAM-gated,
with no new ingress and no new credentials path. #119 is the only security-shaped
item and its own body describes it as tidiness: the buckets already report
`BucketOwnerEnforced` and public-ACL blocks are set, so the guarantee holds; it
simply is not *stated* in IaC. #148 deepens an audit trail that #118 created
rather than closing a hole.

### Features, QoL and refactors

| | |
|---|---|
| **#165** | Render `--depth full` facts for humans |
| **#166** | Ship the verifier inline on the pull path |
| **#150** | Platform manifests source a deployment manager can consume |
| **#137** | Condense verbose comments |
| **#70** | Custom Checkov graph check for bare AWS resources |
| **#101** | IPv6 public addresses (`wontfix`) |

### Process

| | |
|---|---|
| **#175** | Stacked PRs skip CI and can merge into a dead branch |

Not product, so out of the release — but it cost real work during #118 (a merged
PR's changes never reached `main`, including the test written to prevent that
class of drift). Worth closing before cutting many more releases.

---

## Recommendation

Ship **#118 alone**, plus **#136** if one item is added — it is deterministic,
scoped to a single template, and costs money continuously while it is open.

**#141** is the more serious defect and the better candidate on severity, but it
needs a placement-or-storage decision plus a soak to confirm, which is a poor fit
for a release already at its scope boundary. Cutting v2.0.0 without it is
defensible provided it is named in the release notes as a known issue, with the
workaround (keep Prometheus off control-plane nodes).

**#128** should be resolved before v2.0.0 is recommended to anyone evaluating the
project, because it is a first-run experience problem — but a loud pre-destroy
check is enough for that, and the full Lambda can follow.
