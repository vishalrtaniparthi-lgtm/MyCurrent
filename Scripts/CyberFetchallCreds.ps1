param (
    [string]$AppID       = "VMAutomation",
    [string]$Safe        = "WEB-NUTANIX",
    [string]$CyberArkURL = "https://cyberarkapi.net/",
    [string]$Domain      = "test.net"
)

$ErrorActionPreference = "Stop"
$ProgressPreference   = "SilentlyContinue"

# ------------------------------------------------------------
# CyberArk AIM REST helper
# ------------------------------------------------------------
function Get-CyberArkCredential {
    param (
        [Parameter(Mandatory)] [string]$AppID,
        [Parameter(Mandatory)] [string]$Safe,
        [Parameter(Mandatory)] [string]$Object,
        [Parameter(Mandatory)] [string]$CyberArkURL
    )

    $uri = "$CyberArkURL/AIMWebService/api/Accounts" +
           "?APPID=$AppID" +
           "&SAFE=$Safe" +
           "&FOLDER=ROOT" +
           "&OBJECT=$Object"

    Invoke-RestMethod `
        -Method Get `
        -Uri $uri `
        -UseDefaultCredentials `
        -ErrorAction Stop
}

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

    @{
        nutanix_username      = "$($prism.UserName)"
        nutanix_password      = "$($prism.Content)"
        local_admin_username  = "$($localAdmin.UserName)"
        local_admin_password  = "$($localAdmin.Content)"
        domain_admin_username = "$($domainAdmin.UserName)"
        domain_admin_password = "$($domainAdmin.Content)"
        domain_name           = "$Domain"
    } | ConvertTo-Json -Compress
}
catch {
    @{ error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress
    exit 1
}
