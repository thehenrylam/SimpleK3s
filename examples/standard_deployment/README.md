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
    - Executes `tofu apply` for `cluster` IaC modules
- `./playbooks/cluster_destroy.yml`
    - Executes `tofu destroy` for `cluster` IaC modules
- `./playbooks/cluster_update.yml`
    - Executes `tofu apply` + `./scripts/ssm_update_services.sh` to ask the cluster to pull from S3, pull new files, and redoing the node setup to update services
- `./playbooks/cluster_verify.yml`
    - .Executes `./scripts/ssm_verify_cluster.sh` to get the health status of the cluster

#### Support Actions

- `./playbooks/support_template.yml`
    - Templates the `terraform.tfvars` for `support` IaC modules (*Will stop in place if `__CONFIGURE_THIS__` string is detected*)
- `./playbooks/support_plan.yml`
    - Executes `tofu plan` for `support` IaC modules
- `./playbooks/support_apply.yml`
    - Executes `tofu apply` for `support` IaC modules
- `./playbooks/support_destroy.yml`
    - Executes `tofu destroy` for `support` IaC modules

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
- `./scripts/ssm_verify_cluster.sh <aws_profile>`
    - In an EC2 node, execute a script to verify the health of the cluster

### AI Skills

- `cluster-ops`
    - Invoke directly or ask Claude Code (or equivalent) to perform actions for you within the cluster.
        - Read-type actions will be executed without need for approval
        - Mutation actions will require approval (in individual commands or batch commands)
    - DISCLAIMER: Use at your own risk (*Try it on test environment to get a feel for it and then experiment on PROD once you have properly vetted and understood the process*)
