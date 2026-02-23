output "vm_names" {
  description = "Names of all provisioned VMs."
  value       = [for name in keys(nutanix_virtual_machine.windows_vm) : name]
}

output "vm_uuids" {
  description = "Map of VM name to Nutanix VM UUID."
  value       = { for name, vm in nutanix_virtual_machine.windows_vm : name => vm.id }
}

output "static_ips" {
  description = "Map of VM name to assigned static IP."
  value       = { for name, cfg in var.vm_map : name => cfg.static_ip }
}

output "local_admin_username" {
  description = "Local admin username fetched from CyberArk — used by Ansible."
  value       = data.external.cyberark.result.local_admin_username
  sensitive   = true
}

output "local_admin_password" {
  description = "Local admin password fetched from CyberArk — used by Ansible."
  value       = data.external.cyberark.result.local_admin_password
  sensitive   = true
}
