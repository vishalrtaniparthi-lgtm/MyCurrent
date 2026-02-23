<#
.SYNOPSIS
    Step 1 of 2 — Fetch a free IP from phpIPAM and run terraform plan for a new VM.

.DESCRIPTION
    Reads the target cluster config, fetches a free IP from phpIPAM using the
    cluster-specific subnet, writes a per-VM tfvars JSON, selects (or creates)
    a Terraform workspace, and runs terraform plan.

    Run order:
        .\Scripts\build_vm_plan_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"
        .\Scripts\build_vm_apply_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"

.PARAMETER VmName
    Name of the VM. Max 15 characters (NetBIOS limit).

.PARAMETER Cluster
    Cluster folder name under clusters\. E.g. "TCD-NTX-CLS-01".

.PARAMETER Cpu
    vCPUs per socket. Default: 4.

.PARAMETER Sockets
    CPU sockets. Default: 1.

.PARAMETER Memory
    Memory in MiB. Default: 8192.

.EXAMPLE
    .\Scripts\build_vm_plan_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"
    .\Scripts\build_vm_plan_v2.ps1 -VmName "PCH-VM-01" -Cluster "TLO-NTX-CLS-01"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$VmName,
    [Parameter(Mandatory)] [string]$Cluster,
    [ValidateRange(1,64)]  [int]$Cpu     = 4,
    [ValidateRange(1,8)]   [int]$Sockets = 1,
    [ValidateRange(512,524288)] [int]$Memory = 8192
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
# Resolve paths
# ─────────────────────────────────────────────────────────────
$repoRoot      = Resolve-Path (Join-Path $PSScriptRoot "..")
$clusterDir    = Join-Path $repoRoot "clusters\$Cluster"
$clusterTfvars = Join-Path $clusterDir "cluster.tfvars"
$tfvarsDir     = Join-Path $clusterDir "tfvars"
$tfplanDir     = Join-Path $clusterDir "tfplan"
$vmTfvarsPath  = Join-Path $tfvarsDir "$VmName.tfvars.json"
$planFilePath  = Join-Path $tfplanDir "tfplan_output_$VmName.tfplan"

Write-Host ""
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Cluster  : $Cluster"                     -ForegroundColor Cyan
Write-Host "  VM Name  : $VmName"                      -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

if (-not (Test-Path $clusterTfvars)) {
    Write-Error "Cluster config not found: $clusterTfvars`nCreate it under clusters\$Cluster\cluster.tfvars"
    exit 1
}

# Create runtime directories
foreach ($dir in @($tfvarsDir, $tfplanDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-Host "  Created: $dir" -ForegroundColor DarkGray
    }
}

# ─────────────────────────────────────────────────────────────
# Parse cluster.tfvars for subnet info needed by phpIPAM
# ─────────────────────────────────────────────────────────────
function Get-TfVarValue([string]$FilePath, [string]$VarName) {
    $content = Get-Content $FilePath -Raw
    if ($content -match "(?m)^\s*$VarName\s*=\s*`"?([^`"\r\n]+)`"?") {
        return $Matches[1].Trim().Trim('"')
    }
    throw "Could not find '$VarName' in $FilePath"
}

$subnetCidr   = Get-TfVarValue $clusterTfvars "subnet_cidr"
$ipamSubnetId = [int](Get-TfVarValue $clusterTfvars "ipam_subnet_id")
$gateway      = Get-TfVarValue $clusterTfvars "gateway"
$dns1         = Get-TfVarValue $clusterTfvars "dns1"
$dns2         = Get-TfVarValue $clusterTfvars "dns2"
$prefix       = [int](Get-TfVarValue $clusterTfvars "prefix")

Write-Host "  Subnet   : $subnetCidr (ID: $ipamSubnetId)" -ForegroundColor DarkGray
Write-Host "  Gateway  : $gateway"                         -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────
# Fetch free IP from phpIPAM using cluster-specific subnet
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

$freeIpResult = & $fetchScript -Subnet $subnetCidr -SubnetId $ipamSubnetId
$staticIP     = ($freeIpResult | ConvertFrom-Json).ip

if ([string]::IsNullOrWhiteSpace($staticIP)) {
    Write-Error "No IP returned from fetchfreeip.ps1 for subnet $subnetCidr"
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
            prefix               = $prefix
            gateway              = $gateway
            dns1                 = $dns1
            dns2                 = $dns2
        }
    }
}

$vmConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $vmTfvarsPath -Encoding UTF8
Write-Host "  Saved: $vmTfvarsPath" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# Terraform init + workspace + plan
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  terraform init"                           -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

Push-Location $clusterDir
try {
    # Verify Azure login for backend state
    $azCtx = az account show 2>$null | ConvertFrom-Json
    if (-not $azCtx) {
        Write-Host "  Logging into Azure for state backend..." -ForegroundColor Yellow
        az login --output none
        $azCtx = az account show | ConvertFrom-Json
    }
    Write-Host "  Azure subscription: $($azCtx.name)" -ForegroundColor DarkGray

    terraform init -reconfigure
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed (exit $LASTEXITCODE)" }

    # Workspace scoped per VM name
    $workspaceName = $VmName.ToLower()
    Write-Host "  Selecting workspace: $workspaceName"

    $workspaces = terraform workspace list |
        ForEach-Object { $_.Trim().TrimStart('*').Trim() }

    if ($workspaces -contains $workspaceName) {
        terraform workspace select $workspaceName | Out-Null
    } else {
        terraform workspace new $workspaceName | Out-Null
    }

    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  terraform plan"                           -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

    terraform plan `
        -var-file="cluster.tfvars" `
        -var-file="$vmTfvarsPath" `
        -out="$planFilePath"

    if ($LASTEXITCODE -ne 0) { throw "terraform plan failed (exit $LASTEXITCODE)" }

} finally {
    Pop-Location
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Plan complete!"                                     -ForegroundColor Green
Write-Host "  Cluster  : $Cluster"                               -ForegroundColor Green
Write-Host "  VM       : $VmName"                                -ForegroundColor Green
Write-Host "  IP       : $staticIP"                              -ForegroundColor Green
Write-Host ""
Write-Host "  When ready:" -ForegroundColor Green
Write-Host "  .\Scripts\build_vm_apply_v2.ps1 -VmName $VmName -Cluster $Cluster" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
