# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : Build migration plan from VM list.
#                 Reuses Build-Cache logic from original script.
#                 Cache built ONCE — returned for reuse across all batches.
#                 Host load (CPU/MEM %) checked via Get-VMHost.
# Name          : Get-VMwareMigrationPlan.ps1
# Compatibility : PS 5.1-compatible (requires VMware.PowerCLI)
# =================================================

function Get-VMwareMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string[]]$VMNames,
        [string[]]$VCenter,
        [switch]$UseCache,
        [switch]$RefreshCache,
        [int]$CacheMaxAgeHours    = 6,
        [int]$BatchSize           = 100,
        [int]$MaxHostAllocatedPct = 80
    )

    $funcName = "Get-VMwareMigrationPlan"

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
        try { $vcList = @($Global:VMwareSessions.Keys) } catch {}
    }
    $vcList = @($vcList | Select-Object -Unique)

    if ($vcList.Count -eq 0) {
        Write-VMwareLog -Function $funcName -Message "No connected vCenters found." -Level "ERROR"
        return $null
    }

    Write-Host "`n[$funcName] Building plan across vCenter(s): $($vcList -join ', ')" -ForegroundColor Cyan

    # ----------------------------------------------------------------
    # Helper: unique MoRef-style ID
    # ----------------------------------------------------------------
    function New-ViewId { param($MoRef)
        if (-not $MoRef) { return $null }
        return ("{0}-{1}" -f $MoRef.Type, $MoRef.Value)
    }

    # ----------------------------------------------------------------
    # 2. Build or load cache per vCenter
    # ----------------------------------------------------------------
    if (-not $Global:VMwareSACache) { $Global:VMwareSACache = @{} }

    $mergedVmLookup  = @{}   # vmName -> cache entry
    $mergedClusterMap = @{}  # "vcName|clusterName" -> cluster info

    foreach ($vc in $vcList) {
        $viServer = $null
        try { $viServer = $Global:VMwareSessions[$vc] } catch {}

        if (-not $viServer -or -not $viServer.IsConnected) {
            Write-VMwareLog -Function $funcName -VC $vc -Message "Not connected — attempting reconnect..." -Level "WARN"
            try {
                $cred = Import-VMwareCredential -VCenter $vc
                if ($cred) {
                    $viServer = Connect-VIServer -Server $vc -Credential $cred -Force -ErrorAction Stop
                    $Global:VMwareSessions[$vc] = $viServer
                }
            } catch {
                Write-VMwareLog -Function $funcName -VC $vc -Message "Reconnect failed: $($_.Exception.Message)" -Level "ERROR"
                continue
            }
        }

        # Cache key + path
        $safeVc    = ($vc -replace '[^a-z0-9\.\-]','_')
        $cachePath = Join-Path (Get-VMwareDirs).Cache ("vmcache_$safeVc.clixml")

        $cache     = $null
        $needBuild = $true

        if (-not $RefreshCache -and $UseCache) {
            # Try in-memory first
            if ($Global:VMwareSACache.ContainsKey($vc)) {
                $cache = $Global:VMwareSACache[$vc]
            } elseif (Test-Path -LiteralPath $cachePath) {
                try { $cache = Import-Clixml -LiteralPath $cachePath } catch { $cache = $null }
            }
            if ($cache) {
                $ageHours = [double]::PositiveInfinity
                try {
                    $ageHours = ((Get-Date) - [datetime]::Parse($cache.GeneratedAt)).TotalHours
                } catch {}
                if ($ageHours -le $CacheMaxAgeHours) {
                    $needBuild = $false
                    Write-VMwareLog -Function $funcName -VC $vc -Message "Using cached data ($([math]::Round($ageHours,1))h old)"
                } else {
                    Write-VMwareLog -Function $funcName -VC $vc -Message "Cache expired ($([math]::Round($ageHours,1))h). Rebuilding..." -Level "WARN"
                }
            }
        }

        if ($needBuild) {
            Write-Host "  [$vc] Building DRS group cache..." -ForegroundColor Yellow
            $clusterMap = @{}
            $vmLookup   = @{}

            foreach ($cluster in (Get-Cluster -Server $viServer)) {
                $s01vm = Get-DrsClusterGroup -Cluster $cluster -Name "site01_vms"   -Server $viServer -ErrorAction SilentlyContinue
                $s02vm = Get-DrsClusterGroup -Cluster $cluster -Name "site02_vms"   -Server $viServer -ErrorAction SilentlyContinue
                $s01h  = Get-DrsClusterGroup -Cluster $cluster -Name "site01_hosts" -Server $viServer -ErrorAction SilentlyContinue
                $s02h  = Get-DrsClusterGroup -Cluster $cluster -Name "site02_hosts" -Server $viServer -ErrorAction SilentlyContinue

                $s01HostIds = @(); $s02HostIds = @()
                if ($s01h -and $s01h.Member) {
                    foreach ($h in $s01h.Member) {
                        if ($h -and $h.ExtensionData -and $h.ExtensionData.MoRef) {
                            $s01HostIds += (New-ViewId -MoRef $h.ExtensionData.MoRef)
                        }
                    }
                }
                if ($s02h -and $s02h.Member) {
                    foreach ($h in $s02h.Member) {
                        if ($h -and $h.ExtensionData -and $h.ExtensionData.MoRef) {
                            $s02HostIds += (New-ViewId -MoRef $h.ExtensionData.MoRef)
                        }
                    }
                }

                $clusterMap[$cluster.Name] = @{
                    ClusterName   = $cluster.Name
                    Site01HostIds = $s01HostIds
                    Site02HostIds = $s02HostIds
                }

                foreach ($grp in @(
                    @{ Group=$s01vm; Site="site01" },
                    @{ Group=$s02vm; Site="site02" }
                )) {
                    if ($grp.Group -and $grp.Group.Member) {
                        foreach ($vm in $grp.Group.Member) {
                            if ($vm -and $vm.Name -and $vm.ExtensionData -and $vm.ExtensionData.MoRef) {
                                $vmLookup[$vm.Name] = @{
                                    VMName      = $vm.Name
                                    ClusterName = $cluster.Name
                                    SourceSite  = $grp.Site
                                    VmViewId    = (New-ViewId -MoRef $vm.ExtensionData.MoRef)
                                    VCenter     = $vc
                                }
                            }
                        }
                    }
                }
            }

            $cache = @{
                VCenter     = $vc
                GeneratedAt = (Get-Date).ToString("s")
                ClusterMap  = $clusterMap
                VmLookup    = $vmLookup
            }
            $Global:VMwareSACache[$vc] = $cache
            try { $cache | Export-Clixml -LiteralPath $cachePath -Force } catch {}
            Write-VMwareLog -Function $funcName -VC $vc -Message "Cache built: $($vmLookup.Count) VMs across $($clusterMap.Count) cluster(s)"
        }

        # Merge into combined lookup (keyed by vmName)
        foreach ($key in $cache.VmLookup.Keys) { $mergedVmLookup[$key] = $cache.VmLookup[$key] }
        foreach ($key in $cache.ClusterMap.Keys) { $mergedClusterMap["$vc|$key"] = $cache.ClusterMap[$key] }
    }

    # ----------------------------------------------------------------
    # 3. Resolve VM list against merged cache
    # ----------------------------------------------------------------
    $tasks   = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $seen    = @{}

    $total = $VMNames.Count; $idx = 0
    foreach ($rawName in $VMNames) {
        $idx++
        $name = $rawName.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true

        Write-Progress -Id 1 -Activity "[$funcName] Resolving VMs" `
            -Status "[$idx/$total] $name" -PercentComplete ([math]::Round(($idx/$total)*100))

        if (-not $mergedVmLookup.ContainsKey($name)) {
            [void]$skipped.Add([pscustomobject]@{
                VMName = $name; VCenter = "UNKNOWN"; Cluster = "UNKNOWN"
                Status = "FAILED"
                Remarks = "Not found in site01_vms/site02_vms across vCenter(s): $($vcList -join ', ')"
            })
            continue
        }

        $info    = $mergedVmLookup[$name]
        $vc      = $info.VCenter
        $cacheMapKey = "$vc|$($info.ClusterName)"

        if (-not $mergedClusterMap.ContainsKey($cacheMapKey)) {
            [void]$skipped.Add([pscustomobject]@{
                VMName=$name; VCenter=$vc; Cluster=$info.ClusterName
                Status="SKIPPED"; Remarks="Cluster [$($info.ClusterName)] not found in cache"
            })
            continue
        }

        $clusterInfo = $mergedClusterMap[$cacheMapKey]
        $targetSite  = if ($info.SourceSite -eq "site01") { "site02" } else { "site01" }
        $targetHostIds = if ($targetSite -eq "site01") {
            @($clusterInfo.Site01HostIds)
        } else {
            @($clusterInfo.Site02HostIds)
        }

        if (-not $targetHostIds -or $targetHostIds.Count -eq 0) {
            [void]$skipped.Add([pscustomobject]@{
                VMName=$name; VCenter=$vc; Cluster=$info.ClusterName
                Status="SKIPPED"
                Remarks="No host IDs found for target site [$targetSite] in cluster [$($info.ClusterName)]"
            })
            continue
        }

        [void]$tasks.Add([pscustomobject]@{
            VMName          = $name
            VCenter         = $vc
            Cluster         = $info.ClusterName
            VmViewId        = $info.VmViewId
            SourceSite      = $info.SourceSite
            TargetSite      = $targetSite
            TargetHostIds   = $targetHostIds
            SourceHostName  = $null     # resolved below
            TargetHostName  = $null     # assigned at dispatch
            VmMemoryGB      = $null     # resolved below
            BatchNumber     = 0
            BatchId         = $null
            Status          = "QUEUED"
            RetryCount      = 0
            TaskId          = $null
            StartTime       = $null
            EndTime         = $null
            DurationMin     = $null
            Remarks         = $null
        })
    }

    Write-Progress -Id 1 -Activity "[$funcName] Resolving VMs" -Completed

    if ($tasks.Count -eq 0) {
        Write-VMwareLog -Function $funcName -Message "No resolvable VMs found." -Level "WARN"
        return $null
    }

    # ----------------------------------------------------------------
    # 4. Bulk resolve VM objects + source host + memory per vCenter
    # ----------------------------------------------------------------
    Write-Host "  Resolving VM objects + host placement in bulk..." -ForegroundColor Yellow

    $tasksByVc = @{}
    foreach ($t in $tasks) {
        if (-not $tasksByVc.ContainsKey($t.VCenter)) { $tasksByVc[$t.VCenter] = @() }
        $tasksByVc[$t.VCenter] = @($tasksByVc[$t.VCenter] + $t)
    }

    # Store resolved VM + host objects for use by workers
    $vmObjMap   = [hashtable]::Synchronized(@{})  # vmViewId -> VM PowerCLI object
    $hostObjMap = [hashtable]::Synchronized(@{})  # hostViewId -> VMHost PowerCLI object

    foreach ($vc in $tasksByVc.Keys) {
        $viServer = $Global:VMwareSessions[$vc]

        # Bulk Get-View for VMs
        $vmIds    = @($tasksByVc[$vc] | Select-Object -ExpandProperty VmViewId -Unique)
        $vmViews  = @()
        try { $vmViews = @(Get-View -Server $viServer -Id $vmIds -Property Name,Runtime.Host,Config.Hardware.MemoryMB) } catch {}

        $vmViewById = @{}
        foreach ($v in $vmViews) { $vmViewById[$v.Id] = $v }

        # Collect required host IDs (source + all target)
        $hostIdsNeeded = @{}
        foreach ($v in $vmViews) {
            if ($v.Runtime -and $v.Runtime.Host) {
                $hostIdsNeeded[(New-ViewId -MoRef $v.Runtime.Host)] = $true
            }
        }
        foreach ($t in $tasksByVc[$vc]) {
            foreach ($hid in $t.TargetHostIds) { $hostIdsNeeded[$hid] = $true }
        }

        # Bulk Get-View for hosts
        $hostViews = @()
        if ($hostIdsNeeded.Count -gt 0) {
            try { $hostViews = @(Get-View -Server $viServer -Id @($hostIdsNeeded.Keys) -Property Name) } catch {}
        }
        $hostViewById = @{}
        foreach ($h in $hostViews) { $hostViewById[$h.Id] = $h }

        # Resolve PowerCLI VM objects + source host name + memory
        foreach ($t in $tasksByVc[$vc]) {
            $vv = $vmViewById[$t.VmViewId]
            if (-not $vv) {
                $t.Status  = "FAILED"
                $t.Remarks = "VM not found via Get-View"
                continue
            }

            # VM PowerCLI object
            try {
                $vmObj = Get-VIObjectByVIView -VIObject $vv -Server $viServer
                $vmObjMap[$t.VmViewId] = $vmObj
            } catch {
                $t.Status  = "FAILED"
                $t.Remarks = "Get-VIObjectByVIView failed: $($_.Exception.Message)"
                continue
            }

            # Source host name
            if ($vv.Runtime -and $vv.Runtime.Host) {
                $srcId = New-ViewId -MoRef $vv.Runtime.Host
                if ($hostViewById.ContainsKey($srcId)) {
                    $t.SourceHostName = $hostViewById[$srcId].Name
                }
            }

            # Memory GB
            try {
                if ($vv.Config -and $vv.Config.Hardware -and $vv.Config.Hardware.MemoryMB) {
                    $t.VmMemoryGB = [math]::Round($vv.Config.Hardware.MemoryMB / 1024, 2)
                }
            } catch {}
        }

        # Resolve PowerCLI host objects for target hosts (with CPU/MEM load)
        Write-Host "  [$vc] Getting host CPU/MEM load..." -ForegroundColor Yellow
        $targetHostViewIds = @($tasksByVc[$vc] | ForEach-Object { $_.TargetHostIds } | Select-Object -Unique)
        try {
            $vmHostObjs = @(Get-VMHost -Server $viServer -Id $targetHostViewIds -ErrorAction SilentlyContinue)
            foreach ($h in $vmHostObjs) {
                $hid = New-ViewId -MoRef $h.ExtensionData.MoRef
                $cpuPct = $null; $memPct = $null
                try {
                    if ($h.CpuUsageMhz -gt 0 -and $h.CpuTotalMhz -gt 0) {
                        $cpuPct = [math]::Round(($h.CpuUsageMhz / $h.CpuTotalMhz) * 100, 1)
                    }
                } catch {}
                try {
                    if ($h.MemoryUsageGB -gt 0 -and $h.MemoryTotalGB -gt 0) {
                        $memPct = [math]::Round(($h.MemoryUsageGB / $h.MemoryTotalGB) * 100, 1)
                    }
                } catch {}
                $hostObjMap[$hid] = [pscustomobject]@{
                    Id     = $hid
                    Name   = $h.Name
                    Obj    = $h
                    CpuPct = $cpuPct
                    MemPct = $memPct
                }
            }
        } catch {
            Write-VMwareLog -Function $funcName -VC $vc -Message "Host load query failed: $($_.Exception.Message)" -Level "WARN"
        }
    }

    # Remove failed tasks from main list
    $validTasks = @($tasks | Where-Object { $_.Status -eq "QUEUED" })
    $failedDuringResolve = @($tasks | Where-Object { $_.Status -ne "QUEUED" })
    foreach ($t in $failedDuringResolve) {
        [void]$skipped.Add([pscustomobject]@{
            VMName=$t.VMName; VCenter=$t.VCenter; Cluster=$t.Cluster
            Status=$t.Status; Remarks=$t.Remarks
        })
    }

    # ----------------------------------------------------------------
    # 5. Assign batch numbers — interleaved site01/site02 within each batch
    # ----------------------------------------------------------------
    $site01 = @($validTasks | Where-Object { $_.SourceSite -eq "site01" })
    $site02 = @($validTasks | Where-Object { $_.SourceSite -eq "site02" })

    $batchNum = 1
    for ($i = 0; $i -lt [math]::Max($site01.Count, $site02.Count); $i += $BatchSize) {
        $bId = "Batch-{0:D3}" -f $batchNum
        foreach ($t in @($site01 | Select-Object -Skip $i -First $BatchSize)) {
            $t.BatchNumber = $batchNum; $t.BatchId = $bId
        }
        foreach ($t in @($site02 | Select-Object -Skip $i -First $BatchSize)) {
            $t.BatchNumber = $batchNum; $t.BatchId = $bId
        }
        $batchNum++
    }
    $totalBatches = $batchNum - 1

    # Build batch summary objects
    $batches = New-Object System.Collections.Generic.List[object]
    for ($b = 1; $b -le $totalBatches; $b++) {
        $bId    = "Batch-{0:D3}" -f $b
        $bTasks = @($validTasks | Where-Object { $_.BatchNumber -eq $b })
        [void]$batches.Add([pscustomobject]@{
            BatchNumber  = $b
            BatchId      = $bId
            VMCount      = $bTasks.Count
            Site01Count  = @($bTasks | Where-Object { $_.SourceSite -eq "site01" }).Count
            Site02Count  = @($bTasks | Where-Object { $_.SourceSite -eq "site02" }).Count
            Tasks        = $bTasks
            BatchStart   = $null; BatchEnd = $null; BatchDurMin = $null
        })
    }

    Write-Host "[$funcName] Plan: $($validTasks.Count) VMs | $($skipped.Count) skipped | $totalBatches batch(es)" -ForegroundColor Cyan

    return @{
        Batches      = $batches
        Skipped      = $skipped
        AllVCenters  = $vcList
        PlanTime     = Get-Date
        TotalVMs     = $validTasks.Count
        TotalBatches = $totalBatches
        VmObjMap     = $vmObjMap     # hashtable vmViewId -> VM object (shared with workers)
        HostObjMap   = $hostObjMap   # hashtable hostViewId -> host info (shared with workers)
    }
}
