# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 08-Apr-2026
# Version       : 2.0
# Module Type   : Public
# Purpose       : End-to-end VMware DRS affinity change + vMotion.
#                 Sequential execution — no RunspacePool, no GUI.
#                 Retry after full pass. 9000 VM capable.
# Name          : Invoke-VMwareSiteAffinityMigration.ps1
# Compatibility : PS 5.1-compatible (requires VMware.PowerCLI)
# =================================================

function Invoke-VMwareSiteAffinityMigration {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
    param(
        [string[]]$VCenter,
        [switch]$UseCache,
        [switch]$RefreshCache,
        [int]$CacheMaxAgeHours        = 6,
        [int]$BatchSize               = 100,
        [int]$MaxConcurrentPerVC      = 10,
        [int]$MaxConcurrentPerCluster = 8,
        [int]$MaxGlobalConcurrent     = 30,
        [int]$MaxHostAllocatedPct     = 80,
        [int]$MaxRetry                = 2,
        [int]$PollIntervalSeconds     = 10,
        [int]$MaxMonitorMinutes       = 480,
        [int]$CpuMemRefreshAfter      = 50,
        [int]$CpuMemRefreshStaleMin   = 5,
        [switch]$DryRun,
        [ValidateSet("HTML")]
        [string[]]$ReportFormats
    )

    $funcName   = "Invoke-VMwareSiteAffinityMigration"
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportsDir = Resolve-VMwareReportDir

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing       | Out-Null

    # ----------------------------------------------------------------
    # 1. Resolve vCenter list
    # ----------------------------------------------------------------
    $vcList = @()
    if ($VCenter -and $VCenter.Count -gt 0) {
        foreach ($v in $VCenter) {
            foreach ($p in ($v -split ',')) {
                $t = $p.Trim().ToLowerInvariant(); if ($t) { $vcList += $t }
            }
        }
    }
    if ($vcList.Count -eq 0) {
        try { $vcList = @($Global:VMwareSessions.Keys | Where-Object { $Global:VMwareSessions[$_].IsConnected }) } catch {}
    }
    $vcList = @($vcList | Select-Object -Unique)

    if ($vcList.Count -eq 0) {
        Write-Warning "[$funcName] No connected vCenters. Run Connect-VMwareVC first."
        return
    }

    # ----------------------------------------------------------------
    # 2. VM input GUI
    # ----------------------------------------------------------------
    $vmNames = Show-VMwareMigrationInputDialog -ConnectedVCenters $vcList
    if (-not $vmNames -or $vmNames.Count -eq 0) {
        Write-Host "[$funcName] No VMs entered. Exiting." -ForegroundColor Yellow
        return
    }

    # ----------------------------------------------------------------
    # 3. Build migration plan
    # ----------------------------------------------------------------
    $plan = Get-VMwareMigrationPlan `
        -VMNames          $vmNames `
        -VCenter          $vcList `
        -UseCache:$UseCache `
        -RefreshCache:$RefreshCache `
        -CacheMaxAgeHours $CacheMaxAgeHours `
        -BatchSize        $BatchSize `
        -MaxHostAllocatedPct $MaxHostAllocatedPct

    if ($plan -and $plan.Skipped -and @($plan.Skipped).Count -gt 0) {
        Write-Host "`n[$funcName] ----- Skipped VMs ($(@($plan.Skipped).Count)) -----" -ForegroundColor Yellow
        $plan.Skipped | Select-Object VMName,VCenter,Cluster,Status,Remarks | Format-Table -AutoSize
    }

    if (-not $plan -or $plan.TotalVMs -eq 0) {
        Write-Warning "[$funcName] No VMs could be planned."
        return
    }

    # ----------------------------------------------------------------
    # 4. DryRun
    # ----------------------------------------------------------------
    if ($DryRun) {
        $planRows = New-Object System.Collections.Generic.List[object]
        foreach ($b in $plan.Batches) {
            foreach ($t in $b.Tasks) {
                [void]$planRows.Add([pscustomobject]@{
                    BatchId=$t.BatchId; VMName=$t.VMName; VCenter=$t.VCenter
                    Cluster=$t.Cluster; VmMemoryGB=$t.VmMemoryGB
                    SourceHostName=$t.SourceHostName; SourceSite=$t.SourceSite
                    TargetSite=$t.TargetSite; Status="PLANNED"; Remarks=""
                })
            }
        }
        foreach ($s in $plan.Skipped) {
            [void]$planRows.Add([pscustomobject]@{
                BatchId=""; VMName=$s.VMName; VCenter=$s.VCenter
                Cluster=$s.Cluster; VmMemoryGB=""
                SourceHostName=""; SourceSite=""; TargetSite=""
                Status=$s.Status; Remarks=$s.Remarks
            })
        }
        $dryPath = Join-Path $reportsDir "$funcName`_$timestamp`_DryRun.csv"
        $planRows | Export-Csv -Path $dryPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host "[DryRun] $($planRows.Count) rows: $dryPath" -ForegroundColor Green
        $planRows | Select-Object BatchId,VMName,Cluster,SourceSite,TargetSite,Status,Remarks | Format-Table -AutoSize
        return
    }

    if (-not $PSCmdlet.ShouldProcess(
        "$($plan.TotalVMs) VM(s) across $($plan.TotalBatches) batch(es)",
        "Change DRS affinity and vMotion")) { return }

    # ----------------------------------------------------------------
    # 5. Show plan summary
    # ----------------------------------------------------------------
    Write-Host "`n===== VMware MIGRATION PLAN =====" -ForegroundColor Cyan
    Write-Host "  Total VMs  : $($plan.TotalVMs)"
    Write-Host "  Batches    : $($plan.TotalBatches)"
    Write-Host "  Concurrent : $MaxConcurrentPerCluster/cluster  $MaxConcurrentPerVC/vCenter  $MaxGlobalConcurrent global"
    Write-Host "  Poll every : $PollIntervalSeconds s   Timeout: $MaxMonitorMinutes min"
    Write-Host ""
    foreach ($b in $plan.Batches) {
        Write-Host ("  {0}  — {1,3} VM(s)  [site01:{2} site02:{3}]" -f `
            $b.BatchId, $b.VMCount, $b.Site01Count, $b.Site02Count) -ForegroundColor Gray
    }
    Write-Host ""

    # ----------------------------------------------------------------
    # 6. Helpers
    # ----------------------------------------------------------------
    $rrState = @{}

    function Select-TargetHost {
        param($task)
        $hids = @($task.TargetHostIds)
        if ($hids.Count -eq 0) { return $null }

        $rrKey = "$($task.VCenter)|$($task.Cluster)|$($task.TargetSite)"
        if (-not $rrState.ContainsKey($rrKey)) { $rrState[$rrKey] = 0 }
        $start = $rrState[$rrKey]

        for ($a = 0; $a -lt $hids.Count; $a++) {
            $idx = ($start + $a) % $hids.Count
            $hid = $hids[$idx]
            $h   = if ($plan.HostObjMap.ContainsKey($hid)) { $plan.HostObjMap[$hid] } else { $null }
            if (-not $h) { continue }
            $cpuOk = ($null -eq $h.CpuPct -or $h.CpuPct -le $MaxHostAllocatedPct)
            $memOk = ($null -eq $h.MemPct -or $h.MemPct -le $MaxHostAllocatedPct)
            if ($cpuOk -and $memOk) {
                $rrState[$rrKey] = (($idx + 1) % $hids.Count)
                return $h
            }
        }
        return $null
    }

    function Dispatch-VMTask {
        param($task, [hashtable]$VcRunning, [hashtable]$ClRunning, [ref]$TotalRunning, $ViServer)
        $host = Select-TargetHost -task $task
        if (-not $host) {
            $task.Status  = "FAILED"
            $task.Remarks = "No host under $MaxHostAllocatedPct% in [$($task.TargetSite)]"
            return $false
        }

        $vmObj = if ($plan.VmObjMap.ContainsKey($task.VmMoRefId)) { $plan.VmObjMap[$task.VmMoRefId] } else { $null }
        if (-not $vmObj) {
            $task.Status  = "FAILED"
            $task.Remarks = "VM object not in plan map"
            return $false
        }

        try {
            Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
            $pTask = Move-VM -VM $vmObj -Destination $host.Obj -RunAsync -Confirm:$false -ErrorAction Stop

            $task.TaskId         = [string]$pTask.Id
            $task.TargetHostName = $host.Name
            $task.TargetHostCpu  = $host.CpuPct
            $task.TargetHostMem  = $host.MemPct
            $task.Status         = "RUNNING"
            $task.StartTime      = Get-Date
            $task.Remarks        = "Dispatched -> $($host.Name) [CPU:$($host.CpuPct)% MEM:$($host.MemPct)%]"

            if (-not $VcRunning.ContainsKey($task.VCenter))  { $VcRunning[$task.VCenter]  = 0 }
            if (-not $ClRunning.ContainsKey($task.Cluster))  { $ClRunning[$task.Cluster]  = 0 }
            $VcRunning[$task.VCenter]++
            $ClRunning[$task.Cluster]++
            $TotalRunning.Value++

            Write-Host ("    → {0,-38} -> {1} [CPU:{2}% MEM:{3}%]" -f `
                $task.VMName, $host.Name, $host.CpuPct, $host.MemPct) -ForegroundColor Cyan
            return $true
        } catch {
            $task.Status  = "FAILED"
            $task.Remarks = "Move-VM error: $($_.Exception.Message)"
            Write-Host ("    ✗ {0,-38} {1}" -f $task.VMName, $task.Remarks) -ForegroundColor Red
            return $false
        }
    }

    function Poll-RunningTasks {
        # Accepts a RunningList (Generic.List) for O(n_running) scan — not O(n_all_tasks)
        # Removes completed tasks from RunningList in-place
        param(
            [object[]]$Tasks,
            [hashtable]$VcRunning,
            [hashtable]$ClRunning,
            [ref]$TotalRunning,
            $ViServer,
            [System.Collections.Generic.List[object]]$RunningList
        )

        # If RunningList provided, use it (fast path for large batches)
        # Otherwise fall back to scanning Tasks array
        $toScan = if ($RunningList -and $RunningList.Count -gt 0) {
            @($RunningList)
        } else {
            @($Tasks | Where-Object { $_.Status -eq "RUNNING" -and $_.TaskId })
        }

        $completed = New-Object System.Collections.Generic.List[object]

        foreach ($t in $toScan) {
            try {
                $pt = Get-Task -Id $t.TaskId -ErrorAction SilentlyContinue
                if ($pt -and $pt.State -in @("Success","Error")) {
                    $end = if ($pt.FinishTime) { $pt.FinishTime } else { Get-Date }
                    $t.EndTime = $end
                    try { $t.DurationMin = [math]::Round(((New-TimeSpan -Start $t.StartTime -End $end).TotalMinutes),2) } catch {}

                    if (-not $VcRunning.ContainsKey($t.VCenter)) { $VcRunning[$t.VCenter] = 0 }
                    if (-not $ClRunning.ContainsKey($t.Cluster))  { $ClRunning[$t.Cluster]  = 0 }
                    $VcRunning[$t.VCenter] = [math]::Max(0, $VcRunning[$t.VCenter] - 1)
                    $ClRunning[$t.Cluster]  = [math]::Max(0, $ClRunning[$t.Cluster]  - 1)
                    $TotalRunning.Value     = [math]::Max(0, $TotalRunning.Value - 1)

                    if ($pt.State -eq "Success") {
                        $t.Status  = "SUCCESS"
                        $t.Remarks = "SUCCESS -> $($t.TargetHostName) [CPU:$($t.TargetHostCpu)% MEM:$($t.TargetHostMem)%] $($t.DurationMin) min"
                        Write-Host ("    ✓ {0,-38} $($t.DurationMin) min -> $($t.TargetHostName)" -f $t.VMName) -ForegroundColor Green
                    } else {
                        $errMsg = ""
                        try { if ($pt.ExtensionData -and $pt.ExtensionData.Error) { $errMsg = $pt.ExtensionData.Error.LocalizedMessage } } catch {}
                        $t.Status  = "FAILED_PENDING_RETRY"
                        $t.Remarks = "FAILED ($errMsg) — queued for retry"
                        Write-Host ("    ✗ {0,-38} FAILED — retry after pass" -f $t.VMName) -ForegroundColor Yellow
                    }
                    [void]$completed.Add($t)
                }
            } catch {}
        }

        # Remove completed from RunningList
        if ($RunningList) {
            foreach ($c in $completed) { [void]$RunningList.Remove($c) }
        }
    }

    function Refresh-HostLoad {
        param([string[]]$VCenters)
        foreach ($vc in $VCenters) {
            $viSrv = $Global:VMwareSessions[$vc]
            if (-not $viSrv -or -not $viSrv.IsConnected) { continue }
            $hids = @($plan.HostObjMap.Keys)
            try {
                $hostObjs = @(Get-VMHost -Server $viSrv -Id $hids -ErrorAction SilentlyContinue)
                foreach ($h in $hostObjs) {
                    $hid = "$($h.ExtensionData.MoRef.Type)-$($h.ExtensionData.MoRef.Value)"
                    if ($plan.HostObjMap.ContainsKey($hid)) {
                        $cpu = $null; $mem = $null
                        try { if ($h.CpuUsageMhz -gt 0 -and $h.CpuTotalMhz -gt 0) { $cpu = [math]::Round(($h.CpuUsageMhz/$h.CpuTotalMhz)*100,1) } } catch {}
                        try { if ($h.MemoryUsageGB -gt 0 -and $h.MemoryTotalGB -gt 0) { $mem = [math]::Round(($h.MemoryUsageGB/$h.MemoryTotalGB)*100,1) } } catch {}
                        $plan.HostObjMap[$hid].CpuPct = $cpu
                        $plan.HostObjMap[$hid].MemPct = $mem
                    }
                }
            } catch {}
        }
    }

    # ----------------------------------------------------------------
    # 7. Execute batches sequentially
    # ----------------------------------------------------------------
    $allTasks = New-Object System.Collections.Generic.List[object]

    foreach ($batch in $plan.Batches) {
        $bId    = $batch.BatchId
        $tasks  = @($batch.Tasks)
        $bStart = Get-Date

        Write-Host "`n===== $bId — $($tasks.Count) VM(s) =====" -ForegroundColor Cyan

        # ---- Step A: DRS affinity change (batch per cluster) ----
        Write-Host "  [Step A] DRS affinity change..." -ForegroundColor Yellow

        $clustersByVc = @{}
        foreach ($t in $tasks) {
            $ck = "$($t.VCenter)|$($t.Cluster)"
            if (-not $clustersByVc.ContainsKey($ck)) { $clustersByVc[$ck] = @{ VC=$t.VCenter; Cluster=$t.Cluster; Tasks=New-Object System.Collections.Generic.List[object] } }
            [void]$clustersByVc[$ck].Tasks.Add($t)
        }

        foreach ($ck in $clustersByVc.Keys) {
            $vc    = $clustersByVc[$ck].VC
            $cln   = $clustersByVc[$ck].Cluster
            $cTasks = @($clustersByVc[$ck].Tasks)
            $viSrv = $Global:VMwareSessions[$vc]

            try {
                $clObj = Get-Cluster -Name $cln -Server $viSrv -ErrorAction Stop
                $s01g  = Get-DrsClusterGroup -Cluster $clObj -Name "site01_vms" -Server $viSrv -ErrorAction SilentlyContinue
                $s02g  = Get-DrsClusterGroup -Cluster $clObj -Name "site02_vms" -Server $viSrv -ErrorAction SilentlyContinue

                $toSite01 = New-Object System.Collections.Generic.List[object]
                $toSite02 = New-Object System.Collections.Generic.List[object]

                foreach ($t in $cTasks) {
                    $vmObj = if ($plan.VmObjMap.ContainsKey($t.VmMoRefId)) { $plan.VmObjMap[$t.VmMoRefId] } else { $null }
                    if (-not $vmObj) { $t.AffinityStatus = "FAILED"; $t.AffinityRemark = "VM object not found"; continue }
                    if ($t.SourceSite -eq "site01") { [void]$toSite02.Add($vmObj) }
                    else                             { [void]$toSite01.Add($vmObj) }
                }

                if ($toSite02.Count -gt 0 -and $s01g -and $s02g) {
                    Set-DrsClusterGroup -DrsClusterGroup $s01g -Remove $toSite02.ToArray() -Confirm:$false -ErrorAction Stop | Out-Null
                    Set-DrsClusterGroup -DrsClusterGroup $s02g -Add    $toSite02.ToArray() -Confirm:$false -ErrorAction Stop | Out-Null
                }
                if ($toSite01.Count -gt 0 -and $s01g -and $s02g) {
                    Set-DrsClusterGroup -DrsClusterGroup $s02g -Remove $toSite01.ToArray() -Confirm:$false -ErrorAction Stop | Out-Null
                    Set-DrsClusterGroup -DrsClusterGroup $s01g -Add    $toSite01.ToArray() -Confirm:$false -ErrorAction Stop | Out-Null
                }

                foreach ($t in $cTasks) {
                    if (-not $t.AffinityStatus) {
                        $t.AffinityStatus = "SUCCESS"
                        $t.AffinityRemark = "Moved: $($t.SourceSite) -> $($t.TargetSite)"
                    }
                }
                Write-Host ("    ✓ $cln  — site01->site02: $($toSite02.Count)  site02->site01: $($toSite01.Count)") -ForegroundColor Green
            } catch {
                $errMsg = $_.Exception.Message
                foreach ($t in $cTasks) {
                    $t.AffinityStatus = "FAILED"; $t.AffinityRemark = "DRS error: $errMsg"
                    $t.Status = "FAILED"; $t.Remarks = "DRS affinity change failed"
                }
                Write-Host ("    ✗ $cln  DRS failed: $errMsg") -ForegroundColor Red
            }
        }

        $afOk   = @($tasks | Where-Object { $_.AffinityStatus -eq "SUCCESS" }).Count
        $afFail = @($tasks | Where-Object { $_.AffinityStatus -eq "FAILED"  }).Count
        Write-Host ("  Affinity done — ✅ $afOk  ❌ $afFail") -ForegroundColor Cyan

        # ---- Step B: vMotion dispatch ----
        Write-Host "`n  [Step B] vMotion dispatch..." -ForegroundColor Yellow

        $vcRunning    = @{}
        $clRunning    = @{}
        $totalRunning = 0
        $trRef        = [ref]$totalRunning
        $viServerMap  = @{}
        foreach ($vc in $vcList) { $viServerMap[$vc] = $Global:VMwareSessions[$vc] }

        # RunningList — only tracks RUNNING tasks, avoids scanning all 3000+ tasks
        $runningList           = New-Object System.Collections.Generic.List[object]
        $completedSinceRefresh = 0
        $lastRefresh           = [datetime]::MinValue

        foreach ($t in @($tasks | Where-Object { $_.AffinityStatus -eq "SUCCESS" -and $_.Status -eq "QUEUED" })) {

            # Wait for slot — scan only running list, not all tasks
            $waited = 0
            while ($true) {
                $vr = if ($vcRunning.ContainsKey($t.VCenter))  { $vcRunning[$t.VCenter]  } else { 0 }
                $cr = if ($clRunning.ContainsKey($t.Cluster))   { $clRunning[$t.Cluster]   } else { 0 }
                if ($vr -lt $MaxConcurrentPerVC -and $cr -lt $MaxConcurrentPerCluster -and $totalRunning -lt $MaxGlobalConcurrent) { break }

                Start-Sleep -Seconds 3; $waited += 3
                if ($waited -gt ($MaxMonitorMinutes * 60)) { $t.Status = "TIMEOUT"; $t.Remarks = "Timed out waiting for slot"; break }

                $prevCount = $runningList.Count
                Poll-RunningTasks -Tasks $tasks -VcRunning $vcRunning -ClRunning $clRunning -TotalRunning $trRef -ViServer $null -RunningList $runningList
                $totalRunning = $trRef.Value
                $completedSinceRefresh += ($prevCount - $runningList.Count)

                # Refresh host load during dispatch — matters for target host selection
                if ($completedSinceRefresh -ge $CpuMemRefreshAfter) {
                    $ageMin = ((Get-Date) - $lastRefresh).TotalMinutes
                    if ($ageMin -ge $CpuMemRefreshStaleMin) {
                        Refresh-HostLoad -VCenters $vcList
                        $lastRefresh = Get-Date; $completedSinceRefresh = 0
                        Write-Host "  [Dispatch] Host load refreshed" -ForegroundColor DarkCyan
                    }
                }
            }
            if ($t.Status -eq "TIMEOUT") { continue }
            $dispatched = Dispatch-VMTask -task $t -VcRunning $vcRunning -ClRunning $clRunning -TotalRunning $trRef -ViServer $viServerMap[$t.VCenter]
            $totalRunning = $trRef.Value
            if ($dispatched) { [void]$runningList.Add($t) }
        }

        # ---- Step C: Monitor until all done ----
        Write-Host "`n  [Step C] Monitoring..." -ForegroundColor Yellow
        $deadline = (Get-Date).AddMinutes($MaxMonitorMinutes)
        $completedSinceRefresh = 0
        $lastRefresh = [datetime]::MinValue

        do {
            Start-Sleep -Seconds $PollIntervalSeconds

            # Step C — no host refresh needed, all VMs already dispatched
            Poll-RunningTasks -Tasks $tasks -VcRunning $vcRunning -ClRunning $clRunning -TotalRunning $trRef -ViServer $null -RunningList $runningList
            $totalRunning = $trRef.Value

            $stillRunning = $runningList.Count
            $doneCount    = @($tasks | Where-Object { $_.Status -in @("SUCCESS","FAILED","FAILED_PENDING_RETRY","TIMEOUT") }).Count

            Write-Progress -Id 1 -Activity "[$bId] vMotion" `
                -Status "Done:$doneCount Running:$stillRunning Total:$($tasks.Count)" `
                -PercentComplete ([math]::Round(($doneCount / [math]::Max(1,$tasks.Count)) * 100))

        } until ($stillRunning -eq 0 -or (Get-Date) -ge $deadline)

        Write-Progress -Id 1 -Activity "[$bId] vMotion" -Completed

        # Timeout stragglers
        foreach ($t in @($tasks | Where-Object { $_.Status -eq "RUNNING" })) {
            $t.Status = "TIMEOUT"; $t.Remarks = "Timed out after $MaxMonitorMinutes min"
            if (-not $vcRunning.ContainsKey($t.VCenter)) { $vcRunning[$t.VCenter] = 0 }
            if (-not $clRunning.ContainsKey($t.Cluster))  { $clRunning[$t.Cluster]  = 0 }
            $vcRunning[$t.VCenter] = [math]::Max(0, $vcRunning[$t.VCenter] - 1)
            $clRunning[$t.Cluster]  = [math]::Max(0, $clRunning[$t.Cluster]  - 1)
            $totalRunning           = [math]::Max(0, $totalRunning - 1)
        }

        # ---- Step D: Retry failures after full pass ----
        $toRetry = @($tasks | Where-Object { $_.Status -eq "FAILED_PENDING_RETRY" -and $_.RetryCount -lt $MaxRetry })
        if ($toRetry.Count -gt 0) {
            Write-Host "`n  [Step D] Retrying $($toRetry.Count) failed VM(s)..." -ForegroundColor Yellow
            foreach ($t in $toRetry) {
                $t.RetryCount++; $t.Status = "QUEUED"
                $t.TaskId=$null; $t.StartTime=$null; $t.EndTime=$null; $t.DurationMin=$null
                $t.Remarks = "Retry $($t.RetryCount)/$MaxRetry"
            }
            foreach ($t in $toRetry) {
                $waited = 0
                while ($true) {
                    $vr = if ($vcRunning.ContainsKey($t.VCenter)) { $vcRunning[$t.VCenter] } else { 0 }
                    $cr = if ($clRunning.ContainsKey($t.Cluster))  { $clRunning[$t.Cluster]  } else { 0 }
                    if ($vr -lt $MaxConcurrentPerVC -and $cr -lt $MaxConcurrentPerCluster -and $totalRunning -lt $MaxGlobalConcurrent) { break }
                    Start-Sleep -Seconds 3; $waited += 3
                    if ($waited -gt 300) { $t.Status = "FAILED"; $t.Remarks = "Retry slot timeout"; break }
                    Poll-RunningTasks -Tasks $toRetry -VcRunning $vcRunning -ClRunning $clRunning -TotalRunning $trRef -ViServer $null
                    $totalRunning = $trRef.Value
                }
                if ($t.Status -eq "QUEUED") {
                    Dispatch-VMTask -task $t -VcRunning $vcRunning -ClRunning $clRunning -TotalRunning $trRef -ViServer $viServerMap[$t.VCenter]
                    $totalRunning = $trRef.Value
                }
            }
            # Poll retries to completion
            $retryDeadline = (Get-Date).AddMinutes([math]::Min(60, $MaxMonitorMinutes))
            do {
                Start-Sleep -Seconds $PollIntervalSeconds
                Poll-RunningTasks -Tasks $toRetry -VcRunning $vcRunning -ClRunning $clRunning -TotalRunning $trRef -ViServer $null
                $totalRunning = $trRef.Value
                $retryRunning = @($toRetry | Where-Object { $_.Status -eq "RUNNING" }).Count
            } until ($retryRunning -eq 0 -or (Get-Date) -ge $retryDeadline)

            foreach ($t in @($toRetry | Where-Object { $_.Status -eq "RUNNING" })) {
                $t.Status = "FAILED"; $t.Remarks = "Retry timed out"
            }
        }

        # Cleanup any remaining FAILED_PENDING_RETRY
        foreach ($t in @($tasks | Where-Object { $_.Status -eq "FAILED_PENDING_RETRY" })) {
            $t.Status = "FAILED"; $t.Remarks = "Max retries ($MaxRetry) exhausted"
        }

        # ---- Step E: Post-batch host verification ----
        Write-Host "`n  [Step E] Verifying VM placement..." -ForegroundColor Yellow
        foreach ($t in @($tasks | Where-Object { $_.Status -eq "SUCCESS" })) {
            $vc    = $t.VCenter
            $viSrv = $Global:VMwareSessions[$vc]
            if (-not $viSrv -or -not $viSrv.IsConnected) { $t.VerifyStatus = "UNKNOWN"; continue }
            try {
                $vmNow   = Get-VM -Server $viSrv -Id $t.VmMoRefId -ErrorAction Stop
                $curHost = $vmNow.VMHost.Name
                $curHid  = "$($vmNow.VMHost.ExtensionData.MoRef.Type)-$($vmNow.VMHost.ExtensionData.MoRef.Value)"
                $inTarget = $t.TargetHostIds -contains $curHid
                if ($inTarget) {
                    $t.VerifyStatus  = "OK"
                    $t.VerifyRemark  = "On $curHost — confirmed in $($t.TargetSite)"
                    Write-Host ("    ✓ {0,-38} on $curHost" -f $t.VMName) -ForegroundColor Green
                } else {
                    $t.VerifyStatus  = "WRONG_HOST"
                    $t.VerifyRemark  = "On $curHost — NOT in $($t.TargetSite) host group"
                    Write-Host ("    ⚠ {0,-38} on $curHost (wrong site!)" -f $t.VMName) -ForegroundColor Yellow
                }
            } catch {
                $t.VerifyStatus = "ERROR"; $t.VerifyRemark = $_.Exception.Message
            }
        }

        # ---- Batch summary ----
        $bSuccess = @($tasks | Where-Object { $_.Status -eq "SUCCESS" }).Count
        $bFailed  = @($tasks | Where-Object { $_.Status -notin @("SUCCESS","QUEUED") }).Count
        $bDur     = [math]::Round(((Get-Date) - $bStart).TotalMinutes, 2)
        $bColor   = if ($bFailed -eq 0) { "Green" } else { "Yellow" }
        Write-Host ("`n  $bId complete — ✅ $bSuccess  ❌ $bFailed  Duration: $bDur min") -ForegroundColor $bColor

        # Per-batch CSV
        $batchCsvPath = Join-Path $reportsDir "$bId`_$timestamp.csv"
        $tasks | Select-Object VMName,VCenter,Cluster,BatchId,
            SourceSite,TargetSite,SourceHostName,TargetHostName,TargetHostCpu,TargetHostMem,
            VmMemoryGB,AffinityStatus,AffinityRemark,
            Status,RetryCount,DurationMin,VerifyStatus,VerifyRemark,
            Remarks,StartTime,EndTime |
            Export-Csv -Path $batchCsvPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host "  Report: $batchCsvPath" -ForegroundColor Cyan

        foreach ($t in $tasks) { [void]$allTasks.Add($t) }
    }

    # ----------------------------------------------------------------
    # 8. Overall summary
    # ----------------------------------------------------------------
    $totalSuccess = @($allTasks | Where-Object { $_.Status -eq "SUCCESS" }).Count
    $totalFailed  = @($allTasks | Where-Object { $_.Status -notin @("SUCCESS","QUEUED") }).Count

    Write-Host "`n===== $funcName SUMMARY =====" -ForegroundColor Cyan
    Write-Host "  Total VMs : $($allTasks.Count)"
    Write-Host "  Success   : $totalSuccess" -ForegroundColor Green
    $failColor = if ($totalFailed -gt 0) { "Red" } else { "Green" }
    Write-Host "  Failed    : $totalFailed" -ForegroundColor $failColor

    $summaryPath = Join-Path $reportsDir "Summary_$timestamp.csv"
    $allTasks | Select-Object BatchId,VMName,VCenter,Cluster,
        SourceSite,TargetSite,SourceHostName,TargetHostName,TargetHostCpu,TargetHostMem,
        VmMemoryGB,AffinityStatus,AffinityRemark,
        Status,RetryCount,DurationMin,VerifyStatus,VerifyRemark,
        Remarks,StartTime,EndTime |
        Export-Csv -Path $summaryPath -NoTypeInformation -Force -Encoding UTF8
    Write-Host "  Summary   : $summaryPath" -ForegroundColor Cyan

    return $allTasks
}
