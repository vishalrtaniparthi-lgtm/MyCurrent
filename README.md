# MyCurrent — Nutanix VM Provisioning Automation

Terraform + Ansible workflow for deploying Windows VMs on Nutanix Prism Central.
Credentials are fetched at runtime from **CyberArk**. IPs are allocated dynamically from **phpIPAM**.
Terraform state is stored in **Azure Blob Storage**. Post-boot configuration is handled by **Ansible**.

---

## Repo Structure

```
MyCurrent/
├── clusters/
│   ├── TCD-NTX-CLS-01/        # TCD cluster — backend.tf, main.tf, variables.tf, cluster.tfvars
│   └── TLO-NTX-CLS-01/        # TLO cluster — same structure
├── modules/
│   └── nutanix-vm/             # Shared Terraform module (main.tf, variables.tf, outputs.tf)
├── SysPrep/
│   └── unattend.xml            # Windows Sysprep template (static IP, domain join, WinRM bootstrap)
├── ansible/
│   ├── ansible.cfg
│   ├── postboot.yml            # Playbook: WinRM HTTPS, Q-drive, pagefile, IPv6 off, service checks
│   └── roles/windows-postboot/
│       ├── defaults/main.yml
│       └── tasks/main.yml
└── Scripts/
    ├── build_vm_plan_v2.ps1    # Step 1 — fetch IP, write tfvars, terraform plan
    ├── build_vm_apply_v2.ps1   # Step 2 — terraform apply + wait for WinRM + run Ansible
    ├── CyberFetchallCreds.ps1  # Fetches all credentials from CyberArk CCP at runtime
    ├── fetchfreeip.ps1         # Allocates a free IP from phpIPAM for the target subnet
    └── Get-IPAMAddress.ps1     # Helper for phpIPAM API queries
```

---

## Setup & Run Guide

### Checklist

```
PHASE 1 — One-time setup
  [ ] 1A  Tools installed: terraform, az cli, git, ssh
  [ ] 1B  Repo cloned to workstation
  [ ] 1C  Azure Storage Account created for Terraform state
  [ ] 1D  cluster.tfvars filled with real UUIDs (both clusters)
  [ ] 1E  CyberArk object names verified in CyberFetchallCreds.ps1
  [ ] 1F  SSH key copied from workstation to TCD-ANS-LNX-01
  [ ] 1G  pywinrm installed + repo cloned on TCD-ANS-LNX-01
  [ ] 1H  SysPrep/unattend.xml in place and pushed to GitHub

PHASE 2 — Dry run (no VM created)
  [ ] DRY-1  CyberArk test
  [ ] DRY-2  phpIPAM test
  [ ] DRY-3  terraform init only
  [ ] DRY-4  Full plan run (no apply)
  [ ] DRY-5  SSH key test to TCD-ANS-LNX-01
  [ ] DRY-6  Ansible win_ping against an existing Windows VM

PHASE 3 — Real deployment
  [ ] Step 1  build_vm_plan_v2.ps1
  [ ] Step 2  build_vm_apply_v2.ps1
```

---

## PHASE 1 — One-Time Setup

### 1A. Confirm prerequisites are installed

Open PowerShell and run:

```powershell
terraform -version   # Terraform v1.x.x
az version           # azure-cli 2.x.x
git --version
ssh -V               # OpenSSH_for_Windows
```

Install anything missing:
- Terraform: https://developer.hashicorp.com/terraform/install
- Azure CLI: `winget install Microsoft.AzureCLI`
- Git: https://git-scm.com/download/win

---

### 1B. Clone the repo

```powershell
cd C:\Users\raovi
git clone https://github.com/vishalrtaniparthi-lgtm/MyCurrent.git
cd MyCurrent
```

If already cloned:
```powershell
cd C:\Users\raovi\MyCurrent
git pull
```

---

### 1C. Create the Azure Storage Account for Terraform state

Run once in PowerShell:

```powershell
az login

$RG   = "rg-terraform-state"
$SA   = "stterraformstate"     # must be globally unique, lowercase, 3-24 chars
$CONT = "tfstate"
$LOC  = "eastus"               # change to your Azure region

az group create --name $RG --location $LOC
az storage account create --name $SA --resource-group $RG --location $LOC --sku Standard_LRS --kind StorageV2
az storage container create --name $CONT --account-name $SA
```

