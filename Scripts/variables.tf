variable "vm_name" { type = string }

variable "num_sockets" { 
  type = number
   default = 1
    }

variable "num_vcpus_per_socket" { 
  type = number
   default = 2
    }

variable "memory_size_mib" { 
  type = number
   default = 4096
    }

variable "nutanix_endpoint" { type = string }

# variable "nutanix_username" { type = string }

# variable "nutanix_password" {
#   type      = string
#   sensitive = true
# }

variable "custom_image_uuid" { type = string }

variable "subnet_uuid" { type = string }

variable "cluster_uuid" { type = string }

variable "paging_disk_uuid" { type = string }

variable "domain_name" { type = string }

# variable "domain_user" { type = string }

# variable "domain_pass" {
#   type      = string
#   sensitive = true
# }

# variable "admin_password" {
#   type      = string
#   sensitive = true
# }



# variable "static_ip" {}
# variable "gateway" {}
# variable "dns1" {}
# variable "dns2" {}

##################################################################################################################

# variable "first_run_script_uri" {
#   type        = string
#   description = "Public URL or internal file share path to the first boot PowerShell script"
# }

# variable "vm_config" {
#   description = "VM configuration passed dynamically"
#   type = object({
#     vm_name              = string
#     memory               = number
#     num_sockets          = number
#     num_vcpus_per_socket = number
#     gateway              = string
#     dns1                 = string
#     dns2                 = string
#   })
# }

#######################################################################################################################
# variables.tf

# variable "vm_config" {
#   description = "Single VM configuration passed dynamically via -var"
#   type = object({
#     vm_name              = string
#     memory               = number
#     num_sockets          = number
#     num_vcpus_per_socket = number
#     gateway              = string
#     dns1                 = string
#     dns2                 = string
#   })
# }

# variable "cluster_uuid" {
#   type        = string
#   description = "UUID of the Nutanix cluster"
# }

# variable "subnet_uuid" {
#   type        = string
#   description = "UUID of the subnet to attach the VM"
# }

# variable "image_uuid" {
#   type        = string
#   description = "UUID of the image to clone from"
# }

# variable "admin_password" {
#   type        = string
#   description = "Local admin password for the VM"
#   sensitive   = true
# }

# variable "domain_name" {
#   type        = string
#   description = "Domain to join"
# }

# variable "domain_user" {
#   type        = string
#   description = "Domain join user"
# }

# variable "domain_pass" {
#   type        = string
#   description = "Domain join password"
#   sensitive   = true
# }

# variable "static_ip" {
#   type        = string
#   description = "Static IP to assign to the VM"
# }

# variable "prefix" {
#   type        = number
#   description = "CIDR prefix for the static IP"
# }

variable "vm_map" {
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



