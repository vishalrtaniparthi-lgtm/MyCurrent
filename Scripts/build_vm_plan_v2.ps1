<#
.SYNOPSIS
    Step 1 of 2 — Fetch a free IP from phpIPAM and run terraform plan for a new VM.

.DESCRIPTION
    Validates the Terraform repo root, fetches an available IP from phpIPAM,
    writes a per-VM tfvars JSON file, selects (or creates) a Terraform workspace,
    and runs terraform plan, saving the plan output for use by build_vm_apply_v2.ps1.

    Run order:
        .\Scripts\build_vm_plan_v2.ps1 -VmName "MY-VM-01"
        .\Scripts\build_vm_apply_v2.ps1 -VmName "MY-VM-01"

.PARAMETER VmName
    Name of the VM to provision. Must be 15 characters or fewer (NetBIOS limit).

.PARAMETER Cpu
    Number of vCPUs per socket. Default: 4.

.PARAMETER Sockets
    Number of CPU sockets. Default: 1.

.PARAMETER Memory
    Memory in MiB. Default: 8192.

.PARAMETER Prefix
    Network prefix length (CIDR). Default: 24.

.PARAMETER Gateway
    Default gateway IP. Default: 10.10.1.1.

.PARAMETER Dns1
    Primary DNS server. Default: 10.10.11.51.

.PARAMETER Dns2
    Secondary DNS server. Default: 10.10.12.52.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$VmName,
    [ValidateRange(1,64)]  [int]$Cpu     = 4,
    [ValidateRange(1,8)]   [int]$Sockets = 1,
    [ValidateRange(512, 524288)] [int]$Memory  = 8192,
    [ValidateRange(8,30)]  [int]$Prefix  = 24,
    [string]$Gateway = "10.10.1.1",
    [string]$Dns1    = "10.10.11.51",
    [string]$Dns2    = "10.10.12.52"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────────
if ($VmName.Length -gt 15) {
    Write-Error "VmName '$VmName' is $($VmName.Length) chars — Windows NetBIOS limit is 15."
    exit 1
}

# ─────────────────────────────────────────────────────────────
# Guardrail: confirm we can find the Terraform root
# ─────────────────────────────────────────────────────────────
function Assert-TerraformRoot {
    param([string]$TerraformRoot)
    foreach ($file in @("main.tf", "variables.tf")) {
        if (-not (Test-Path (Join-Path $TerraformRoot $file))) {
            Write-Error @"
Terraform root validation failed.

Expected '$file' in:
  $TerraformRoot

Ensure this script lives inside a 'Scripts' subfolder of the Terraform repo root.
"@
            exit 1
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Resolve paths
# ─────────────────────────────────────────────────────────────
$tfDir        = Resolve-Path (Join-Path $PSScriptRoot "..")
$tfvarsDir    = Join-Path $tfDir "tfvars"
$stateDir     = Join-Path $tfDir "StateFiles"
$tfplanDir    = Join-Path $tfDir "tfplan"
$vmTfvarsPath = Join-Path $tfvarsDir "$VmName.tfvars.json"
$planFilePath = Join-Path $tfplanDir "tfplan_output_$VmName.tfplan"

Assert-TerraformRoot -TerraformRoot $tfDir

# Create output directories if they don't exist
foreach ($dir in @($tfvarsDir, $stateDir, $tfplanDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# ─────────────────────────────────────────────────────────────
# Fetch a free static IP from phpIPAM
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Fetching free IP from phpIPAM..."        -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

$fetchScript = Join-Path $PSScriptRoot "fetchfreeip.ps1"
if (-not (Test-Path $fetchScript)) {
    Write-Error "fetchfreeip.ps1 not found at: $fetchScript"
    exit 1
}

$freeIpResult = & $fetchScript
$staticIP     = ($freeIpResult | ConvertFrom-Json).ip

if ([string]::IsNullOrWhiteSpace($staticIP)) {
    Write-Error "No IP returned from fetchfreeip.ps1. Aborting."
    exit 1
}

Write-Host "  IP assigned: $staticIP" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# Write per-VM tfvars JSON
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Writing tfvars for $VmName"              -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

$vmConfig = @{
    vm_map = @{
        $VmName = @{
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

$vmConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $vmTfvarsPath -Encoding UTF8
Write-Host "  Saved: $vmTfvarsPath"

# ─────────────────────────────────────────────────────────────
# Terraform init (no -upgrade on routine runs)
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  terraform init"                           -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

Push-Location $tfDir
try {
    terraform init -reconfigure
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed (exit $LASTEXITCODE)" }

    # ─────────────────────────────────────────────────────────
    # Terraform workspace
    # ─────────────────────────────────────────────────────────
    $workspaceName = $VmName.ToLower()
    Write-Host "  Selecting workspace: $workspaceName"

    $workspaces = terraform workspace list |
        ForEach-Object { $_.Trim().TrimStart('*').Trim() }

    if ($workspaces -contains $workspaceName) {
        terraform workspace select $workspaceName | Out-Null
    } else {
        terraform workspace new $workspaceName | Out-Null
    }

    # ─────────────────────────────────────────────────────────
    # Terraform plan
    # ─────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  terraform plan"                           -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

    terraform plan -var-file="$vmTfvarsPath" -out="$planFilePath"
    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed (exit $LASTEXITCODE)" }

} finally {
    Pop-Location
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Plan complete. Review the output above."           -ForegroundColor Green
Write-Host "  VM       : $VmName"                                -ForegroundColor Green
Write-Host "  IP       : $staticIP"                              -ForegroundColor Green
Write-Host "  Plan file: $planFilePath"                          -ForegroundColor Green
Write-Host ""
Write-Host "  When ready:  .\Scripts\build_vm_apply_v2.ps1 -VmName $VmName" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
