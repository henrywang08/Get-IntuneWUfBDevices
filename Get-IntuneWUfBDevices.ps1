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

# Format the report using $Report.schema and $Report.values
$Devices = @()
if ($Report.schema -and $Report.values) {
    # $Report.schema is an array of objects with a 'column' property
    $columns = $Report.schema | ForEach-Object { $_.column }
    foreach ($row in $Report.values) {
        $obj = @{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $obj[$columns[$i]] = $row[$i]
        }
        $Devices += [PSCustomObject]$obj
    }
}

# Output the devices as a table
$Devices | Format-Table -AutoSize

# Step 5: Get OS version for each device from Intune using Graph API
$DeviceOsInfo = @()
foreach ($device in $Devices) {
    $deviceId = $device.DeviceId
    if ($deviceId) {
        $deviceUrl = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$deviceId"
        try {
            $deviceInfo = Invoke-RestMethod -Method GET -Uri $deviceUrl -Headers $Headers
            $osVersion = $deviceInfo.osVersion
        } catch {
            $osVersion = $null
        }
        $DeviceOsInfo += [PSCustomObject]@{
            DeviceId = $deviceId
            DeviceName = $device.DeviceName
            WUfBSwiched = $device.WindowsUpdateforBusiness
            OSVersion = $osVersion
        }
    }
}

# Output the devices with OS version
$DeviceOsInfo | Format-Table -AutoSize

# Step 6: Map OSVersion to Windows release and update info using static mapping with smart matching
$OsReleaseTable = @(
    [PSCustomObject]@{ 'OS Name' = 'Windows 11 24H2'; 'OS Version' = '10.0.26100.4349'; 'Update Date and KB' = 'June 10, 2025 – KB5060842' },
    [PSCustomObject]@{ 'OS Name' = 'Windows 11 24H2'; 'OS Version' = '10.0.26100.4061'; 'Update Date and KB' = 'May 13, 2025 – KB5058411' },
    [PSCustomObject]@{ 'OS Name' = 'Windows 11 23H2'; 'OS Version' = '10.0.22631.5472'; 'Update Date and KB' = 'June 10, 2025 – KB5060999' },
    [PSCustomObject]@{ 'OS Name' = 'Windows 11 23H2'; 'OS Version' = '10.0.22631.5335'; 'Update Date and KB' = 'May 13, 2025 – KB5058405' },
    [PSCustomObject]@{ 'OS Name' = 'Windows 11 22H2'; 'OS Version' = '10.0.22621.5472'; 'Update Date and KB' = 'June 10, 2025 – KB5060999' },
    [PSCustomObject]@{ 'OS Name' = 'Windows 11 22H2'; 'OS Version' = '10.0.22621.5335'; 'Update Date and KB' = 'May 13, 2025 – KB5058405' },
    [PSCustomObject]@{ 'OS Name' = 'Windows 10 22H2'; 'OS Version' = '10.0.19045.5965'; 'Update Date and KB' = 'June 10, 2025 – KB5060533' },
    [PSCustomObject]@{ 'OS Name' = 'Windows 10 22H2'; 'OS Version' = '10.0.19045.5854'; 'Update Date and KB' = 'May 13, 2025 – KB5058379' }
)

foreach ($device in $DeviceOsInfo) {
    $osVersion = $device.OSVersion
    $device.'OS Name' = $null
    $device.'Update Date and KB' = $null

    if ($osVersion -match '^([\d]+\.[\d]+\.[\d]+)\.(\d+)$') {
        $buildRoot = $Matches[1]
        $patchNum = [int]$Matches[2]

        # Get all release table entries for this build root
        $matchingReleases = $OsReleaseTable | Where-Object { $_.'OS Version' -like "$buildRoot.*" }
        if ($matchingReleases) {
            $device.'OS Name' = $matchingReleases[0].'OS Name'

            # Build a sorted list of patch numbers and their update info
            $patchList = $matchingReleases | ForEach-Object {
                if ($_.'OS Version' -match "^$buildRoot\.(\d+)$") {
                    [PSCustomObject]@{
                        Patch = [int]$Matches[1]
                        Update = $_.'Update Date and KB'
                    }
                }
            } | Where-Object { $_ } | Sort-Object Patch

            if ($patchList.Count -gt 0) {
                # Find the update info for the closest patch less than or equal to the device's patch
                $bestMatch = $patchList | Where-Object { $_.Patch -le $patchNum } | Sort-Object Patch -Descending | Select-Object -First 1
                if ($bestMatch) {
                    $device.'Update Date and KB' = $bestMatch.Update
                } else {
                    # If device patch is less than all, use the lowest available
                    $device.'Update Date and KB' = $patchList[0].Update
                }
            }
        }
    }
}

# Output the devices with OS version, OS Name, and Update info
$DeviceOsInfo | Format-Table DeviceId,DeviceName,WUfBSwiched,OSVersion,'OS Name','Update Date and KB' -AutoSize




