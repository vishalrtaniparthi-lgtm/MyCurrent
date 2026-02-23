variable "nutanix_endpoint"  { type = string }
variable "cluster_uuid"      { type = string }
variable "subnet_uuid"        { type = string }
variable "custom_image_uuid"  { type = string }
variable "paging_disk_uuid"   { type = string }
variable "domain_name"        { type = string }
variable "gateway"            { type = string }
variable "dns1"               { type = string }
variable "dns2"               { type = string }
variable "subnet_cidr"        { type = string }
variable "ipam_subnet_id"     { type = number }
variable "prefix"             { type = number }

variable "vm_map" {
  description = "Map of VM names to their configuration. Populated at runtime by build_vm_plan_v2.ps1."
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
  default = {}
}
