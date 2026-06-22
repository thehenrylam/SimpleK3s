# Storage

This document describes how persistent storage works in SimpleK3s, which solution covers which workload type, and how to configure each tier.

## Design Philosophy

Standard EBS volumes are AZ-locked — a pod rescheduled to a different Availability Zone cannot reattach its old volume. SimpleK3s runs the Descheduler, which actively rebalances pods across nodes and AZs. Combining AZ-locked storage with an active descheduler causes `VolumeZoneMismatch` errors and silently prevents pods from moving.

The solution is a tiered storage model where the default tier (Longhorn) uses distributed replicas so volumes are not tied to a single AZ. The Descheduler can then move any pod freely, and the volume follows.

A second design goal is **lifecycle decoupling**: by default, Kubernetes volumes live and die with the cluster. SimpleK3s requires developers to pre-provision external EBS volumes so that a `tofu destroy` + `tofu apply` cycle does not wipe application data. There is no fallback to node root disks — nodes are kept at the OS/K3s minimum footprint, and all persistent data lives on explicitly provisioned volumes.

---

## Storage Tiers at a Glance

| Tier | Solution | Cost/GB-month | Access | Best For |
|---|---|---|---|---|
| **1 (80–90%)** | Longhorn | N× EBS gp3 (N = volumes per pool) | ReadWriteOnce, cross-AZ | All standard stateful workloads |
| **2 (5–10%)** | S3 Mountpoint CSI | ~$0.023 | ReadWriteMany, object | Bulk/cold read-heavy data |
| **3 (1%)** | Custom / BYO | varies | varies | Workload-specific requirements |

---

## Tier 1 — Longhorn (Standard Workhorse)

### How It Works

Longhorn is a distributed block storage system built for Kubernetes. It runs as a DaemonSet on each storage node and presents volumes to pods via a CSI driver. When a Longhorn volume is created, Longhorn maintains one replica per registered disk, spread across nodes. The replica local to the pod's node serves reads and writes; if the pod moves to a different AZ, it switches to the replica already on that node.

```
Pod (any AZ)
    │
    ▼  (CSI)
Longhorn Engine (on pod's node)
    │
    ├─── Replica A  ──► external EBS  (AZ-1 node)
    ├─── Replica B  ──► external EBS  (AZ-2 node)
    └─── Replica C  ──► external EBS  (AZ-3 node, if 3 volumes provided)
```

Every write goes to all replicas synchronously, so any replica is always up to date and can serve immediately when a pod moves.

**Why Longhorn for SimpleK3s specifically:**
- Rancher maintains both K3s and Longhorn — they are explicitly tested together, including on ARM64 (the default t4g.medium nodes).
- Installs via Helm, fitting the existing subsystems layer pattern.
- Built-in backup to S3, reusing the IAM role and bucket already provisioned by the SimpleK3s bootstrap layer — no extra AWS resources needed.
- Volumes are not AZ-locked, so the Descheduler can rebalance stateful pods without hitting `VolumeZoneMismatch`.

---

### Pools

Rather than one shared storage pool for the entire cluster, SimpleK3s organises Longhorn storage into named **pools**. Each pool has its own set of EBS volumes, its own StorageClass, and its own replica configuration. Pools are fully independent: resizing, replacing, or having an issue with one pool has no effect on the others.

```
Node (AZ-1)                         Node (AZ-2)                         Node (AZ-3)
┌─────────────────────────┐         ┌─────────────────────────┐         ┌─────────────────────────┐
│ /mnt/longhorn-platform  │◄──EBS──►│ /mnt/longhorn-platform  │◄──EBS──►│ /mnt/longhorn-platform  │
│   [tag: platform]       │         │   [tag: platform]       │         │   [tag: platform]       │
│                         │         │                         │         │                         │
│ /mnt/longhorn-alpha     │◄──EBS──►│ /mnt/longhorn-alpha     │◄──EBS──►│ /mnt/longhorn-alpha     │
│   [tag: alpha]          │         │   [tag: alpha]          │         │   [tag: alpha]          │
└─────────────────────────┘         └─────────────────────────┘         └─────────────────────────┘

StorageClass "longhorn-platform"  →  diskSelector: platform  →  only platform disks
StorageClass "longhorn-alpha"     →  diskSelector: alpha     →  only alpha disks
```

