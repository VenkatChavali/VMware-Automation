# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : Path resolution for VMware module.
#                 Priority: env var -> module-relative -> Documents
# Name          : VmwarePathHelpers.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Get-VMwareBasePath {
    # Priority:
    #   1. Already set in session
    #   2. Environment variable VMWARE_SA_BASE_PATH
    #   3. Module-relative: <ModuleRoot>\Data\
    #   4. MyDocuments\VMwareSiteAffinityData  (last resort)

    if (-not [string]::IsNullOrWhiteSpace($Global:VMwareSABasePath)) {
        return $Global:VMwareSABasePath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:VMWARE_SA_BASE_PATH)) {
        $Global:VMwareSABasePath = $env:VMWARE_SA_BASE_PATH.Trim()
        return $Global:VMwareSABasePath
    }

    $modBase = $null
    try {
        $modBase = $ExecutionContext.SessionState.Module.ModuleBase
    } catch {}

    if ($modBase) {
        $Global:VMwareSABasePath = Join-Path $modBase 'Data'
    } else {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        if (-not [string]::IsNullOrWhiteSpace($docs)) {
            $Global:VMwareSABasePath = Join-Path $docs 'VMwareSiteAffinityData'
        } else {
            $Global:VMwareSABasePath = Join-Path $env:TEMP 'VMwareSiteAffinityData'
        }
    }

    return $Global:VMwareSABasePath
}

function Get-VMwareDirs {
    $base = Get-VMwareBasePath
    $dirs = @{
        Root        = $base
        Logs        = Join-Path $base 'Logs'
        Reports     = Join-Path $base 'Reports'
        Cache       = Join-Path $base 'Cache'
        Credentials = Join-Path $base 'Credentials'
        Temp        = Join-Path $base 'Temp'
    }
    foreach ($d in $dirs.Values) {
        if (-not (Test-Path -LiteralPath $d)) {
            try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch {}
        }
    }
    return $dirs
}

function Resolve-VMwareReportDir {
    $dirs = $null
    try { $dirs = Get-VMwareDirs } catch {}
    if ($dirs -and $dirs.Reports -and (Test-Path -LiteralPath $dirs.Reports)) {
        return $dirs.Reports
    }
    $fallback = Join-Path $env:TEMP 'VMwareSiteAffinity_Reports'
    if (-not (Test-Path -LiteralPath $fallback)) {
        try { New-Item -ItemType Directory -Path $fallback -Force | Out-Null } catch {}
    }
    return $fallback
}
