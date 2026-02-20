terraform {
  required_providers {
    nutanix = {
      source  = "nutanix/nutanix"
      version = "2.2.0"
    }
  }
}

# ─────────────────────────────────────────────────────────────
# Provider — credentials come from CyberArk at runtime
# NOTE: insecure = true disables SSL verification.
#       Replace with a trusted CA cert in production.
# ─────────────────────────────────────────────────────────────
provider "nutanix" {
  username = local.nutanix_creds.username
  password = local.nutanix_creds.password
  endpoint = var.nutanix_endpoint
  insecure = false  # Set to true only if your Prism CA cert is not trusted by this machine
}

# ─────────────────────────────────────────────────────────────
# External data: CyberArk credential fetch
# ─────────────────────────────────────────────────────────────
data "external" "cyberark" {
  program = [
    "powershell",
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "${path.module}/Scripts/CyberFetchallCreds.ps1"
  ]
}

# ─────────────────────────────────────────────────────────────
# Locals: structured credential access + XML-safe escaping
# ─────────────────────────────────────────────────────────────
locals {
  nutanix_creds = {
    username = data.external.cyberark.result.nutanix_username
    password = data.external.cyberark.result.nutanix_password
  }

  domain_creds = {
    domain   = data.external.cyberark.result.domain_name
    username = data.external.cyberark.result.domain_admin_username
    password = data.external.cyberark.result.domain_admin_password
  }

  local_admin_creds = {
    username = data.external.cyberark.result.local_admin_username
    password = data.external.cyberark.result.local_admin_password
  }

  # Escape XML special characters for safe embedding in unattend.xml
  domain_pass_xml    = replace(replace(replace(local.domain_creds.password, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
  admin_password_xml = replace(replace(replace(local.local_admin_creds.password, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
}

# ─────────────────────────────────────────────────────────────
# VM resource — one per entry in var.vm_map
# ─────────────────────────────────────────────────────────────
resource "nutanix_virtual_machine" "windows_vm" {
  for_each = var.vm_map

  name                 = each.key
  cluster_uuid         = var.cluster_uuid
  num_vcpus_per_socket = each.value.num_vcpus_per_socket
  num_sockets          = each.value.num_sockets
  memory_size_mib      = each.value.memory_size_mib
  boot_type            = "LEGACY"
  boot_device_order_list = ["CDROM", "DISK"]
  use_hot_add          = true

  # OS disk — cloned from golden image
  disk_list {
    disk_size_mib = 102400
    device_properties {
      device_type = "DISK"
    }
    data_source_reference = {
      kind = "image"
      uuid = var.custom_image_uuid
    }
  }

  # Paging disk — attached as a raw disk, initialized by postboot.ps1
  disk_list {
    disk_size_mib = 0
    device_properties {
      device_type = "DISK"
    }
    data_source_reference = {
      kind = "image"
      uuid = var.paging_disk_uuid
    }
  }

  nic_list {
    subnet_uuid  = var.subnet_uuid
    is_connected = true
  }

  guest_customization_is_overridable = true

  guest_customization_sysprep = {
    install_type = "PREPARED"
    unattend_xml = base64encode(templatefile("${path.module}/SysPrep/unattend.xml", {
      static_ip          = each.value.static_ip
      prefix             = each.value.prefix
      gateway            = each.value.gateway
      dns1               = each.value.dns1
      dns2               = each.value.dns2
      vm_name            = each.key
      domain_name        = var.domain_name
      domain_user        = local.domain_creds.username
      domain_pass_xml    = local.domain_pass_xml
      admin_password_xml = local.admin_password_xml
    }))
  }

  # Ignore Sysprep and NIC changes after initial creation —
  # these are one-time setup values that must not trigger replacement.
  lifecycle {
    ignore_changes = [
      guest_customization_sysprep,
      nic_list
    ]
  }
}
