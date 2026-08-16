locals {
  #########################################
  #   Computed Values (Controller Node)   #
  #########################################
  # Controller node networking (node 0)
  # If the controller_subnet_id is not set, default to the FIRST subnet in subnet_ids
  controller_subnet_id          = var.subnet_ids[0]
  controller_subnet_cidr        = data.aws_subnet.controller.cidr_block
  controller_private_ip_hostnum = 100 # Default value to set the host number for the controller ip (XXX.XXX.XXX.100, where XXX.XXX.XXX.--- is the controller's subnet CIDR)
  # If the controller_private_ip is not set, compute it via cidrhost()
  controller_private_ip = coalesce(var.controlplane.controller_private_ip_override, cidrhost(local.controller_subnet_cidr, local.controller_private_ip_hostnum))

  # Pin default AMI version in text form
  default_ami_owner = "136693071363" # Debian's official AWS account
  # Exact, pinned AMI name (sourced from var.ec2_ami_name). Using an exact name
  # instead of a "debian-13-arm64-*" wildcard keeps the resolved AMI stable across
  # plans, so a new Debian release does not trigger EC2 replacement.
  default_ami_name_pattern = var.ec2_ami_name

  default_controlplane = {
    node_count = 3
    ec2_ami_id = data.aws_ami.default.id
    # t4g.large (2 vCPU / 8 GiB), NOT t4g.medium (2 vCPU / 4 GiB).
    #
    # A control-plane node carries ~1.4 vCPU and ~1 GiB of requests before any
    # workload: the k3s server (apiserver, scheduler, controller-manager, etcd)
    # plus the per-node DaemonSets (longhorn-manager, longhorn-csi-plugin,
    # engine-image, node-exporter, svclb-traefik) and a Longhorn instance-manager
    # sized at 12% of node CPU.
    #
    # On 4 GiB that left the full platform stack at 81% memory allocated, which
    # was measured driving nodes into swap, then etcd apply latency of ~59s
    # against a 100ms expectation, kubelet missing heartbeats, and a node going
    # NotReady with a Longhorn volume faulted. 8 GiB drops the same stack to ~48%.
    #
    # Do not drop to a 1-vCPU type (r7g.medium etc.). The ~1.4 vCPU of baseline
    # requests exceeds a 1-vCPU node's allocatable, so pods cannot be scheduled —
    # a hard scheduling failure, not a slow node. Measured: 3x r7g.medium spilled
    # the platform (Traefik, ArgoCD, Prometheus) onto Karpenter nodes and cost the
    # same as 3x t4g.large to within $0.15/month.
    ec2_instance_type = "t4g.large"
    ec2_swapfile_size = "1G"
    ebs_volume_size   = 16
    ebs_volume_type   = "gp3"
  }

  default_agentplane = {
    node_count = 3
    ec2_ami_id = data.aws_ami.default.id
    # Matched to the control plane for consistency. An agent node does not run the
    # k3s server components, so its floor is lower — but it still carries the same
    # per-node DaemonSets and a Longhorn instance-manager, and it is the plane that
    # actually hosts workloads. t4g.medium may well be adequate here; it is set to
    # t4g.large only because the measurements behind that choice were taken on the
    # control plane, and guessing a smaller size for the agent plane would not be
    # evidence-backed.
    ec2_instance_type = "t4g.large"
    ec2_swapfile_size = "1G"
    ebs_volume_size   = 16
    ebs_volume_type   = "gp3"
  }

  controlplane = {
    # General
    node_count = coalesce(try(var.controlplane.node_count, null), local.default_controlplane.node_count)

    # EC2
    ec2_ami_id        = coalesce(try(var.controlplane.ec2_ami_id, null), local.default_controlplane.ec2_ami_id)
    ec2_instance_type = coalesce(try(var.controlplane.ec2_instance_type, null), local.default_controlplane.ec2_instance_type)
    ec2_swapfile_size = coalesce(try(var.controlplane.ec2_swapfile_size, null), local.default_controlplane.ec2_swapfile_size)

    # EBS
    ebs_volume_size = coalesce(try(var.controlplane.ec2_volume_size, null), local.default_controlplane.ebs_volume_size)
    ebs_volume_type = coalesce(try(var.controlplane.ec2_volume_type, null), local.default_controlplane.ebs_volume_type)

    # Custom (Overrides)
    controller_private_ip_override = local.controller_private_ip
  }

  agentplane = {
    # General
    node_count = coalesce(try(var.agentplane.node_count, null), local.default_agentplane.node_count)

    # EC2
    ec2_ami_id        = coalesce(try(var.agentplane.ec2_ami_id, null), local.default_agentplane.ec2_ami_id)
    ec2_instance_type = coalesce(try(var.agentplane.ec2_instance_type, null), local.default_agentplane.ec2_instance_type)
    ec2_swapfile_size = coalesce(try(var.agentplane.ec2_swapfile_size, null), local.default_agentplane.ec2_swapfile_size)

    # EBS
    ebs_volume_size = coalesce(try(var.agentplane.ec2_volume_size, null), local.default_agentplane.ebs_volume_size)
    ebs_volume_type = coalesce(try(var.agentplane.ec2_volume_type, null), local.default_agentplane.ebs_volume_type)
  }
}

