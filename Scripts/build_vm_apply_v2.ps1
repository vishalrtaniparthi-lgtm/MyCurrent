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

    Ansible modes:
      Option A — Ansible installed locally on this machine (no extra params needed):
        .\Scripts\build_vm_apply_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01"

      Option B — Trigger Ansible remotely via SSH on a Linux control node:
        .\Scripts\build_vm_apply_v2.ps1 -VmName "TCD-VM-01" -Cluster "TCD-NTX-CLS-01" `
            -AnsibleHost "TCD-ANS-LNX-01" -AnsibleUser "ansibleadmin" `
            -AnsibleRepoPath "/home/ansibleadmin/MyCurrent"

.PARAMETER VmName
    Name of the VM. Must match what was used in build_vm_plan_v2.ps1.

.PARAMETER Cluster
    Cluster folder name under clusters\. E.g. "TCD-NTX-CLS-01".

.PARAMETER SkipAnsible
    Skip the Ansible post-boot step entirely. Useful for debugging Terraform-only issues.

.PARAMETER AnsibleHost
    (Option B) Hostname or IP of the Linux Ansible control node (e.g. TCD-ANS-LNX-01).
    When provided, the playbook is triggered via SSH instead of running locally.

.PARAMETER AnsibleUser
    (Option B) SSH username on the Ansible control node. Default: ansibleadmin.

.PARAMETER AnsibleRepoPath
    (Option B) Absolute path to the MyCurrent repo clone on the control node.
    Default: /home/ansibleadmin/MyCurrent
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$VmName,
    [Parameter(Mandatory)] [string]$Cluster,
    [switch]$SkipAnsible,

    # Option B parameters — leave blank to run Ansible locally (Option A)
    [string]$AnsibleHost      = "",
    [string]$AnsibleUser      = "ansibleadmin",
    [string]$AnsibleRepoPath  = "/home/ansibleadmin/MyCurrent"
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
if ($AnsibleHost) {
    Write-Host "  Ansible  : $AnsibleUser@$AnsibleHost (Option B - remote SSH)" -ForegroundColor Cyan
} else {
    Write-Host "  Ansible  : local (Option A)"          -ForegroundColor Cyan
}
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
    Write-Host "  Skipping Ansible (-SkipAnsible specified)." -ForegroundColor Yellow
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
        Write-Warning "WinRM did not become available within ${maxWait}s."
        Write-Host ""
        Write-Host "  Run Ansible manually on TCD-ANS-LNX-01:" -ForegroundColor Yellow
        Write-Host "    cd ~/MyCurrent && git pull" -ForegroundColor Yellow
        Write-Host "    ansible-playbook ansible/postboot.yml -i `"$staticIP,`" -e `"target_vm=$staticIP vm_name=$VmName`"" -ForegroundColor Yellow
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

        if ($AnsibleHost) {
            # ─────────────────────────────────────────────────────────────
            # OPTION B: SSH into the Linux control node and run playbook there
            # Requires: SSH key-based auth from this machine to $AnsibleHost
            # Setup:    ssh-keygen then ssh-copy-id ansibleadmin@TCD-ANS-LNX-01
            # ─────────────────────────────────────────────────────────────
            Write-Host "  Mode: Option B — Remote SSH to $AnsibleUser@$AnsibleHost" -ForegroundColor Cyan

            # Escape single quotes in password for bash safety
            $escapedPass = $adminPass -replace "'", "'\'''"

            # Build the bash command to run on the remote Linux host
            $remoteCmd = "cd $AnsibleRepoPath && git pull --quiet && " +
                         "ansible-playbook ansible/postboot.yml " +
                         "-i '$staticIP,' " +
                         "-e 'target_vm=$staticIP' " +
                         "-e 'ansible_user=$adminUser' " +
                         "-e 'ansible_password=$escapedPass' " +
                         "-e 'ansible_winrm_server_cert_validation=ignore' " +
                         "-e 'vm_name=$VmName'"

            ssh -o StrictHostKeyChecking=no -o BatchMode=yes `
                "${AnsibleUser}@${AnsibleHost}" `
                $remoteCmd

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Ansible postboot playbook failed on $AnsibleHost. Check output above."
            } else {
                Write-Host "  Ansible postboot complete (via $AnsibleHost)." -ForegroundColor Green
            }

        } else {
            # ─────────────────────────────────────────────────────────────
            # OPTION A: Run ansible-playbook locally on this Windows machine
            # Requires: WSL or Cygwin with Ansible + pywinrm installed
            # ─────────────────────────────────────────────────────────────
            Write-Host "  Mode: Option A — Local ansible-playbook" -ForegroundColor Cyan

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
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Deploy complete!"                                   -ForegroundColor Green
Write-Host "  Cluster : $Cluster"                                 -ForegroundColor Green
Write-Host "  VM      : $VmName"                                  -ForegroundColor Green
Write-Host "  IP      : $staticIP"                                -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
