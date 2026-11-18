# Offline tests for the app module (mocked AWS provider, nothing is created). `apply` against the mock gives
# resource ids to compare, so wiring between security groups can be checked too.
mock_provider "aws" {
  # The mock invents random strings for ids; these attributes are validated by the provider, so give them real shapes.
  # Security group ids are left alone on purpose: each group keeps its own random id, which makes the wiring assertions meaningful.
  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-north-1:123456789012:loadbalancer/app/t-alb/0123456789abcdef"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-north-1:123456789012:targetgroup/t-web/0123456789abcdef"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-north-1:123456789012:t-alarms"
    }
  }
  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }
}

variables {
  name               = "t"
  vpc_id             = "vpc-12345678"
  public_subnet_ids  = ["subnet-aaaa1111", "subnet-bbbb2222"]
  private_subnet_ids = ["subnet-cccc3333", "subnet-dddd4444"]
  bastion_sg_id      = "sg-0bastion0000000000"
  key_name           = "t-bastion"
}

# the load balancer is the only public way in
run "the_load_balancer_is_the_only_public_way_in" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_http.from_port == 80 && aws_vpc_security_group_ingress_rule.alb_http.to_port == 80
    error_message = "the load balancer should accept only port 80"
  }
  assert {
    condition     = aws_security_group.alb.id != aws_security_group.web.id
    error_message = "the mock gave both security groups the same id, so the wiring assertions below would prove nothing"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_http.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.web_http.referenced_security_group_id == aws_security_group.alb.id
    error_message = "web instances must accept HTTP only from the load balancer's security group"
  }
}

# SSH to the web tier comes only from the bastion's security group
run "ssh_to_the_web_tier_comes_only_from_the_bastion_s_security_group" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.web_ssh.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.web_ssh.referenced_security_group_id == "sg-0bastion0000000000"
    error_message = "SSH to the web tier must come from the bastion security group, not from a CIDR"
  }
}

# web instances require IMDSv2 and encrypted gp3 disks
run "web_instances_require_imdsv2_and_encrypted_gp3_disks" {
  command = apply

  assert {
    condition     = aws_launch_template.web.metadata_options[0].http_tokens == "required" && aws_launch_template.web.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 must be required with a hop limit of 1"
  }
  assert {
    condition     = aws_launch_template.web.block_device_mappings[0].ebs[0].encrypted == "true" && aws_launch_template.web.block_device_mappings[0].ebs[0].volume_type == "gp3"
    error_message = "the root volume must be an encrypted gp3 volume"
  }
}

# the health check is what the recovery numbers in the README assume
run "the_health_check_is_what_the_recovery_numbers_in_the_readme_assume" {
  command = apply

  assert {
    condition     = aws_lb_target_group.web.health_check[0].path == "/health" && aws_lb_target_group.web.health_check[0].interval == 10 && aws_lb_target_group.web.health_check[0].unhealthy_threshold == 2
    error_message = "health check changed: /health every 10 s, unhealthy after 2 failures"
  }
}

# the web tier scales between 2 and 4 and tracks 50% CPU
run "the_web_tier_scales_between_2_and_4_and_tracks_50_cpu" {
  command = apply

  assert {
    condition     = aws_autoscaling_group.web.min_size == 2 && aws_autoscaling_group.web.max_size == 4 && aws_autoscaling_group.web.health_check_type == "ELB"
    error_message = "Auto Scaling group bounds or health check type changed"
  }
  assert {
    condition     = aws_autoscaling_policy.cpu.target_tracking_configuration[0].target_value == 50
    error_message = "the CPU target changed from 50%"
  }
}

# Every alarm tells the same SNS topic, so subscribing one address is enough to hear about all of them.
run "all_alarms_notify_the_shared_topic" {
  command = apply

  assert {
    condition = alltrue([
      for a in [
        aws_cloudwatch_metric_alarm.unhealthy_hosts,
        aws_cloudwatch_metric_alarm.elb_5xx,
        aws_cloudwatch_metric_alarm.target_5xx,
        aws_cloudwatch_metric_alarm.capacity,
        aws_cloudwatch_metric_alarm.cpu_high,
      ] : length(a.alarm_actions) == 1 && contains(a.alarm_actions, aws_sns_topic.alarms.arn)
    ])
    error_message = "an alarm does not notify the shared topic"
  }
}

# The capacity alarm follows the group's minimum and treats "no data" as a problem.
run "capacity_alarm_follows_the_minimum" {
  command = apply

  variables {
    min_size = 3
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.capacity.threshold == 3 && aws_cloudwatch_metric_alarm.capacity.treat_missing_data == "breaching"
    error_message = "the capacity alarm must use the group's minimum and treat missing data as breaching"
  }
}

run "user_facing_error_alarms_use_the_expected_thresholds" {
  command = apply

  assert {
    condition     = aws_cloudwatch_metric_alarm.elb_5xx.metric_name == "HTTPCode_ELB_5XX_Count" && aws_cloudwatch_metric_alarm.elb_5xx.threshold == 5 && aws_cloudwatch_metric_alarm.elb_5xx.period == 60
    error_message = "the load balancer 5xx alarm changed"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.unhealthy_hosts.metric_name == "UnHealthyHostCount" && aws_cloudwatch_metric_alarm.unhealthy_hosts.threshold == 0
    error_message = "the unhealthy-host alarm changed"
  }
}
