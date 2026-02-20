# ─────────────────────────────────────────────────────────────
# VM names
# ─────────────────────────────────────────────────────────────
output "vm_names" {
  description = "Names of all provisioned VMs."
  value       = [for name in keys(nutanix_virtual_machine.windows_vm) : name]
}

# ─────────────────────────────────────────────────────────────
# VM UUIDs
# ─────────────────────────────────────────────────────────────
output "vm_uuids" {
  description = "Map of VM name to Nutanix VM UUID."
  value       = { for name, vm in nutanix_virtual_machine.windows_vm : name => vm.id }
}

# ─────────────────────────────────────────────────────────────
# Static IPs (from vm_map input)
# ─────────────────────────────────────────────────────────────
output "static_ips" {
  description = "Map of VM name to assigned static IP address."
  value       = { for name, cfg in var.vm_map : name => cfg.static_ip }
}

# ─────────────────────────────────────────────────────────────
# Sysprep configs — marked sensitive (contains rendered passwords)
# ─────────────────────────────────────────────────────────────
output "rendered_vm_configs" {
  description = "Rendered guest customization Sysprep configs per VM (sensitive — base64-encoded unattend.xml)."
  value       = { for name in keys(nutanix_virtual_machine.windows_vm) : name => "base64-encoded unattend.xml (sensitive)" }
  sensitive   = true
}
