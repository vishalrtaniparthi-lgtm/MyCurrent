$ip = "10.10.10.10"
$adminUser = "Administrator"
$adminPass = ConvertTo-SecureString "password" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($adminUser, $adminPass)

Invoke-Command -ComputerName $ip -Credential $cred -ScriptBlock {
    # --- Join domain ---
    # $domainCred = New-Object PSCredential("asptest.net\sa-vctdeploy", (ConvertTo-SecureString "DomainPasswordHere" -AsPlainText -Force))
    # Write-Host "Joining domain..."
    # Add-Computer -DomainName "asptest.net" -Credential $domainCred -Restart:$false

    # --- Rename paging drive from D: to Q: ---
    $volume = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    if ($volume) {
        Write-Host "Changing drive letter D: to Q:..."
        Set-Volume -DriveLetter D -NewDriveLetter Q
    } else {
        Write-Host "Drive D: not found. Skipping drive rename."
    }

    # --- Check NCPA and CrowdStrike services ---
    $services = @(
        @{ Name = "ncpad"; Display = "NCPA Agent" },
        @{ Name = "CSFalconService"; Display = "CrowdStrike" }
    )

    foreach ($svc in $services) {
        $status = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($status -and $status.Status -eq "Running") {
            Write-Host "$($svc.Display) is running."
        } else {
            Write-Host "$($svc.Display) is NOT running!"
        }
    }
}
