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
                $t = $p.Trim().ToLowerInvariant()
                if ($t) { $vcList += $t }
            }
        }
    }
    if ($vcList.Count -eq 0) {
        try { $vcList = @($Global:VMwareSessions.Keys) } catch {}
    }
    $vcList = @($vcList | Select-Object -Unique)

    if ($vcList.Count -eq 0) {
        Write-VMwareLog -Function $funcName -Message "No connected vCenters." -Level "ERROR"
        return $null
    }

    Write-Host "`n[$funcName] Building plan across: $($vcList -join ', ')" -ForegroundColor Cyan

    # ----------------------------------------------------------------
    # Helper: MoRef -> consistent string ID
    # ----------------------------------------------------------------
    function Get-MoRefId {
        param($MoRef)
        if (-not $MoRef) { return $null }
        return "$($MoRef.Type)-$($MoRef.Value)"
    }

    # ----------------------------------------------------------------
    # 2. Build or load cache per vCenter
    # ----------------------------------------------------------------
    if (-not $Global:VMwareSACache) { $Global:VMwareSACache = @{} }

    $mergedVmLookup   = @{}   # vmNameLower -> List[entry]
    $mergedClusterMap = @{}   # "vc|clusterName" -> cluster info

    foreach ($vc in $vcList) {
        $viServer = $null
        try { $viServer = $Global:VMwareSessions[$vc] } catch {}

        if (-not $viServer -or -not $viServer.IsConnected) {
            Write-VMwareLog -Function $funcName -VC $vc -Message "Not connected — reconnecting..." -Level "WARN"
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

        $safeVc    = ($vc -replace '[^a-z0-9\.\-]','_')
        $cachePath = Join-Path (Get-VMwareDirs).Cache ("vmcache_$safeVc.clixml")
        $cache     = $null
        $needBuild = $true

        if (-not $RefreshCache -and $UseCache) {
            if ($Global:VMwareSACache.ContainsKey($vc)) {
                $cache = $Global:VMwareSACache[$vc]
            } elseif (Test-Path -LiteralPath $cachePath) {
                try { $cache = Import-Clixml -LiteralPath $cachePath } catch { $cache = $null }
            }

            if ($cache) {
                $ageHours = [double]::PositiveInfinity
                try { $ageHours = ((Get-Date) - [datetime]::Parse($cache.GeneratedAt)).TotalHours } catch {}
                if ($ageHours -le $CacheMaxAgeHours) {
                    $needBuild = $false
                    Write-VMwareLog -Function $funcName -VC $vc -Message "Using cache ($([math]::Round($ageHours,1))h old)"
                } else {
                    Write-VMwareLog -Function $funcName -VC $vc -Message "Cache expired — rebuilding" -Level "WARN"
                }
            }
        }

        if ($needBuild) {
            Write-Host "  [$vc] Building DRS cache..." -ForegroundColor Yellow
            $t0 = Get-Date

            $clusterMap = @{}   # clusterName -> { Site01HostIds, Site02HostIds }
            $vmLookup   = @{}   # vmNameLower -> List[entry]

            # -- Step 1: Get all clusters --
            $allClusters = @()
            try {
                $allClusters = @(Get-Cluster -Server $viServer -ErrorAction Stop)
            } catch {
                Write-VMwareLog -Function $funcName -VC $vc -Message "Get-Cluster failed: $($_.Exception.Message)" -Level "ERROR"
                continue
            }
            Write-Host "    $($allClusters.Count) cluster(s) found" -ForegroundColor Gray

            # -- Step 2: Per cluster — 1 Get-DrsClusterGroup call --
            foreach ($cluster in $allClusters) {
                $allGroups = @()
                try {
                    $allGroups = @(Get-DrsClusterGroup -Cluster $cluster -Server $viServer -ErrorAction Stop)
                } catch {
                    Write-VMwareLog -Function $funcName -VC $vc -Message "DRS groups failed for $($cluster.Name): $($_.Exception.Message)" -Level "WARN"
                    continue
                }

                $s01vm = $allGroups | Where-Object { $_.Name -eq "site01_vms"   } | Select-Object -First 1
                $s02vm = $allGroups | Where-Object { $_.Name -eq "site02_vms"   } | Select-Object -First 1
                $s01h  = $allGroups | Where-Object { $_.Name -eq "site01_hosts" } | Select-Object -First 1
                $s02h  = $allGroups | Where-Object { $_.Name -eq "site02_hosts" } | Select-Object -First 1

                $s01HostIds = New-Object System.Collections.Generic.List[string]
                $s02HostIds = New-Object System.Collections.Generic.List[string]

                if ($s01h -and $s01h.Member) {
                    foreach ($h in @($s01h.Member)) {
                        if ($h -and $h.ExtensionData -and $h.ExtensionData.MoRef) {
                            [void]$s01HostIds.Add((Get-MoRefId -MoRef $h.ExtensionData.MoRef))
                        }
                    }
                }

                if ($s02h -and $s02h.Member) {
                    foreach ($h in @($s02h.Member)) {
                        if ($h -and $h.ExtensionData -and $h.ExtensionData.MoRef) {
                            [void]$s02HostIds.Add((Get-MoRefId -MoRef $h.ExtensionData.MoRef))
                        }
                    }
                }

                $clusterMap[$cluster.Name] = @{
                    ClusterName   = $cluster.Name
                    Site01HostIds = $s01HostIds.ToArray()
                    Site02HostIds = $s02HostIds.ToArray()
                }

                foreach ($grp in @(
                    @{ Group = $s01vm; Site = "site01" },
                    @{ Group = $s02vm; Site = "site02" }
                )) {
                    if ($grp.Group -and $grp.Group.Member) {
                        foreach ($vm in @($grp.Group.Member)) {
                            if ($vm -and $vm.Name -and $vm.ExtensionData -and $vm.ExtensionData.MoRef) {
                                $nameKey = $vm.Name.ToLowerInvariant()

                                if (-not $vmLookup.ContainsKey($nameKey)) {
                                    $vmLookup[$nameKey] = New-Object System.Collections.Generic.List[object]
                                }

                                [void]$vmLookup[$nameKey].Add(@{
                                    VMName      = $vm.Name
                                    ClusterName = $cluster.Name
                                    SourceSite  = $grp.Site
                                    VmMoRefId   = (Get-MoRefId -MoRef $vm.ExtensionData.MoRef)
                                    VmMoRefType = $vm.ExtensionData.MoRef.Type
                                    VmMoRefVal  = $vm.ExtensionData.MoRef.Value
                                    VCenter     = $vc
                                })
                            }
                        }
                    }
                }

                $s01c  = if ($s01vm -and $s01vm.Member) { @($s01vm.Member).Count } else { 0 }
                $s02c  = if ($s02vm -and $s02vm.Member) { @($s02vm.Member).Count } else { 0 }
                $s01hc = $s01HostIds.Count
                $s02hc = $s02HostIds.Count

                Write-Host ("    ✓ {0,-30} VMs: site01={1} site02={2}  Hosts: site01={3} site02={4}" -f `
                    $cluster.Name, $s01c, $s02c, $s01hc, $s02hc) -ForegroundColor Gray
            }

            $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
            Write-Host ("  [$vc] DRS cache built in ${elapsed}s") -ForegroundColor Cyan

            $cache = @{
                VCenter     = $vc
                GeneratedAt = (Get-Date).ToString("s")
                ClusterMap  = $clusterMap
                VmLookup    = $vmLookup
            }

            $Global:VMwareSACache[$vc] = $cache
            try { $cache | Export-Clixml -LiteralPath $cachePath -Force } catch {}

            Write-Host "  [$vc] Cache built in ${elapsed}s — $($vmLookup.Count) VM names, $($clusterMap.Count) clusters" -ForegroundColor Cyan
        }

        foreach ($key in $cache.VmLookup.Keys) {
            if (-not $mergedVmLookup.ContainsKey($key)) {
                $mergedVmLookup[$key] = New-Object System.Collections.Generic.List[object]
            }
            foreach ($entry in @($cache.VmLookup[$key])) {
                [void]$mergedVmLookup[$key].Add($entry)
            }
        }

        foreach ($key in $cache.ClusterMap.Keys) {
            $mergedClusterMap["$vc|$key"] = $cache.ClusterMap[$key]
        }
    }

    # ----------------------------------------------------------------
    # 3. Resolve VM names against cache
    # ----------------------------------------------------------------
    $tasks   = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $seen    = @{}

    $total = $VMNames.Count
    $idx   = 0

    foreach ($rawName in $VMNames) {
        $idx++
        $name = ""
        try { $name = $rawName.Trim() } catch { $name = "" }

        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $nameLow = $name.ToLowerInvariant()
        if ($seen.ContainsKey($nameLow)) { continue }
        $seen[$nameLow] = $true

        Write-Progress -Id 1 -Activity "[$funcName] Resolving VMs" `
            -Status "[$idx/$total] $name" -PercentComplete ([math]::Round(($idx/$total)*100))

        if (-not $mergedVmLookup.ContainsKey($nameLow)) {
            [void]$skipped.Add([pscustomobject]@{
                VMName  = $name
                VCenter = "UNKNOWN"
                Cluster = "UNKNOWN"
                Status  = "FAILED"
                Remarks = "Not found in site01_vms/site02_vms on: $($vcList -join ', ')"
            })
            continue
        }

        $matches = @($mergedVmLookup[$nameLow])

        if ($matches.Count -gt 1) {
            $vcNames = @($matches | ForEach-Object { $_.VCenter } | Select-Object -Unique)
            [void]$skipped.Add([pscustomobject]@{
                VMName  = $name
                VCenter = ($vcNames -join ', ')
                Cluster = "MULTIPLE"
                Status  = "SKIPPED"
                Remarks = "VM name exists in multiple vCenters. Input must uniquely identify the VM."
            })
            continue
        }

        $info        = $matches[0]
        $vc          = $info.VCenter
        $cacheMapKey = "$vc|$($info.ClusterName)"

        if (-not $mergedClusterMap.ContainsKey($cacheMapKey)) {
            [void]$skipped.Add([pscustomobject]@{
                VMName  = $name
                VCenter = $vc
                Cluster = $info.ClusterName
                Status  = "SKIPPED"
                Remarks = "Cluster not in cache"
            })
            continue
        }

        $clusterInfo   = $mergedClusterMap[$cacheMapKey]
        $targetSite    = if ($info.SourceSite -eq "site01") { "site02" } else { "site01" }
        $targetHostIds = if ($targetSite -eq "site01") { @($clusterInfo.Site01HostIds) } else { @($clusterInfo.Site02HostIds) }

        if (-not $targetHostIds -or $targetHostIds.Count -eq 0) {
            [void]$skipped.Add([pscustomobject]@{
                VMName  = $name
                VCenter = $vc
                Cluster = $info.ClusterName
                Status  = "SKIPPED"
                Remarks = "No hosts in target site [$targetSite] for cluster [$($info.ClusterName)]"
            })
            continue
        }

        [void]$tasks.Add([pscustomobject]@{
            VMName         = $info.VMName
            VCenter        = $vc
            Cluster        = $info.ClusterName
            VmMoRefId      = $info.VmMoRefId
            VmMoRefType    = $info.VmMoRefType
            VmMoRefVal     = $info.VmMoRefVal
            SourceSite     = $info.SourceSite
            TargetSite     = $targetSite
            TargetHostIds  = $targetHostIds
            SourceHostName = $null
            TargetHostName = $null
            TargetHostCpu  = $null
            TargetHostMem  = $null
            VmMemoryGB     = $null
            BatchNumber    = 0
            BatchId        = $null
            Status         = "QUEUED"
            RetryCount     = 0
            TaskId         = $null
            StartTime      = $null
            EndTime        = $null
            DurationMin    = $null
            Remarks        = $null
            AffinityStatus = $null
            AffinityRemark = $null
            VerifyStatus   = $null
            VerifyRemark   = $null
        })
    }

    Write-Progress -Id 1 -Activity "[$funcName] Resolving VMs" -Completed

    if ($tasks.Count -eq 0) {
        Write-VMwareLog -Function $funcName -Message "0 VMs planned, $($skipped.Count) skipped" -Level "WARN"

        $result = @{
            Batches      = @()
            Skipped      = @($skipped)
            AllVCenters  = @($vcList)
            TotalVMs     = 0
            TotalBatches = 0
            VmObjMap     = @{}
            HostObjMap   = @{}
        }

        return $result
    }

    # ----------------------------------------------------------------
    # 4. Bulk resolve VM PowerCLI objects + bulk host objects
    # ----------------------------------------------------------------
    $t0Resolve = Get-Date
    Write-Host "  Bulk resolving VM + host objects..." -ForegroundColor Yellow

    $tasksByVc = @{}
    foreach ($t in $tasks) {
        if (-not $tasksByVc.ContainsKey($t.VCenter)) {
            $tasksByVc[$t.VCenter] = New-Object System.Collections.Generic.List[object]
        }
        [void]$tasksByVc[$t.VCenter].Add($t)
    }

    $vmObjMap   = @{}
    $hostObjMap = @{}

    foreach ($vc in $tasksByVc.Keys) {
        $viServer = $Global:VMwareSessions[$vc]
        $vcTasks  = @($tasksByVc[$vc])

        $allMoRefIds = @($vcTasks | ForEach-Object { $_.VmMoRefId } | Select-Object -Unique)
        Write-Host "  [$vc] Fetching $($allMoRefIds.Count) VM object(s)..." -ForegroundColor Gray

        $vmObjs = @()
        try {
            $vmObjs = @(Get-VM -Server $viServer -Id $allMoRefIds -ErrorAction Stop)
        } catch {
            Write-VMwareLog -Function $funcName -VC $vc -Message "Bulk Get-VM failed, trying per-VM: $($_.Exception.Message)" -Level "WARN"
            foreach ($id in $allMoRefIds) {
                try {
                    $vo = Get-VM -Server $viServer -Id $id -ErrorAction Stop
                    $vmObjs += $vo
                } catch {
                    Write-VMwareLog -Function $funcName -VC $vc -Message "Get-VM failed for $id`: $($_.Exception.Message)" -Level "WARN"
                }
            }
        }

        foreach ($vo in $vmObjs) {
            $moType = [string]$vo.ExtensionData.MoRef.Type
            $moVal  = [string]$vo.ExtensionData.MoRef.Value
            $vid    = "$moType-$moVal"
            $vmObjMap[$vid]   = $vo
            $vmObjMap[$moVal] = $vo
        }

        foreach ($t in $vcTasks) {
            if (-not $vmObjMap.ContainsKey($t.VmMoRefId) -and -not $vmObjMap.ContainsKey($t.VmMoRefVal)) {
                $t.Status  = "FAILED"
                $t.Remarks = "VM object not found (MoRef: $($t.VmMoRefId))"
            }
        }

        $targetHidSet = @{}
        foreach ($t in $vcTasks) {
            foreach ($hid in @($t.TargetHostIds)) { $targetHidSet[$hid] = $true }
        }
        $targetHostIds = @($targetHidSet.Keys)
        Write-Host "  [$vc] Fetching $($targetHostIds.Count) host object(s) + CPU/MEM..." -ForegroundColor Gray

        if ($targetHostIds.Count -gt 0) {
            try {
                $hostObjs = @(Get-VMHost -Server $viServer -Id $targetHostIds -ErrorAction SilentlyContinue)
                foreach ($h in $hostObjs) {
                    $hid    = "$($h.ExtensionData.MoRef.Type)-$($h.ExtensionData.MoRef.Value)"
                    $cpuPct = $null
                    $memPct = $null
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
                Write-Host "  [$vc] Hosts resolved — $(($hostObjs | Measure-Object).Count) found" -ForegroundColor Gray
            } catch {
                Write-VMwareLog -Function $funcName -VC $vc -Message "Get-VMHost failed: $($_.Exception.Message)" -Level "WARN"
            }
        }
    }

    $validTasks = @($tasks | Where-Object { $_.Status -eq "QUEUED" })
    foreach ($t in @($tasks | Where-Object { $_.Status -ne "QUEUED" })) {
        [void]$skipped.Add([pscustomobject]@{
            VMName  = $t.VMName
            VCenter = $t.VCenter
            Cluster = $t.Cluster
            Status  = $t.Status
            Remarks = $t.Remarks
        })
    }

    # ----------------------------------------------------------------
    # 5. Assign batches
    # ----------------------------------------------------------------
    $site01   = @($validTasks | Where-Object { $_.SourceSite -eq "site01" })
    $site02   = @($validTasks | Where-Object { $_.SourceSite -eq "site02" })
    $batchNum = 1

    for ($i = 0; $i -lt [math]::Max($site01.Count, $site02.Count); $i += $BatchSize) {
        $bId = "Batch-{0:D3}" -f $batchNum

        foreach ($t in @($site01 | Select-Object -Skip $i -First $BatchSize)) {
            $t.BatchNumber = $batchNum
            $t.BatchId     = $bId
        }
        foreach ($t in @($site02 | Select-Object -Skip $i -First $BatchSize)) {
            $t.BatchNumber = $batchNum
            $t.BatchId     = $bId
        }

        $batchNum++
    }

    $totalBatches = $batchNum - 1

    $batches = New-Object System.Collections.Generic.List[object]
    for ($b = 1; $b -le $totalBatches; $b++) {
        $bId    = "Batch-{0:D3}" -f $b
        $bTasks = @($validTasks | Where-Object { $_.BatchNumber -eq $b })
        [void]$batches.Add([pscustomobject]@{
            BatchNumber = $b
            BatchId     = $bId
            VMCount     = $bTasks.Count
            Site01Count = @($bTasks | Where-Object { $_.SourceSite -eq "site01" }).Count
            Site02Count = @($bTasks | Where-Object { $_.SourceSite -eq "site02" }).Count
            Tasks       = $bTasks
        })
    }

    $resolveElapsed = [math]::Round(((Get-Date) - $t0Resolve).TotalSeconds, 1)
    Write-Host "  VM + host objects resolved in ${resolveElapsed}s" -ForegroundColor Gray
    Write-Host "[$funcName] Plan complete — $($validTasks.Count) VMs | $($skipped.Count) skipped | $totalBatches batch(es)" -ForegroundColor Cyan

    $result = @{
        Batches      = @($batches)
        Skipped      = @($skipped)
        AllVCenters  = @($vcList)
        TotalVMs     = [int]$validTasks.Count
        TotalBatches = [int]$totalBatches
        VmObjMap     = $vmObjMap
        HostObjMap   = $hostObjMap
    }

    return $result
}
