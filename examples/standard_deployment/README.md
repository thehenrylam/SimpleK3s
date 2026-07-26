# Example: Standard Deployment

## First Time Setup

1. Configure the following files:
    - ./group_vars/all.yml 
        - Template: all.TEMPLATE.yml
    - ./terraform/standard_cluster/terraform.tfvars 
        - Template: terraform.TEMPLATE.tfvars
    - ./terraform/standard_idp/terraform.tfvars
        - Template: terraform.TEMPLATE.tfvars
    - ./terraform/standard_pvc/terraform.tfvars
        - Template: terraform.TEMPLATE.tfvars
    - ./terraform/standard_tailscale/terraform.tfvars
        - Template: terraform.TEMPLATE.tfvars

## Usage

### A. Create Cluster

1. Create `support` modules
``` sh
# Update the support infra
ansible-playbook ./playbooks/support_apply.yml
```

2. Create `cluster` modules
``` sh
# Update the cluster infra
ansible-playbook ./playbooks/cluster_apply.yml
``` 

### B. Check Everything

1. Check `support` modules
``` sh
# Executes a "tofu plan" 
ansible-playbook ./playbooks/support_plan.yml
```

2. Check `cluster` modules
``` sh
# Executes a "tofu plan" (This will FAIL if you don't create the `support` modules because the cluster depends on it)
ansible-playbook ./playbooks/cluster_plan.yml
```

3. Verify `cluster` health
``` sh
# Goes into the cluster and checks if the Kubernetes cluster works as intended
ansible-playbook ./playbooks/cluster_verify.yml
```

### C. Update the Cluster

1. Update `cluster` (Suppose you have new node scripts or helmcharts you want to deploy)
``` sh
# 1. Execute a "tofu apply"
# 2. Execute ./scripts/ssm_update_services.sh 
#   - Which will pull files from S3 and and do a HelmChart update on the entire cluster
ansible-playbook ./playbooks/cluster_update.yml
```

### D. SSH into a Node

## 
