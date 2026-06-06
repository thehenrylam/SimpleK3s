# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

SimpleK3s is an opinionated Terraform/OpenTofu module that deploys a production-grade K3s (lightweight Kubernetes) cluster on AWS. It targets hobbyists and startup teams who want enterprise features (auto-scaling, GitOps, monitoring, secrets management) without EKS cost and complexity.

## Common Commands

All commands are run from an example directory (e.g., `examples/ex_basic/`):

```bash
# Set up git hooks (required for contributors)
./.git-custom/apply.sh

# Initialize providers
AWS_PROFILE="your_aws_profile" tofu init

# Preview changes
AWS_PROFILE="your_aws_profile" tofu plan

# Apply infrastructure
AWS_PROFILE="your_aws_profile" tofu apply

# Connect to a cluster node (no SSH keys — uses SSM)
aws ssm start-session --target INSTANCE_ID --profile AWS_PROFILE
```

**Tool requirements**: OpenTofu v1.11.2+ (or Terraform v1.14.3+), AWS CLI, session-manager-plugin.

## Local Testing

### Toolchain Setup (macOS)

Scripts in `toolchain/` manage the local testing dependencies (shellcheck, tflint, checkov):

```bash
# Install testing tools
./toolchain/tc_testing_macos_install.sh

# Verify tools are installed and print versions
./toolchain/tc_testing_macos_check.sh

# Remove testing tools
./toolchain/tc_testing_macos_uninstall.sh
```

### Test Scripts

Scripts in `testcases/` mirror what the CI pipeline runs. Execute from the repo root:

```bash
# shellcheck on all .sh files in the repo
bash testcases/test_check_all_shellscripts.sh

# tofu fmt, tflint, checkov, and tofu validate across all modules
bash testcases/test_check_all_terraform.sh
```

Each script prints `[OK]` / `[FAIL]` per check and exits non-zero if anything fails.
Use the `/testcase` Claude command to run these interactively with guided output (see below).

## Claude Commands

The `.claude/commands/` directory contains slash commands for use inside Claude Code:

- **`/introduce-contributor`** — Onboards a new contributor: project overview, architecture walkthrough, contribution workflow, and local environment check.
- **`/new-issue`** — Creates a GitHub issue following project conventions and checks out a matching branch.
- **`/testcase`** — Runs one or more scripts from `testcases/` interactively, logs all output to a timestamped file under `testcases/`, and reports pass/fail results with a nested summary per failure.

## Architecture

### Layers

**1. Infrastructure Layer** (`k3s_cluster/*.tf`)
- Provisions EC2 nodes (control plane + agent plane), a Network Load Balancer, S3 bootstrap bucket, IAM roles, and security groups.
- `cluster_ec2.tf`: EC2 instance configs (default: 3 control-plane nodes, `t4g.medium`, Debian 13 ARM).
- `cloudinit.sh.tftpl`: User-data template — the entry point for all on-node provisioning.

**2. Bootstrap Layer** (`k3s_cluster/cluster_app/bootstrap/`)
- Shell scripts run on EC2 startup via cloud-init. They download further scripts from S3, install packages, configure swap, install K3s, then sequence subsystem and application setup.

**3. Subsystems Layer** (`k3s_cluster/cluster_app/{traefik,kyverno,external-secrets,descheduler,karpenter}/`)
- Kubernetes-level infrastructure components installed after K3s is ready.
- **Traefik**: Ingress controller (HTTP :30080, HTTPS :30443).
- **External-Secrets**: Pulls secrets from AWS Parameter Store into Kubernetes.
- **Karpenter**: Node auto-scaling.
- **Kyverno**: Policy engine.
- **Descheduler**: Pod rebalancing.

**4. Applications Layer** (`k3s_cluster/cluster_app/{argocd,monitoring}/`)
- **ArgoCD**: GitOps deployer, requires OIDC IdP config in Parameter Store.
- **Monitoring**: Prometheus + Grafana stack.

**5. Shared Utilities** (`k3s_cluster/cluster_app/utils/`)
- `common_values/`: CPU/memory resource presets used by subsystems/apps.
- `aws_pstore/`: AWS Parameter Store helper module.
- `aws_s3obj/`: S3 object management.

### Module Interface

The `k3s_cluster` module is consumed from example or user Terraform configs. Key inputs:

```hcl
module "k3s_cluster" {
    source        = "../../k3s_cluster"
    nickname      = var.nickname         # short name used in resource naming
    aws_region    = var.aws_region
    admin_ip_list = var.admin_ip_list    # IPs allowed direct access
    vpc_id        = module.vpc_cloud.vpc_id
    subnet_ids    = module.vpc_cloud.subnet_public_ids

    controlplane = { node_count = 3 }
    agentplane   = { node_count = 0 }

    subsystems = {
        karpenter = { version = "1.9.0", ... }
    }

    applications = {
        argocd     = { pstore_idp_config = "...", domain_name = "..." }
        monitoring = { pstore_idp_config = "...", domain_name = "..." }
    }
}
```

### Identity Provider (IdP)

The `examples/ex_idp/` directory and `examples/modules/idp_cognito/` deploy AWS Cognito as an OIDC provider. It is kept in a separate Terraform root from the cluster so it is not torn down when the cluster is destroyed. ArgoCD and Grafana authenticate through it.

### Examples

- `examples/ex_basic/`: Full cluster with apps — the primary reference implementation.
- `examples/ex_idp/`: Standalone IdP setup (deploy this first).
- `examples/modules/vpc_cloud/`: Reusable VPC module used by examples.

## Conventions

### Commit Format

Commits must follow: `TYPE/#ISSUE_ID - Description`

Valid types: `document`, `feature`, `bugfix`, `refactor`, `chore`, `sandbox`

Example: `feature/#41 implement autoscaling`

Git hooks in `.git-custom/` enforce this. Apply them with `./.git-custom/apply.sh`.

### File Naming in `bootstrap/`

Bootstrap files use category-based names (not numbered sequences) — e.g., `install_k3s.sh`, not `02_install.sh`.

### Subsystem/App Pattern

Each subsystem or application directory contains:
- A Terraform module (`*.tf`) that renders Kubernetes manifests and uploads them to S3.
- Shell scripts consumed by the bootstrap layer to apply those manifests via `kubectl`.
- Values from `utils/common_values/` for consistent resource sizing.
