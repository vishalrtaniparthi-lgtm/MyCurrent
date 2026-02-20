# ─────────────────────────────────────────────────────────────
# terraform.tfvars — Non-secret infrastructure values only.
#
# IMPORTANT:
#   - Never put credentials (passwords, usernames) in this file.
#   - Credentials are fetched at runtime from CyberArk.
#   - Replace xxx-xxx placeholder UUIDs with real values.
# ─────────────────────────────────────────────────────────────

# Nutanix Prism Central endpoint (no credentials here)
nutanix_endpoint = "prismcentral.corp.net"

# Domain
domain_name = "test.net"

# Infrastructure UUIDs — update with your actual values
custom_image_uuid = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
paging_disk_uuid  = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
subnet_uuid       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
cluster_uuid      = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# VM name (used for workspace naming)
vm_name = "TCF-TST-11"
