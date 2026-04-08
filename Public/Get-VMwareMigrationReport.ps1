# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 09-Apr-2026
# Version       : 1.1
# Module Type   : Public
# Purpose       : Review generated VMware migration reports.
# =================================================

function Get-VMwareMigrationReport {
    [CmdletBinding()]
    param(
        [string]$Path,
        [ValidateSet('ALL','SUCCESS','FAILED','SKIPPED','TIMEOUT')]
        [string]$StatusFilter = 'ALL',
        [switch]$Latest,
        [switch]$SummaryOnly,
        [switch]$PassThru
    )

    $reportDir = Resolve-VMwareReportDir
    if (-not $Path) {
        if ($Latest) {
            $file = Get-ChildItem -LiteralPath $reportDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $file) {
                Write-Host 'No CSV reports found.' -ForegroundColor Yellow
                return
            }
            $Path = $file.FullName
        } else {
            $file = Get-ChildItem -LiteralPath $reportDir -Filter 'Summary_*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $file) { $file = Get-ChildItem -LiteralPath $reportDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
            if (-not $file) {
                Write-Host 'No CSV reports found.' -ForegroundColor Yellow
                return
            }
            $Path = $file.FullName
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host ("Report not found: {0}" -f $Path) -ForegroundColor Red
        return
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    if (-not $rows -or $rows.Count -eq 0) {
        Write-Host 'Report is empty.' -ForegroundColor Yellow
        return
    }

    $filtered = if ($StatusFilter -eq 'ALL') { $rows } else { @($rows | Where-Object { $_.Status -eq $StatusFilter }) }

    Write-Host ("`nReport: {0}" -f $Path) -ForegroundColor Cyan
    Write-Host ("Rows  : {0}" -f $rows.Count)
    Write-Host ("Shown : {0}" -f $filtered.Count)

    $byStatus = @($rows | Group-Object Status | Sort-Object Name)
    foreach ($g in $byStatus) {
        $color = switch ($g.Name) {
            'SUCCESS' { 'Green' }
            'FAILED'  { 'Red' }
            'SKIPPED' { 'Yellow' }
            'TIMEOUT' { 'Magenta' }
            default   { 'Gray' }
        }
        Write-Host ("  {0,-10} {1,5}" -f $g.Name, $g.Count) -ForegroundColor $color
    }

    if (-not $SummaryOnly) {
        Write-Host ''
        $filtered | Select-Object BatchId,VMName,VCenter,Cluster,SourceHostName,TargetHostName,Status,DurationMin,Remarks | Format-Table -AutoSize
    }

    if ($PassThru) { return $filtered }
}