Confirm the name matches both `backend.tf` files:
```hcl
# clusters/TCD-NTX-CLS-01/backend.tf  AND  clusters/TLO-NTX-CLS-01/backend.tf
storage_account_name = "stterraformstate"   # must match exactly
resource_group_name  = "rg-terraform-state"
container_name       = "tfstate"
```

---

### 1D. Fill in real UUIDs in cluster.tfvars

Edit `clusters\TCD-NTX-CLS-01\cluster.tfvars`:

```hcl
nutanix_endpoint  = "tcd-prism.corp.net"       # Prism Central FQDN or IP

cluster_uuid      = "PASTE-REAL-UUID-HERE"      # Prism > Infrastructure > Clusters > click cluster > URL
subnet_uuid       = "PASTE-REAL-UUID-HERE"      # Prism > Network > Subnets > click subnet > URL
custom_image_uuid = "PASTE-REAL-UUID-HERE"      # Prism > Compute & Storage > Images > Windows golden image > URL
paging_disk_uuid  = "PASTE-REAL-UUID-HERE"      # Prism > Compute & Storage > Images > paging disk image > URL

domain_name       = "corp.net"
gateway           = "10.12.110.1"
dns1              = "10.10.11.51"
dns2              = "10.10.12.52"
subnet_cidr       = "10.12.110.0/24"
ipam_subnet_id    = 33                          # phpIPAM > Subnets > click subnet > ID in URL
prefix            = 24
```

Do the same for `clusters\TLO-NTX-CLS-01\cluster.tfvars` with TLO-specific values.

---

### 1E. Verify CyberArk object names

Open `Scripts\CyberFetchallCreds.ps1` and confirm lines 25-29 match your environment:

```powershell
[string]$AppID       = "VMAutomation"
[string]$Safe        = "WEB-NUTANIX"
[string]$CyberArkURL = "https://cyberarkapi.corp.net"
```

And the three object names (lines ~64-80):
```powershell
-Object "PrismCentralAdmin"                          # Nutanix Prism credentials
-Object "Website-WEB-NUTANIX-test.net-Administrator" # Local admin credentials
-Object "Website-ASP-P-WEB-NUTANIX-test.net-deploy"  # Domain join credentials
```

These must match exactly what is registered in your CyberArk vault.

---

### 1F. Set up SSH key from workstation to TCD-ANS-LNX-01

Required for `build_vm_apply_v2.ps1` to SSH in non-interactively (Option B).

```powershell
# Generate SSH key (skip if C:\Users\raovi\.ssh\id_ed25519 already exists)
ssh-keygen -t ed25519 -C "build-automation" -f "$env:USERPROFILE\.ssh\id_ed25519"
# Press Enter twice for no passphrase

# Copy public key to control node (replace 'ansibleadmin' with your actual username)
type "$env:USERPROFILE\.ssh\id_ed25519.pub" | ssh ansibleadmin@TCD-ANS-LNX-01 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
# Enter your password once — last time

# Test: should connect with NO password prompt
ssh ansibleadmin@TCD-ANS-LNX-01 "echo SSH_KEY_AUTH_WORKS"
# Expected: SSH_KEY_AUTH_WORKS
```

---

### 1G. Set up TCD-ANS-LNX-01 (Ansible control node)

SSH in and run once:

```bash
ssh ansibleadmin@TCD-ANS-LNX-01

# Install pywinrm — required for Ansible to talk WinRM to Windows VMs
pip3 install pywinrm requests-ntlm

# Clone repo onto the control node
cd ~
git clone https://github.com/vishalrtaniparthi-lgtm/MyCurrent.git
# If already cloned: cd ~/MyCurrent && git pull

# Verify
ansible-doc win_shell | head -5
python3 -c "import winrm; print('pywinrm OK')"

exit
```

---

### 1H. Confirm SysPrep/unattend.xml is in place

The Terraform module references `SysPrep/unattend.xml` at the repo root level.