# Output local variables
locals {
  controlplane_ids     = [for instance in aws_instance.controlplane_ec2_node : instance.id]
  agentplane_ids       = [for instance in aws_instance.agentplane_ec2_node : instance.id]
  cluster_instance_ids = concat(local.controlplane_ids, local.agentplane_ids)
}

data "aws_subnet" "controller" {
  id = local.controller_subnet_id
}

# Resolve the pinned AMI name to a region-specific AMI ID.
# The name (var.ec2_ami_name) is exact, so this stays stable across plans; the
# lookup only exists so the same pinned image resolves correctly in any region.
# most_recent is kept as a defensive tie-breaker in the unlikely event a name
# matches more than one image.
data "aws_ami" "default" {
  most_recent = true
  owners      = [local.default_ami_owner]

  filter {
    name   = "name"
    values = [local.default_ami_name_pattern]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#######################################
#    EC2 instances for K3S Cluster    #
#######################################
# Set up random strings for the purposes of appending them to node names
resource "random_string" "controlplane_node_suffix" {
  count   = local.controlplane.node_count
  length  = 5
  special = false
  upper   = false
  numeric = true
}
# Initialize EC2 instances for the K3s cluster
resource "aws_instance" "controlplane_ec2_node" {
  count         = local.controlplane.node_count
  ami           = local.controlplane.ec2_ami_id
  instance_type = local.controlplane.ec2_instance_type
  # Distribute nodes across the provided subnets:
  # The first node (controller) goes into controller_subnet_id
  # The rest are round-robin'd across the other subnets
  subnet_id                   = var.subnet_ids[count.index % length(var.subnet_ids)]
  key_name                    = aws_key_pair.tls_key.key_name
  iam_instance_profile        = aws_iam_instance_profile.iprofile_ec2.name
  vpc_security_group_ids      = [aws_security_group.sg_instances.id]
  associate_public_ip_address = true
  # The first node will have the controller private IP, the rest get dynamic IPs
  private_ip = count.index == 0 ? local.controlplane.controller_private_ip_override : null

  user_data = templatefile("${path.module}/cloudinit.sh.tftpl", {
    count_index       = count.index,
    cluster_type      = "controlplane",
    bootstrap_bucket  = aws_s3_bucket.bootstrap.bucket,
    bootstrap_dir     = local.bstrap_dir,
    aws_cli_version   = var.aws_cli_version,
    ssm_agent_version = var.ssm_agent_version,
    # Referenced by name, not by list position (see local.s3key_install_script)
    s3key_install_script = local.s3key_install_script,
  })

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = local.controlplane.ebs_volume_size
    volume_type = local.controlplane.ebs_volume_type

    tags = {
      Name     = "${local.ebs_name}_controlplane-root-${random_string.controlplane_node_suffix[count.index].result}"
      Nickname = var.nickname
    }
  }

  tags = {
    Name     = "${local.ec2_name}_controlplane-${random_string.controlplane_node_suffix[count.index].result}"
    Nickname = var.nickname
  }
}

#######################################
#    EC2 instances for K3S Cluster    #
#######################################
# Set up random strings for the purposes of appending them to node names
resource "random_string" "agentplane_node_suffix" {
  count   = local.agentplane.node_count
  length  = 5
  special = false
  upper   = false
  numeric = true
}
# Initialize EC2 instances for the K3s cluster
resource "aws_instance" "agentplane_ec2_node" {
  count         = local.agentplane.node_count
  ami           = local.agentplane.ec2_ami_id
  instance_type = local.agentplane.ec2_instance_type
  # Distribute nodes across the provided subnets
  subnet_id                   = var.subnet_ids[count.index % length(var.subnet_ids)]
  key_name                    = aws_key_pair.tls_key.key_name
  iam_instance_profile        = aws_iam_instance_profile.iprofile_ec2.name
  vpc_security_group_ids      = [aws_security_group.sg_instances.id]
  associate_public_ip_address = true
  # All agentplane ec2 nodes will get dynamic IPs
  private_ip = null

  user_data = templatefile("${path.module}/cloudinit.sh.tftpl", {
    count_index       = count.index,
    cluster_type      = "agentplane",
    bootstrap_bucket  = aws_s3_bucket.bootstrap.bucket,
    bootstrap_dir     = local.bstrap_dir,
    aws_cli_version   = var.aws_cli_version,
    ssm_agent_version = var.ssm_agent_version,
    # Referenced by name, not by list position (see local.s3key_install_script)
    s3key_install_script = local.s3key_install_script,
  })

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = local.agentplane.ebs_volume_size
    volume_type = local.agentplane.ebs_volume_type

    tags = {
      Name     = "${local.ebs_name}_agentplane-root-${random_string.agentplane_node_suffix[count.index].result}"
      Nickname = var.nickname
    }
  }

  tags = {
    Name     = "${local.ec2_name}_agentplane-${random_string.agentplane_node_suffix[count.index].result}"
    Nickname = var.nickname
  }

  # Wait for EC2 node to be set up before we start setting up ELB
  depends_on = [
    aws_instance.controlplane_ec2_node # aws_instance.ec2_node 
  ]
}
