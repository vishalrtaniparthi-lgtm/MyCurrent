<#
.SYNOPSIS
    Step 2 of 2 — Apply a previously saved Terraform plan for a VM.

.DESCRIPTION
    Validates the Terraform repo root, locates the saved .tfplan file created
    by build_vm_plan_v2.ps1, selects the correct workspace, and runs terraform apply.

    Run order:
        .\Scripts\build_vm_plan_v2.ps1 -VmName "MY-VM-01"   <- run first
        .\Scripts\build_vm_apply_v2.ps1 -VmName "MY-VM-01"  <- you are here

.PARAMETER VmName
    Name of the VM to apply. Must match what was used in build_vm_plan_v2.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$VmName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────
# Guardrail: confirm Terraform root
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
$tfplanDir    = Join-Path $tfDir "tfplan"
$planFilePath = Join-Path $tfplanDir "tfplan_output_${VmName}.tfplan"

Assert-TerraformRoot -TerraformRoot $tfDir

# ─────────────────────────────────────────────────────────────
# Validate plan file exists
# ─────────────────────────────────────────────────────────────
if (-not (Test-Path $planFilePath)) {
    Write-Error @"
Terraform plan file not found:
  $planFilePath

Run the plan script first:
  .\Scripts\build_vm_plan_v2.ps1 -VmName $VmName
"@
    exit 1
}

# ─────────────────────────────────────────────────────────────
# Terraform init
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
    # Select workspace — must already exist from plan step
    # ─────────────────────────────────────────────────────────
    $workspaceName = $VmName.ToLower()
    Write-Host "  Selecting workspace: $workspaceName"

    $workspaces = terraform workspace list |
        ForEach-Object { $_.Trim().TrimStart('*').Trim() }

    if ($workspaces -contains $workspaceName) {
        terraform workspace select $workspaceName | Out-Null
    } else {
        Write-Error @"
Terraform workspace '$workspaceName' not found.

The workspace is created during the plan step. Run:
  .\Scripts\build_vm_plan_v2.ps1 -VmName $VmName
"@
        exit 1
    }

    # ─────────────────────────────────────────────────────────
    # Terraform apply
    # ─────────────────────────────────────────────────────────
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
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Apply complete!"                                    -ForegroundColor Green
Write-Host "  VM: $VmName"                                       -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