```powershell
Test-Path "C:\Users\raovi\MyCurrent\SysPrep\unattend.xml"
# If False:
New-Item -ItemType Directory -Force "C:\Users\raovi\MyCurrent\SysPrep"
Copy-Item "C:\Users\raovi\MyCurrent\Scripts\unattend.xml" "C:\Users\raovi\MyCurrent\SysPrep\unattend.xml"

# Push it
cd C:\Users\raovi\MyCurrent
git add SysPrep/unattend.xml
git commit -m "Add SysPrep/unattend.xml"
git push origin main
```

---

## PHASE 2 — Dry Run (Nothing Created in Nutanix)

### DRY-1: Test CyberArk credentials

```powershell
cd C:\Users\raovi\MyCurrent
.\Scripts\CyberFetchallCreds.ps1 | ConvertFrom-Json | Format-List
```

Expected output:
```
nutanix_username      : prism_admin
nutanix_password      : ************
local_admin_username  : Administrator
local_admin_password  : ************
domain_admin_username : svc_deploy
domain_admin_password : ************
```

Fix any object name mismatches before continuing.

---

### DRY-2: Test phpIPAM IP allocation

```powershell
# Use your actual subnet CIDR and phpIPAM subnet ID from cluster.tfvars
.\Scripts\fetchfreeip.ps1 -Subnet "10.12.110.0/24" -SubnetId 33
```

Expected output:
```
Fetching used IPs for subnet ID 33 (10.12.110.0/24)...
  Selected free IP: 10.12.110.21
{"ip":"10.12.110.21"}
```

---

### DRY-3: Test Azure login and Terraform init only

```powershell
az login
az account show    # confirm correct subscription

cd C:\Users\raovi\MyCurrent\clusters\TCD-NTX-CLS-01
terraform init -reconfigure
```

Expected:
```
Successfully configured the backend "azurerm"!
Terraform has been successfully initialized!
```

Fix any storage account name mismatch in `backend.tf` if this fails.

---

### DRY-4: Full plan run — no apply, nothing created

```powershell
cd C:\Users\raovi\MyCurrent

.\Scripts\build_vm_plan_v2.ps1 -VmName "TCD-DRY-01" -Cluster "TCD-NTX-CLS-01"
```

This will:
1. Log in to Azure if needed
2. Fetch a free IP from phpIPAM
3. Write `clusters\TCD-NTX-CLS-01\tfvars\TCD-DRY-01.tfvars.json`
4. Run `terraform init` then `terraform plan`

Expected final output:
```
Plan: 1 to add, 0 to change, 0 to destroy.
Plan complete!
  VM  : TCD-DRY-01
  IP  : 10.12.110.21
```

Review the plan — confirm correct VM name, IP, cluster UUID, disk sizes.
**Do NOT run the apply script against this plan** — discard it after review.

---

### DRY-5: Test SSH to Ansible control node

```powershell
ssh -o BatchMode=yes ansibleadmin@TCD-ANS-LNX-01 "ansible --version && python3 -c 'import winrm; print(\"pywinrm OK\")'"
```

Expected:
```
ansible [core 2.x.x]
pywinrm OK
```

---

### DRY-6: Test Ansible WinRM against an existing Windows VM

SSH into TCD-ANS-LNX-01 and run:

```bash
ssh ansibleadmin@TCD-ANS-LNX-01

# Replace 10.12.110.X with a real existing VM on the same subnet
ansible -i "10.12.110.X," all \
  -m win_ping \
  -e "ansible_connection=winrm" \
  -e "ansible_winrm_transport=ntlm" \
  -e "ansible_winrm_scheme=https" \
  -e "ansible_port=5986" \
  -e "ansible_winrm_server_cert_validation=ignore" \
  -e "ansible_user=Administrator" \
  -e "ansible_password=YourPassword"
```

Expected:
```
10.12.110.X | SUCCESS => {"changed": false, "ping": "pong"}
```

This confirms the network path from `TCD-ANS-LNX-01` to the VM subnet is open on port 5986.

---

## PHASE 3 — Full Deployment

### Step 1: Plan

```powershell
cd C:\Users\raovi\MyCurrent

# Basic (defaults: 4 vCPU, 1 socket, 8192 MiB RAM)
.\Scripts\build_vm_plan_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"

# Custom sizing
.\Scripts\build_vm_plan_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01" -Cpu 8 -Memory 16384
```

