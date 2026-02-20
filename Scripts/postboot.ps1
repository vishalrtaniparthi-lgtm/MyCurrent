<#
.SYNOPSIS
    Post-boot configuration for newly provisioned Windows Server 2022 VMs.

.DESCRIPTION
    Runs as SYSTEM via the "PostBootSetup" scheduled task registered by
    unattend.xml FirstLogonCommands.  Safe to re-run — every step is
    idempotent and checks current state before acting.

    Actions performed:
      1. Initialize Disk 1 (GPT), create partition, format NTFS, assign Q:
      2. Move Windows paging file from C: to Q:
      3. Disable IPv6 on all adapters and via registry
      4. Self-remove the PostBootSetup scheduled task
      5. Reboot once to activate paging file

.NOTES
    Log written to C:\Windows\Logs\PostBoot.log
    Script location  : C:\Windows\Setup\Scripts\PostBoot.ps1
    Scheduled task   : PostBootSetup (ONSTART / SYSTEM / HIGHEST)
    Task is removed  : automatically at end of this script
#>

#Requires -RunAsAdministrator

$LogFile  = "C:\Windows\Logs\PostBoot.log"
$TaskName = "PostBootSetup"

# ─────────────────────────────────────────────────────────────
# Logging helper — writes to file and console
# ─────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    $colour = switch ($Level) {
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host $line -ForegroundColor $colour
}

# Ensure log directory exists
$logDir = Split-Path $LogFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-Log "═══════════════════════════════════════════"
Write-Log "PostBoot.ps1 started"
Write-Log "Running as : $($env:USERNAME)"
Write-Log "Computer   : $($env:COMPUTERNAME)"
Write-Log "═══════════════════════════════════════════"


# ═══════════════════════════════════════════════════════════════
# STEP 1 — Initialize Disk 1 and assign Q:
#
# Disk 1 is the raw data disk attached by Terraform.
# Idempotent — checks state at each sub-step before acting.
# Edge cases handled:
#   • Disk already initialized (skip init, still check partition)
#   • Q: letter already in use by a CD-ROM or other device
#     (reassign that device to a high letter first)
#   • Partition exists but Q: not assigned
# ═══════════════════════════════════════════════════════════════
Write-Log "--- STEP 1: Disk 1 initialization ---"

# Check if Q: is already occupied by something else (e.g. CD-ROM)
$existingQ = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq "Q:" }
if ($existingQ -and $existingQ.DriveType -ne 3) {
    # DriveType 3 = local fixed disk — if it's not our disk, reassign it
    Write-Log "Q: is currently assigned to drive type $($existingQ.DriveType) — reassigning it to Z:" "WARN"
    try {
        $vol = Get-WmiObject -Class Win32_Volume | Where-Object { $_.DriveLetter -eq "Q:" }
        if ($vol) {
            $vol.DriveLetter = "Z:"
            $vol.Put() | Out-Null
            Write-Log "Reassigned existing Q: to Z:"
        }
    } catch {
        Write-Log "Could not reassign Q: — will attempt to set Q: on Disk 1 anyway: $_" "WARN"
    }
}

