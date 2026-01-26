# SimpleK3s
A simple K3s implementation for AWS

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
| Auto Scaling 📈      | 🚫          | 🏗️ (**WIP**) 🏗️   | ✅       |
| Monitoring 👀        | 🚫          | 🏗️ (**WIP**) 🏗️   | ✅       |
| Security 🔐          | ⭐️          | ⭐️⭐️⭐️            | ⭐️⭐️⭐️⭐️⭐️ |
| Operational Ease 🛠️  | ⭐️          | ⭐️⭐️⭐️            | ⭐️⭐️⭐️⭐️⭐️ |
| Best For... 🫥       | Small Projects | Scalable MVPs | Full Production |

# Disclaimer
- This is **NOT** meant to be a $0 or lowest possible price point setup.
    - Remember, a webapp running on 1-2 instances will **ALWAYS** be cheaper than a Kubernetes cluster.
- This is **NOT** meant to replace managed Kubernetes services like `EKS`.
    - `SimpleK3s` helps get people started with Kubernetes before moving onto `EKS`.
- `SimpleK3s` offers **ZERO** guarantee or warranty of reliability.
    - Workloads or services that cannot fail at whatever the cost should explore managed services like `EKS`.

# Requirements
- OpenTofu v1.11.2 or Terraform v1.14.3
- AWS account
- AWS profile with the correct IAM rights that can use Terraform
    - [How to set up AWS Credentials for Terraform](https://www.sudeepa.com/?p=382)
    - [How to use a Terraform with an AWS profile](https://renatogolia.com/2022/05/31/how-to-use-terraform-with-multiple-aws-profiles/)
- A domain name (Approx. $15USD for 4 yrs)

# How to use
This is used as a Terraform module for your AWS IaC Projects.
In your Terraform configuration, add the following module to create the k3s cluster:
``` Terraform
module "k3s_cluster" {
    source                  = "<PATH_TO_MODULE>/k3s_cluster" # Path to the k3s cluster
    nickname                = var.nickname                   # Nickname that resources will use (e.g. Name, Tags, etc)
    node_count              = var.node_count                 # The number of nodes that K3s will start with
    admin_ip_list           = var.admin_ip_list              # The list of IPs (in CIDR) to allow for admin SSH connections 
    vpc_id                  = module.vpc_cloud.vpc_id        # The VPC that resources will be put inside of
    subnet_ids              = module.vpc_cloud.subnet_public_ids # The list of subnets that the cluster nodes reside in
}

# Optional variables:
#   Networking:
#       - controller_subnet_id          : Override the subnet that the controller node will use 
#                                         (Default is the first subnet from `subnet_ids`)
#                                         (controller subnet id MUST be found within `subnet_ids`)
#       - controller_private_ip         : Override the private IP for the controller node 
#                                         (Won't work if private IP is outside of subnet's CIDR block)
#       - controller_private_ip_hostnum : Determine the last 3 digits of the controller's private IP
#                                         (Doesn't get used if `controller_private_ip` is used)
#       - k3s_nodeport_traefik_http     : The Traefik nodeport that HTTP traffic goes through
#       - k3s_nodeport_traefik_https    : The Traefik nodeport that HTTPS traffic goes through
#  Node Infra (EC2):
#       - ec2_ami_id                    : The AMI id that the EC2 instances (Nodes) will use
#                                         (default is Debian 13 for ARM on the us-east-1 region)
#                                         (WARNING: The default value may not work depending on input VPC's region / instance type)
#       - ec2_instance_type             : The instance type that the K3s nodes will be made up of
#                                         (Absolute minimum is t4g.small: Kubernetes can crash if cpu/memory is slow or constrained)
#                                         (Highly recommend to upgrade to t4g.medium or t4g.large if you are planning to run 3 or more pods)
#       - ec2_swapfile_size             : Sets the size of the SWAPFILE
#                                         (Default is 1G : Should be between 512M - 1G
#                                          Too much leads to inconsistent k3s behavior because nodes to be responsive to work)
#                                         (NOTE: In the context of Kubernetes, SWAPFILE isn't a solution to add more RAM, unfortunately
#                                          SWAP should ONLY be used as an emergency cushion to avoid OOM issues) 
#       - ec2_ebs_volume_size           : The disk size of the volume in Gb (Recommended minimum is 12)
#       - ec2_ebs_volume_type           : The volume type (Recommended is GP3 for performance and price for smaller volume sizes)
```

# Try it out (As an example):
0. Navigate to `./examples/ex_basic/` (e.g. `cd ./examples/ex_basic/`)
1. Copy `./main.TEMPLATE.tfvars` file to `./main.tfvars`
2. Modify the newly created `main.tfvars` file to your satisfaction
3. Execute the following command(s): 
 - `AWS_PROFILE="your_aws_profile" tofu init -var-file="main.tfvars"` # Initialize the project
 - `AWS_PROFILE="your_aws_profile" tofu plan -var-file="main.tfvars"` # Dry run the infra allocation
 - `AWS_PROFILE="your_aws_profile" tofu apply -var-file="main.tfvars"` # Allocate infra
 - `AWS_PROFILE="your_aws_profile" tofu destroy -var-file="main.tfvars"` # Free allocation of infra 

# Contributing
Interested in adding more features? Check out the [CONTRIBUTING.md](https://github.com/thehenrylam/SimpleK3s?tab=contributing-ov-file) for code of conduct and a guide on how to make changes ot the project!
