# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Module Type   : Public
# Purpose       : Connect to one or more vCenter servers.
#                 Saves credentials via DPAPI Export-Clixml so
#                 Runspace workers can reconnect without prompting.
#                 Maintains $Global:VMwareSessions keyed by vCenter FQDN.
# Name          : Connect-VMwareVC.ps1
# Compatibility : PS 5.1-compatible (requires VMware.PowerCLI)
# =================================================

<#
.SYNOPSIS
Connect to one or more vCenter servers with credential persistence.

.DESCRIPTION
Connects to each vCenter using Connect-VIServer (PowerCLI).
Credentials are saved to DPAPI-encrypted XML so background Runspace
workers can reconnect automatically if the session expires, without
any interactive prompt.

Session state is stored in $Global:VMwareSessions keyed by vCenter FQDN.

.PARAMETER VCenter
One or more vCenter FQDNs or IPs.

.PARAMETER Credential
PSCredential to use. If omitted, tries the saved credential file first,
then prompts if none found.

.PARAMETER Force
Re-authenticate even if a valid session already exists.

.EXAMPLE
Connect-VMwareVC -VCenter "vc01.corp.local"

.EXAMPLE
Connect-VMwareVC -VCenter "vc01.corp.local","vc02.corp.local" -Force
#>
function Connect-VMwareVC {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$VCenter,

        [pscredential]$Credential,

        [switch]$Force
    )

    $funcName = "Connect-VMwareVC"

    # Ensure sessions dict exists
    if (-not $Global:VMwareSessions) { $Global:VMwareSessions = @{} }

    # Normalise list
    $vcList = @()
    foreach ($v in $VCenter) {
        foreach ($p in ($v -split ',')) {
            $t = $p.Trim().ToLowerInvariant()
            if ($t) { $vcList += $t }
        }
    }
    $vcList = @($vcList | Select-Object -Unique)

    foreach ($vc in $vcList) {

        # Check if already connected and not forcing
        if (-not $Force -and $Global:VMwareSessions.ContainsKey($vc)) {
            $existing = $Global:VMwareSessions[$vc]
            if ($existing -and $existing.IsConnected) {
                Write-VMwareLog -Function $funcName -VC $vc -Message "Already connected — skipping (use -Force to re-authenticate)"
                continue
            }
        }

        # Resolve credential
        $cred = $null

        if ($Credential) {
            $cred = $Credential
        } else {
            # Try saved DPAPI credential first
            $cred = Import-VMwareCredential -VCenter $vc
        }

        if (-not $cred) {
            # Prompt
            try {
                $cred = Get-Credential -Message "Enter credentials for vCenter: $vc"
            } catch {}
        }

        if (-not $cred) {
            Write-VMwareLog -Function $funcName -VC $vc -Message "No credential provided. Skipping." -Level "WARN"
            continue
        }

        # Connect
        try {
            Write-VMwareLog -Function $funcName -VC $vc -Message "Connecting..."

            # Suppress PowerCLI certificate warnings in the same way
            $viServer = Connect-VIServer -Server $vc -Credential $cred -Force -ErrorAction Stop

            # Save credential for Runspace reconnects
            Export-VMwareCredential -VCenter $vc -Credential $cred

            # Store session
            $Global:VMwareSessions[$vc] = $viServer

            Write-VMwareLog -Function $funcName -VC $vc -Message "Connected. Build: $($viServer.ProductLine) $($viServer.Version)"

        } catch {
            Write-VMwareLog -Function $funcName -VC $vc -Message "Connection failed: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    # Show summary
    $connected = @($Global:VMwareSessions.Keys | Where-Object {
        $Global:VMwareSessions[$_] -and $Global:VMwareSessions[$_].IsConnected
    })
    Write-Host "`n[Connect-VMwareVC] Connected vCenters ($($connected.Count)): $($connected -join ', ')" -ForegroundColor Cyan
}

function Disconnect-VMwareVC {
    <#
    .SYNOPSIS
    Disconnect from one or more vCenters and clear the session map.
    #>
    [CmdletBinding()]
    param(
        [string[]]$VCenter
    )

    if (-not $Global:VMwareSessions) { return }

    $vcList = if ($VCenter -and $VCenter.Count -gt 0) {
        @($VCenter | ForEach-Object { $_.Trim().ToLowerInvariant() })
    } else {
        @($Global:VMwareSessions.Keys)
    }

    foreach ($vc in $vcList) {
        if ($Global:VMwareSessions.ContainsKey($vc)) {
            try {
                Disconnect-VIServer -Server $Global:VMwareSessions[$vc] -Confirm:$false -Force -ErrorAction SilentlyContinue
                Write-VMwareLog -Function "Disconnect-VMwareVC" -VC $vc -Message "Disconnected"
            } catch {}
            $Global:VMwareSessions.Remove($vc)
        }
    }
}

function Get-VMwareVC {
    <#
    .SYNOPSIS
    List currently connected vCenters and their connection status.
    #>
    if (-not $Global:VMwareSessions -or $Global:VMwareSessions.Count -eq 0) {
        Write-Host "No vCenter sessions. Run Connect-VMwareVC first." -ForegroundColor Yellow
        return
    }
    foreach ($vc in $Global:VMwareSessions.Keys) {
        $s = $Global:VMwareSessions[$vc]
        $status = if ($s -and $s.IsConnected) { "Connected" } else { "Disconnected" }
        $colour = if ($status -eq "Connected") { "Green" } else { "Red" }
        Write-Host ("  {0,-40} {1}" -f $vc, $status) -ForegroundColor $colour
    }
}
