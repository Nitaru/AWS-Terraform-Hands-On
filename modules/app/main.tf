terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "name" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "bastion_sg_id" { type = string }
variable "key_name" { type = string }
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "min_size" {
  type    = number
  default = 2
}
variable "max_size" {
  type    = number
  default = 4
}

data "aws_region" "current" {}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# --- security groups: the load balancer is the only way in -------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public HTTP into the load balancer"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  #checkov:skip=CKV_AWS_260:The load balancer is the public entry point, port 80 from anywhere is the point
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_security_group" "web" {
  name        = "${var.name}-web"
  description = "Web instances: HTTP from the load balancer, SSH from the bastion"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "web_http" {
  #checkov:skip=CKV_AWS_260:False positive: the source is the ALB security group, not 0.0.0.0/0
  security_group_id            = aws_security_group.web.id
  description                  = "HTTP from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "web_ssh" {
  #checkov:skip=CKV_AWS_24:False positive: the source is the bastion security group, not 0.0.0.0/0
  security_group_id            = aws_security_group.web.id
  description                  = "SSH from the bastion only"
  referenced_security_group_id = var.bastion_sg_id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "web_out" {
  security_group_id = aws_security_group.web.id
  description       = "Outbound for package installs (through NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Load balancer to web instances"
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# --- load balancer ------------------------------------------------------------

resource "aws_lb" "this" {
  #checkov:skip=CKV_AWS_150:Demo stack must be destroyable; set true in a real environment
  #checkov:skip=CKV_AWS_91:Access logs need an S3 bucket and policy; out of scope for the demo
  #checkov:skip=CKV2_AWS_20:No domain or certificate in the demo, so there is no HTTPS to redirect to
  #checkov:skip=CKV2_AWS_28:WAF costs about $5/month plus rules; documented as the next step
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "web" {
  #checkov:skip=CKV_AWS_378:Traffic between the ALB and instances stays inside the VPC
  name     = "${var.name}-web"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Plain HTTP because there is no domain in this demo. With a domain this becomes
# an ACM certificate, an HTTPS listener and a redirect on port 80.
resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:No domain in the demo; see the comment above for the HTTPS version
  #checkov:skip=CKV_AWS_103:Applies to HTTPS listeners only
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# --- instances ----------------------------------------------------------------

resource "aws_launch_template" "web" {
  name_prefix            = "${var.name}-web-"
  image_id               = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.web.id]
  ebs_optimized          = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  monitoring { enabled = true }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type = "gp3"
      volume_size = 8
      encrypted   = true
    }
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx fail2ban
    cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'CONF'
    PasswordAuthentication no
    PermitRootLogin no
    MaxAuthTries 3
    CONF
    systemctl restart ssh
    TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
    ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    echo "served by $ID in $AZ" > /var/www/html/index.html
    echo ok > /var/www/html/health
    systemctl enable --now nginx fail2ban
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-web" }
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "web" {
  name                      = "${var.name}-web"
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.min_size
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180
  # One-minute group metrics (free) so the capacity alarm below has data.
  enabled_metrics = ["GroupInServiceInstances"]

  tag {
    key                 = "Name"
    value               = "${var.name}-web"
    propagate_at_launch = true
  }

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  # Changing the template replaces instances gradually, never all at once.
  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 50 }
  }
}

# Scale to hold average CPU near 50%.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 50
  }
}

output "alb_dns_name" { value = aws_lb.this.dns_name }
output "web_security_group_id" { value = aws_security_group.web.id }

# --- monitoring: alarms and a dashboard ----------------------------------------
# Before this, the only monitoring was VPC flow logs. These alarms watch what users feel (5xx from the load balancer or
# the instances), what the load balancer knows (unhealthy targets) and what the Auto Scaling group holds (capacity).

resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = "alias/aws/sns"
}

locals {
  lb_dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name}-unhealthy-hosts"
  alarm_description   = "The load balancer sees at least one unhealthy web instance"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.lb_dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "elb_5xx" {
  alarm_name          = "${var.name}-elb-5xx"
  alarm_description   = "The load balancer itself returned 5xx (for example no healthy target): users are seeing errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name}-target-5xx"
  alarm_description   = "The web instances returned 5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.lb_dimensions
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "capacity" {
  alarm_name          = "${var.name}-capacity-below-minimum"
  alarm_description   = "Fewer web instances are in service than the minimum"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web.name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no data from the group at all is also a problem
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name}-cpu-high"
  alarm_description   = "Average CPU above 80% for 3 minutes: the group is not scaling out fast enough or has reached its maximum"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_dashboard" "web" {
  dashboard_name = "${var.name}-web"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Requests and 5xx"
          region = data.aws_region.current.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.web.arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Healthy and unhealthy targets"
          region = data.aws_region.current.region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.web.arn_suffix],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.web.arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Instances in service"
          region = data.aws_region.current.region
          stat   = "Minimum"
          period = 60
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.web.name],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "CPU and response time"
          region = data.aws_region.current.region
          period = 60
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.web.name, { stat = "Average" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p95", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}

output "alarm_topic_arn" { value = aws_sns_topic.alarms.arn }
output "dashboard_name" { value = aws_cloudwatch_dashboard.web.dashboard_name }
