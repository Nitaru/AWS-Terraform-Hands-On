# Offline tests for the network module: the AWS provider is mocked, so nothing is created and no credentials are needed.
# Run with `terraform test` inside this module (or `make test-modules` from the repo root).
mock_provider "aws" {
  # The mock returns random strings for data sources; the IAM role needs real JSON for its trust policy.
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-north-1:123456789012:log-group:/vpc/t/flow"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/t-flow-logs"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name = "t"
  azs  = ["eu-north-1a", "eu-north-1b"]
}

# two public and two private subnets in the expected ranges
run "two_public_and_two_private_subnets_in_the_expected_ranges" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "expected one public and one private subnet per availability zone"
  }
  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.20.0.0/24" && aws_subnet.private[0].cidr_block == "10.20.10.0/24"
    error_message = "subnet ranges changed: public starts at 10.20.0.0/24, private at 10.20.10.0/24"
  }
}

# public subnets never hand out public IPs on their own
run "public_subnets_never_hand_out_public_ips_on_their_own" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "a public subnet auto-assigns public IPs; they must be attached explicitly"
  }
}

# one NAT gateway by default
run "one_nat_gateway_by_default" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "expected exactly one NAT gateway and one Elastic IP"
  }
}

# no NAT gateway and no default route when NAT is disabled
run "no_nat_gateway_and_no_default_route_when_nat_is_disabled" {
  command = apply # the route set is only known after apply (against the mock)

  variables {
    enable_nat = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_eip.nat) == 0
    error_message = "NAT resources exist although enable_nat is false"
  }
  assert {
    condition     = length(aws_route_table.private.route) == 0
    error_message = "the private route table has a route although there is no NAT gateway"
  }
}

# flow logs capture all traffic and are kept for a year
run "flow_logs_capture_all_traffic_and_are_kept_for_a_year" {
  command = plan

  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "flow logs must capture ACCEPT and REJECT traffic"
  }
  assert {
    condition     = aws_cloudwatch_log_group.flow.retention_in_days == 365
    error_message = "flow log retention changed from 365 days"
  }
}
