terraform {
  required_providers {
    nutanix = {
      source  = "nutanix/nutanix"
      version = "2.2.0"
    }
  }
}

module "vms" {
  source            = "../../modules/nutanix-vm"
  nutanix_endpoint  = var.nutanix_endpoint
  cluster_uuid      = var.cluster_uuid
  subnet_uuid       = var.subnet_uuid
  custom_image_uuid = var.custom_image_uuid
  paging_disk_uuid  = var.paging_disk_uuid
  domain_name       = var.domain_name
  vm_map            = var.vm_map
}
