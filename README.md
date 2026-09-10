# SimpleK3s
A simple K3s implementation for AWS

[![Static Analysis](https://github.com/thehenrylam/SimpleK3s/actions/workflows/static-analysis.yml/badge.svg)](https://github.com/thehenrylam/SimpleK3s/actions/workflows/static-analysis.yml)

# Features
Perfect for Hobbyists and Entrepreneurs who want a setup with critical enterprise features without committing to EKS.
This acts as a perfect starting point to deploy MVPs with scaling, monitoring, and good defaults for security in mind. 
In addition, it serves as a way to transition nicely into EKS since your apps would be built with Kubernetes in mind from the very beginning.

| Features             | `Full DiY` | `SimpleK3s`       | `EKS`    |
| -------------------: | :--------: | :---------------: | :------: |
| Setup Speed 🚀       | ⭐️          | ⭐️⭐️⭐️⭐️⭐️         | ⭐️⭐️⭐️    |
| Cost Efficiency 🤑   | ⭐️⭐️⭐️⭐️⭐️   | ⭐️⭐️⭐️             | ⭐️       |
| Kubernetes-Ready ⚙️  | 🚫          | ✅                | ✅       |
| High Availability 🦾 | 🚫          | ✅                | ✅       |
| Auto Scaling 📈      | 🚫          | ✅                | ✅       |
| Monitoring 👀        | 🚫          | ✅                | ✅       |
| Deployer 🏗️          | 🚫          | ✅                | ✅       |
| QoL: ArgoCD 🦑       | 🚫          | ✅                | 🚫       |
| QoL: Grafana 🍥      | 🚫          | ✅                | 🚫       |
| QoL: Governance 👨‍⚖️   | 🚫          | ✅                | 🚫       |
| QoL: Secrets Mgmt 🤫 | 🚫          | ✅                | 🚫       |
| Security 🔐          | ⭐️          | ⭐️⭐️⭐️            | ⭐️⭐️⭐️⭐️⭐️ |
| Operational Ease 🛠️  | ⭐️          | ⭐️⭐️⭐️⭐️⭐️        | ⭐️⭐️⭐️⭐️⭐️ |
| Best For... 🫥       | Small Projects | Scalable MVPs | Full Production |

# AI Coding Agents
There are some useful commands/skills for your coding agents to utilize:

## Claude Code

__General Skills__
- **/check-versions** (Helps scan through the entire repo for software used and their versions)
    - WARNING: Very token intensive, use on a fresh claude session if possible.
- **/test-out** (Helps perform testcases and provide a report on the results)

__[Contributing Skills](./CONTRIBUTING.md#ai-cheatsheet-for-contributing)__
- **/introduce-contributor** (Introduces the potential contributor to the project)
- **/new-issue** (Helps create a new issue based on the formatting outlined in this document)

# Pricing
Estimated monthly costs for common deployment profiles, plus a side-by-side comparison with equivalent EKS setups — see [PRICING.md](./PRICING.md).

# Runbooks
Manual recovery procedures for failures automation cannot fix on its own — see [RUNBOOKS.md](./RUNBOOKS.md).

# CI and Testing
Every pull request and push to `main` runs a static analysis pipeline (no AWS credentials required):
- **`tofu fmt` / `terraform fmt`** — enforces consistent formatting
- **`tflint`** — lint rules for naming, versioning, and AWS best practices
- **`tofu validate` / `terraform validate`** — type-checks all seven root modules (CI runs this under both tools)
- **`checkov`** — security and compliance scan of Terraform resources
- **`shellcheck`** — linting, syntax and validity of shell scripts
- **`ruff`** — lint and format check for Python
- **`pytest`** — unit tests for the on-node verification logic

The same checks run locally from the repo root. Each prints `[OK]` / `[FAIL]` per
check and exits non-zero if anything fails:

``` bash
bash testcases/test-out_shellscripts.sh   # shellcheck
bash testcases/test-out_terraform.sh      # fmt, tflint, checkov, validate
bash testcases/test-out_python.sh         # ruff check + format
bash testcases/test-out_unittests.sh      # pytest
```

`testcases/test-out_simplek3s.sh` is the fifth script and is **not** part of CI —
it grades a **deployed** cluster and needs AWS credentials.

Or via [Claude Code](./README.md#claude-code):

``` bash
> /test-out             # all static tests
> /test-out relevant    # only what your changes touched
> /test-out python      # one area
# Logs land in testcases/, and it confirms the plan before running.
```

# Disclaimer
- This is **NOT** meant to be a $0 or lowest possible price point setup.
    - Remember, a webapp running on 1-2 instances will **ALWAYS** be cheaper than a Kubernetes cluster.
- This is **NOT** meant to replace managed Kubernetes services like `EKS`.
    - `SimpleK3s` helps get people started with Kubernetes before moving onto `EKS`.
- `SimpleK3s` offers **ZERO** guarantee or warranty of reliability.
    - Workloads or services that cannot fail at whatever the cost should explore managed services like `EKS`.

# Requirements
- OpenTofu v1.11.2 or Terraform v1.14.3
    - The commands below use `tofu`; substitute `terraform` if you use Terraform — the configuration is compatible with both.
- AWS account
- AWS profile with the correct IAM rights that can use Terraform
    - [How to set up AWS Credentials for Terraform](https://www.sudeepa.com/?p=382)
    - [How to use a Terraform with an AWS profile](https://renatogolia.com/2022/05/31/how-to-use-terraform-with-multiple-aws-profiles/)
- A domain name (Approx. $15USD for 4 yrs)
- `aws` package (Helpful tool to interact with AWS resources for debugging and advanced usage)
    - Search up "Install aws cli" via a search engine
    - https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- `session-manager-plugin` package (Used for connecting to instances without needing keypairs)
    - Search up "Install session-manager-plugin for aws cli" via a search engine 
    - https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

# Quickstart
The fastest path to a running cluster is the reference deployment, which wires up
the IdP, persistent volumes, Tailscale and the cluster itself in the right order:

**➜ [examples/standard_deployment/README.md](./examples/standard_deployment/README.md)**

It is driven by Ansible over four Terraform roots, fronted by a single CLI:

``` bash
cd examples/standard_deployment

cp group_vars/all.TEMPLATE.yml group_vars/all.yml   # then edit it
./sk3s infra support apply                          # IdP, volumes, Tailscale
./sk3s infra cluster apply                          # the K3s cluster itself
./sk3s status                                       # confirm it came up healthy
```

Deploy the support tier **before** the cluster: the cluster reads Parameter Store
values that tier owns. Tear down in the reverse order.

# Operating a cluster
`examples/standard_deployment/sk3s` is the operator entry point. Run it with no
arguments for the full list, or `./sk3s <verb> --help` for one verb.

| | |
| --- | --- |
| `./sk3s status` | Health, merged across control-plane nodes (`--depth quick\|standard\|full`) |
| `./sk3s nodes` | List the cluster's EC2 instances |
| `./sk3s connect` | Interactive shell on a node (over SSM — no SSH keys) |
| `./sk3s exec` | Run one command on a node |
| `./sk3s sync` / `apply` / `pull` | Push bootstrap files from S3; stage manifests; both |
| `./sk3s refresh` | Restart platform workloads that are wedged |
| `./sk3s repair` | Rejoin a control-plane node that cannot rejoin itself |
| `./sk3s infra <tier> <verb>` | `plan` / `apply` / `destroy` a tier (`cluster`, `support`) |

Mutating verbs preview by default and act only on an explicit flag. Every run is
logged under `logs/`. See [RUNBOOKS.md](./RUNBOOKS.md) when something is broken.

# Using the module directly
`k3s_cluster` is a Terraform module, so you can consume it from your own IaC
instead of using the reference deployment. A minimal working invocation:

``` Terraform
module "k3s_cluster" {
    source = "<PATH_TO_REPO>/k3s_cluster"

    # ── Required ──
    nickname      = "my-cluster"                        # short name used in resource naming
    aws_region    = "us-east-1"
    vpc_id        = module.vpc_cloud.vpc_id
    subnet_ids    = module.vpc_cloud.subnet_public_ids  # cluster nodes live here
    admin_ip_list = ["203.0.113.4/32"]                  # IPs allowed direct access

    # ── Node planes ──
    # 3 control-plane nodes gives etcd quorum (survives losing one).
    # Minimum 2 vCPU: a control-plane node carries ~1.4 vCPU of requests before
    # any workload, so a 1-vCPU type cannot schedule its own baseline.
    controlplane = {
        node_count        = 3
        ec2_instance_type = "t4g.medium"
    }
    agentplane = {
        node_count = 0
    }

    # ── Optional: built-in applications ──
    # Both need an OIDC config in Parameter Store as a JSON string:
    #   { issuer, client_id, client_secret, domain }
    # examples/modules/idp_cognito creates one for you.
    applications = {
        argocd = {
            pstore_idp_config = "/idp-standalone/idp-standalone/idp_config"
            domain_name       = "example.com"
            exposure          = "external"   # public LB; "internal" = tailnet-only
        }
        monitoring = {
            pstore_idp_config = "/idp-standalone/idp-standalone/idp_config"
            domain_name       = "example.com"
            exposure          = "external"
        }
    }
}
```

Optional inputs are grouped into objects rather than a flat list. Every field and
its default is declared in
[`k3s_cluster/variables.tf`](./k3s_cluster/variables.tf), which is the source of
truth — this table is only a map of where to look:

| Input | Covers |
| --- | --- |
| `controlplane` / `agentplane` | `node_count`, `ec2_instance_type`, `ec2_ami_id`, `ec2_swapfile_size`, `ebs_volume_size`, `ebs_volume_type`, `kube_reserved_cpu`, `kube_reserved_memory`, and (control plane only) `controller_private_ip_override` |
| `subsystems` | `traefik`, `kyverno`, `external-secrets`, `descheduler`, `karpenter`, `longhorn`, `tailscale` |
| `applications` | `argocd`, `monitoring` (versions, `exposure`, Grafana/Prometheus/Alertmanager volume sizes) |
| top level | `k3s_version`, `ec2_ami_name`, `aws_cli_version`, `ssm_agent_version`, `k3s_nodeport_traefik_http`, `k3s_nodeport_traefik_https`, `account_id` |

For a fully worked example with every subsystem configured, read
[`examples/standard_deployment/terraform/standard_cluster/main.tf`](./examples/standard_deployment/terraform/standard_cluster/main.tf).

## Things to keep in mind
* **AWS Free Tier allows 50K Monthly Active Users for Cognito.** Comfortable for a
  small team — but destroying and recreating the user pool forces everyone to
  register again, and each re-registration spends MAU budget.
* **That is why the IdP is its own Terraform root.** It survives cluster
  teardowns, so you can rebuild the cluster freely without redoing Cognito.
  `./sk3s infra support destroy --limit '!idp'` tears down the rest and leaves it.
* **Keep the IdP and the cluster in the same region** (e.g. both `us-east-1`).

# Contributing
Interested in adding more features? Check out the [CONTRIBUTING.md](https://github.com/thehenrylam/SimpleK3s?tab=contributing-ov-file) for code of conduct and a guide on how to make changes ot the project!
