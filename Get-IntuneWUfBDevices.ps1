<#
.SYNOPSIS
    Retrieves Intune devices with Windows Update for Business enabled and their OS version.

.DESCRIPTION
    Connects to Microsoft Graph, requests a cached report for co-managed devices with WUfB enabled,
    waits for the report to complete, and retrieves the report data.

.NOTES
    Requires Microsoft.Graph PowerShell module and appropriate permissions (DeviceManagementManagedDevices.Read.All).
#>

param()

# Ensure required modules are installed and imported
$modules = @(
    @{ Name = 'Microsoft.Graph.Authentication'; MinimumVersion = '1.27.0' },
    @{ Name = 'Microsoft.Graph.DeviceManagement' },
    @{ Name = 'Microsoft.Graph.Groups' },
    @{ Name = 'MSAL.PS'; MinimumVersion = '4.37.0.0' }
)
foreach ($mod in $modules) {
    if (-not (Get-Module -ListAvailable -Name $mod.Name)) {
        Install-Module -Name $mod.Name -Force -Scope CurrentUser -AllowClobber
    }
    if ($mod.MinimumVersion) {
        Import-Module $mod.Name -MinimumVersion $mod.MinimumVersion -Force -ErrorAction Stop
    } else {
        Import-Module $mod.Name -Force -ErrorAction Stop
    }
}

# Ensure Get-MsalToken is available
if (-not (Get-Command Get-MsalToken -ErrorAction SilentlyContinue)) {
    Write-Error "Get-MsalToken is not available. Please restart your PowerShell session to complete module import, then rerun this script."
    exit 1
}

# Step 1: Connect to Microsoft Graph
$Scopes = @(
    "DeviceManagementManagedDevices.Read.All",
    "Group.Read.All",
    "GroupMember.Read.All"
)
$ClientId = "1a4d712f-91f8-4f93-8c73-a7718eca0274" # Custom Entra ID App Registration
$TenantId = "55f37ed7-ebe7-4cea-8686-1ca9653384f1" # <-- Replace with your Azure AD tenant ID

# Get access token using MSAL with tenant-specific endpoint
$MsalToken = Get-MsalToken -ClientId $ClientId -TenantId $TenantId -Scopes $Scopes -Interactive
$AccessToken = $MsalToken.AccessToken

# Connect to Graph (optional, for SDK cmdlets)
# Convert access token to SecureString for Connect-MgGraph
$SecureAccessToken = ConvertTo-SecureString $AccessToken -AsPlainText -Force
Connect-MgGraph -AccessToken $SecureAccessToken
# Select-MgProfile -Name beta

# Step 2: Request cached report configuration
$ReportId = "ComanagedDeviceWorkloads_00000000-0000-0000-0000-000000000001"
$Payload = @{
    id     = $ReportId
    filter = "(WindowsUpdateforBusiness eq '1')"
    orderBy = @("DeviceName")
    select = @("DeviceName", "DeviceId", "WindowsUpdateforBusiness")
} | ConvertTo-Json

$CachedReportUrl = "https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations"
$Headers = @{
    "Content-Type" = "application/json"
    "Authorization" = "Bearer $AccessToken"
}

try {
    $response = Invoke-RestMethod -Method POST -Uri $CachedReportUrl -Headers $Headers -Body $Payload
    $StatusCode = 200  # Success
    Write-Host "POST $CachedReportUrl succeeded with status code $StatusCode"
} catch {
    $StatusCode = $_.Exception.Response.StatusCode.value__
    Write-Error "POST $CachedReportUrl failed with status code $StatusCode"
    throw
}

# Step 3: Wait for report state to "completed"
$StatusUrl = "https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations('$ReportId')"
$MaxAttempts = 30
$Attempt = 0
do {
    Start-Sleep -Seconds 5
    $Status = Invoke-RestMethod -Method GET -Uri $StatusUrl -Headers $Headers
    $State = $Status.status
    Write-Host "Report state: $State"
    $Attempt++
} while ($State -ne "completed" -and $Attempt -lt $MaxAttempts)

if ($State -ne "completed") {
    Write-Error "Report did not complete in expected time."
    exit 1
}

# Step 4: Retrieve the report
$GetReportUrl = "https://graph.microsoft.com/beta/deviceManagement/reports/getCachedReport"
$Report = Invoke-RestMethod -Method POST -Uri $GetReportUrl -Headers $Headers -Body $Payload

# Output the report
$Report.values | Format-Table -AutoSize
