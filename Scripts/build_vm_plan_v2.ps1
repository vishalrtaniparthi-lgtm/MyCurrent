# ===============================
# Script parameters (MUST be first)
# ===============================
param(
  [Parameter(Mandatory = $true)] [string]$VmName,
  [int]$Cpu     = 4,
  [int]$Sockets = 1,
  [int]$Memory  = 8192,
  [int]$Prefix  = 24,
  [string]$Gateway = "10.10.1.1",
  [string]$Dns1    = "10.10.11.51",
  [string]$Dns2    = "10.10.12.52"
)

# ===============================
# Guardrail: Terraform root check
# ===============================
function Assert-TerraformRoot {
    param([string]$TerraformRoot)

    foreach ($file in @("main.tf", "variables.tf")) {
        if (-not (Test-Path (Join-Path $TerraformRoot $file))) {
            Write-Error @"
Terraform root validation failed.

Expected '$file' in:
  $TerraformRoot

This script must be run from the Terraform repo root
(or from the scripts folder inside it).
"@
            exit 1
        }
    }
}

# ===============================
# Resolve Terraform root (repo root)
# ===============================
$tfDir = Resolve-Path (Join-Path $PSScriptRoot "..")

# FAIL FAST if this is not the Terraform root
Assert-TerraformRoot -TerraformRoot $tfDir

# ===============================
# Paths
# ===============================
$tfvarsDir    = Join-Path $tfDir "tfvars"
$stateDir     = Join-Path $tfDir "StateFiles"
$vmTfvarsPath = Join-Path $tfvarsDir "$VmName.tfvars.json"
$tfplanDir = "$tfDir\\tfplan"
if (-not (Test-Path $tfplanDir)) {
    New-Item -Path $tfplanDir -ItemType Directory | Out-Null
}

$planFilePath = "$tfplanDir\\tfplan_output_$VmName.tfplan"

New-Item -ItemType Directory -Force -Path $tfvarsDir | Out-Null
New-Item -ItemType Directory -Force -Path $stateDir  | Out-Null

# ===============================
# Fetch static IP from phpIPAM
# ===============================
Write-Host "Fetching IP from phpIPAM..."
$freeIpResult = & (Join-Path $PSScriptRoot "fetchfreeip_v2.ps1")
$staticIP     = ($freeIpResult | ConvertFrom-Json).ip

if (-not $staticIP) {
    Write-Error "No IP returned from fetchfreeip_v2.ps1. Aborting."
    exit 1
}

Write-Host "IP assigned: $staticIP"

# ===============================
# Build tfvars content
# ===============================
$vmConfig = @{
  vm_map = @{
    "$VmName" = @{
      num_sockets          = $Sockets
      num_vcpus_per_socket = $Cpu
      memory_size_mib      = $Memory
      static_ip            = $staticIP
      prefix               = $Prefix
      gateway              = $Gateway
      dns1                 = $Dns1
      dns2                 = $Dns2
    }
  }
}

$vmConfig |
  ConvertTo-Json -Depth 5 |
  Set-Content -Path $vmTfvarsPath -Encoding UTF8

Write-Host "Created tfvars for $VmName : $vmTfvarsPath"

# ===============================
# Terraform init + workspace
# ===============================
Set-Location $tfDir
terraform init -upgrade

Write-Host "Selecting Terraform workspace: $VmName"
$workspaceName = $VmName.ToLower()
$workspaces = terraform workspace list |
    ForEach-Object { $_.Trim().TrimStart('*').Trim() }

if ($workspaces -contains $workspaceName) {
    terraform workspace select $workspaceName | Out-Null
} else {
    terraform workspace new $workspaceName | Out-Null
}

# ===============================
# Terraform plan
# ===============================
Write-Host "Running terraform plan for $VmName"

$tfArgs = @(
  "plan",
  "-var-file=$vmTfvarsPath",
  "-out=$planFilePath"
)

& terraform @tfArgs

if ($LASTEXITCODE -eq 0) {
    Write-Host "Plan saved to $planFilePath"
} else {
    Write-Error "Terraform plan failed."
    exit 1
}
