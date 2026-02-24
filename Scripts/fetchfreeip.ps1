param(
    [string]$phpIPAMUrl     = "https://phpipam.adamsstreetpartners.net/api",
    [string]$phpIPAMAppID   = "terraform",
    [string]$subnet         = "10.12.110.0/24",
    [int]$subnetId          = 33,

    # CyberArk CCP (AIM REST)
    [string]$cyberarkUrl    = 'https://cyberarkapi.adamsstreetpartners.net/',
    [string]$cyberarkAppID  = "VMAutomation",
    [string]$cyberarkSafe   = "P-US-WEB-NUTANIX",
    [string]$cyberarkObject = "PHPApiUser",

     [switch]$Quiet
)

# Always emit JSON as UTF-8 without BOM
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function LogInfo([string]$msg) {
    if (-not $Quiet) {
        # STDERR (safe for Terraform external)
        [Console]::Error.WriteLine($msg)
    }
}

$ErrorActionPreference = "Stop"
$ProgressPreference   = "SilentlyContinue"

#Write-Host "Retrieving PHP IPAM credentials from CyberArk (AIM REST)..." -ForegroundColor Cyan
LogInfo "Retrieving PHP IPAM credentials from CyberArk (AIM REST)..."

# ------------------------------------------------------------
# CyberArk AIM REST call (CORRECT endpoint)
# ------------------------------------------------------------
try {
    $ccpUri =
        "$cyberarkUrl/AIMWebService/api/Accounts" +
        "?APPID=$cyberarkAppID" +
        "&SAFE=$cyberarkSafe" +
        "&FOLDER=ROOT" +
        "&OBJECT=$cyberarkObject"

    $ccpResponse = Invoke-RestMethod `
        -Method Get `
        -Uri $ccpUri `
        -UseDefaultCredentials `
        -ErrorAction Stop

    $username = $ccpResponse.UserName
    $password = $ccpResponse.Content

    if (-not $password) {
        throw "Empty password returned from CyberArk AIM REST"
    }

    #Write-Host "Retrieved PHP IPAM credentials successfully." -ForegroundColor Green
    LogInfo "Retrieved PHP IPAM credentials successfully."
}
catch {
    Write-Error "CyberArk AIM REST call failed: $($_.Exception.Message)"
    exit 1
}

# ------------------------------------------------------------
# Authenticate with PHPIPAM
# ------------------------------------------------------------
try {
    $pair   = "$username`:$password"
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $base64 = [Convert]::ToBase64String($bytes)

    $headers = @{
        Authorization  = "Basic $base64"
        "Content-Type" = "application/json"
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "$phpIPAMUrl/$phpIPAMAppID/user/" `
        -Headers $headers `
        -ErrorAction Stop

    $token   = $response.data.token
    $headers = @{ "phpipam-token" = $token }
}
catch {
    Write-Error "Failed to authenticate to PHPIPAM: $($_.Exception.Message)"
    exit 1
}

# ------------------------------------------------------------
# Retrieve used IPs
# ------------------------------------------------------------
try {
    $response = Invoke-RestMethod `
        -Uri "$phpIPAMUrl/$phpIPAMAppID/subnets/$subnetId/addresses/" `
        -Headers $headers

    $usedIps = $response.data | ForEach-Object { $_.ip }
}
catch {
    Write-Error "Failed to retrieve IP list for subnet ID $subnetId"
    exit 1
}

# ------------------------------------------------------------
# IP helper functions
# ------------------------------------------------------------
function ConvertTo-DecimalIP($ip) {
    $parts = $ip -split '\.'
    return ($parts[0] -as [int]) * 16777216 +
           ($parts[1] -as [int]) * 65536 +
           ($parts[2] -as [int]) * 256 +
           ($parts[3] -as [int])
}

function ConvertFrom-DecimalIP($num) {
    return "$([math]::Floor($num / 16777216))." +
           "$([math]::Floor(($num % 16777216) / 65536))." +
           "$([math]::Floor(($num % 65536) / 256))." +
           "$($num % 256)"
}

function Get-IPRangeFromCIDR($cidr) {
    $parts  = $cidr -split '/'
    $base   = ConvertTo-DecimalIP $parts[0]
    $prefix = [int]$parts[1]
    $hosts  = [math]::Pow(2, 32 - $prefix)

    1..($hosts - 2) | ForEach-Object {
        ConvertFrom-DecimalIP ($base + $_)
    }
}

# ------------------------------------------------------------
# Determine free IP
# ------------------------------------------------------------
$allIps     = Get-IPRangeFromCIDR $subnet
$freeIps    = $allIps | Where-Object { $_ -notin $usedIps }
$selectedIp = $freeIps | Select-Object -Skip 10 -First 1

if (-not $selectedIp) {
    Write-Error "No free IPs found in subnet $subnet"
    exit 1
}

# ------------------------------------------------------------
# Terraform output
# ------------------------------------------------------------
# Write-Host "Selected Free IP: $selectedIp" -ForegroundColor Green
# @{ ip = $selectedIp } | ConvertTo-Json -Compress
LogInfo "Selected Free IP: $selectedIp"
@{ ip = "$selectedIp" } | ConvertTo-Json -Compress | Write-Output
