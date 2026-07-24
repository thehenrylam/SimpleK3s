# Network/Resource Settings
aws_region = "us-east-1"
nickname   = "pvc-standalone" # Must match the nickname used in examples/ex_basic

# EBS volume pools for Longhorn.
# Deploy this root before the cluster — volumes survive cluster destroy/apply cycles.
# All volumes in a pool must be the same size: Longhorn usable capacity = smallest volume in pool.
#
# Cost estimate (gp3, us-east-1):
#   1 volume × 50 GB = $4.00/month   (no redundancy)
#   2 volumes × 50 GB = $8.00/month  (survives 1 AZ failure)
#   3 volumes × 50 GB = $12.00/month (survives any 1 AZ failure, still serves from 2)
pools = [
  {
    # Platform pool: hosts SimpleK3s built-in apps (ArgoCD, Grafana, Prometheus, AlertManager)
    # Usable capacity = 28 GB. Built-in apps consume ~27 GB total, we add +1GB as a safety precaution (5 + 20 + 2).
    name               = "platform"
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
    volume_size_gb     = 10
  },
]
