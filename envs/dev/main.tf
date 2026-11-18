terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # Bucket and region are passed at init time (see the Makefile), so no account details live in Git.
  backend "s3" {
    key          = "dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native locking, no DynamoDB table needed
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "aws-terraform-hands-on", Environment = "dev", ManagedBy = "terraform" }
  }
}

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Only the first two zones are used (slice), so new zones cannot change the plan
  state = "available"
}

locals {
  name = "tfdemo"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "network" {
  source     = "../../modules/network"
  name       = local.name
  azs        = local.azs
  enable_nat = var.enable_nat
}

module "bastion" {
  # Wait for the whole network, including the NAT gateway and the routes to it. The instances install packages at boot,
  # and without this the first ones can start before there is a route out and fail their health checks.
  depends_on = [module.network]

  source     = "../../modules/bastion"
  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_id  = module.network.public_subnet_ids[0]
  admin_cidr = var.admin_cidr
  public_key = var.public_key
}

module "app" {
  # Same reason as the bastion: the web instances install nginx at boot, so the private subnets need their route to the
  # NAT gateway first. Observed on a fresh apply: the Auto Scaling group was created 19 s in, the NAT gateway only after
  # 1m55s, and both first instances failed their health checks and were replaced.
  depends_on = [module.network]

  source             = "../../modules/app"
  name               = local.name
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  bastion_sg_id      = module.bastion.security_group_id
  key_name           = module.bastion.key_name
}
