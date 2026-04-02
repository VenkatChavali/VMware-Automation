# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Module Type   : Public
# Purpose       : View, re-export or summarise any migration report.
#                 Same pattern as FusionCompute Get-FusionMigrationReport.
# Name          : Get-VMwareMigrationReport.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Get-VMwareMigrationReport {
    [CmdletBinding()]
    param(
        [string]$ReportPath,
        [switch]$Latest,
        [string[]]$StatusFilter,
        [switch]$PassThru
    )

    $reportsDir = Resolve-VMwareReportDir

    # Resolve file
    $csvFile = $null
    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        if (-not (Test-Path -LiteralPath $ReportPath)) {
            Write-Error "Report not found: $ReportPath"; return
        }
        $csvFile = $ReportPath
    } elseif ($Latest) {
        $candidates = @(
            Get-ChildItem -LiteralPath $reportsDir -Filter "Batch-*.csv" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        )
        if ($candidates.Count -eq 0) {
            # Try Summary files
            $candidates = @(
                Get-ChildItem -LiteralPath $reportsDir -Filter "Summary_*.csv" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
            )
        }
        if ($candidates.Count -eq 0) { Write-Warning "No reports found in $reportsDir"; return }
        $csvFile = $candidates[0].FullName
        Write-Host "Using: $($candidates[0].Name)" -ForegroundColor Cyan
    } else {
        $candidates = @(
            Get-ChildItem -LiteralPath $reportsDir -Filter "*.csv" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        )
        if ($candidates.Count -eq 0) { Write-Warning "No reports in $reportsDir"; return }
        Write-Host "`nAvailable reports:" -ForegroundColor Cyan
        Write-Host ("-" * 80)
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $f    = $candidates[$i]
            $size = [math]::Round($f.Length/1KB, 1)
            Write-Host ("  [{0,2}]  {1,-55}  {2,7} KB" -f ($i+1), $f.Name, $size)
        }
        Write-Host "  [ 0]  Browse for a file..." -ForegroundColor DarkGray
        Write-Host ("-" * 80)
        while ($true) {
            $raw = Read-Host "Enter number"
            $n   = $null
            if ([int]::TryParse($raw.Trim(), [ref]$n)) {
                if ($n -eq 0) {
                    Add-Type -AssemblyName System.Windows.Forms | Out-Null
                    $ofd = New-Object System.Windows.Forms.OpenFileDialog
                    $ofd.Filter = "CSV files (*.csv)|*.csv"; $ofd.InitialDirectory = $reportsDir
                    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $csvFile = $ofd.FileName }
                    else { return }; break
                } elseif ($n -ge 1 -and $n -le $candidates.Count) {
                    $csvFile = $candidates[$n-1].FullName; break
                }
            }
            Write-Host "  Invalid — enter 0-$($candidates.Count)" -ForegroundColor Yellow
        }
    }

    $data = @(Import-Csv -LiteralPath $csvFile -Encoding UTF8)
    if (-not $data -or $data.Count -eq 0) { Write-Warning "Report is empty: $csvFile"; return }

    Write-Host "`n[$($data.Count) rows] $(Split-Path $csvFile -Leaf)" -ForegroundColor Cyan

    $filtered = $data
    if ($StatusFilter -and $StatusFilter.Count -gt 0) {
        $filtered = @($data | Where-Object { $_.MigrationStatus -in $StatusFilter })
        Write-Host "Filter [$($StatusFilter -join ', ')]: $($filtered.Count) match(es)" -ForegroundColor Cyan
    }

    # Summary
    Write-Host ""
    Write-Host "===== STATUS BREAKDOWN =====" -ForegroundColor Yellow
    $data | Group-Object MigrationStatus | Sort-Object Name | ForEach-Object {
        $col = switch ($_.Name) { "SUCCESS" { "Green" } default { "Red" } }
        Write-Host ("  {0,-22} : {1}" -f $_.Name, $_.Count) -ForegroundColor $col
    }

    # Per-batch
    $batches = @($data | Where-Object { $_.BatchId -ne "" } |
        Group-Object BatchId | Sort-Object { [int]($_.Name -replace 'Batch-','') })
    if ($batches.Count -gt 0) {
        Write-Host ""
        Write-Host "===== PER-BATCH SUMMARY =====" -ForegroundColor Yellow
        Write-Host ("  {0,-12} {1,6} {2,8} {3,8} {4,10} {5,10} {6,12}" -f "Batch","VMs","✅","❌","Start","End","Duration")
        Write-Host ("  " + "-" * 72)
        foreach ($bg in $batches) {
            $rows = @($bg.Group)
            $ok   = @($rows | Where-Object { $_.MigrationStatus -eq "SUCCESS" }).Count
            $fail = @($rows | Where-Object { $_.MigrationStatus -notin @("SUCCESS","SKIPPED","") }).Count
            $starts = @($rows | Where-Object { $_.StartTime } | ForEach-Object { try { [datetime]$_.StartTime } catch {} } | Where-Object { $_ } | Sort-Object)
            $ends   = @($rows | Where-Object { $_.EndTime }   | ForEach-Object { try { [datetime]$_.EndTime }   catch {} } | Where-Object { $_ } | Sort-Object -Descending)
            $s = if ($starts.Count -gt 0) { $starts[0].ToString("HH:mm:ss") } else { "—" }
            $e = if ($ends.Count   -gt 0) { $ends[0].ToString("HH:mm:ss")   } else { "—" }
            $d = if ($starts.Count -gt 0 -and $ends.Count -gt 0) { "$([math]::Round(($ends[0]-$starts[0]).TotalMinutes,1)) min" } else { "—" }
            Write-Host ("  {0,-12} {1,6} {2,8} {3,8} {4,10} {5,10} {6,12}" -f $bg.Name, $rows.Count, $ok, $fail, $s, $e, $d) -ForegroundColor $(if ($fail -gt 0) {"Yellow"} else {"Green"})
        }
    }

    if ($StatusFilter -and $filtered.Count -gt 0) {
        Write-Host ""
        $filtered | Select-Object BatchId,VMName,VCenter,Cluster,MigrationStatus,VerifyStatus,Remarks,VerifyRemarks | Format-Table -AutoSize
    }

    if ($PassThru) { return $filtered }
}
