# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 09-Apr-2026
# Version       : 2.0
# Module Type   : Public
# Purpose       : Simplified end-to-end VMware DRS affinity change + manual vMotion.
#                 No runspaces. PowerShell 5.1 compatible.
# =================================================

function Invoke-VMwareSiteAffinityMigration {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param(
        [string[]]$VCenter,
        [switch]$UseCache,
        [switch]$RefreshCache,
        [int]$CacheMaxAgeHours        = 6,
        [int]$BatchSize               = 100,
        [int]$MaxConcurrentPerVC      = 6,
        [int]$MaxConcurrentPerCluster = 4,
        [int]$MaxGlobalConcurrent     = 12,
        [int]$MaxHostAllocatedPct     = 80,
        [int]$MaxRetry                = 1,
        [int]$PollIntervalSeconds     = 10,
        [int]$MaxMonitorMinutes       = 480,
        [int]$CpuMemRefreshAfter      = 50,
        [int]$CpuMemRefreshStaleMin   = 5,
        [switch]$DryRun,
        [ValidateSet('CSV')]
        [string[]]$ReportFormats = @('CSV')
    )

    $funcName  = 'Invoke-VMwareSiteAffinityMigration'
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportsDir = Resolve-VMwareReportDir

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing       | Out-Null

    $vcList = @()
    if ($VCenter -and $VCenter.Count -gt 0) {
        foreach ($v in $VCenter) {
            foreach ($p in ($v -split ',')) {
                $t = $p.Trim().ToLowerInvariant(); if ($t) { $vcList += $t }
            }
        }
    }
    if ($vcList.Count -eq 0) {
        try { $vcList = @($Global:VMwareSessions.Keys | Where-Object { $Global:VMwareSessions[$_] -and $Global:VMwareSessions[$_].IsConnected }) } catch {}
    }
    $vcList = @($vcList | Select-Object -Unique)
    if ($vcList.Count -eq 0) {
        Write-Warning "[$funcName] No connected vCenters. Run Connect-VMwareVC first."
        return
    }

    $vmNames = Show-VMwareMigrationInputDialog -ConnectedVCenters $vcList
    if (-not $vmNames -or $vmNames.Count -eq 0) {
        Write-Host "[$funcName] No VMs entered. Exiting." -ForegroundColor Yellow
        return
    }

    $plan = Get-VMwareMigrationPlan -VMNames $vmNames -VCenter $vcList -UseCache:$UseCache -RefreshCache:$RefreshCache -CacheMaxAgeHours $CacheMaxAgeHours -BatchSize $BatchSize -MaxHostAllocatedPct $MaxHostAllocatedPct
    if (-not $plan -or $plan.TotalVMs -eq 0) {
        Write-Warning "[$funcName] No VMs could be planned."
        return
    }

    if ($plan.Skipped -and @($plan.Skipped).Count -gt 0) {
        Write-Host "`n[$funcName] ----- Skipped VMs ($(@($plan.Skipped).Count)) -----" -ForegroundColor Yellow
        $plan.Skipped | Select-Object VMName,VCenter,Cluster,Status,Remarks | Format-Table -AutoSize
    }

    if ($DryRun) {
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($b in $plan.Batches) {
            foreach ($t in $b.Tasks) {
                [void]$rows.Add([pscustomobject]@{
                    BatchId         = $t.BatchId
                    VMName          = $t.VMName
                    VCenter         = $t.VCenter
                    Cluster         = $t.Cluster
                    VmMemoryGB      = $t.VmMemoryGB
                    SourceHostName  = $t.SourceHostName
                    SourceSite      = $t.SourceSite
                    TargetSite      = $t.TargetSite
                    Status          = 'PLANNED'
                    Remarks         = ''
                })
            }
        }
        foreach ($s in $plan.Skipped) { [void]$rows.Add($s) }
        $dryPath = Join-Path $reportsDir ("{0}_{1}_DryRun.csv" -f $funcName, $timestamp)
        $rows | Export-Csv -Path $dryPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host "[DryRun] $($rows.Count) rows exported: $dryPath" -ForegroundColor Green
        return $rows
    }

    if (-not $PSCmdlet.ShouldProcess("$($plan.TotalVMs) VM(s) across $($plan.TotalBatches) batch(es)", 'Change DRS affinity and vMotion')) { return }

    function New-ViewId { param($MoRef) if (-not $MoRef) { return $null }; return ('{0}-{1}' -f $MoRef.Type, $MoRef.Value) }

    function Refresh-TargetHostLoads {
        param([object[]]$Tasks)
        $byVc = @{}
        foreach ($t in $Tasks) {
            if (-not $byVc.ContainsKey($t.VCenter)) { $byVc[$t.VCenter] = @() }
            foreach ($hid in $t.TargetHostIds) { $byVc[$t.VCenter] += [string]$hid }
        }
        foreach ($vc in $byVc.Keys) {
            $uniqueIds = @($byVc[$vc] | Select-Object -Unique)
            if ($uniqueIds.Count -eq 0) { continue }
            try {
                $vmHostObjs = @(Get-VMHost -Server $Global:VMwareSessions[$vc] -Id $uniqueIds -ErrorAction SilentlyContinue)
                foreach ($h in $vmHostObjs) {
                    $hid = New-ViewId -MoRef $h.ExtensionData.MoRef
                    if ($plan.HostObjMap.ContainsKey($hid)) {
                        $cpu = $null; $mem = $null
                        try { if ($h.CpuUsageMhz -ge 0 -and $h.CpuTotalMhz -gt 0) { $cpu = [math]::Round(($h.CpuUsageMhz / $h.CpuTotalMhz) * 100, 1) } } catch {}
                        try { if ($h.MemoryUsageGB -ge 0 -and $h.MemoryTotalGB -gt 0) { $mem = [math]::Round(($h.MemoryUsageGB / $h.MemoryTotalGB) * 100, 1) } } catch {}
                        $plan.HostObjMap[$hid].CpuPct = $cpu
                        $plan.HostObjMap[$hid].MemPct = $mem
                    }
                }
            } catch {
                Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message ("Host refresh failed: {0}" -f $_.Exception.Message) -Level 'WARN'
            }
        }
    }

    $rrState = @{}
    function Get-EligibleTargetHost {
        param($Task)

        $eligible = New-Object System.Collections.Generic.List[object]
        foreach ($hid in @($Task.TargetHostIds)) {
            $h = $null
            if ($plan.HostObjMap.ContainsKey([string]$hid)) { $h = $plan.HostObjMap[[string]$hid] }
            if (-not $h) { continue }
            if ($h.InMaintenanceMode) { continue }
            if ($h.ConnectionState -and $h.ConnectionState.ToString().ToLowerInvariant() -ne 'connected') { continue }
            if ($Task.SourceHostId -and ([string]$Task.SourceHostId -eq [string]$h.Id)) { continue }
            if ($h.CpuPct -ne $null -and $h.CpuPct -gt $MaxHostAllocatedPct) { continue }
            if ($h.MemPct -ne $null -and $h.MemPct -gt $MaxHostAllocatedPct) { continue }
            [void]$eligible.Add($h)
        }
        if ($eligible.Count -eq 0) { return $null }

        $key = ('{0}|{1}|{2}' -f $Task.VCenter, $Task.Cluster, $Task.TargetSite)
        if (-not $rrState.ContainsKey($key)) { $rrState[$key] = 0 }
        $start = [int]$rrState[$key]
        $idx = $start % $eligible.Count
        $rrState[$key] = (($idx + 1) % $eligible.Count)
        return $eligible[$idx]
    }

    function Invoke-BulkAffinityFlip {
        param([object[]]$BatchTasks)
        $groups = @{}
        foreach ($t in $BatchTasks) {
            $ck = ('{0}|{1}' -f $t.VCenter, $t.Cluster)
            if (-not $groups.ContainsKey($ck)) { $groups[$ck] = New-Object System.Collections.Generic.List[object] }
            [void]$groups[$ck].Add($t)
        }

        foreach ($ck in $groups.Keys) {
            $batchClusterTasks = @($groups[$ck])
            if ($batchClusterTasks.Count -eq 0) { continue }
            $vc = [string]$batchClusterTasks[0].VCenter
            $clusterName = [string]$batchClusterTasks[0].Cluster
            $viSrv = $Global:VMwareSessions[$vc]
            try {
                $clObj = Get-Cluster -Name $clusterName -Server $viSrv -ErrorAction Stop
                $s01g  = Get-DrsClusterGroup -Cluster $clObj -Name 'site01_vms' -Server $viSrv -ErrorAction Stop
                $s02g  = Get-DrsClusterGroup -Cluster $clObj -Name 'site02_vms' -Server $viSrv -ErrorAction Stop

                $toSite01 = @()
                $toSite02 = @()
                foreach ($t in $batchClusterTasks) {
                    $vmKey = [string]$t.VmViewId
                    if ($vmKey -notmatch '^VirtualMachine-') { $vmKey = 'VirtualMachine-' + $vmKey.Trim() }
                    if (-not $plan.VmObjMap.ContainsKey($vmKey)) {
                        $t.Status = 'FAILED'
                        $t.Remarks = 'VM object not found in plan map'
                        $t.AffinityChangeStatus = 'FAILED'
                        $t.AffinityChangeRemarks = 'VM object not found'
                        continue
                    }
                    $vmObj = $plan.VmObjMap[$vmKey]
                    if ($t.SourceSite -eq 'site01') { $toSite02 += $vmObj } else { $toSite01 += $vmObj }
                }

                if ($toSite02.Count -gt 0) {
                    Set-DrsClusterGroup -DrsClusterGroup $s01g -Remove $toSite02 -Confirm:$false -ErrorAction Stop | Out-Null
                    Set-DrsClusterGroup -DrsClusterGroup $s02g -Add    $toSite02 -Confirm:$false -ErrorAction Stop | Out-Null
                }
                if ($toSite01.Count -gt 0) {
                    Set-DrsClusterGroup -DrsClusterGroup $s02g -Remove $toSite01 -Confirm:$false -ErrorAction Stop | Out-Null
                    Set-DrsClusterGroup -DrsClusterGroup $s01g -Add    $toSite01 -Confirm:$false -ErrorAction Stop | Out-Null
                }
                foreach ($t in $batchClusterTasks | Where-Object { $_.Status -eq 'QUEUED' }) {
                    $t.AffinityChangeStatus = 'SUCCESS'
                    $t.AffinityChangeRemarks = ("Moved: {0} -> {1}" -f $t.SourceSite, $t.TargetSite)
                }
            } catch {
                $msg = $_.Exception.Message
                Write-VMwareLog -Function $funcName -VC $vc -Message ("DRS affinity update failed for cluster [{0}]: {1}" -f $clusterName, $msg) -Level 'ERROR'
                foreach ($t in $batchClusterTasks | Where-Object { $_.Status -eq 'QUEUED' }) {
                    $t.AffinityChangeStatus = 'FAILED'
                    $t.AffinityChangeRemarks = $msg
                    $t.Status = 'FAILED'
                    $t.Remarks = 'DRS affinity change failed — skipping vMotion'
                }
            }
        }
    }

    function Start-PlannedMove {
        param($Task)
        $target = Get-EligibleTargetHost -Task $Task
        if (-not $target) {
            if ($Task.SourceHostId -and @($Task.TargetHostIds) -contains [string]$Task.SourceHostId) {
                $Task.Status = 'SKIPPED'
                $Task.Remarks = 'Source host already belongs to target host group. No migration required.'
            } else {
                $Task.Status = 'FAILED'
                $Task.Remarks = ("No eligible target host under {0}% CPU/MEM in target site [{1}]" -f $MaxHostAllocatedPct, $Task.TargetSite)
            }
            return $null
        }

        $Task.TargetHostName = [string]$target.Name
        $Task.TargetHostId = [string]$target.Id
        $Task.TargetHostCpuPct = $target.CpuPct
        $Task.TargetHostMemPct = $target.MemPct

        $vmKey = [string]$Task.VmViewId
        if ($vmKey -notmatch '^VirtualMachine-') { $vmKey = 'VirtualMachine-' + $vmKey.Trim() }
        if (-not $plan.VmObjMap.ContainsKey($vmKey)) {
            $Task.Status = 'FAILED'
            $Task.Remarks = 'VM object missing at dispatch time'
            return $null
        }
        $vmObj = $plan.VmObjMap[$vmKey]
        $vmHostObj = $target.Obj

        try {
            $taskObj = Move-VM -VM $vmObj -Destination $vmHostObj -RunAsync -Confirm:$false -ErrorAction Stop
            $Task.TaskId = [string]$taskObj.Id
            $Task.Status = 'RUNNING'
            $Task.StartTime = Get-Date
            $Task.Remarks = ("Dispatched -> {0} [CPU:{1}% MEM:{2}%]" -f $Task.TargetHostName, $Task.TargetHostCpuPct, $Task.TargetHostMemPct)
            return $taskObj
        } catch {
            $Task.RetryCount++
            if ($Task.RetryCount -le $MaxRetry) {
                $Task.Status = 'QUEUED'
                $Task.Remarks = ("Dispatch failed, will retry: {0}" -f $_.Exception.Message)
            } else {
                $Task.Status = 'FAILED'
                $Task.Remarks = ("Dispatch failed: {0}" -f $_.Exception.Message)
            }
            return $null
        }
    }

    $allRows = New-Object System.Collections.Generic.List[object]
    foreach ($s in @($plan.Skipped)) { [void]$allRows.Add($s) }

    Write-Host "`n===== MIGRATION PLAN =====" -ForegroundColor Cyan
    Write-Host "  Total VMs  : $($plan.TotalVMs)"
    Write-Host "  Batches    : $($plan.TotalBatches)"
    Write-Host "  Concurrent : $MaxConcurrentPerCluster/cluster  $MaxConcurrentPerVC/vCenter  $MaxGlobalConcurrent global"
    Write-Host ''

    foreach ($batch in $plan.Batches) {
        $batch.BatchStart = Get-Date
        $batchId = [string]$batch.BatchId
        $tasks = @($batch.Tasks)
        Write-Host ("`n===== {0} — {1} VM(s) =====" -f $batchId, $tasks.Count) -ForegroundColor Cyan

        Invoke-BulkAffinityFlip -BatchTasks $tasks

        $active = @{}
        $vcRunning = @{}
        $clusterRunning = @{}
        $globalRunning = 0
        $completedSinceRefresh = 0
        $lastRefresh = Get-Date
        $deadline = (Get-Date).AddMinutes($MaxMonitorMinutes)

        do {
            # poll active tasks
            foreach ($taskId in @($active.Keys)) {
                $meta = $active[$taskId]
                $ptask = $meta.PowerCLITask
                $t = $meta.TaskRow
                try {
                    $current = Get-Task -Id $ptask.Id -Server $Global:VMwareSessions[$t.VCenter] -ErrorAction SilentlyContinue
                    if ($current -and $current.State -in @('Success','Error')) {
                        $t.EndTime = Get-Date
                        try { $t.DurationMin = [math]::Round(((New-TimeSpan -Start $t.StartTime -End $t.EndTime).TotalMinutes), 2) } catch {}
                        if ($current.State -eq 'Success') {
                            $t.Status = 'SUCCESS'
                            $t.Remarks = ("SUCCESS -> {0} [CPU:{1}% MEM:{2}%]" -f $t.TargetHostName, $t.TargetHostCpuPct, $t.TargetHostMemPct)
                            Write-Host ("  ✓ {0,-35} {1}" -f $t.VMName, $t.TargetHostName) -ForegroundColor Green
                        } else {
                            $t.RetryCount++
                            if ($t.RetryCount -le $MaxRetry) {
                                $t.Status = 'QUEUED'
                                $t.TaskId = $null
                                $t.StartTime = $null
                                $t.EndTime = $null
                                $t.DurationMin = $null
                                $t.Remarks = ("Task failed, retry queued: {0}" -f $current.DescriptionId)
                                Write-Host ("  ✗ {0,-35} retry queued" -f $t.VMName) -ForegroundColor Yellow
                            } else {
                                $t.Status = 'FAILED'
                                $t.Remarks = 'Task failed — max retries exhausted'
                                Write-Host ("  ✗ {0,-35} failed" -f $t.VMName) -ForegroundColor Red
                            }
                        }
                        $currentVcCount = 0
                        if ($vcRunning.ContainsKey($t.VCenter)) { $currentVcCount = [int]$vcRunning[$t.VCenter] }
                        $vcRunning[$t.VCenter] = [math]::Max(0, ($currentVcCount - 1))
                        $clusterKey = ('{0}|{1}' -f $t.VCenter, $t.Cluster)
                        $currentClusterCount = 0
                        if ($clusterRunning.ContainsKey($clusterKey)) { $currentClusterCount = [int]$clusterRunning[$clusterKey] }
                        $clusterRunning[$clusterKey] = [math]::Max(0, ($currentClusterCount - 1))
                        $globalRunning = [math]::Max(0, $globalRunning - 1)
                        $active.Remove($taskId)
                        $completedSinceRefresh++
                    }
                } catch {}
            }

            if ($completedSinceRefresh -ge $CpuMemRefreshAfter -and ((Get-Date) - $lastRefresh).TotalMinutes -ge $CpuMemRefreshStaleMin) {
                Refresh-TargetHostLoads -Tasks $tasks
                $lastRefresh = Get-Date
                $completedSinceRefresh = 0
            }

            $queue = @($tasks | Where-Object { $_.AffinityChangeStatus -eq 'SUCCESS' -and $_.Status -eq 'QUEUED' })
            foreach ($t in $queue) {
                if ((Get-Date) -ge $deadline) { break }
                $vcCount = if ($vcRunning.ContainsKey($t.VCenter)) { $vcRunning[$t.VCenter] } else { 0 }
                $clusterKey = ('{0}|{1}' -f $t.VCenter, $t.Cluster)
                $clusterCount = if ($clusterRunning.ContainsKey($clusterKey)) { $clusterRunning[$clusterKey] } else { 0 }
                if ($vcCount -ge $MaxConcurrentPerVC) { continue }
                if ($clusterCount -ge $MaxConcurrentPerCluster) { continue }
                if ($globalRunning -ge $MaxGlobalConcurrent) { continue }

                $pwTask = Start-PlannedMove -Task $t
                if ($pwTask) {
                    $active[[string]$pwTask.Id] = @{ PowerCLITask=$pwTask; TaskRow=$t }
                    $vcRunning[$t.VCenter] = $vcCount + 1
                    $clusterRunning[$clusterKey] = $clusterCount + 1
                    $globalRunning++
                }
            }

            $done = @($tasks | Where-Object { $_.Status -in @('SUCCESS','FAILED','SKIPPED') }).Count
            $running = @($tasks | Where-Object { $_.Status -eq 'RUNNING' }).Count
            $queued = @($tasks | Where-Object { $_.Status -eq 'QUEUED' }).Count
            $pct = [math]::Round(($done / [math]::Max(1,$tasks.Count)) * 100)
            Write-Progress -Id 1 -Activity ("[$batchId] VMware Site Affinity + vMotion") -Status ("Total:{0} Success:{1} Running:{2} Queued:{3} Failed:{4} Skipped:{5}" -f $tasks.Count, (@($tasks | ?{$_.Status -eq 'SUCCESS'}).Count), $running, $queued, (@($tasks | ?{$_.Status -eq 'FAILED'}).Count), (@($tasks | ?{$_.Status -eq 'SKIPPED'}).Count)) -PercentComplete $pct

            if ((@($tasks | Where-Object { $_.Status -in @('QUEUED','RUNNING') }).Count) -gt 0 -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds ([math]::Max(2,$PollIntervalSeconds))
            }
        } until ((@($tasks | Where-Object { $_.Status -in @('QUEUED','RUNNING') }).Count) -eq 0 -or (Get-Date) -ge $deadline)
        Write-Progress -Id 1 -Activity ("[$batchId] VMware Site Affinity + vMotion") -Completed

        foreach ($t in @($tasks | Where-Object { $_.Status -eq 'RUNNING' })) {
            $t.Status = 'TIMEOUT'
            $t.Remarks = ("Timed out after {0} min" -f $MaxMonitorMinutes)
        }
        foreach ($t in @($tasks | Where-Object { $_.Status -eq 'QUEUED' })) {
            $t.Status = 'FAILED'
            if (-not $t.Remarks) { $t.Remarks = 'Unable to dispatch before deadline' }
        }

        $batch.BatchEnd = Get-Date
        try { $batch.BatchDurMin = [math]::Round(((New-TimeSpan -Start $batch.BatchStart -End $batch.BatchEnd).TotalMinutes),2) } catch {}

        $batchPath = Join-Path $reportsDir ("{0}_{1}.csv" -f $batchId, $timestamp)
        $tasks | Select-Object BatchId,VMName,VCenter,Cluster,VmMemoryGB,SourceHostName,SourceSite,TargetSite,AffinityChangeStatus,AffinityChangeRemarks,TargetHostName,TargetHostCpuPct,TargetHostMemPct,Status,RetryCount,TaskId,StartTime,EndTime,DurationMin,Remarks | Export-Csv -Path $batchPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host ("  Report: {0}" -f $batchPath) -ForegroundColor Cyan

        foreach ($t in $tasks) { [void]$allRows.Add($t) }
    }

    $summaryPath = Join-Path $reportsDir ("Summary_{0}.csv" -f $timestamp)
    $allRows | Select-Object BatchId,VMName,VCenter,Cluster,VmMemoryGB,SourceHostName,SourceSite,TargetSite,AffinityChangeStatus,AffinityChangeRemarks,TargetHostName,TargetHostCpuPct,TargetHostMemPct,Status,RetryCount,TaskId,StartTime,EndTime,DurationMin,Remarks | Export-Csv -Path $summaryPath -NoTypeInformation -Force -Encoding UTF8

    Write-Host "`n===== $funcName SUMMARY =====" -ForegroundColor Cyan
    Write-Host ("  Total Rows : {0}" -f $allRows.Count)
    Write-Host ("  Success    : {0}" -f (@($allRows | Where-Object { $_.Status -eq 'SUCCESS' }).Count)) -ForegroundColor Green
    Write-Host ("  Failed     : {0}" -f (@($allRows | Where-Object { $_.Status -eq 'FAILED' }).Count)) -ForegroundColor Red
    Write-Host ("  Skipped    : {0}" -f (@($allRows | Where-Object { $_.Status -eq 'SKIPPED' }).Count)) -ForegroundColor Yellow
    Write-Host ("  Summary    : {0}" -f $summaryPath) -ForegroundColor Cyan

    return $allRows
}