**Why pools instead of one unified pool:**
- **Independent scaling** — resize the alpha pool's EBS volumes without touching the platform pool.
- **Blast radius** — a disk issue in the alpha pool degrades only alpha PVCs; platform keeps running.
- **Cost transparency** — each pool's EBS volumes are separate AWS line items. Tag them per project/team for per-pool billing in Cost Explorer.
- **Long-term manageability** — over months and years, knowing exactly which storage belongs to which concern is far easier than untangling a single shared pool.

#### Replica Count

SimpleK3s derives the replica count automatically from the number of volumes in the pool's EBS list: `replica_count = len(volumes)`. One volume per AZ means one replica per AZ. This is always the correct configuration — there is no input to override it.

- Requesting more replicas than volumes would put some replicas in a permanently degraded state.
- Requesting fewer replicas than volumes would leave disks unused as non-replicas while still paying for them.

`max_replicas_per_node` is hardcoded to `1` internally. Two replicas on the same node would mean two copies of the data on the same physical machine, which provides no AZ-level fault tolerance.

| Volumes in list | Replica count | HA level | Cost multiplier |
|---|---|---|---|
| 1 | 1 | No redundancy — disk failure = data loss | 1× EBS gp3 |
| 2 | 2 | Survives loss of 1 AZ | 2× EBS gp3 |
| 3 | 3 | Survives loss of any 1 AZ, still serving from 2 | 3× EBS gp3 |

#### EBS Volume Requirements

- **One volume per AZ** the cluster spans. Each volume can only be attached to one EC2 instance at a time.
- **All volumes in a pool must be the same size.** With replication, every GB written to a Longhorn volume occupies 1 GB on every replica disk. Usable pool capacity equals the smallest disk in the pool. If sizes differ, the smallest disk becomes the bottleneck and the guardrail uses it as the capacity ceiling.
- **Format:** Store volume IDs in an SSM Parameter Store entry as a JSON array:
    ```json
    ["vol-0abc1234567890aaa", "vol-0def1234567890bbb", "vol-0ghi1234567890ccc"]
    ```
- **Missing or empty list:** If `ebs_volumes_pstore_name` is not provided, or if the SSM param contains an empty array, the pool is not created — no StorageClass, no disk registration. `tofu plan` will surface this as a validation error. There is no fallback to node root disks.

#### Bootstrap Flow (per node, per pool, automatic)

1. Node reads its own AZ from the EC2 Instance Metadata Service.
2. Calls `aws ec2 describe-volumes` on the full volume list to get each volume's AZ.
3. Selects the volume in the matching AZ.
4. Attaches the volume (idempotent — safe to re-run on cluster rebuild).
5. Runs `blkid` to detect an existing filesystem. **If one is found, skips formatting.** This is what makes reattach-after-rebuild safe — existing data is never wiped.
6. Formats with `ext4` only on first attach (no filesystem detected).
7. Mounts to `disk_path` and adds to `/etc/fstab`.
8. Registers the disk with the pool's disk tag via the `longhorn.io/default-disks-annotation` node label.

#### Lifecycle Decoupling

```
WITHOUT external EBS:
  Cluster lifecycle  ─────────────────────────────────► data lost on destroy
  Data lifecycle     ═══════════════════════╗
                                            ✗ (node terminated)

WITH external EBS:
  Cluster lifecycle  ────────────╗  ╔──────────────────►
  Data lifecycle     ════════════╬══╬══════════════════►
                                 ╚══╝ (volumes detach, reattach to new nodes)
```

