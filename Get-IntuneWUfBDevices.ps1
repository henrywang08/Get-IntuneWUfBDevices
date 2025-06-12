<#
.SYNOPSIS
    Retrieves Intune devices with Windows Update for Business enabled and their OS version, mapping each OS version to its Windows release and update info.

.DESCRIPTION
    This script connects to Microsoft Graph using a custom Entra ID app registration, requests a cached report for co-managed devices with Windows Update for Business (WUfB) enabled, waits for the report to complete, and retrieves the report data. It then fetches the OS version for each device, maps the OS version to the corresponding Windows release and update (using a static mapping table), and outputs a table with device and OS update information.

.NOTES
    Requires Microsoft.Graph PowerShell modules and appropriate permissions (DeviceManagementManagedDevices.Read.All).
    Handles module installation/import robustly to avoid assembly conflicts.
    Outputs: DeviceId, DeviceName, WUfBSwiched, OSVersion, OS Name, Update Date and KB.
#>

param()

# --- Module Installation and Import Section ---
# Check if any Microsoft.Graph.* module is already loaded to avoid assembly conflicts
$graphLoaded = Get-Module -Name 'Microsoft.Graph*'

$modules = @(
    @{ Name = 'Microsoft.Graph.Authentication'; MinimumVersion = '1.27.0' },
    @{ Name = 'Microsoft.Graph.DeviceManagement' },
    @{ Name = 'Microsoft.Graph.Groups' },
    @{ Name = 'MSAL.PS'; MinimumVersion = '4.37.0.0' }
)

foreach ($mod in $modules) {
    # Install module if not available
    if (-not (Get-Module -ListAvailable -Name $mod.Name)) {
        Install-Module -Name $mod.Name -Force -Scope CurrentUser -AllowClobber
    }
    # Only import if not already loaded, and avoid importing additional Graph modules if any Graph module is loaded
    if ($mod.Name -like 'Microsoft.Graph*') {
        if (-not $graphLoaded) {
            if (-not (Get-Module -Name $mod.Name)) {
                if ($mod.MinimumVersion) {
                    Import-Module $mod.Name -MinimumVersion $mod.MinimumVersion -Force -ErrorAction Stop
                } else {
                    Import-Module $mod.Name -Force -ErrorAction Stop
                }
            }
        }
    } else {
        if (-not (Get-Module -Name $mod.Name)) {
            if ($mod.MinimumVersion) {
                Import-Module $mod.Name -MinimumVersion $mod.MinimumVersion -Force -ErrorAction Stop
            } else {
                Import-Module $mod.Name -Force -ErrorAction Stop
            }
        }
    }
}

# Ensure Get-MsalToken is available for authentication
if (-not (Get-Command Get-MsalToken -ErrorAction SilentlyContinue)) {
    Write-Error "Get-MsalToken is not available. Please restart your PowerShell session to complete module import, then rerun this script."
    exit 1
}

# --- Authentication and Graph Connection Section ---
# Define required Microsoft Graph API scopes
$Scopes = @(
    "DeviceManagementManagedDevices.Read.All",
    "Group.Read.All",
    "GroupMember.Read.All"
)
# Set your Entra ID app registration and tenant ID
$ClientId = "1a4d712f-91f8-4f93-8c73-a7718eca0274" # Custom Entra ID App Registration
$TenantId = "55f37ed7-ebe7-4cea-8686-1ca9653384f1" # <-- Replace with your Azure AD tenant ID

# Authenticate and get access token using MSAL
$MsalToken = Get-MsalToken -ClientId $ClientId -TenantId $TenantId -Scopes $Scopes -Interactive
$AccessToken = $MsalToken.AccessToken

# Connect to Microsoft Graph SDK (optional, for SDK cmdlets)
$SecureAccessToken = ConvertTo-SecureString $AccessToken -AsPlainText -Force
Connect-MgGraph -AccessToken $SecureAccessToken
# Select-MgProfile -Name beta # Uncomment if you need beta profile

# --- Cached Report Request Section ---
# Request a cached report for co-managed devices with WUfB enabled
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

# Submit the report request
try {
    $response = Invoke-RestMethod -Method POST -Uri $CachedReportUrl -Headers $Headers -Body $Payload
    $StatusCode = 200  # Success
    Write-Host "POST $CachedReportUrl succeeded with status code $StatusCode"
} catch {
    $StatusCode = $_.Exception.Response.StatusCode.value__
    Write-Error "POST $CachedReportUrl failed with status code $StatusCode"
    throw
}

# --- Report Completion Polling Section ---
# Wait for the report to complete (polling)
$StatusUrl = "https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations('$ReportId')"
$MaxAttempts = 30
$Attempt = 0
$State = $null

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

# --- Report Retrieval and Parsing Section ---
# Retrieve the completed report
$GetReportUrl = "https://graph.microsoft.com/beta/deviceManagement/reports/getCachedReport"
$Report = Invoke-RestMethod -Method POST -Uri $GetReportUrl -Headers $Headers -Body $Payload

# Parse the report schema and values into an array of device objects
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

# --- Device OS Version Retrieval Section ---
# For each device, fetch the OS version from Intune managedDevices endpoint
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
            'OS Name' = $null
            'Update Date and KB' = $null
        }
    }
}

# --- OS Version Mapping Section ---
# Map each device's OSVersion to Windows release and update info using a static mapping table
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

# --- Output Section ---
# Output the devices with OS version, OS Name, and Update info as a table
$DeviceOsInfo | Format-Table DeviceId,DeviceName,WUfBSwiched,OSVersion,'OS Name','Update Date and KB' -AutoSize