Review the plan output. When satisfied, proceed to Step 2.

---

### Step 2: Apply + Ansible

```powershell
# Option B — recommended (Ansible runs on TCD-ANS-LNX-01)
.\Scripts\build_vm_apply_v2.ps1 `
    -VmName "TCD-VM-01" `
    -Cluster "TCD-NTX-CLS-01" `
    -AnsibleHost "TCD-ANS-LNX-01" `
    -AnsibleUser "ansibleadmin" `
    -AnsibleRepoPath "/home/ansibleadmin/MyCurrent"

# Option A — local Ansible (WSL required)
.\Scripts\build_vm_apply_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"

# Terraform only, skip Ansible
.\Scripts\build_vm_apply_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01" -SkipAnsible
```

**What happens automatically:**
1. `terraform apply` — provisions VM in Nutanix (sysprep runs, static IP set, domain joined)
2. Polls port 5986 every 15s — waits up to 10 minutes for WinRM to come up
3. Fetches credentials from CyberArk
4. SSHes into `TCD-ANS-LNX-01` → `git pull` → runs `ansible-playbook postboot.yml`
5. Ansible tasks on the new VM:
   - Creates WinRM HTTPS certificate + listener on port 5986
   - Initialises Disk 1 → Q: drive (NTFS, 64K allocation unit)
   - Moves pagefile to Q:\
   - Disables IPv6
   - Checks ncpad + CrowdStrike (CSFalconService) are running
   - Reboots if pagefile was moved

---

## Parameter Reference

### build_vm_plan_v2.ps1

| Parameter  | Required | Default | Description |
|------------|----------|---------|-------------|
| `-VmName`  | Yes      | —       | VM name, max 15 chars (NetBIOS limit) |
| `-Cluster` | Yes      | —       | Folder name under `clusters\` |
| `-Cpu`     | No       | `4`     | vCPUs per socket |
| `-Sockets` | No       | `1`     | CPU sockets |
| `-Memory`  | No       | `8192`  | RAM in MiB |

### build_vm_apply_v2.ps1

| Parameter           | Required       | Default                          | Description |
|---------------------|----------------|----------------------------------|-------------|
| `-VmName`           | Yes            | —                                | Must match plan script |
| `-Cluster`          | Yes            | —                                | Must match plan script |
| `-SkipAnsible`      | No             | off                              | Skip Ansible, Terraform only |
| `-AnsibleHost`      | No (Option B)  | —                                | Linux control node hostname/IP |
| `-AnsibleUser`      | No (Option B)  | `ansibleadmin`                   | SSH username on control node |
| `-AnsibleRepoPath`  | No (Option B)  | `/home/ansibleadmin/MyCurrent`   | Repo path on control node |

---

## Ansible Postboot Role — What It Does

| Task | Details |
|------|---------|
| WinRM HTTPS | Creates self-signed cert, HTTPS listener on port 5986, opens firewall, sets service to auto-start |
| Q: drive | Initialises Disk 1 (GPT), creates partition, formats NTFS with 64K allocation unit, labels DATA |
| Pagefile | Disables auto-managed, deletes existing pagefile, sets Q:\pagefile.sys, triggers reboot |
| IPv6 | Disables via registry (0xFF) and adapter binding |
| Services | Warns if ncpad or CSFalconService are not running (does not fail the playbook) |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Bad Request` from Nutanix on apply | Wrong UUID in `cluster.tfvars` — verify all 4 UUIDs against Prism Central |
| Static IP not applied (169.x.x.x in Prism) | `RouterDiscoveryEnabled` must be `false` in `unattend.xml` — destroy and redeploy |
| Prism shows 169.x.x.x but VM has correct IP | NGT not installed — informational only, not blocking |
| `terraform init` backend error | Storage account name mismatch in `backend.tf` or not logged into Azure |
| `Workspace not found` on apply | Plan script was not run first for this VM/cluster combination |
| Ansible SSH fails | SSH key not set up — re-run Step 1F |
| `import winrm` error on Ansible node | Run `pip3 install pywinrm requests-ntlm` on TCD-ANS-LNX-01 |
| WinRM timeout (10 min) | VM still booting — run Ansible manually once VM is up |
