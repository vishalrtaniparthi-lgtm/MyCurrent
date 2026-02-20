<#
.SYNOPSIS
    Fetches all required credentials from CyberArk AIM (CCP) REST API
    and outputs them as a compressed JSON object for Terraform external data source.

.DESCRIPTION
    Retrieves Nutanix Prism Central, local admin, and domain join credentials
    from CyberArk. Outputs a flat JSON object compatible with Terraform's
    external data source (all values must be strings).

.PARAMETER AppID
    CyberArk Application ID registered for this automation.

.PARAMETER Safe
    CyberArk Safe containing the credential objects.

.PARAMETER CyberArkURL
    Base URL of the CyberArk CCP (AIM Web Service), e.g. https://cyberarkapi.corp.net

.PARAMETER Domain
    Domain name to include in the output (e.g. test.net).
#>

param (
    [string]$AppID       = "VMAutomation",
    [string]$Safe        = "WEB-NUTANIX",
    [string]$CyberArkURL = "https://cyberarkapi.corp.net",
    [string]$Domain      = "test.net"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ─────────────────────────────────────────────────────────────
# CyberArk AIM REST helper
# ─────────────────────────────────────────────────────────────
function Get-CyberArkCredential {
    param (
        [Parameter(Mandatory)] [string]$AppID,
        [Parameter(Mandatory)] [string]$Safe,
        [Parameter(Mandatory)] [string]$Object,
        [Parameter(Mandatory)] [string]$CyberArkURL
    )

    # URL-encode each query parameter to handle special characters
    $uri = "$CyberArkURL/AIMWebService/api/Accounts" +
           "?AppID=$([uri]::EscapeDataString($AppID))" +
           "&Safe=$([uri]::EscapeDataString($Safe))" +
           "&Folder=ROOT" +
           "&Object=$([uri]::EscapeDataString($Object))"

    Invoke-RestMethod `
        -Method      Get `
        -Uri         $uri `
        -UseDefaultCredentials `
        -SkipCertificateCheck `
        -ErrorAction Stop
}

# ─────────────────────────────────────────────────────────────
# Fetch all three credential sets
# ─────────────────────────────────────────────────────────────
try {
    $prism = Get-CyberArkCredential `
        -AppID       $AppID `
        -Safe        $Safe `
        -Object      "PrismCentralAdmin" `
        -CyberArkURL $CyberArkURL

    $localAdmin = Get-CyberArkCredential `
        -AppID       $AppID `
        -Safe        $Safe `
        -Object      "Website-WEB-NUTANIX-test.net-Administrator" `
        -CyberArkURL $CyberArkURL

    $domainAdmin = Get-CyberArkCredential `
        -AppID       $AppID `
        -Safe        $Safe `
        -Object      "Website-ASP-P-WEB-NUTANIX-test.net-deploy" `
        -CyberArkURL $CyberArkURL

    # Validate that passwords were actually returned
    foreach ($pair in @(
        @{ Label = "Nutanix";      Value = $prism.Content },
        @{ Label = "LocalAdmin";   Value = $localAdmin.Content },
        @{ Label = "DomainAdmin";  Value = $domainAdmin.Content }
    )) {
        if ([string]::IsNullOrWhiteSpace($pair.Value)) {
            throw "CyberArk returned an empty password for: $($pair.Label)"
        }
    }

    # Output flat JSON — Terraform external data source requires all string values
    @{
        nutanix_username      = [string]$prism.UserName
        nutanix_password      = [string]$prism.Content
        local_admin_username  = [string]$localAdmin.UserName
        local_admin_password  = [string]$localAdmin.Content
        domain_admin_username = [string]$domainAdmin.UserName
        domain_admin_password = [string]$domainAdmin.Content
        domain_name           = [string]$Domain
    } | ConvertTo-Json -Compress
}
catch {
    # Terraform external data source reads stderr for errors
    [Console]::Error.WriteLine("CyberFetchallCreds ERROR: $($_.Exception.Message)")
    exit 1
}
