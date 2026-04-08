# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.1
# Module Type   : Public
# Purpose       : Connect to one or more vCenter servers.
# Compatibility : PS 5.1-compatible (requires VMware.PowerCLI)
# =================================================

function Connect-VMwareVC {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$VCenter,

        [pscredential]$Credential,

        [switch]$Force
    )

    $funcName = 'Connect-VMwareVC'
    if (-not $Global:VMwareSessions) { $Global:VMwareSessions = @{} }

    $vcList = @()
    foreach ($v in $VCenter) {
        foreach ($p in (($v | Out-String).Trim() -split ',')) {
            $t = $p.Trim().ToLowerInvariant()
            if ($t) { $vcList += $t }
        }
    }
    $vcList = @($vcList | Select-Object -Unique)

    foreach ($vc in $vcList) {
        if (-not $Force -and $Global:VMwareSessions.ContainsKey($vc)) {
            $existing = $Global:VMwareSessions[$vc]
            if ($existing -and $existing.IsConnected) {
                Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message 'Already connected — skipping (use -Force to re-authenticate)'
                continue
            }
        }

        $cred = $null
        if ($Credential) { $cred = $Credential }
        if (-not $cred) { $cred = Import-VMwareCredential -VCenter ([string]$vc) }
        if (-not $cred) {
            try { $cred = Get-Credential -Message "Enter credentials for vCenter: $vc" } catch {}
        }
        if (-not $cred) {
            Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message 'No credential provided. Skipping.' -Level 'WARN'
            continue
        }

        try {
            Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message 'Connecting...'
            $viServer = Connect-VIServer -Server $vc -Credential $cred -Force -ErrorAction Stop
            Export-VMwareCredential -VCenter ([string]$vc) -Credential $cred
            $Global:VMwareSessions[$vc] = $viServer
            Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message ("Connected. Product: {0} {1}" -f $viServer.ProductLine, $viServer.Version)
        } catch {
            Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message ("Connection failed: {0}" -f $_.Exception.Message) -Level 'ERROR'
        }
    }

    $connected = @($Global:VMwareSessions.Keys | Where-Object { $Global:VMwareSessions[$_] -and $Global:VMwareSessions[$_].IsConnected })
    Write-Host "`n[Connect-VMwareVC] Connected vCenters ($($connected.Count)): $($connected -join ', ')" -ForegroundColor Cyan
}

function Disconnect-VMwareVC {
    [CmdletBinding()]
    param([string[]]$VCenter)

    if (-not $Global:VMwareSessions) { return }
    $vcList = if ($VCenter -and $VCenter.Count -gt 0) {
        @($VCenter | ForEach-Object { $_.Trim().ToLowerInvariant() })
    } else {
        @($Global:VMwareSessions.Keys)
    }

    foreach ($vc in $vcList) {
        if ($Global:VMwareSessions.ContainsKey($vc)) {
            try { Disconnect-VIServer -Server $Global:VMwareSessions[$vc] -Confirm:$false -Force -ErrorAction SilentlyContinue } catch {}
            $Global:VMwareSessions.Remove($vc)
            Write-VMwareLog -Function 'Disconnect-VMwareVC' -VC ([string]$vc) -Message 'Disconnected'
        }
    }
}

function Get-VMwareVC {
    [CmdletBinding()]
    param()

    if (-not $Global:VMwareSessions -or $Global:VMwareSessions.Count -eq 0) {
        Write-Host 'No vCenter sessions. Run Connect-VMwareVC first.' -ForegroundColor Yellow
        return
    }

    foreach ($vc in $Global:VMwareSessions.Keys) {
        $s = $Global:VMwareSessions[$vc]
        $status = if ($s -and $s.IsConnected) { 'Connected' } else { 'Disconnected' }
        $colour = if ($status -eq 'Connected') { 'Green' } else { 'Red' }
        Write-Host ("  {0,-40} {1}" -f $vc, $status) -ForegroundColor $colour
    }
}