try {
    $disk = Get-Disk -Number 1 -ErrorAction Stop
    Write-Log "Disk 1 found: $($disk.FriendlyName) | Size: $([math]::Round($disk.Size/1GB,1)) GB | Style: $($disk.PartitionStyle)"

    # ── Initialize if RAW ──
    if ($disk.PartitionStyle -eq 'RAW') {
        Write-Log "Disk 1 is RAW — initializing as GPT"
        Initialize-Disk -Number 1 -PartitionStyle GPT -ErrorAction Stop
        Write-Log "Disk 1 initialized as GPT"
        # Brief pause to let the disk manager settle
        Start-Sleep -Seconds 3
    } else {
        Write-Log "Disk 1 already initialized ($($disk.PartitionStyle)) — skipping init"
    }

    # ── Create partition and format if Q: doesn't exist ──
    if (Test-Path "Q:\") {
        Write-Log "Q: drive already exists — skipping partition/format"
    } else {
        # Check if there's already a data partition on Disk 1 without a letter
        $existingPart = Get-Partition -DiskNumber 1 -ErrorAction SilentlyContinue |
                        Where-Object { $_.Type -eq 'Basic' -or $_.Type -eq 'IFS' }

        if ($existingPart) {
            Write-Log "Partition exists on Disk 1 but Q: not assigned — assigning drive letter"
            Set-Partition -InputObject $existingPart -NewDriveLetter Q -ErrorAction Stop
        } else {
            Write-Log "Creating new partition on Disk 1 (max size)"
            $partition = New-Partition -DiskNumber 1 -UseMaximumSize -DriveLetter Q -ErrorAction Stop
            Write-Log "Partition created. Formatting as NTFS with label DATA"
            Format-Volume -DriveLetter Q -FileSystem NTFS `
                          -NewFileSystemLabel "DATA" `
                          -AllocationUnitSize 65536 `
                          -Confirm:$false -ErrorAction Stop
            Write-Log "Disk 1 formatted and assigned Q:"
        }
    }

    Write-Log "STEP 1 complete — Q: drive is ready"

} catch {
    Write-Log "STEP 1 FAILED: $_" "ERROR"
    Write-Log "Disk setup did not complete. Paging file will NOT be moved." "ERROR"
}


# ═══════════════════════════════════════════════════════════════
# STEP 2 — Move paging file to Q:
#
# Uses CIM (preferred in PS 5+) with WMI fallback.
# Idempotent — skips if pagefile already on Q:.
# Sets system-managed size (0/0) so Windows auto-sizes it.
# ═══════════════════════════════════════════════════════════════
Write-Log "--- STEP 2: Paging file configuration ---"

if (-not (Test-Path "Q:\")) {
    Write-Log "Q: drive not available — skipping pagefile move" "WARN"
} else {
    try {
        # Check if pagefile is already on Q:
        $currentPF = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue
        $alreadyOnQ = $currentPF | Where-Object { $_.Name -like "Q:*" }

        if ($alreadyOnQ) {
            Write-Log "Paging file already configured on Q: — skipping"
        } else {
            Write-Log "Disabling automatic pagefile management"

            # Disable automatic management (required before manual config)
            $cs = Get-WmiObject -Class Win32_ComputerSystem
            if ($cs.AutomaticManagedPagefile) {
                $cs.AutomaticManagedPagefile = $false
                $cs.Put() | Out-Null
                Write-Log "Automatic managed pagefile disabled"
            }

            # Remove all existing pagefile settings
            foreach ($pf in $currentPF) {
                Write-Log "Removing existing pagefile: $($pf.Name)"
                $pf.Delete()
            }

            # Create pagefile on Q: — size 0/0 = system managed
            $newPF = Set-WmiInstance -Class Win32_PageFileSetting `
                         -Arguments @{
                             Name        = "Q:\pagefile.sys"
                             InitialSize = 0
                             MaximumSize = 0
                         } -ErrorAction Stop
            Write-Log "Paging file created at Q:\pagefile.sys (system-managed size)"
        }

        Write-Log "STEP 2 complete"

    } catch {
        Write-Log "STEP 2 FAILED: $_" "ERROR"
        Write-Log "Paging file may still be on C: — check manually after reboot." "ERROR"
    }
}


# ═══════════════════════════════════════════════════════════════
# STEP 3 — Disable IPv6
#
# Two-layer approach:
#   a) Registry key DisabledComponents=0xFF  — disables all IPv6
#      components system-wide, persists across reboots
#   b) Disable ms_tcpip6 binding on every adapter  — immediate
#      effect without requiring reboot on most adapters
# ═══════════════════════════════════════════════════════════════
Write-Log "--- STEP 3: Disable IPv6 ---"

try {
    # Registry method
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    $current = (Get-ItemProperty -Path $regPath -Name DisabledComponents -ErrorAction SilentlyContinue).DisabledComponents
    if ($current -eq 0xFF) {
        Write-Log "Registry DisabledComponents already set to 0xFF — skipping"
    } else {
        Set-ItemProperty -Path $regPath -Name "DisabledComponents" -Value 0xFF -Type DWord -Force
        Write-Log "Registry: DisabledComponents set to 0xFF"
    }

    # Adapter binding method
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
    foreach ($adapter in $adapters) {
        try {
            $binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID "ms_tcpip6" -ErrorAction SilentlyContinue
            if ($binding -and $binding.Enabled) {
                Disable-NetAdapterBinding -Name $adapter.Name -ComponentID "ms_tcpip6" -ErrorAction Stop
                Write-Log "IPv6 binding disabled on: $($adapter.Name)"
            } else {
                Write-Log "IPv6 already disabled on: $($adapter.Name)"
            }
        } catch {
            Write-Log "Could not disable IPv6 on $($adapter.Name): $_" "WARN"
        }
    }

    Write-Log "STEP 3 complete"

} catch {
    Write-Log "STEP 3 FAILED: $_" "ERROR"
}


# ═══════════════════════════════════════════════════════════════
# STEP 4 — Remove the scheduled task (self-cleanup)
#
# The PostBootSetup task was registered as ONSTART so it would
# fire as SYSTEM on every boot.  We remove it here so it only
# runs once.  If this step fails the script will re-run on next
# reboot — all steps are idempotent so that is safe.
# ═══════════════════════════════════════════════════════════════
Write-Log "--- STEP 4: Removing scheduled task '$TaskName' ---"

try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Log "Scheduled task '$TaskName' removed"
    } else {
        Write-Log "Scheduled task '$TaskName' not found (already removed or never registered)"
    }
} catch {
    Write-Log "Could not remove scheduled task: $_" "WARN"
    Write-Log "Task may re-run on next boot — all steps are idempotent." "WARN"
}


# ═══════════════════════════════════════════════════════════════
# Final log and reboot
# ═══════════════════════════════════════════════════════════════
Write-Log "═══════════════════════════════════════════"
Write-Log "PostBoot.ps1 completed"
Write-Log "Rebooting in 15 seconds to activate paging file..."
Write-Log "═══════════════════════════════════════════"

Start-Sleep -Seconds 15
Restart-Computer -Force
