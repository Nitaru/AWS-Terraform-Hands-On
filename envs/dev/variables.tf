variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "admin_cidr" {
  description = "Your public IP as a /32, the only address that may SSH to the bastion"
  type        = string
}

variable "public_key" {
  description = "Contents of your SSH public key (e.g. ~/.ssh/id_ed25519.pub)"
  type        = string
}

variable "enable_nat" {
  description = "NAT gateway for private instances (costs about $0.045/hour)"
  type        = bool
  default     = true
}

variable "health_check_interval" {
  description = "Seconds between load balancer health checks (see docs/health-check-experiment.md)"
  type        = number
  default     = 10
}

variable "health_check_timeout" {
  description = "Seconds to wait for one health check answer; must be below the interval"
  type        = number
  default     = 5
}
