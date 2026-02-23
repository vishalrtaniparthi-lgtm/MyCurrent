variable "nutanix_endpoint" {
  type        = string
  description = "Prism Central hostname or IP."
}

variable "cluster_uuid" {
  type        = string
  description = "UUID of the Nutanix cluster to deploy on."
}

variable "subnet_uuid" {
  type        = string
  description = "UUID of the Nutanix subnet to attach VMs to."
}

variable "custom_image_uuid" {
  type        = string
  description = "UUID of the golden Windows image."
}

variable "paging_disk_uuid" {
  type        = string
  description = "UUID of the paging disk image."
}

variable "domain_name" {
  type        = string
  description = "Active Directory domain to join."
}

variable "insecure" {
  type        = bool
  description = "Skip TLS verification for Prism Central. Set true for self-signed certs."
  default     = true
}

variable "vm_map" {
  description = "Map of VM names to per-VM configuration."
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
