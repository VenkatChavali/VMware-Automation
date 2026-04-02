# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : Structured log writer for VMware module
# Name          : Write-VMwareLog.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Write-VMwareLog {
    [CmdletBinding()]
    param(
        [string]$Function  = "Unknown",
        [string]$VC        = "",
        [string]$Message   = "",
        [ValidateSet("INFO","WARN","ERROR","DEBUG")]
        [string]$Level     = "INFO"
    )

    $ts      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $vcPart  = if ($VC) { "[$VC] " } else { "" }
    $line    = "$ts [$Level] [$Function] $vcPart$Message"

    # Console output
    $colour = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "DEBUG" { "DarkGray" }
        default { "Gray" }
    }
    Write-Host $line -ForegroundColor $colour

    # File output
    try {
        $logDir = $null
        try {
            $dirs = Get-VMwareDirs
            $logDir = $dirs.Logs
        } catch {
            $logDir = Join-Path $env:TEMP 'VMwareSiteAffinity_Logs'
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
        }
        $logFile = Join-Path $logDir ("VMwareSiteAffinity_{0}.log" -f (Get-Date -Format "yyyyMMdd"))
        $line | Out-File -LiteralPath $logFile -Append -Encoding utf8 -Force
    } catch {}
}