On `tofu destroy`: EBS volumes detach from terminated EC2 instances and persist in AWS.
On `tofu apply`: new EC2 nodes attach the same volumes, the bootstrap script detects the existing filesystem, mounts, and Longhorn continues with all existing replica data intact.

#### Pool Inputs

Each entry in the `longhorn.pools` list accepts the following inputs:

| Input | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Pool name. Used as the StorageClass name suffix (`longhorn-{name}`) and as the Longhorn disk tag. |
| `default` | `bool` | `false` | If `true`, this pool's StorageClass becomes the cluster default. Any PVC without an explicit `storageClassName` uses this pool. Exactly one pool should be marked default. |
| `ebs_volumes_pstore_name` | `string` | required | SSM Parameter Store name containing the JSON array of EBS volume IDs. Must be non-empty. Missing or empty = validation error, pool not created. |
| `node_target` | `string` | `"controlplane"` | Which node class hosts this pool's disks. `"controlplane"` is the safe default — control-plane nodes are on-demand and stable. Karpenter-managed spot workers can be interrupted mid-write, causing replica rebuild churn; only use `"agentplane"` or `"all"` if those nodes are on-demand. |
| `disk_path` | `string` | `"/mnt/longhorn-{name}"` | Filesystem path where the EBS volume is mounted on each node. Must be unique per pool and consistent across nodes so Longhorn can find the disk on reattach. |
| `reclaim_policy` | `string` | `"Retain"` | Kubernetes PV reclaim policy. `"Retain"` means the Longhorn volume survives PVC deletion — safe default. `"Delete"` means the Longhorn volume (and all data) is deleted with the PVC. A mistake with `"Delete"` is unrecoverable. |
| `data_locality` | `string` | `"disabled"` | When `"best-effort"`, Longhorn schedules the active replica on the same node as the pod, turning cross-AZ reads into local disk reads. `"disabled"` keeps scheduling behaviour predictable. |
| `backup_s3_prefix` | `string` | `"longhorn-backups/{name}/"` | Key prefix in the SimpleK3s S3 bootstrap bucket for Longhorn snapshot backups. Reuses existing IAM — no extra AWS resources needed. Set to `null` to disable backups for this pool. |

#### Example Configuration

```hcl
subsystems = {
  longhorn = {
    pools = [
      {
        # Platform pool: SimpleK3s built-in apps (ArgoCD, Grafana, Prometheus)
        name                    = "platform"
        default                 = true
        ebs_volumes_pstore_name = "/simplek3s/longhorn/platform-volumes"
        node_target             = "controlplane"
        reclaim_policy          = "Retain"
        data_locality           = "disabled"
        backup_s3_prefix        = "longhorn-backups/platform/"
      },
      {
        # App pool: developer workloads, independently scalable
        name                    = "app"
        ebs_volumes_pstore_name = "/simplek3s/longhorn/app-volumes"
        node_target             = "controlplane"
        reclaim_policy          = "Retain"
        data_locality           = "best-effort"
        backup_s3_prefix        = "longhorn-backups/app/"
      },
      {
        # Critical pool: mission-critical service, 3 volumes = 3-AZ HA
        name                    = "critical"
        ebs_volumes_pstore_name = "/simplek3s/longhorn/critical-volumes"
        node_target             = "controlplane"
        reclaim_policy          = "Retain"
        data_locality           = "disabled"
        backup_s3_prefix        = "longhorn-backups/critical/"
      }
    ]
  }
}
```

This generates three StorageClasses: `longhorn-platform` (cluster default), `longhorn-app`, and `longhorn-critical`.

---

### Built-in App Storage

The SimpleK3s built-in apps (ArgoCD, Grafana, Prometheus, AlertManager) currently run ephemeral by default — pod restarts lose state. Persistent storage for each component is opt-in, controlled by a `storage` block inside each app's configuration.

