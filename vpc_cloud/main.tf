# OPENTOFU : VPC Cloud

terraform {
    required_providers {
        assert = {
            source = "opentofu/assert"
            version = "0.14.0"
        }
        aws = {
            source  = "hashicorp/aws"
            version = ">= 6.0"
        }
        cloudinit = {
            source  = "opentofu/cloudinit"
            version = ">= 2.3.7"
        }
    }
}

locals {
    vpc_name = "vpc-${var.nickname}"
    rtb_name = "rtb-${var.nickname}"
    igw_name = "igw-${var.nickname}"
    sbn_name = "sbn-${var.nickname}"
}

provider "aws" {
    region = var.aws_region
}

# VPC
resource "aws_vpc" "vpc" {
    cidr_block  = var.vpc_cidr_block
    
    tags = {
        Name        = local.vpc_name
        Nickname    = var.nickname
    }
}

# Internet Gateway 
resource "aws_internet_gateway" "igw" {
    vpc_id  = aws_vpc.vpc.id

    tags = {
        Name        = local.igw_name
        Nickname    = var.nickname
    }
}

# VPC Route Table
resource "aws_route_table" "rtb_public" {
    count   = var.node_count
    vpc_id  = aws_vpc.vpc.id

    tags = {
        Name        = "${local.rtb_name}_${count.index}"
        Nickname    = var.nickname
    }
}

# Route
resource "aws_route" "rt_default" {
    count                   = var.node_count
    route_table_id          = aws_route_table.rtb_public[count.index].id
    destination_cidr_block  = "0.0.0.0/0"
    gateway_id              = aws_internet_gateway.igw.id
}

# Associate only the public subnets to the route table
resource "aws_route_table_association" "rtb_assoc_public" {
    count           = var.node_count
    subnet_id       = aws_subnet.sbn_public[count.index].id
    route_table_id  = aws_route_table.rtb_public[count.index].id
} 

# VPC Subnet
resource "aws_subnet" "sbn_public" {
    count               = var.node_count
    vpc_id              = aws_vpc.vpc.id 
    cidr_block          = var.sbn_cidr_blocks[count.index]
    availability_zone   = var.sbn_availability_zones[count.index]

    tags = {
        Name        = "${local.sbn_name}_${count.index}"
        Nickname    = var.nickname
    }
}


