# param(
#   [Parameter(Mandatory = $true)] [string]$VmName
# )

# # Terraform working directory
# $tfDir        = "C:\Users\vtaniparthi\Git\Terraform\Environment\TCD-Windows"
# $planFilePath = "$tfDir\tfplan_output_$VmName.tfplan"

# # Ensure plan file exists
# if (-not (Test-Path $planFilePath)) {
#   Write-Error "❌ Terraform plan file not found: $planFilePath"
#   exit 1
# }



# # Switch to directory
# Set-Location $tfDir

# Write-Host "`n🚀 Running terraform apply for $VmName..."
# terraform apply "$planFilePath"

# if ($LASTEXITCODE -ne 0) {
#   Write-Error "❌ Terraform apply failed."
#   exit 1
# }

# Write-Host "✅ Terraform apply completed for $VmName"

# ===============================
# Script parameters (MUST be first)
# ===============================
param(
  [Parameter(Mandatory = $true)]
  [string]$VmName
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

# FAIL FAST if not a Terraform root
Assert-TerraformRoot -TerraformRoot $tfDir

# ===============================
# Paths
# ===============================
$tfplanDir = Join-Path $tfDir "tfplan"
$planFilePath = Join-Path $tfplanDir "tfplan_output_${VmName}.tfplan"

# Ensure plan file exists
if (-not (Test-Path $planFilePath)) {
    Write-Error "Terraform plan file not found: $planFilePath. Run the plan script first."
    exit 1
}

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
    Write-Error "Terraform workspace '$workspaceName' not found. Run the plan script first."
    exit 1
}

# ===============================
# Terraform apply
# ===============================
Write-Host "Running terraform apply for $VmName..."
terraform apply "$planFilePath"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Terraform apply failed."
    exit 1
}

Write-Host "Terraform apply completed for $VmName"

