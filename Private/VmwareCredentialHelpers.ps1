# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : Save and load vCenter credentials using
#                 DPAPI-encrypted Export-Clixml (same Windows
#                 user only — same approach as FusionComputeCLI).
# Name          : VmwareCredentialHelpers.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Get-VMwareCredPath {
    param([Parameter(Mandatory=$true)][string]$VCenter)

    $safe = ($VCenter.Trim().ToLowerInvariant() -replace '[^a-z0-9\.\-]','_')
    $dir  = Join-Path (Get-VMwareBasePath) 'Credentials'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir "cred_$safe.xml"
}

function Export-VMwareCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$VCenter,
        [Parameter(Mandatory=$true)][pscredential]$Credential
    )
    $path = Get-VMwareCredPath -VCenter $VCenter
    $tmp  = "$path.tmp"
    try {
        $Credential | Export-Clixml -Path $tmp -Force
        Move-Item -Path $tmp -Destination $path -Force
        Write-VMwareLog -Function "Export-VMwareCredential" -VC $VCenter -Message "Credential saved: $path"
    } catch {
        Write-VMwareLog -Function "Export-VMwareCredential" -VC $VCenter -Message "Failed to save credential: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Import-VMwareCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$VCenter)

    $path = Get-VMwareCredPath -VCenter $VCenter
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $cred = Import-Clixml -LiteralPath $path
        if ($cred -is [pscredential]) {
            Write-VMwareLog -Function "Import-VMwareCredential" -VC $VCenter -Message "Credential loaded: $path"
            return $cred
        }
        return $null
    } catch {
        Write-VMwareLog -Function "Import-VMwareCredential" -VC $VCenter -Message "Failed to load credential: $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}
