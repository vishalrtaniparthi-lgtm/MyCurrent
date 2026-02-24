
output "vm_name" {
  value       = [ for name in keys(nutanix_virtual_machine.windows_vm) : name]
  description = "VM name"
}

output "vm_uuid" {
  value       = { for name, vm in nutanix_virtual_machine.windows_vm : name => vm.id }
  description = "VM UUID"
}

# output "debug_static_ip" {
#   value = local.static_ip
# }

# output "static_ip_from_script" {
#   value = local.static_ip
# }

# output "ip_address" {
#   value = nutanix_virtual_machine.virtual_machine_1.nic_list_status[0].ip_endpoint_list[0].ip
# }

output "rendered_vm_configs" {
description = "Rendered guest customization Sysprep per VM (sensitive)"
value = {
for name in keys(nutanix_virtual_machine.windows_vm) :
name => "Rendered via templatefile - base64encoded unattend.xml"
}
sensitive = true
}

output "static_ips" {
  description = "Static IPs assigned to each VM"
  value = {
    for name, cfg in var.vm_map :
    name => cfg.static_ip
  }
}
