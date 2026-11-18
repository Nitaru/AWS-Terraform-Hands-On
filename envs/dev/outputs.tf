output "url" {
  value = "http://${module.app.alb_dns_name}"
}

output "bastion_ip" {
  value = module.bastion.public_ip
}
output "alarm_topic_arn" { value = module.app.alarm_topic_arn }
output "dashboard_name" { value = module.app.dashboard_name }
