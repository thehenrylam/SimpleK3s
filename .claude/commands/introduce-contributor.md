# introduce-contributor

Onboard a new contributor by walking them through the project, how to make changes, how to test, and verifying their local setup is ready.

## Steps

### 1. Project Overview

Present this to the user:

---

**What is SimpleK3s?**

SimpleK3s is an opinionated Terraform/OpenTofu module that deploys a production-grade K3s (lightweight Kubernetes) cluster on AWS. It targets hobbyists and startup teams who want enterprise features — auto-scaling, GitOps, monitoring, secrets management — without the cost and complexity of EKS.

**Most common types of contributions:**
- Bug fixes
- Reliability and robustness
- Ease of use
- Enterprise features
- Cost optimization
- Documentation

---

### 2. Project Layout

Present this to the user:

---

**Layer 1 — Infrastructure** (`k3s_cluster/*.tf`)
Provisions EC2 nodes, a Network Load Balancer, S3 bootstrap bucket, IAM roles, and security groups.

**Layer 2 — Bootstrap** (`k3s_cluster/cluster_app/bootstrap/`)
Shell scripts run on EC2 startup via cloud-init. They install packages, configure swap, install K3s, then sequence subsystem/app setup.

**Layer 3 — Subsystems** (`k3s_cluster/cluster_app/{traefik,kyverno,external-secrets,descheduler,karpenter}/`)
Kubernetes infrastructure components installed after K3s is ready (ingress, policy engine, secrets, autoscaling, pod rebalancing).

**Layer 4 — Applications** (`k3s_cluster/cluster_app/{argocd,monitoring}/`)
ArgoCD (GitOps) and Prometheus + Grafana (monitoring), both backed by AWS Cognito OIDC.

**Layer 5 — Shared Utilities** (`k3s_cluster/cluster_app/utils/`)
Parameter Store helpers, S3 object management, and CPU/memory resource presets.

**Examples**
- `examples/standard_deployment/terraform/standard_cluster/` — Full cluster with apps; the primary reference.
- `examples/standard_deployment/terraform/standard_idp/` — Standalone IdP (deploy this before the cluster).
- `examples/standard_deployment/terraform/standard_pvc/` — Standalone PVC (deploy this before the cluster).
- `examples/standard_deployment/terraform/standard_tailscale/` — Standalone Tailscale (deploy this before the cluster).
- `examples/modules/vpc_cloud/` — Reusable VPC module.

---

### 3. How to Introduce a Change

Present this to the user:

---

1. **Find or create an issue** on GitHub. Use `/new-issue` to create one with the right format.
2. **Create a branch** following the branch naming convention:
   ```
   TYPE/#ISSUE_ID_branch_name
   # e.g. bugfix/#42_fix_cluster_startup
   ```
3. **Make commits** following the commit convention:
   ```
   TYPE/#ISSUE_ID - Commit message
   # e.g. bugfix/#42 - Wait for service before applying changes
   ```
4. **Push and open a PR** with the title format `TYPE/#ISSUE_ID PR title`. The PR must:
   - Be explainable in your own words (no AI-generated descriptions)
   - Be focused (small, scoped changes)
   - Include before/after evidence that it works

**Types:** `document`, `feature`, `bugfix`, `refactor`, `chore`, `sandbox`

**Tip:** Use `sandbox` to freely experiment without pressure — `sandbox` PRs are intentionally rejected, so nothing will accidentally merge.

---

### 4. How to Test a Change

Present this to the user:

---

**Locally** (run from an example directory, e.g. `examples/standard_deployment/terraform/standard_cluster/`). These use
`tofu`; substitute `terraform` if that is what you have installed — the config
works with both:
```bash
# Format check
tofu fmt -check -recursive

# Lint
tflint --init && tflint --recursive

# Security scan
checkov -d . --config-file .checkov.yaml

# Validate without deploying (no AWS credentials needed)
tofu init -backend=false && tofu validate

# Full plan (requires AWS credentials)
AWS_PROFILE="your_profile" tofu plan
```

**GitHub Actions** (runs automatically on PRs and pushes to `main`):
The `Static Analysis` workflow (`.github/workflows/static-analysis.yml`) runs:
- `tofu fmt` — format check
- `tflint` — linting
- `checkov` — security scanning
- `validate` — validation across all modules and examples, run under **both** OpenTofu and Terraform (matrix)

PRs must pass this workflow before merging. You can watch it in the **Actions** tab on GitHub.

---

### 5. Environment Check

Run the following checks and report results to the user in a clear pass/fail summary:

**a) Base dependency — OpenTofu/Terraform**
```bash
tofu version || terraform version
```
- PASS if either `tofu` (v1.11.2+) or `terraform` (v1.14.3+) is found — the configuration supports both.
- FAIL if neither is found.
- FAIL if neither is found.

**b) Linter — tflint**
```bash
tflint --version
```
- PASS if found.
- FAIL if not found; tell the user to install it (`brew install tflint` on macOS).

**c) Security scanner — checkov**
```bash
checkov --version
```
- PASS if found.
- FAIL if not found; tell the user to install it (`pip install checkov`).

**d) Git hooks**

Check whether the custom commit-msg hook is installed:
```bash
diff .git-custom/hooks/commit-msg .git/hooks/commit-msg
```
- PASS if both files exist and are identical (diff exits 0).
- FAIL if `.git/hooks/commit-msg` is missing or differs — tell the user to run `./.git-custom/apply.sh` to install the hooks.

After running all checks, present a summary table:

| Check | Status | Notes |
|-------|--------|-------|
| OpenTofu/Terraform | ✅ / ❌ | version found |
| tflint | ✅ / ❌ | version or install hint |
| checkov | ✅ / ❌ | version or install hint |
| Git commit-msg hook | ✅ / ❌ | installed or run apply.sh |

Close with: *"You're all set! Start with `/new-issue` to create your first ticket, or browse open issues on GitHub."* (or list any failing checks the user needs to resolve first).

## Notes

- Run the checks using Bash — do not ask the user to run them manually.
- Keep each section clearly separated so the user can read at their own pace.
- Do not overwhelm the user with options — guide them toward the happy path.
