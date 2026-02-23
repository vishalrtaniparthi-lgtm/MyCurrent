<#
.SYNOPSIS
    Step 2 of 2 — Apply a saved Terraform plan and run Ansible post-boot config.

.DESCRIPTION
    Applies the .tfplan saved by build_vm_plan_v2.ps1, then immediately triggers
    the Ansible postboot playbook against the newly provisioned VM using credentials
    fetched from CyberArk.

    Run order:
        .\Scripts\build_vm_plan_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"
        .\Scripts\build_vm_apply_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"

.PARAMETER VmName
    Name of the VM. Must match what was used in build_vm_plan_v2.ps1.

.PARAMETER Cluster
    Cluster folder name under clusters\. E.g. "TCD-NTX-CLS-01".

.PARAMETER SkipAnsible
    Skip the Ansible post-boot step. Useful for debugging Terraform-only issues.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$VmName,
    [Parameter(Mandatory)] [string]$Cluster,
    [switch]$SkipAnsible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────
# Resolve paths
# ─────────────────────────────────────────────────────────────
$repoRoot      = Resolve-Path (Join-Path $PSScriptRoot "..")
$clusterDir    = Join-Path $repoRoot "clusters\$Cluster"
$clusterTfvars = Join-Path $clusterDir "cluster.tfvars"
$tfvarsDir     = Join-Path $clusterDir "tfvars"
$tfplanDir     = Join-Path $clusterDir "tfplan"
$vmTfvarsPath  = Join-Path $tfvarsDir "$VmName.tfvars.json"
$planFilePath  = Join-Path $tfplanDir "tfplan_output_${VmName}.tfplan"
$ansibleDir    = Join-Path $repoRoot "ansible"

Write-Host ""
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Cluster  : $Cluster"                     -ForegroundColor Cyan
Write-Host "  VM Name  : $VmName"                      -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

if (-not (Test-Path $clusterDir)) {
    Write-Error "Cluster directory not found: $clusterDir"
    exit 1
}

if (-not (Test-Path $planFilePath)) {
    Write-Error "Plan file not found: $planFilePath`nRun the plan script first:`n  .\Scripts\build_vm_plan_v2.ps1 -VmName $VmName -Cluster $Cluster"
    exit 1
}

# Read static IP from tfvars JSON for Ansible
$vmTfvars = Get-Content $vmTfvarsPath | ConvertFrom-Json
$staticIP  = $vmTfvars.vm_map.$VmName.static_ip

# ─────────────────────────────────────────────────────────────
# Terraform init + workspace select + apply
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  terraform init"                           -ForegroundColor Cyan
Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

Push-Location $clusterDir
try {
    # Verify Azure login
    $azCtx = az account show 2>$null | ConvertFrom-Json
    if (-not $azCtx) {
        Write-Host "  Logging into Azure for state backend..." -ForegroundColor Yellow
        az login --output none
        $azCtx = az account show | ConvertFrom-Json
    }
    Write-Host "  Azure subscription: $($azCtx.name)" -ForegroundColor DarkGray

    terraform init -reconfigure
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed (exit $LASTEXITCODE)" }

    $workspaceName = $VmName.ToLower()
    Write-Host "  Selecting workspace: $workspaceName"

    $workspaces = terraform workspace list |
        ForEach-Object { $_.Trim().TrimStart('*').Trim() }

    if ($workspaces -contains $workspaceName) {
        terraform workspace select $workspaceName | Out-Null
    } else {
        Write-Error "Workspace '$workspaceName' not found. Run the plan script first."
        exit 1
    }

    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  terraform apply"                          -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

    terraform apply "$planFilePath"
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed (exit $LASTEXITCODE)" }

} finally {
    Pop-Location
}

Write-Host ""
Write-Host "  VM deployed: $VmName ($staticIP)" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# Ansible post-boot configuration
# ─────────────────────────────────────────────────────────────
if ($SkipAnsible) {
    Write-Host "  Skipping Ansible (--SkipAnsible specified)." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  Waiting for VM to finish booting..."     -ForegroundColor Cyan
    Write-Host "  (WinRM on port 5986 — up to 10 mins)"   -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

    # Wait for WinRM HTTPS port to be available (max 10 minutes)
    $maxWait  = 600
    $waited   = 0
    $interval = 15
    $winrmUp  = $false

    while ($waited -lt $maxWait) {
        $conn = Test-NetConnection -ComputerName $staticIP -Port 5986 -WarningAction SilentlyContinue
        if ($conn.TcpTestSucceeded) {
            $winrmUp = $true
            Write-Host "  WinRM is up after ${waited}s." -ForegroundColor Green
            break
        }
        Write-Host "  Waiting... (${waited}s elapsed)" -ForegroundColor DarkGray
        Start-Sleep -Seconds $interval
        $waited += $interval
    }

    if (-not $winrmUp) {
        Write-Warning "WinRM did not become available within ${maxWait}s. Run Ansible manually:`n  ansible-playbook ansible/postboot.yml -i $staticIP,"
    } else {
        # Fetch credentials from CyberArk for Ansible
        Write-Host "  Fetching credentials for Ansible..." -ForegroundColor Cyan
        $credsJson = & (Join-Path $PSScriptRoot "CyberFetchallCreds.ps1") | ConvertFrom-Json
        $adminUser = $credsJson.local_admin_username
        $adminPass = $credsJson.local_admin_password

        Write-Host ""
        Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host "  Running Ansible postboot playbook..."    -ForegroundColor Cyan
        Write-Host "──────────────────────────────────────────" -ForegroundColor Cyan

        Push-Location $repoRoot
        try {
            ansible-playbook "$ansibleDir\postboot.yml" `
                -i "$staticIP," `
                -e "target_vm=$staticIP" `
                -e "ansible_user=$adminUser" `
                -e "ansible_password=$adminPass" `
                -e "ansible_winrm_server_cert_validation=ignore" `
                -e "vm_name=$VmName"

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Ansible postboot playbook failed. Check output above."
            } else {
                Write-Host "  Ansible postboot complete." -ForegroundColor Green
            }
        } finally {
            Pop-Location
        }
    }
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Deploy complete!"                                   -ForegroundColor Green
Write-Host "  Cluster : $Cluster"                                 -ForegroundColor Green
Write-Host "  VM      : $VmName"                                  -ForegroundColor Green
Write-Host "  IP      : $staticIP"                                -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
