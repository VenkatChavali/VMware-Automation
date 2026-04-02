# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Module Type   : Public
# Purpose       : End-to-end VMware DRS affinity change + vMotion
#                 dispatcher. Manual batch triggering from GUI.
#                 Each batch runs in its own Runspace (thread) sharing
#                 a synchronized state for cross-batch vCenter-level
#                 concurrency control. Per-batch CSV + combined summary.
# Name          : Invoke-VMwareSiteAffinityMigration.ps1
# Compatibility : PS 5.1-compatible (requires VMware.PowerCLI)
# =================================================

<#
.SYNOPSIS
End-to-end VMware DRS affinity change + vMotion with manual batch dispatch.

.DESCRIPTION
Mirrors the FusionCompute dispatcher pattern exactly:
  - Input GUI (textbox or CSV browse)
  - Plan built once across all connected vCenters
  - Cache built once and reused across all batches
  - Dispatcher GUI with manual Start per batch
  - Each batch runs in its own Runspace (thread)
  - Shared synchronized state enforces vCenter-level concurrency cap
    across ALL active batches simultaneously
  - Host selection uses round-robin + CPU/MEM load check
  - Retry on failure
  - Per-batch CSV report + Generate Summary button

.PARAMETER VCenter
One or more vCenter FQDNs/IPs. Defaults to all sessions in $Global:VMwareSessions.

.PARAMETER UseCache
Use existing DRS group cache instead of rebuilding.

.PARAMETER BatchSize
VMs per batch. Default: 100.

.PARAMETER MaxConcurrentPerVC
Max simultaneous vMotions on a single vCenter across ALL active batches. Default: 10.

.PARAMETER MaxConcurrentPerCluster
Max simultaneous vMotions within a single cluster. Default: 8.

.PARAMETER MaxGlobalConcurrent
Max simultaneous vMotions across all vCenters and batches. Default: 30.

.PARAMETER MaxHostAllocatedPct
Skip hosts above this CPU or MEM %. Default: 80.

.PARAMETER MaxRetry
Retry attempts per failed vMotion. Default: 2.

.PARAMETER PollIntervalSeconds
Seconds between task poll cycles per worker. Default: 10.

.PARAMETER MaxMonitorMinutes
Timeout per batch. Default: 480.

.PARAMETER DryRun
Plan only — no DRS changes, no vMotions.

.EXAMPLE
Invoke-VMwareSiteAffinityMigration

