output "url" {
  value = "http://${module.app.alb_dns_name}"
}

output "bastion_ip" {
  value = module.bastion.public_ip
}
