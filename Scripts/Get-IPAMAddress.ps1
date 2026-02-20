<#
.SYNOPSIS
    Fetches a free IP address and full network details from PHP IPAM
    based on the requested server role (APP / SQL / WEB).

.DESCRIPTION
    - Maps server_role → IPAM subnet CIDR
    - Authenticates to PHP IPAM using API app-key auth
    - Looks up the subnet ID from PHP IPAM by CIDR
    - Requests the next free IP in that subnet
    - Returns IP, gateway, DNS list, prefix length as a PSCustomObject
    - Optionally marks the IP as used in IPAM (set $MarkAsUsed = $true)

.OUTPUTS
    [PSCustomObject] with properties:
        IPAddress    – e.g. "10.12.1.45"
        Gateway      – e.g. "10.12.1.1"
        PrefixLength – e.g. 24
        DNSServers   – e.g. @("10.12.0.10","10.12.0.11")
        SubnetCIDR   – e.g. "10.12.1.0/24"

.NOTES
    Called by Deploy.ps1.  Not intended to be run standalone.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("APP","SQL","WEB")]
    [string]$ServerRole,

    [Parameter(Mandatory)]
    [string]$IPAMBaseUrl,          # e.g. "https://ipam.corp.example.com"

    [Parameter(Mandatory)]
    [string]$IPAMAppID,            # PHP IPAM API application ID

    [Parameter(Mandatory)]
    [string]$IPAMAppKey,           # PHP IPAM API application key (app-key auth)

    [bool]$MarkAsUsed = $true,     # Register the IP in IPAM after fetch

    [string]$Hostname = "",        # Optional: tag the IPAM reservation with a hostname
    [string]$Description = ""      # Optional: tag with a description
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────
# Role → subnet CIDR map
# Must match terraform.tfvars subnet_uuid_map roles.
# ─────────────────────────────────────────────────────────────
$SubnetMap = @{
    APP = "10.12.1.0/24"
    SQL = "10.12.2.0/24"
    WEB = "10.12.3.0/24"
}

$TargetCIDR = $SubnetMap[$ServerRole]
Write-Host "[IPAM] Role '$ServerRole' → target subnet: $TargetCIDR"

# ─────────────────────────────────────────────────────────────
# Helper: invoke PHP IPAM REST API
# ─────────────────────────────────────────────────────────────
function Invoke-IPAM {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body = @{}
    )

    $uri     = "$IPAMBaseUrl/api/$IPAMAppID/$Endpoint"
    $headers = @{
        "token"        = $IPAMAppKey
        "Content-Type" = "application/json"
    }

    $params = @{
        Uri                  = $uri
        Method               = $Method
        Headers              = $headers
        UseBasicParsing      = $true
        SkipCertificateCheck = $true   # Remove in production if IPAM has valid cert
    }

    if ($Method -in @("POST","PATCH") -and $Body.Count -gt 0) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 5)
    }

    $response = Invoke-RestMethod @params
    return $response
}

# ─────────────────────────────────────────────────────────────
# Step 1: Find subnet ID by CIDR
# ─────────────────────────────────────────────────────────────
Write-Host "[IPAM] Looking up subnet ID for $TargetCIDR ..."

$subnetsResponse = Invoke-IPAM -Endpoint "subnets/cidr/$([uri]::EscapeDataString($TargetCIDR))/"

if (-not $subnetsResponse.data) {
    throw "[IPAM] ERROR: Subnet '$TargetCIDR' not found in PHP IPAM."
}

# IPAM may return multiple matches; take the first
$subnet      = $subnetsResponse.data | Select-Object -First 1
$subnetId    = $subnet.id
$gateway     = $subnet.gateway.ip_addr
$prefix      = [int]$subnet.mask
$description = $subnet.description

Write-Host "[IPAM] Subnet ID: $subnetId | Gateway: $gateway | Prefix: /$prefix"

# ─────────────────────────────────────────────────────────────
# Step 2: Get custom fields for DNS servers
#         PHP IPAM stores custom fields per-subnet.
#         Adjust field names below to match your IPAM config.
# ─────────────────────────────────────────────────────────────
$dnsServers = @()

try {
    $subnetDetail = Invoke-IPAM -Endpoint "subnets/$subnetId/"
    $data         = $subnetDetail.data

    # Try common custom field names — adjust to match your IPAM setup
    foreach ($field in @("custom_DNS1","custom_dns1","DNS1","dns1")) {
        if ($data.PSObject.Properties[$field] -and $data.$field) {
            $dnsServers += $data.$field.Trim()
            break
        }
    }
    foreach ($field in @("custom_DNS2","custom_dns2","DNS2","dns2")) {
        if ($data.PSObject.Properties[$field] -and $data.$field) {
            $dnsServers += $data.$field.Trim()
            break
        }
    }
} catch {
    Write-Host "[IPAM] WARNING: Could not fetch custom DNS fields: $_"
}

# Fallback to hardcoded defaults if IPAM has no DNS fields configured
if ($dnsServers.Count -eq 0) {
    Write-Host "[IPAM] No DNS custom fields found — using subnet defaults."
    $dnsServers = @("10.12.0.10","10.12.0.11")
}

Write-Host "[IPAM] DNS servers: $($dnsServers -join ', ')"

# ─────────────────────────────────────────────────────────────
# Step 3: Get next free IP in subnet
# ─────────────────────────────────────────────────────────────
Write-Host "[IPAM] Fetching next free IP in subnet $subnetId ..."

$freeResponse = Invoke-IPAM -Endpoint "subnets/$subnetId/first_free/"

if (-not $freeResponse.data) {
    throw "[IPAM] ERROR: No free IPs available in subnet $TargetCIDR (ID: $subnetId)."
}

$freeIP = $freeResponse.data
Write-Host "[IPAM] Next free IP: $freeIP"

# ─────────────────────────────────────────────────────────────
# Step 4: Register (mark as used) in IPAM
# ─────────────────────────────────────────────────────────────
if ($MarkAsUsed) {
    Write-Host "[IPAM] Reserving IP $freeIP in IPAM..."

    $reserveBody = @{
        subnetId    = $subnetId
        ip          = $freeIP
        is_gateway  = "0"
        description = if ($Description) { $Description } else { "Reserved by Terraform deploy" }
        hostname    = if ($Hostname)    { $Hostname    } else { "" }
        note        = "Auto-provisioned $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }

    try {
        $reserveResponse = Invoke-IPAM -Endpoint "addresses/" -Method "POST" -Body $reserveBody
        if ($reserveResponse.success -eq $true) {
            Write-Host "[IPAM] IP $freeIP reserved successfully (ID: $($reserveResponse.id))."
        } else {
            Write-Host "[IPAM] WARNING: Reservation response did not confirm success: $($reserveResponse | ConvertTo-Json)"
        }
    } catch {
        Write-Host "[IPAM] WARNING: Failed to reserve IP in IPAM: $_"
        # Non-fatal — Terraform will still proceed; clean up manually if needed
    }
}

# ─────────────────────────────────────────────────────────────
# Return structured result
# ─────────────────────────────────────────────────────────────
$result = [PSCustomObject]@{
    IPAddress    = $freeIP
    Gateway      = $gateway
    PrefixLength = $prefix
    DNSServers   = $dnsServers
    SubnetCIDR   = $TargetCIDR
}

Write-Host "[IPAM] Result: IP=$($result.IPAddress) GW=$($result.Gateway) Prefix=$($result.PrefixLength) DNS=$($result.DNSServers -join ',')"

return $result
