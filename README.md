# SimpleK3s
A simple K3s implementation for AWS

# How to use:
### Example Setup:
1. Copy the `main.TEMPLATE.tfvars` file to a filename of your choosing (e.g. Suppose its changed to `main.tfvars` for the sake of example)
2. Modify the `main.tfvars` file to your satisfaction
3. Execute the following command(s): 
 - `AWS_PROFILE="your_aws_profile" tofu init -var-file="main.tfvars"` # Initialize the project
 - `AWS_PROFILE="your_aws_profile" tofu plan -var-file="main.tfvars"` # Dry run the infra allocation
 - `AWS_PROFILE="your_aws_profile" tofu apply -var-file="main.tfvars"` # Allocate infra
 - `AWS_PROFILE="your_aws_profile" tofu destroy -var-file="main.tfvars"` # Free allocation of infra 
