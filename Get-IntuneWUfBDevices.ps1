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

# Step 1: Connect to Microsoft Graph
$Scopes = @("DeviceManagementManagedDevices.Read.All")
Connect-MgGraph -Scopes $Scopes
Select-MgProfile -Name beta

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
    "Authorization" = "Bearer $((Get-MgContext).AccessToken)"
}

Invoke-RestMethod -Method POST -Uri $CachedReportUrl -Headers $Headers -Body $Payload | Out-Null

# Step 3: Wait for report state to "completed"
$StatusUrl = "https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations('$ReportId')"
$MaxAttempts = 30
$Attempt = 0
do {
    Start-Sleep -Seconds 5
    $Status = Invoke-RestMethod -Method GET -Uri $StatusUrl -Headers $Headers
    $State = $Status.state
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
$Report.value | Format-Table -AutoSize
