<#
.SYNOPSIS
    Fetches a free IP from phpIPAM using credentials from CyberArk AIM REST.

.DESCRIPTION
    Authenticates to CyberArk to retrieve phpIPAM credentials, then queries
    phpIPAM for used IPs in the target subnet, calculates available addresses,
    and outputs the selected free IP as compressed JSON for Terraform.

.PARAMETER phpIPAMUrl
    Base URL of the phpIPAM API. Default: https://phpipam.corp.net/api

.PARAMETER phpIPAMAppID
    phpIPAM API application ID. Default: terraform

.PARAMETER Subnet
    CIDR subnet to search for free IPs. Default: 10.10.10.0/24

.PARAMETER SubnetId
    phpIPAM internal subnet ID for the target subnet. Default: 33

.PARAMETER SkipCount
    Number of usable IPs to skip from the start of the range (reserves
    low addresses for infrastructure). Default: 10

.PARAMETER CyberArkUrl
    Base URL of the CyberArk CCP (AIM Web Service).

.PARAMETER CyberArkAppID
    CyberArk Application ID for phpIPAM credential retrieval.

.PARAMETER CyberArkSafe
    CyberArk Safe containing the phpIPAM credential object.

.PARAMETER CyberArkObject
    CyberArk Object name for the phpIPAM account.
#>

param(
    [string]$phpIPAMUrl     = "https://phpipam.corp.net/api",
    [string]$phpIPAMAppID   = "terraform",
    [string]$Subnet         = "10.10.10.0/24",
    [int]   $SubnetId       = 33,
    [int]   $SkipCount      = 10,

    # CyberArk CCP (AIM REST)
    [string]$CyberArkUrl    = "https://cyberarkapi.corp.net",
    [string]$CyberArkAppID  = "VMAutomation",
    [string]$CyberArkSafe   = "P-US-WEB-NUTANIX",
    [string]$CyberArkObject = "PHPUser"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ─────────────────────────────────────────────────────────────
# Step 1: Retrieve phpIPAM credentials from CyberArk
# ─────────────────────────────────────────────────────────────
Write-Host "Retrieving phpIPAM credentials from CyberArk..." -ForegroundColor Cyan

try {
    $ccpUri = "$CyberArkUrl/AIMWebService/api/Accounts" +
              "?AppID=$([uri]::EscapeDataString($CyberArkAppID))" +
              "&Safe=$([uri]::EscapeDataString($CyberArkSafe))" +
              "&Folder=ROOT" +
              "&Object=$([uri]::EscapeDataString($CyberArkObject))"

    $ccpResponse = Invoke-RestMethod `
        -Method  Get `
        -Uri     $ccpUri `
        -UseDefaultCredentials `
        -SkipCertificateCheck `
        -ErrorAction Stop

    $ipamUser = $ccpResponse.UserName
    $ipamPass = $ccpResponse.Content

    if ([string]::IsNullOrWhiteSpace($ipamPass)) {
        throw "CyberArk returned an empty password for object: $CyberArkObject"
    }

    Write-Host "  Retrieved phpIPAM credentials for: $ipamUser" -ForegroundColor Green
}
catch {
    [Console]::Error.WriteLine("CyberArk credential fetch failed: $($_.Exception.Message)")
    exit 1
}

# ─────────────────────────────────────────────────────────────
# Step 2: Authenticate to phpIPAM
# ─────────────────────────────────────────────────────────────
Write-Host "Authenticating to phpIPAM..." -ForegroundColor Cyan

try {
    $base64  = [Convert]::ToBase64String(
                   [System.Text.Encoding]::UTF8.GetBytes("${ipamUser}:${ipamPass}"))

    $authHeaders = @{
        Authorization  = "Basic $base64"
        "Content-Type" = "application/json"
    }

    $authResponse = Invoke-RestMethod `
        -Method  Post `
        -Uri     "$phpIPAMUrl/$phpIPAMAppID/user/" `
        -Headers $authHeaders `
        -ErrorAction Stop

    $token       = $authResponse.data.token
    $ipamHeaders = @{ "phpipam-token" = $token }

    Write-Host "  Authenticated successfully." -ForegroundColor Green
}
catch {
    [Console]::Error.WriteLine("phpIPAM authentication failed: $($_.Exception.Message)")
    exit 1
}

# ─────────────────────────────────────────────────────────────
# Step 3: Get used IPs for the subnet
# ─────────────────────────────────────────────────────────────
Write-Host "Fetching used IPs for subnet ID $SubnetId ($Subnet)..." -ForegroundColor Cyan

try {
    $ipResponse = Invoke-RestMethod `
        -Uri     "$phpIPAMUrl/$phpIPAMAppID/subnets/$SubnetId/addresses/" `
        -Headers $ipamHeaders `
        -ErrorAction Stop

    $usedIps = $ipResponse.data | ForEach-Object { $_.ip }
    Write-Host "  Used IPs found: $($usedIps.Count)" -ForegroundColor Green
}
catch {
    [Console]::Error.WriteLine("Failed to retrieve IP list for subnet ID ${SubnetId}: $($_.Exception.Message)")
    exit 1
}

# ─────────────────────────────────────────────────────────────
# IP math helpers
# ─────────────────────────────────────────────────────────────
function ConvertTo-DecimalIP([string]$ip) {
    $p = $ip -split '\.'
    return ([int]$p[0] * 16777216) +
           ([int]$p[1] * 65536)    +
           ([int]$p[2] * 256)      +
           ([int]$p[3])
}

function ConvertFrom-DecimalIP([long]$num) {
    return "$([math]::Floor($num / 16777216))." +
           "$([math]::Floor(($num % 16777216) / 65536))." +
           "$([math]::Floor(($num % 65536) / 256))." +
           "$($num % 256)"
}

function Get-UsableIPRange([string]$cidr) {
    $parts  = $cidr -split '/'
    $base   = ConvertTo-DecimalIP $parts[0]
    $prefix = [int]$parts[1]
    $count  = [math]::Pow(2, 32 - $prefix)
    # Skip network address (+0) and broadcast (+last); return usable range
    1..($count - 2) | ForEach-Object { ConvertFrom-DecimalIP ($base + $_) }
}

# ─────────────────────────────────────────────────────────────
# Step 4: Find and select a free IP
# ─────────────────────────────────────────────────────────────
$allIps     = Get-UsableIPRange -cidr $Subnet
$freeIps    = $allIps | Where-Object { $_ -notin $usedIps }
$selectedIp = $freeIps | Select-Object -Skip $SkipCount -First 1

if ([string]::IsNullOrWhiteSpace($selectedIp)) {
    [Console]::Error.WriteLine("No free IPs found in subnet $Subnet after skipping $SkipCount addresses.")
    exit 1
}

Write-Host "  Selected free IP: $selectedIp" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
# Output — Terraform external data source expects JSON to stdout
# ─────────────────────────────────────────────────────────────
@{ ip = $selectedIp } | ConvertTo-Json -Compress