#### Inputs

```hcl
applications = {
  argocd = {
    pstore_idp_config = "..."
    domain_name       = "..."

    storage = {
      pool_name = "platform"  # which pool to bind to; defaults to the pool with default=true
      pvc_size  = 5           # GB; 0 = ephemeral (no PVC created)
    }
  }

  monitoring = {
    pstore_idp_config = "..."
    domain_name       = "..."

    storage = {
      pool_name             = "platform"
      grafana_pvc_size      = 5   # GB; 0 = ephemeral
      prometheus_pvc_size   = 20  # GB; 0 = ephemeral
      alertmanager_pvc_size = 2   # GB; 0 = ephemeral
    }
  }
}
```

#### Default PVC Sizes

| Component | Default | What it stores |
|---|---|---|
| ArgoCD | 5 GB | Repo-server git cache, Redis state |
| Grafana | 5 GB | SQLite database, dashboards |
| Prometheus | 20 GB | TSDB — ~2 weeks of metrics at typical hobbyist scale |
| AlertManager | 2 GB | Silences, notification state |

These are conservative starting points. Adjust based on observed usage. Setting any value to `0` skips PVC creation for that component — it runs ephemeral and restarts clean.

#### Pool Capacity Guardrail

At `tofu plan` time, SimpleK3s checks that the declared PVC sizes fit within each pool's actual capacity before anything is deployed.

For each pool:
1. Read volume IDs from the SSM parameter.
2. Query `aws ec2 describe-volumes` to get each volume's size in GB.
3. Take the minimum across all volumes in the pool — this is the effective usable capacity, because every GB written to a Longhorn volume occupies 1 GB on every replica disk simultaneously.
4. Sum all `pvc_size` values declared for apps bound to this pool.
5. If the sum exceeds the minimum volume size, `tofu plan` fails with an explicit error.

```
Guardrail: sum(pvc_sizes bound to pool) ≤ min(EBS volume sizes in pool)

Example — pool "platform", 3 × 50 GB volumes:
  Effective capacity:  50 GB  (not 150 GB — replication is not RAID-0)
  ArgoCD:               5 GB
  Grafana:              5 GB
  Prometheus:          20 GB
  AlertManager:         2 GB
  ─────────────────────────
  Total declared:      32 GB  ≤ 50 GB  ✓

If Prometheus were set to 60 GB:
  Total declared:      72 GB  > 50 GB  ✗  →  tofu plan error
```

The guardrail only covers the built-in apps declared in the `applications` block. PVCs created by developer workloads at runtime are not checked at plan time — size those pools with enough headroom.

---

### Cost

```
Cost/GB-month per pool = number_of_volumes × $0.08 (EBS gp3)

This is the replication cost: every GB stored consumes 1 GB on each replica disk.

Examples (50 GB volumes):
  2 volumes → $0.16/GB-month usable  (~2× EBS gp3)  ← typical HA
  3 volumes → $0.24/GB-month usable  (~3× EBS gp3)  ← 3-AZ HA, at the cost cap
```

Cross-AZ data transfer ($0.01/GB) applies to replica writes that cross AZ boundaries. For write-heavy workloads (e.g., Prometheus TSDB), set `data_locality: "best-effort"` to serve reads locally and reduce read transfer, but writes will still replicate cross-AZ by design.

Each pool's EBS volumes are separate AWS resources. Tag them at creation time with a project or team identifier to get per-pool cost visibility in AWS Cost Explorer.

---

## Tier 2 — S3 Mountpoint CSI (Bulk Object Data)

### When to Use

Use S3 Mountpoint when the workload accesses large volumes of data that fit an **object storage access pattern**: files are written once (or rarely), then read many times, and random byte-range overwrites are not required.

Good fits:
- Machine learning model weights and training datasets
- Static media files (images, video) served by application pods
- Build artifacts or release bundles shared across CI pods
- Log archives written by a collector and read by an analytics job

