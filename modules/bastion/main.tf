terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "admin_cidr" {
  description = "The only address range allowed to SSH in, e.g. 203.0.113.7/32"
  type        = string
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}
variable "public_key" { type = string }
variable "instance_type" {
  type    = string
  default = "t3.micro"
}

# Latest Ubuntu 24.04 LTS, published by Canonical as a public SSM parameter.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name}-bastion"
  public_key = var.public_key
}

resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion"
  description = "SSH from the admin address only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-bastion" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.bastion.id
  description       = "SSH from the admin address"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# The bastion only needs to reach the private hosts over SSH and the internet for package updates.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.bastion.id
  description       = "Outbound for updates and SSH hops"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "bastion" {
  #checkov:skip=CKV_AWS_88:A bastion needs a public IP; SSH is limited to one admin address
  #checkov:skip=CKV2_AWS_41:The bastion calls no AWS APIs, so it has no role to attach
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  monitoring                  = true
  ebs_optimized               = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Same hardening idea as the Linux project: key-only SSH, no root login, fail2ban.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y fail2ban unattended-upgrades
    cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'CONF'
    PasswordAuthentication no
    PermitRootLogin no
    MaxAuthTries 3
    CONF
    systemctl restart ssh
    systemctl enable --now fail2ban
  EOT

  tags = { Name = "${var.name}-bastion" }

  lifecycle { ignore_changes = [ami] } # a new AMI release must not replace the host
}

output "security_group_id" { value = aws_security_group.bastion.id }
output "public_ip" { value = aws_instance.bastion.public_ip }
output "key_name" { value = aws_key_pair.this.key_name }
