# ─────────────────────────────────────────────────────────────
# cluster.tfvars — TCD-NTX-CLS-01
# Non-secret cluster-specific values only.
# Credentials are fetched from CyberArk at runtime.
# ─────────────────────────────────────────────────────────────

nutanix_endpoint  = "tcd-prism.corp.net"
cluster_uuid      = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
subnet_uuid       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
custom_image_uuid = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
paging_disk_uuid  = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
domain_name       = "corp.net"

# Network defaults for this cluster's subnet
gateway           = "10.12.110.1"
dns1              = "10.10.11.51"
dns2              = "10.10.12.52"
subnet_cidr       = "10.12.110.0/24"
ipam_subnet_id    = 33
prefix            = 24