.EXAMPLE
Invoke-VMwareSiteAffinityMigration -BatchSize 50 -MaxConcurrentPerVC 8 -DryRun
#>
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

    $funcName  = "Invoke-VMwareSiteAffinityMigration"
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
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

    if (-not $plan -or $plan.TotalVMs -eq 0) {
        Write-Warning "[$funcName] No VMs could be planned."
        return
    }

    # ----------------------------------------------------------------
    # 4. DryRun
    # ----------------------------------------------------------------
    if ($DryRun) {
        $planRows = @()
        foreach ($b in $plan.Batches) {
            foreach ($t in $b.Tasks) {
                $planRows += [pscustomobject]@{
                    BatchId=$t.BatchId; BatchNumber=$t.BatchNumber
                    VMName=$t.VMName; VCenter=$t.VCenter; Cluster=$t.Cluster
                    VmMemoryGB=$t.VmMemoryGB; SourceHostName=$t.SourceHostName
                    SourceSite=$t.SourceSite; TargetSite=$t.TargetSite
                    Status="PLANNED"; Remarks=""
                }
            }
        }
        foreach ($s in $plan.Skipped) {
            $planRows += [pscustomobject]@{
                BatchId=""; BatchNumber=""; VMName=$s.VMName
                VCenter=$s.VCenter; Cluster=$s.Cluster; VmMemoryGB=""
                SourceHostName=""; SourceSite=""; TargetSite=""
                Status=$s.Status; Remarks=$s.Remarks
            }
        }
        $dryPath = Join-Path $reportsDir "$funcName`_$timestamp`_DryRun.csv"
        $planRows | Export-Csv -Path $dryPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host "[DryRun] $($planRows.Count) rows exported: $dryPath" -ForegroundColor Green
        return
    }

    if (-not $PSCmdlet.ShouldProcess(
        "$($plan.TotalVMs) VM(s) across $($plan.TotalBatches) batch(es)",
        "Change DRS affinity and vMotion")) { return }

    # ----------------------------------------------------------------
    # 5. Resolve module path for Runspace workers
    # ----------------------------------------------------------------
    $modulePsm1 = $null
    try {
        $lm = Get-Module -Name "VMwareSiteAffinity" -ErrorAction SilentlyContinue
        if ($lm -and $lm.ModuleBase) {
            $modulePsm1 = Join-Path $lm.ModuleBase "VMwareSiteAffinity.psm1"
        }
    } catch {}

    # Also build credential path map for workers
    $vcCredPaths = @{}
    foreach ($vc in $vcList) {
        $vcCredPaths[$vc] = Get-VMwareCredPath -VCenter $vc
    }

    # ----------------------------------------------------------------
    # 6. Build shared synchronized state
    # ----------------------------------------------------------------
    $sync = [hashtable]::Synchronized(@{
        vc_running      = [hashtable]::Synchronized(@{})   # per-VC running count
        total_running   = 0                                 # global running count
        batch_states    = [hashtable]::Synchronized(@{})   # per-batch status
        vm_obj_map      = $plan.VmObjMap                   # vmViewId -> VM object
        host_obj_map    = $plan.HostObjMap                  # hostViewId -> host info
        module_psm1     = $modulePsm1
        vc_cred_paths   = $vcCredPaths                     # for Runspace reconnect
        vc_servers      = $vcList                          # list of vCenter FQDNs
        max_per_vc      = $MaxConcurrentPerVC
        max_per_cluster = $MaxConcurrentPerCluster
        max_global      = $MaxGlobalConcurrent
        max_host_pct    = $MaxHostAllocatedPct
        max_retry       = $MaxRetry
        poll_interval   = $PollIntervalSeconds
        max_monitor     = $MaxMonitorMinutes
        cpu_refresh_after = $CpuMemRefreshAfter
        cpu_refresh_stale = $CpuMemRefreshStaleMin
        reports_dir     = $reportsDir
        run_timestamp   = $timestamp
        base_path       = (Get-VMwareBasePath)
    })

    foreach ($vc in $vcList) { $sync.vc_running[$vc] = 0 }

    foreach ($b in $plan.Batches) {
        $sync.batch_states[$b.BatchId] = [hashtable]::Synchronized(@{
            Status      = "WAITING"
            Total       = $b.VMCount; Success = 0; Failed = 0; Running = 0; Queued = $b.VMCount
            StartTime   = $null; EndTime = $null; DurationMin = $null
            ReportPath  = $null; Error = $null
        })
    }

    # ----------------------------------------------------------------
    # 7. Runspace worker script
    # ----------------------------------------------------------------
    $workerScript = {
        param($sync, $batchData, $batchId)

        # ---- Load module ----
        $loaded = $false
        if ($sync.module_psm1 -and (Test-Path -LiteralPath $sync.module_psm1)) {
            try { Import-Module $sync.module_psm1 -Force -ErrorAction Stop; $loaded = $true } catch {}
        }
        if (-not $loaded) {
            try { Import-Module VMwareSiteAffinity -Force -ErrorAction Stop; $loaded = $true } catch {}
        }
        if (-not $loaded) {
            $sync.batch_states[$batchId].Status = "FAILED"
            $sync.batch_states[$batchId].Error  = "Failed to load VMwareSiteAffinity module"
            return
        }

        # ---- Restore path global ----
        $Global:VMwareSABasePath = $sync.base_path

        # ---- Connect to each vCenter in this worker ----
        # PowerCLI sessions do NOT carry into Runspaces.
        # We reconnect using DPAPI credential from disk.
        $Global:VMwareSessions = @{}
        foreach ($vc in $sync.vc_servers) {
            try {
                $credPath = $sync.vc_cred_paths[$vc]
                if (-not (Test-Path -LiteralPath $credPath)) {
                    Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "No saved credential — cannot connect" -Level "ERROR"
                    continue
                }
                $cred     = Import-Clixml -LiteralPath $credPath
                $viServer = Connect-VIServer -Server $vc -Credential $cred -Force -ErrorAction Stop
                $Global:VMwareSessions[$vc] = $viServer
                Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "Connected in Runspace"
            } catch {
                Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "Connect failed: $($_.Exception.Message)" -Level "ERROR"
            }
        }

        $bs = $sync.batch_states[$batchId]
        $bs.Status    = "RUNNING"
        $bs.StartTime = Get-Date

        $tasks   = @($batchData.Tasks)
        $rrState = @{}

        # ---- Helper: select target host round-robin + load check ----
        function Select-TargetHost {
            param($task)
            $hostIds = @($task.TargetHostIds)
            if ($hostIds.Count -eq 0) { return $null }

            $rrKey = "$($task.VCenter)|$($task.Cluster)|$($task.TargetSite)"
            if (-not $rrState.ContainsKey($rrKey)) { $rrState[$rrKey] = 0 }

            $start = $rrState[$rrKey]
            for ($a = 0; $a -lt $hostIds.Count; $a++) {
                $idx = ($start + $a) % $hostIds.Count
                $hid = $hostIds[$idx]
                $h   = $null
                if ($sync.host_obj_map.ContainsKey($hid)) { $h = $sync.host_obj_map[$hid] }
                if (-not $h) { continue }

                $cpuOk = ($h.CpuPct -eq $null -or $h.CpuPct -le $sync.max_host_pct)
                $memOk = ($h.MemPct -eq $null -or $h.MemPct -le $sync.max_host_pct)

                if ($cpuOk -and $memOk) {
                    $rrState[$rrKey] = (($idx + 1) % $hostIds.Count)
                    return $h
                }
            }
            return $null
        }

        # ---- Helper: refresh host load every N completions if stale ----
        $completedSinceRefresh = 0
        $lastRefresh = [datetime]::MinValue

        function Refresh-HostLoadIfStale {
            $ageMin = ((Get-Date) - $lastRefresh).TotalMinutes
            if ($ageMin -lt $sync.cpu_refresh_stale) { return }

            Write-VMwareLog -Function "Worker-$batchId" -Message "Refreshing host CPU/MEM (last: $([math]::Round($ageMin,1)) min ago)"

            $vcSet = @($tasks | Select-Object -ExpandProperty VCenter -Unique)
            foreach ($vc in $vcSet) {
                $viSrv = $Global:VMwareSessions[$vc]
                if (-not $viSrv -or -not $viSrv.IsConnected) { continue }

                $hostIdsForVc = @($tasks |
                    Where-Object { $_.VCenter -eq $vc } |
                    ForEach-Object { $_.TargetHostIds } |
                    Select-Object -Unique)

                try {
                    $hostObjs = @(Get-VMHost -Server $viSrv -Id $hostIdsForVc -ErrorAction SilentlyContinue)
                    foreach ($h in $hostObjs) {
                        $hid = "$($h.ExtensionData.MoRef.Type)-$($h.ExtensionData.MoRef.Value)"
                        $cpu = $null; $mem = $null
                        try {
                            if ($h.CpuUsageMhz -gt 0 -and $h.CpuTotalMhz -gt 0) {
                                $cpu = [math]::Round(($h.CpuUsageMhz / $h.CpuTotalMhz) * 100, 1)
                            }
                        } catch {}
                        try {
                            if ($h.MemoryUsageGB -gt 0 -and $h.MemoryTotalGB -gt 0) {
                                $mem = [math]::Round(($h.MemoryUsageGB / $h.MemoryTotalGB) * 100, 1)
                            }
                        } catch {}
                        if ($sync.host_obj_map.ContainsKey($hid)) {
                            $sync.host_obj_map[$hid].CpuPct = $cpu
                            $sync.host_obj_map[$hid].MemPct = $mem
                        }
                    }
                } catch {}
            }
            $script:lastRefresh = Get-Date
            $script:completedSinceRefresh = 0
        }

        # ---- PHASE 1: DRS affinity change for this batch ----
        Write-VMwareLog -Function "Worker-$batchId" -Message "Phase 1: DRS affinity change for $($tasks.Count) VMs"

        # Resolve DRS groups per cluster (once per batch)
        $drsGroupMap = @{}
        $clustersByVc = @{}
        foreach ($t in $tasks) {
            $ck = "$($t.VCenter)|$($t.Cluster)"
            if (-not $clustersByVc.ContainsKey($ck)) { $clustersByVc[$ck] = @{ VC=$t.VCenter; Cluster=$t.Cluster } }
        }
        foreach ($ck in $clustersByVc.Keys) {
            $vc  = $clustersByVc[$ck].VC
            $cln = $clustersByVc[$ck].Cluster
            $viSrv = $Global:VMwareSessions[$vc]
            if (-not $viSrv) { continue }
            try {
                $clObj = Get-Cluster -Name $cln -Server $viSrv -ErrorAction Stop
                $s01g  = Get-DrsClusterGroup -Cluster $clObj -Name "site01_vms" -Server $viSrv -ErrorAction SilentlyContinue
                $s02g  = Get-DrsClusterGroup -Cluster $clObj -Name "site02_vms" -Server $viSrv -ErrorAction SilentlyContinue
                if ($s01g -and $s02g) {
                    $drsGroupMap[$ck] = @{ Site01=$s01g; Site02=$s02g; ClusterObj=$clObj }
                }
            } catch {
                Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "DRS group resolve failed for $cln`: $($_.Exception.Message)" -Level "WARN"
            }
        }

        foreach ($ck in $drsGroupMap.Keys) {
            $vc  = $clustersByVc[$ck].VC
            $cln = $clustersByVc[$ck].Cluster
            $viSrv = $Global:VMwareSessions[$vc]

            $toSite01VmObjs = @()
            $toSite02VmObjs = @()

            foreach ($t in @($tasks | Where-Object { "$($t.VCenter)|$($t.Cluster)" -eq $ck })) {
                $vmObj = $null
                if ($sync.vm_obj_map.ContainsKey($t.VmViewId)) { $vmObj = $sync.vm_obj_map[$t.VmViewId] }
                if (-not $vmObj) {
                    $t.Status  = "FAILED"
                    $t.Remarks = "VM object not found in plan map"
                    continue
                }
                if ($t.SourceSite -eq "site01") { $toSite02VmObjs += $vmObj }
                else                             { $toSite01VmObjs += $vmObj }
            }

            $s01g = $drsGroupMap[$ck].Site01
            $s02g = $drsGroupMap[$ck].Site02

            try {
                if ($toSite02VmObjs.Count -gt 0) {
                    Set-DrsClusterGroup -DrsClusterGroup $s01g -Remove $toSite02VmObjs -Confirm:$false -ErrorAction Stop | Out-Null
                    Set-DrsClusterGroup -DrsClusterGroup $s02g -Add    $toSite02VmObjs -Confirm:$false -ErrorAction Stop | Out-Null
                }
                if ($toSite01VmObjs.Count -gt 0) {
                    Set-DrsClusterGroup -DrsClusterGroup $s02g -Remove $toSite01VmObjs -Confirm:$false -ErrorAction Stop | Out-Null
                    Set-DrsClusterGroup -DrsClusterGroup $s01g -Add    $toSite01VmObjs -Confirm:$false -ErrorAction Stop | Out-Null
                }
                $total = $toSite01VmObjs.Count + $toSite02VmObjs.Count
                Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "DRS affinity updated for $total VMs in $cln"
                foreach ($t in @($tasks | Where-Object { "$($t.VCenter)|$($t.Cluster)" -eq $ck -and $t.Status -eq "QUEUED" })) {
                    $t.AffinityChangeStatus  = "SUCCESS"
                    $t.AffinityChangeRemarks = "Moved: $($t.SourceSite) -> $($t.TargetSite)"
                }
            } catch {
                Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "DRS update failed for $cln`: $($_.Exception.Message)" -Level "ERROR"
                foreach ($t in @($tasks | Where-Object { "$($t.VCenter)|$($t.Cluster)" -eq $ck -and $t.Status -eq "QUEUED" })) {
                    $t.AffinityChangeStatus  = "FAILED"
                    $t.AffinityChangeRemarks = "DRS update error: $($_.Exception.Message)"
                    $t.Status  = "FAILED"
                    $t.Remarks = "DRS affinity change failed — skipping vMotion"
                }
            }
        }

        # ---- PHASE 2: vMotion dispatch + monitor loop ----
        Write-VMwareLog -Function "Worker-$batchId" -Message "Phase 2: vMotion dispatch"

        $migratable = @($tasks | Where-Object { $_.AffinityChangeStatus -eq "SUCCESS" -and $_.Status -eq "QUEUED" })

        # Group by cluster for per-cluster throttle
        $clusterGroups = @{}
        foreach ($t in $migratable) {
            $ck = "$($t.VCenter)|$($t.Cluster)"
            if (-not $clusterGroups.ContainsKey($ck)) { $clusterGroups[$ck] = @() }
            $clusterGroups[$ck] = @($clusterGroups[$ck] + $t)
        }

        # Per-cluster task tracking for PowerCLI async tasks
        $taskMeta    = @{}   # PowerCLI task ID -> task metadata
        $activeTasks = New-Object System.Collections.Generic.List[object]  # PowerCLI task objects

        $activeStates   = @("RUNNING")
        $workStates     = @("QUEUED","PENDING_RETRY")
        $deadline       = (Get-Date).AddMinutes($sync.max_monitor)

        function Dispatch-VM { param($task)
            $vc    = [string]$task.VCenter
            $viSrv = $Global:VMwareSessions[$vc]

            # Reconnect if session dropped
            if (-not $viSrv -or -not $viSrv.IsConnected) {
                try {
                    $cred = Import-Clixml -LiteralPath $sync.vc_cred_paths[$vc]
                    $viSrv = Connect-VIServer -Server $vc -Credential $cred -Force -ErrorAction Stop
                    $Global:VMwareSessions[$vc] = $viSrv
                } catch {
                    $task.Status  = "FAILED"
                    $task.Remarks = "vCenter reconnect failed: $($_.Exception.Message)"
                    return
                }
            }

            # Wait for a vCenter + global concurrency slot
            $waited = 0
            while ($true) {
                $vcOk     = ($sync.vc_running[$vc]    -lt $sync.max_per_vc)
                $globalOk = ($sync.total_running       -lt $sync.max_global)
                if ($vcOk -and $globalOk) {
                    $sync.vc_running[$vc]++
                    $sync.total_running++
                    break
                }
                Start-Sleep -Seconds 3; $waited += 3
                if ($waited -gt ($sync.max_monitor * 60)) {
                    $task.Status  = "TIMEOUT"
                    $task.Remarks = "Timed out waiting for concurrency slot"
                    return
                }
            }

            # Select target host
            $host = Select-TargetHost -task $task
            if (-not $host) {
                $sync.vc_running[$vc]--
                $sync.total_running--
                $task.Status  = "FAILED"
                $task.Remarks = "No host under $($sync.max_host_pct)% CPU/MEM in [$($task.TargetSite)] site"
                return
            }

            $vmObj = $null
            if ($sync.vm_obj_map.ContainsKey($task.VmViewId)) { $vmObj = $sync.vm_obj_map[$task.VmViewId] }
            if (-not $vmObj) {
                $sync.vc_running[$vc]--
                $sync.total_running--
                $task.Status  = "FAILED"
                $task.Remarks = "VM object not found"
                return
            }

            try {
                Start-Sleep -Milliseconds (100 + (Get-Random -Minimum 0 -Maximum 300))
                $pTask = Move-VM -VM $vmObj -Destination $host.Obj -RunAsync -Confirm:$false -ErrorAction Stop

                $task.TaskId         = $pTask.Id
                $task.TargetHostName = $host.Name
                $task.TargetHostCpu  = $host.CpuPct
                $task.TargetHostMem  = $host.MemPct
                $task.Status         = "RUNNING"
                $task.StartTime      = Get-Date
                $task.Remarks        = "Dispatched -> $($host.Name) [CPU:$($host.CpuPct)% MEM:$($host.MemPct)%]"

                [void]$activeTasks.Add($pTask)
                $taskMeta[$pTask.Id] = $task

                Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "vMotion started: $($task.VMName) -> $($host.Name)"
            } catch {
                $sync.vc_running[$vc]--
                $sync.total_running--
                $task.Status  = "FAILED"
                $task.Remarks = "Move-VM error: $($_.Exception.Message)"
                Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "Dispatch failed: $($task.VMName): $($_.Exception.Message)" -Level "ERROR"
            }
        }

        do {
            # Refresh host load if due
            if ($completedSinceRefresh -ge $sync.cpu_refresh_after) {
                Refresh-HostLoadIfStale
            }

            # Dispatch queued tasks respecting per-cluster cap
            foreach ($ck in $clusterGroups.Keys) {
                $clTasks  = @($clusterGroups[$ck])
                $clRunning = @($clTasks | Where-Object { $_.Status -in $activeStates }).Count
                if ($clRunning -ge $sync.max_per_cluster) { continue }

                $queued = @($clTasks | Where-Object { $_.Status -in $workStates })
                $slots  = $sync.max_per_cluster - $clRunning

                foreach ($t in ($queued | Select-Object -First $slots)) {
                    Dispatch-VM -task $t
                }
            }

            # Poll active PowerCLI tasks
            if ($activeTasks.Count -gt 0) {
                $completedPTasks = @()
                try {
                    # Get-Task refreshes state; completed tasks returned
                    $allActive = @(Get-Task -Id @($activeTasks | Select-Object -ExpandProperty Id) -ErrorAction SilentlyContinue)
                    $completedPTasks = @($allActive | Where-Object { $_.State -in @("Success","Error") })
                } catch {}

                foreach ($pt in $completedPTasks) {
                    $t  = $taskMeta[$pt.Id]
                    if (-not $t) { continue }

                    $vc  = [string]$t.VCenter
                    $end = $pt.FinishTime
                    if (-not $end) { $end = Get-Date }

                    $t.EndTime = $end
                    try {
                        $t.DurationMin = [math]::Round(((New-TimeSpan -Start $t.StartTime -End $end).TotalMinutes),2)
                    } catch {}

                    # Decrement shared counters
                    $sync.vc_running[$vc]--
                    if ($sync.vc_running[$vc] -lt 0) { $sync.vc_running[$vc] = 0 }
                    $sync.total_running--
                    if ($sync.total_running -lt 0) { $sync.total_running = 0 }
                    $script:completedSinceRefresh++

                    if ($pt.State -eq "Success") {
                        $t.Status  = "SUCCESS"
                        $t.Remarks = "SUCCESS -> $($t.TargetHostName) [CPU:$($t.TargetHostCpu)% MEM:$($t.TargetHostMem)%] $($t.DurationMin) min"
                    } else {
                        $errMsg = ""
                        try { if ($pt.ExtensionData -and $pt.ExtensionData.Error) { $errMsg = $pt.ExtensionData.Error.LocalizedMessage } } catch {}

                        if ($t.RetryCount -lt $sync.max_retry) {
                            $t.RetryCount++
                            $t.Status    = "PENDING_RETRY"
                            $t.TaskId    = $null; $t.StartTime=$null; $t.EndTime=$null; $t.DurationMin=$null
                            $t.Remarks   = "Retry $($t.RetryCount)/$($sync.max_retry) after Error: $errMsg"
                            Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "Retry $($t.RetryCount)/$($sync.max_retry): $($t.VMName)" -Level "WARN"
                        } else {
                            $t.Status  = "FAILED"
                            $t.Remarks = "FAILED after $($sync.max_retry) retries: $errMsg"
                            Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "FAILED (no more retries): $($t.VMName)" -Level "ERROR"
                        }
                    }
                }

                # Remove completed from activeTasks list
                $doneIds = @{}
                foreach ($pt in $completedPTasks) { $doneIds[$pt.Id] = $true }
                $remaining = New-Object System.Collections.Generic.List[object]
                foreach ($pt in $activeTasks) {
                    if (-not $doneIds.ContainsKey($pt.Id)) { [void]$remaining.Add($pt) }
                }
                $activeTasks.Clear()
                foreach ($pt in $remaining) { [void]$activeTasks.Add($pt) }
            }

            # Update $sync batch state (read by GUI timer)
            $bs.Success = @($tasks | Where-Object { $_.Status -eq "SUCCESS" }).Count
            $bs.Failed  = @($tasks | Where-Object { $_.Status -in @("FAILED","TIMEOUT","VERIFY_FAILED") }).Count
            $bs.Running = @($tasks | Where-Object { $_.Status -in $activeStates }).Count
            $bs.Queued  = @($tasks | Where-Object { $_.Status -in $workStates }).Count

            $stillWork = ($bs.Running -gt 0 -or $bs.Queued -gt 0)
            if ($stillWork) { Start-Sleep -Seconds ([math]::Max(2, $sync.poll_interval)) }

        } until (-not $stillWork -or (Get-Date) -ge $deadline)

        # Timeout any still-active
        foreach ($t in @($tasks | Where-Object { $_.Status -in ($activeStates + $workStates) })) {
            if ($t.Status -in $activeStates) {
                $sync.vc_running[$t.VCenter]--
                if ($sync.vc_running[$t.VCenter] -lt 0) { $sync.vc_running[$t.VCenter] = 0 }
                $sync.total_running--
                if ($sync.total_running -lt 0) { $sync.total_running = 0 }
            }
            $t.Status  = "TIMEOUT"
            $t.Remarks = "Timed out after $($sync.max_monitor) minutes"
        }

        # ---- PHASE 3: Post-batch verification ----
        # Check each SUCCESS VM: is it running on a host in the target site host group?
        Write-VMwareLog -Function "Worker-$batchId" -Message "Phase 3: Post-batch verification"
        $successTasks = @($tasks | Where-Object { $_.Status -eq "SUCCESS" })

        foreach ($t in $successTasks) {
            $vc    = [string]$t.VCenter
            $viSrv = $Global:VMwareSessions[$vc]
            if (-not $viSrv -or -not $viSrv.IsConnected) { $t.VerifyStatus = "UNKNOWN"; continue }
            try {
                $vmObj  = $sync.vm_obj_map[$t.VmViewId]
                if (-not $vmObj) { $t.VerifyStatus = "UNKNOWN"; continue }

                # Refresh VM to get current host
                $vmNow  = Get-VM -Id $vmObj.Id -Server $viSrv -ErrorAction Stop
                $curHost = $vmNow.VMHost.Name

                # Check host is in target site host group
                $targetHostIds  = @($t.TargetHostIds)
                $curHostId      = $null
                try {
                    $curHostObj = Get-VMHost -Name $curHost -Server $viSrv -ErrorAction SilentlyContinue
                    if ($curHostObj) {
                        $curHostId = "$($curHostObj.ExtensionData.MoRef.Type)-$($curHostObj.ExtensionData.MoRef.Value)"
                    }
                } catch {}

                $inTargetGroup = $curHostId -and ($targetHostIds -contains $curHostId)

                if ($inTargetGroup) {
                    $t.VerifyStatus  = "SUCCESS"
                    $t.VerifyRemarks = "VM on $curHost — confirmed in target site [$($t.TargetSite)]"
                } else {
                    $t.VerifyStatus  = "FAILED"
                    $t.VerifyRemarks = "VM on $curHost — NOT in target site [$($t.TargetSite)] host group"
                    $t.Status        = "VERIFY_FAILED"
                    Write-VMwareLog -Function "Worker-$batchId" -VC $vc -Message "Verify FAILED: $($t.VMName) on $curHost (expected $($t.TargetSite) host)" -Level "WARN"
                }
            } catch {
                $t.VerifyStatus  = "UNKNOWN"
                $t.VerifyRemarks = "Verification error: $($_.Exception.Message)"
            }
        }

        # Retry VERIFY_FAILED tasks (one attempt)
        $verifyFailed = @($tasks | Where-Object { $_.Status -eq "VERIFY_FAILED" })
        if ($verifyFailed.Count -gt 0) {
            Write-VMwareLog -Function "Worker-$batchId" -Message "Retrying $($verifyFailed.Count) verification failures..."
            foreach ($t in $verifyFailed) {
                $t.Status = "PENDING_RETRY"; $t.TaskId=$null; $t.StartTime=$null; $t.EndTime=$null
                $t.DurationMin=$null; $t.RetryCount++
            }

            # Run them through dispatch loop once more (simplified — no cluster throttle retry)
            foreach ($t in $verifyFailed) { Dispatch-VM -task $t }

            $retryDeadline = (Get-Date).AddMinutes([math]::Min(60, $sync.max_monitor))
            do {
                Start-Sleep -Seconds $sync.poll_interval
                if ($activeTasks.Count -gt 0) {
                    try {
                        $polled = @(Get-Task -Id @($activeTasks | Select-Object -ExpandProperty Id) -ErrorAction SilentlyContinue)
                        foreach ($pt in @($polled | Where-Object { $_.State -in @("Success","Error") })) {
                            $t = $taskMeta[$pt.Id]; if (-not $t) { continue }
                            $sync.vc_running[$t.VCenter]--; if ($sync.vc_running[$t.VCenter] -lt 0) { $sync.vc_running[$t.VCenter]=0 }
                            $sync.total_running--;          if ($sync.total_running -lt 0) { $sync.total_running=0 }
                            $end = if ($pt.FinishTime) { $pt.FinishTime } else { Get-Date }
                            $t.EndTime = $end
                            try { $t.DurationMin = [math]::Round(((New-TimeSpan -Start $t.StartTime -End $end).TotalMinutes),2) } catch {}
                            if ($pt.State -eq "Success") {
                                $t.Status = "SUCCESS"; $t.VerifyStatus = "RETRY_SUCCESS"
                            } else {
                                $errMsg = ""; try { $errMsg = $pt.ExtensionData.Error.LocalizedMessage } catch {}
                                $t.Status = "VERIFY_FAILED"; $t.Remarks = "Retry also failed: $errMsg"
                            }
                        }
                        $doneIds = @{}
                        foreach ($pt in @($polled | Where-Object { $_.State -in @("Success","Error") })) { $doneIds[$pt.Id]=$true }
                        $rem = New-Object System.Collections.Generic.List[object]
                        foreach ($pt in $activeTasks) { if (-not $doneIds[$pt.Id]) { [void]$rem.Add($pt) } }
                        $activeTasks.Clear(); foreach ($pt in $rem) { [void]$activeTasks.Add($pt) }
                    } catch {}
                }
            } until ($activeTasks.Count -eq 0 -or (Get-Date) -ge $retryDeadline)
        }

        # ---- Write per-batch report ----
        $bs.Success     = @($tasks | Where-Object { $_.Status -eq "SUCCESS" }).Count
        $bs.Failed      = @($tasks | Where-Object { $_.Status -notin @("SUCCESS","SKIPPED") }).Count
        $bs.Running     = 0; $bs.Queued = 0

        $reportRows = New-Object System.Collections.Generic.List[object]
        foreach ($t in $tasks) {
            [void]$reportRows.Add([pscustomobject]@{
                BatchId              = $t.BatchId
                BatchNumber          = $t.BatchNumber
                VMName               = $t.VMName
                VCenter              = $t.VCenter
                Cluster              = $t.Cluster
                VmMemoryGB           = $t.VmMemoryGB
                SourceHostName       = $t.SourceHostName
                SourceSite           = $t.SourceSite
                TargetSite           = $t.TargetSite
                AffinityChangeStatus = if ($t.PSObject.Properties['AffinityChangeStatus']) { $t.AffinityChangeStatus } else { "N/A" }
                AffinityChangeRemarks= if ($t.PSObject.Properties['AffinityChangeRemarks']) { $t.AffinityChangeRemarks } else { $null }
                TargetHostName       = $t.TargetHostName
                TargetHostCpuPct     = $t.TargetHostCpu
                TargetHostMemPct     = $t.TargetHostMem
                MigrationStatus      = $t.Status
                RetryCount           = $t.RetryCount
                VerifyStatus         = if ($t.PSObject.Properties['VerifyStatus'])  { $t.VerifyStatus }  else { "N/A" }
                VerifyRemarks        = if ($t.PSObject.Properties['VerifyRemarks']) { $t.VerifyRemarks } else { $null }
                StartTime            = $t.StartTime
                EndTime              = $t.EndTime
                DurationMin          = $t.DurationMin
                Remarks              = $t.Remarks
            })
        }

        $batchReportPath = Join-Path $sync.reports_dir "$($batchId)_$($sync.run_timestamp).csv"
        try { $reportRows | Export-Csv -Path $batchReportPath -NoTypeInformation -Force -Encoding UTF8 } catch {}

        $bs.EndTime     = Get-Date
        $bs.DurationMin = [math]::Round(((New-TimeSpan -Start $bs.StartTime -End $bs.EndTime).TotalMinutes),2)
        $bs.ReportPath  = $batchReportPath
        $bs.Status      = "COMPLETE"

        Write-VMwareLog -Function "Worker-$batchId" -Message "Complete. Success:$($bs.Success) Failed:$($bs.Failed) Duration:$($bs.DurationMin)min Report:$batchReportPath"

        # Disconnect from vCenter in this Runspace
        foreach ($vc in $sync.vc_servers) {
            try { Disconnect-VIServer -Server $Global:VMwareSessions[$vc] -Confirm:$false -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    # ----------------------------------------------------------------
    # 8. RunspacePool + Dispatcher GUI
    # ----------------------------------------------------------------
    $maxWorkers = [math]::Max(1, $plan.TotalBatches)
    $rsPool     = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maxWorkers)
    $rsPool.Open()
    $rsHandles  = [hashtable]::Synchronized(@{})

    # ---- Build GUI ----
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "VMware — Site Affinity Migration Dispatcher"
    $form.Size            = New-Object System.Drawing.Size(860, 560)
    $form.MinimumSize     = New-Object System.Drawing.Size(720, 480)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = "Top"; $header.Height = 58
    $header.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 60)
    $form.Controls.Add($header)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "VMware Site Affinity Migration — Dispatcher"
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoSize = $true; $lblTitle.Location = New-Object System.Drawing.Point(16, 8)
    $header.Controls.Add($lblTitle)

    $lblCaps = New-Object System.Windows.Forms.Label
    $lblCaps.Text = "  VC cap: $MaxConcurrentPerVC/vCenter   Global: $MaxGlobalConcurrent   Cluster: $MaxConcurrentPerCluster   vCenters: $($vcList -join ', ')"
    $lblCaps.ForeColor = [System.Drawing.Color]::FromArgb(190,230,210)
    $lblCaps.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblCaps.AutoSize = $true; $lblCaps.Location = New-Object System.Drawing.Point(14, 36)
    $header.Controls.Add($lblCaps)

    $strip = New-Object System.Windows.Forms.Panel
    $strip.Dock = "Top"; $strip.Height = 28
    $strip.BackColor = [System.Drawing.Color]::FromArgb(210, 240, 225)
    $form.Controls.Add($strip)

    $lblLive = New-Object System.Windows.Forms.Label
    $lblLive.Text = "  Initialising..."
    $lblLive.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblLive.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 40)
    $lblLive.Dock = "Fill"; $lblLive.TextAlign = "MiddleLeft"
    $strip.Controls.Add($lblLive)

    # Batch ListView
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(14, 100)
    $lv.Size = New-Object System.Drawing.Size(822, 340)
    $lv.Anchor = "Top,Left,Right,Bottom"
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.Font = New-Object System.Drawing.Font("Consolas", 8)

    foreach ($col in @(
        @{T="Batch";W=80}, @{T="VMs";W=50}, @{T="✅";W=55},
        @{T="❌";W=55}, @{T="▶";W=55}, @{T="⏳";W=55},
        @{T="Start";W=90}, @{T="End";W=90}, @{T="Duration";W=80}, @{T="Status";W=120}
    )) {
        $c = New-Object System.Windows.Forms.ColumnHeader
        $c.Text = $col.T; $c.Width = $col.W; [void]$lv.Columns.Add($c)
    }
    $form.Controls.Add($lv)

    # Bottom buttons
    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = "Bottom"; $btnPanel.Height = 48
    $btnPanel.BackColor = [System.Drawing.Color]::FromArgb(235,238,243)
    $form.Controls.Add($btnPanel)

    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = "▶  Start Selected Batch"
    $btnStart.Size = New-Object System.Drawing.Size(170, 32)
    $btnStart.Location = New-Object System.Drawing.Point(14, 8)
    $btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 140, 60)
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.FlatStyle = "Flat"; $btnStart.FlatAppearance.BorderSize = 0
    $btnStart.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnPanel.Controls.Add($btnStart)

    $btnReport = New-Object System.Windows.Forms.Button
    $btnReport.Text = "📄  Generate Summary"
    $btnReport.Size = New-Object System.Drawing.Size(160, 32)
    $btnReport.Location = New-Object System.Drawing.Point(194, 8)
    $btnReport.FlatStyle = "Flat"
    $btnReport.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $btnPanel.Controls.Add($btnReport)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Size = New-Object System.Drawing.Size(90, 32)
    $btnClose.Location = New-Object System.Drawing.Point(744, 8)
    $btnClose.FlatStyle = "Flat"
    $btnPanel.Controls.Add($btnClose)

    # Populate ListView
    $lvItems = @{}
    foreach ($b in $plan.Batches) {
        $item = New-Object System.Windows.Forms.ListViewItem($b.BatchId)
        foreach ($val in @([string]$b.VMCount,"0","0","0",[string]$b.VMCount,"—","—","—","WAITING")) {
            [void]$item.SubItems.Add($val)
        }
        $item.Tag = $b.BatchId
        [void]$lv.Items.Add($item)
        $lvItems[$b.BatchId] = $item
    }

    # ---- Start batch handler ----
    $btnStart.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Select a batch row first.","No Selection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $bid    = [string]$lv.SelectedItems[0].Tag
        $bState = $sync.batch_states[$bid]

        if ($bState.Status -ne "WAITING") {
            [System.Windows.Forms.MessageBox]::Show(
                "Batch [$bid] is $($bState.Status). Only WAITING batches can be started.","Cannot Start",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $batchObj = $plan.Batches | Where-Object { $_.BatchId -eq $bid } | Select-Object -First 1
        if (-not $batchObj) { return }

        $bState.Status = "STARTING"
        $lvItems[$bid].SubItems[9].Text = "STARTING"

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $rsPool
        [void]$ps.AddScript($workerScript)
        [void]$ps.AddArgument($sync)
        [void]$ps.AddArgument($batchObj)
        [void]$ps.AddArgument($bid)

        $handle = $ps.BeginInvoke()
        $rsHandles[$bid] = @{ PS=$ps; Handle=$handle }
        Write-VMwareLog -Function $funcName -Message "Batch [$bid] dispatched to Runspace"
    })

    # ---- Generate Summary handler ----
    $btnReport.Add_Click({
        $completed = @($plan.Batches | Where-Object {
            $sync.batch_states[$_.BatchId].Status -eq "COMPLETE" -and
            $sync.batch_states[$_.BatchId].ReportPath -and
            (Test-Path -LiteralPath $sync.batch_states[$_.BatchId].ReportPath)
        })
        if ($completed.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No completed batch reports yet.","No Reports",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $allRows = New-Object System.Collections.Generic.List[object]
        foreach ($b in $completed) {
            try {
                $rows = @(Import-Csv -LiteralPath $sync.batch_states[$b.BatchId].ReportPath -Encoding UTF8)
                foreach ($r in $rows) { [void]$allRows.Add($r) }
            } catch {}
        }
        if ($allRows.Count -gt 0) {
            $summaryPath = Join-Path $sync.reports_dir "Summary_$($sync.run_timestamp).csv"
            $allRows | Export-Csv -Path $summaryPath -NoTypeInformation -Force -Encoding UTF8
            Write-Host "`n===== MIGRATION SUMMARY =====" -ForegroundColor Cyan
            foreach ($b in $completed) {
                $bs = $sync.batch_states[$b.BatchId]
                Write-Host ("  {0,-12}  ✅ {1,4}  ❌ {2,4}  {3} min" -f $b.BatchId, $bs.Success, $bs.Failed, $bs.DurationMin) -ForegroundColor Cyan
            }
            Write-Host "  Summary: $summaryPath" -ForegroundColor Green
            [System.Windows.Forms.MessageBox]::Show("Summary written to:`n$summaryPath","Done",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    })

    # ---- Close handler ----
    $btnClose.Add_Click({
        $running = @($plan.Batches | Where-Object {
            $sync.batch_states[$_.BatchId].Status -in @("RUNNING","STARTING")
        })
        if ($running.Count -gt 0) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "$($running.Count) batch(es) still running. Close anyway?","Running",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $form.Close()
    })

    # ---- Timer ----
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000

    $timer.Add_Tick({
        try {
            $vcStats = @($vcList | ForEach-Object { "$_`:$($sync.vc_running[$_])" })
            $lblLive.Text = "  Running: $($sync.total_running)/$MaxGlobalConcurrent   |   " +
                            "Per VC: $($vcStats -join '   ')   |   Cap: $MaxConcurrentPerVC/VC"

            foreach ($b in $plan.Batches) {
                $bid  = $b.BatchId; $bs = $sync.batch_states[$bid]; $item = $lvItems[$bid]
                if (-not $item) { continue }

                $startStr = if ($bs.StartTime) { try { ([datetime]$bs.StartTime).ToString("HH:mm:ss") } catch { "—" } } else { "—" }
                $endStr   = if ($bs.EndTime)   { try { ([datetime]$bs.EndTime).ToString("HH:mm:ss")   } catch { "—" } } else { "—" }
                $durStr   = if ($bs.DurationMin -ne $null) { "$($bs.DurationMin) min" } else { "—" }

                $item.SubItems[2].Text = [string]$bs.Success
                $item.SubItems[3].Text = [string]$bs.Failed
                $item.SubItems[4].Text = [string]$bs.Running
                $item.SubItems[5].Text = [string]$bs.Queued
                $item.SubItems[6].Text = $startStr
                $item.SubItems[7].Text = $endStr
                $item.SubItems[8].Text = $durStr
                $item.SubItems[9].Text = [string]$bs.Status

                $item.ForeColor = switch ($bs.Status) {
                    "COMPLETE" { [System.Drawing.Color]::FromArgb(0,120,50) }
                    "RUNNING"  { [System.Drawing.Color]::FromArgb(0,80,160) }
                    "FAILED"   { [System.Drawing.Color]::Firebrick }
                    default    { [System.Drawing.Color]::Black }
                }
            }

            # Clean up finished runspace handles
            foreach ($key in @($rsHandles.Keys)) {
                $h = $rsHandles[$key]
                if ($h.Handle.IsCompleted) {
                    try { $h.PS.EndInvoke($h.Handle) } catch {}
                    try { $h.PS.Dispose() }             catch {}
                    $rsHandles.Remove($key)
                }
            }
        } catch {}
    })

    $timer.Start()
    [void]$form.ShowDialog()
    $timer.Stop()
    try { $rsPool.Close(); $rsPool.Dispose() } catch {}
}
