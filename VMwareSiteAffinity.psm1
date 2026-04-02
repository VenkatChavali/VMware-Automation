# =================================================
# Module       : VMwareSiteAffinity
# Author       : Venkat Praveen Kumar Chavali
# Date         : 24-Mar-2026
# Version      : 1.0
# Purpose      : VMware DRS site affinity change + vMotion automation.
#                Mirrors the FusionComputeCLI module architecture.
# Compatibility: PS 5.1, VMware.PowerCLI required
# =================================================

#Requires -Version 5.1

# ---- Resolve module root ----
$ModuleRoot = $PSScriptRoot
if (-not $ModuleRoot) {
    try { $ModuleRoot = $ExecutionContext.SessionState.Module.ModuleBase } catch {}
}
if (-not $ModuleRoot) {
    try { $ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
}

# ---- Verify PowerCLI is available ----
$powerCLIAvailable = $false
try {
    if (Get-Module -ListAvailable -Name "VMware.PowerCLI" -ErrorAction SilentlyContinue) {
        $powerCLIAvailable = $true
    } elseif (Get-Module -ListAvailable -Name "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) {
        $powerCLIAvailable = $true
    }
} catch {}

if (-not $powerCLIAvailable) {
    Write-Warning "[VMwareSiteAffinity] VMware.PowerCLI is not installed. Install it with: Install-Module VMware.PowerCLI"
}

# ---- Base path resolution ----
#   Priority: VMWARE_SA_BASE_PATH env var -> <ModuleRoot>\Data -> Documents
if (-not $Global:VMwareSABasePath) {
    if (-not [string]::IsNullOrWhiteSpace($env:VMWARE_SA_BASE_PATH)) {
        $Global:VMwareSABasePath = $env:VMWARE_SA_BASE_PATH.Trim()
    } elseif ($ModuleRoot) {
        $Global:VMwareSABasePath = Join-Path $ModuleRoot 'Data'
    } else {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $Global:VMwareSABasePath = if ($docs) { Join-Path $docs 'VMwareSiteAffinityData' } else { Join-Path $env:TEMP 'VMwareSiteAffinityData' }
    }
}

# ---- Session map ----
if (-not $Global:VMwareSessions)   { $Global:VMwareSessions   = @{} }
if (-not $Global:VMwareSACache)    { $Global:VMwareSACache     = @{} }

# ---- Load Private functions ----
$privateFiles = @(
    'VmwarePathHelpers.ps1',
    'Write-VMwareLog.ps1',
    'VmwareCredentialHelpers.ps1',
    'Show-VMwareMigrationInputDialog.ps1',
    'Get-VMwareMigrationPlan.ps1'
)

foreach ($file in $privateFiles) {
    $path = Join-Path $ModuleRoot "Private\$file"
    if (Test-Path -LiteralPath $path) {
        . $path
    } else {
        Write-Warning "[VMwareSiteAffinity] Private file not found: $path"
    }
}

# ---- Load Public functions ----
$publicFiles = @(
    'Connect-VMwareVC.ps1',
    'Invoke-VMwareSiteAffinityMigration.ps1',
    'Get-VMwareMigrationReport.ps1'
)

$exportedFunctions = @()
foreach ($file in $publicFiles) {
    $path = Join-Path $ModuleRoot "Public\$file"
    if (Test-Path -LiteralPath $path) {
        . $path
        # Extract function names from file
        $names = (Select-String -Path $path -Pattern '^function\s+([\w-]+)' |
                  ForEach-Object { $_.Matches[0].Groups[1].Value })
        $exportedFunctions += $names
    } else {
        Write-Warning "[VMwareSiteAffinity] Public file not found: $path"
    }
}

Export-ModuleMember -Function $exportedFunctions
