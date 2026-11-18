# Offline tests for the bastion module (mocked AWS provider, nothing is created).
mock_provider "aws" {}

variables {
  name       = "t"
  vpc_id     = "vpc-12345678"
  subnet_id  = "subnet-12345678"
  admin_cidr = "203.0.113.7/32"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTestsOnly test"
}

# the admin address becomes the only SSH source
run "the_admin_address_becomes_the_only_ssh_source" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ssh.cidr_ipv4 == "203.0.113.7/32" && aws_vpc_security_group_ingress_rule.ssh.from_port == 22 && aws_vpc_security_group_ingress_rule.ssh.to_port == 22
    error_message = "SSH must be allowed from the admin address on port 22 and nothing else"
  }
}

# SSH from the whole internet is refused
run "ssh_from_the_whole_internet_is_refused" {
  command = plan

  variables {
    admin_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.admin_cidr]
}

# a value that is not a CIDR is refused
run "a_value_that_is_not_a_cidr_is_refused" {
  command = plan

  variables {
    admin_cidr = "not-an-address"
  }

  expect_failures = [var.admin_cidr]
}

# the bastion requires IMDSv2 and encrypts its disk
run "the_bastion_requires_imdsv2_and_encrypts_its_disk" {
  command = plan

  assert {
    condition     = aws_instance.bastion.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required"
  }
  assert {
    condition     = aws_instance.bastion.root_block_device[0].encrypted == true
    error_message = "the root volume must be encrypted"
  }
}
