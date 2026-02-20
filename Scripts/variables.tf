# ─────────────────────────────────────────────────────────────
# Nutanix connection
# ─────────────────────────────────────────────────────────────
variable "nutanix_endpoint" {
  type        = string
  description = "Hostname or IP of the Nutanix Prism Central endpoint."
}

# ─────────────────────────────────────────────────────────────
# Infrastructure UUIDs
# ─────────────────────────────────────────────────────────────
variable "custom_image_uuid" {
  type        = string
  description = "UUID of the golden Windows image to clone from."
}

variable "paging_disk_uuid" {
  type        = string
  description = "UUID of the paging disk image to attach."
}

variable "subnet_uuid" {
  type        = string
  description = "UUID of the Nutanix subnet to connect VMs to."
}

variable "cluster_uuid" {
  type        = string
  description = "UUID of the Nutanix cluster to deploy VMs on."
}

# ─────────────────────────────────────────────────────────────
# Domain
# ─────────────────────────────────────────────────────────────
variable "domain_name" {
  type        = string
  description = "Active Directory domain to join (e.g. corp.example.com)."
}

# ─────────────────────────────────────────────────────────────
# VM map — one entry per VM to provision
# ─────────────────────────────────────────────────────────────
variable "vm_map" {
  description = "Map of VM names to their individual configuration. One entry = one VM."
  type = map(object({
    num_sockets          = number
    num_vcpus_per_socket = number
    memory_size_mib      = number
    static_ip            = string
    prefix               = number
    gateway              = string
    dns1                 = string
    dns2                 = string
  }))
}

# ─────────────────────────────────────────────────────────────
# Default sizing (used when not overridden per-VM in vm_map)
# ─────────────────────────────────────────────────────────────
variable "vm_name" {
  type        = string
  description = "Single VM name (used for workspace naming / legacy support)."
  default     = ""
}

variable "num_sockets" {
  type        = number
  description = "Default number of CPU sockets."
  default     = 1
}

variable "num_vcpus_per_socket" {
  type        = number
  description = "Default number of vCPUs per socket."
  default     = 2
}

variable "memory_size_mib" {
  type        = number
  description = "Default memory in MiB."
  default     = 4096
}