**Do not use for:**
- Active databases (PostgreSQL, MySQL, Redis) — they require random writes and POSIX semantics that S3 does not support.
- Anything writing frequently at volume — S3 per-request charges and latency characteristics make it unsuitable for active I/O workloads.
- Shared mutable config files — use Kubernetes ConfigMaps or Secrets instead.

### Access Pattern

S3 Mountpoint presents as ReadWriteMany (multiple pods can mount the same bucket simultaneously), but the write semantics are append/upload only. There is no in-place file modification. Design the workload around this constraint before choosing this tier.

### Cost

```
~$0.023/GB-month (S3 Standard)
```

No AZ consideration — S3 is regional and available from any AZ without cross-AZ transfer fees.

### CSI Driver

[`mountpoint-s3-csi-driver`](https://github.com/awslabs/mountpoint-s3-csi-driver) — official AWS Labs driver, maintained alongside Mountpoint for Amazon S3.

---

## Tier 3 — Custom / BYO

For the 1% of workloads with requirements that neither Longhorn nor S3 Mountpoint can satisfy, the developer implements their own solution. SimpleK3s provides no scaffolding here — the intent is that these are exceptional cases with specific, well-understood needs.

**Examples:**

| Need | Possible Solution |
|---|---|
| ReadWriteMany block storage at scale | Rook-Ceph with CephFS (self-managed; 1.5× cost with 4+2 erasure coding vs 3× with replication) |
| Managed enterprise NFS across AZs | Amazon FSx for NetApp ONTAP Multi-AZ (~0.5× EBS cost for storage tier + fixed throughput charge) |
| Ultra-high-IOPS single-writer volume | EBS io2 with topology-pinned scheduling (accept AZ lock-in for this specific pod) |
| Cold shared filesystem (written rarely) | Amazon EFS Intelligent Tiering (only viable if data is accessed infrequently — per-request charges make it expensive for active workloads) |

---

## Decision Guide

```
Does the workload need persistent storage at all?
│
├─ No → Use emptyDir or ephemeral volumes. No PVC needed.
│
└─ Yes
    │
    ├─ Does it write frequently or need low-latency random I/O?
    │   └─ Yes → Use Tier 1 (Longhorn). Pick a pool that matches the workload's
    │            criticality and size budget.
    │
    ├─ Is the data large (>100 GB) and mostly read, with write-once access patterns?
    │   └─ Yes → Consider Tier 2 (S3 Mountpoint).
    │
    ├─ Does it need ReadWriteMany with POSIX semantics (multiple writers, random writes)?
    │   └─ Yes → Use Tier 3 (BYO — Ceph CephFS or FSx ONTAP).
    │
    └─ Everything else → Use Tier 1 (Longhorn). It is the default for a reason.
```

**Choosing a Longhorn pool:**

| Workload type | Suggested pool |
|---|---|
| SimpleK3s built-in apps (ArgoCD, Grafana, Prometheus) | `platform` (the default pool) |
| Developer workloads that can tolerate independent downtime | A dedicated app pool |
| Mission-critical service requiring 3-AZ HA and separate billing visibility | A dedicated pool with 3 volumes (one per AZ) |

---

## Note on Thanos and Prometheus Storage

If you run Thanos Sidecar alongside Prometheus, the sidecar uploads completed TSDB blocks directly to S3 via the AWS SDK — not via a PVC. This allows Prometheus' local retention to be shortened from 30 days to 2–3 days, shrinking its Longhorn PVC from 30–80 GB down to 5–10 GB. Long-term metrics live in S3 at $0.023/GB-month with no Longhorn replica overhead.

Thanos Compactor and Ruler each need small PVCs (5–10 GB) — covered by Tier 1 (Longhorn) with no special configuration beyond adjusting the `prometheus_pvc_size` default downward if Thanos is enabled.
