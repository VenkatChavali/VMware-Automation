# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.1
# Script Type   : Private
# Purpose       : Build migration plan from VM list.
#                 Cache built once per vCenter and reused.
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

    $funcName = 'Get-VMwareMigrationPlan'

    function New-ViewId {
        param($MoRef)
        if (-not $MoRef) { return $null }
        return ('{0}-{1}' -f $MoRef.Type, $MoRef.Value)
    }

    function ConvertTo-VMwareUsagePct {
        param([object]$v)
        if ($null -eq $v) { return $null }
        $s = "$v".Trim() -replace '%',''
        $d = $null
        if ([double]::TryParse($s, [ref]$d)) { return [math]::Round($d, 2) }
        return $null
    }

    function Get-VMwareEndpoint {
        param([string]$uri)
        if ([string]::IsNullOrWhiteSpace($uri)) { return $null }
        if ($uri.StartsWith('/service/')) { return $uri.Substring(9) }
        if ($uri.StartsWith('service/')) { return $uri.Substring(8) }
        return $uri
    }

    function Get-VmMemoryGBFromView {
        param($vmView)
        try {
            if ($vmView.Config -and $vmView.Config.Hardware -and $vmView.Config.Hardware.MemoryMB -ne $null) {
                return [math]::Round(([double]$vmView.Config.Hardware.MemoryMB / 1024), 2)
            }
        } catch {}
        return $null
    }

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
        Write-VMwareLog -Function $funcName -Message 'No connected vCenters found.' -Level 'ERROR'
        return $null
    }

    Write-Host "`n[$funcName] Building plan across vCenter(s): $($vcList -join ', ')" -ForegroundColor Cyan

    if (-not $Global:VMwareSACache) { $Global:VMwareSACache = @{} }
    $mergedVmLookup   = @{}
    $mergedClusterMap = @{}

    foreach ($vc in $vcList) {
        $viServer = $null
        try { $viServer = $Global:VMwareSessions[$vc] } catch {}
        if (-not $viServer -or -not $viServer.IsConnected) {
            Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message 'Not connected — attempting reconnect...' -Level 'WARN'
            try {
                $cred = Import-VMwareCredential -VCenter ([string]$vc)
                if ($cred) {
                    $viServer = Connect-VIServer -Server $vc -Credential $cred -Force -ErrorAction Stop
                    $Global:VMwareSessions[$vc] = $viServer
                }
            } catch {
                Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message ("Reconnect failed: {0}" -f $_.Exception.Message) -Level 'ERROR'
                continue
            }
        }

        $safeVc    = ($vc -replace '[^a-z0-9\.\-]','_')
        $cachePath = Join-Path (Get-VMwareDirs).Cache ("vmcache_{0}.clixml" -f $safeVc)
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
                    Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message ("Using cached data ({0}h old)" -f [math]::Round($ageHours,1))
                }
            }
        }

        if ($needBuild) {
            Write-Host "  [$vc] Building DRS group cache..." -ForegroundColor Yellow
            $clusterMap = @{}
            $vmLookup   = @{}

            foreach ($cluster in (Get-Cluster -Server $viServer)) {
                $s01vm = Get-DrsClusterGroup -Cluster $cluster -Name 'site01_vms'   -Server $viServer -ErrorAction SilentlyContinue
                $s02vm = Get-DrsClusterGroup -Cluster $cluster -Name 'site02_vms'   -Server $viServer -ErrorAction SilentlyContinue
                $s01h  = Get-DrsClusterGroup -Cluster $cluster -Name 'site01_hosts' -Server $viServer -ErrorAction SilentlyContinue
                $s02h  = Get-DrsClusterGroup -Cluster $cluster -Name 'site02_hosts' -Server $viServer -ErrorAction SilentlyContinue

                $s01HostIds = @(); $s02HostIds = @()
                if ($s01h -and $s01h.Member) {
                    foreach ($h in $s01h.Member) {
                        try { if ($h.ExtensionData -and $h.ExtensionData.MoRef) { $s01HostIds += (New-ViewId -MoRef $h.ExtensionData.MoRef) } } catch {}
                    }
                }
                if ($s02h -and $s02h.Member) {
                    foreach ($h in $s02h.Member) {
                        try { if ($h.ExtensionData -and $h.ExtensionData.MoRef) { $s02HostIds += (New-ViewId -MoRef $h.ExtensionData.MoRef) } } catch {}
                    }
                }

                $clusterMap[$cluster.Name] = @{
                    ClusterName   = [string]$cluster.Name
                    Site01HostIds = @($s01HostIds | Select-Object -Unique)
                    Site02HostIds = @($s02HostIds | Select-Object -Unique)
                }

                foreach ($grp in @(@{ Group=$s01vm; Site='site01' }, @{ Group=$s02vm; Site='site02' })) {
                    if ($grp.Group -and $grp.Group.Member) {
                        foreach ($vm in $grp.Group.Member) {
                            try {
                                if ($vm -and $vm.Name -and $vm.ExtensionData -and $vm.ExtensionData.MoRef) {
                                    $key = [string]$vm.Name
                                    $entry = @{
                                        VMName      = [string]$vm.Name
                                        ClusterName = [string]$cluster.Name
                                        SourceSite  = [string]$grp.Site
                                        VmViewId    = (New-ViewId -MoRef $vm.ExtensionData.MoRef)
                                        VCenter     = [string]$vc
                                    }
                                    if ($vmLookup.ContainsKey($key)) {
                                        if (-not ($vmLookup[$key] -is [System.Collections.IList])) {
                                            $vmLookup[$key] = @($vmLookup[$key])
                                        }
                                        $vmLookup[$key] += $entry
                                    } else {
                                        $vmLookup[$key] = $entry
                                    }
                                }
                            } catch {}
                        }
                    }
                }
            }

            $cache = @{ VCenter=[string]$vc; GeneratedAt=(Get-Date).ToString('s'); ClusterMap=$clusterMap; VmLookup=$vmLookup }
            $Global:VMwareSACache[$vc] = $cache
            try { $cache | Export-Clixml -LiteralPath $cachePath -Force } catch {}
            Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message ("Cache built: {0} cluster(s)" -f $clusterMap.Count)
        }

        foreach ($key in $cache.VmLookup.Keys) {
            $entry = $cache.VmLookup[$key]
            if (-not $mergedVmLookup.ContainsKey($key)) { $mergedVmLookup[$key] = @() }
            if ($entry -is [System.Collections.IEnumerable] -and -not ($entry -is [string]) -and -not ($entry -is [hashtable])) {
                foreach ($e in $entry) { $mergedVmLookup[$key] += $e }
            } else {
                $mergedVmLookup[$key] += $entry
            }
        }
        foreach ($key in $cache.ClusterMap.Keys) { $mergedClusterMap["$vc|$key"] = $cache.ClusterMap[$key] }
    }

    $tasks   = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $seen    = @{}

    $total = $VMNames.Count; $idx = 0
    foreach ($rawName in $VMNames) {
        $idx++
        $name = $rawName.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true

        Write-Progress -Id 1 -Activity "[$funcName] Resolving VMs" -Status "[$idx/$total] $name" -PercentComplete ([math]::Round(($idx/$total)*100))

        if (-not $mergedVmLookup.ContainsKey($name)) {
            [void]$skipped.Add([pscustomobject]@{ VMName=$name; VCenter='UNKNOWN'; Cluster='UNKNOWN'; Status='FAILED'; Remarks=("Not found in site01_vms/site02_vms across vCenter(s): {0}" -f ($vcList -join ', ')) })
            continue
        }

        $matches = @($mergedVmLookup[$name])
        if ($matches.Count -gt 1) {
            [void]$skipped.Add([pscustomobject]@{ VMName=$name; VCenter='MULTIPLE'; Cluster='MULTIPLE'; Status='SKIPPED'; Remarks='VM found more than once across site affinity groups or vCenters — ambiguous' })
            continue
        }

        $info    = $matches[0]
        $vc      = [string]$info.VCenter
        $clusterName = [string]$info.ClusterName
        $cacheMapKey = "$vc|$clusterName"
        if (-not $mergedClusterMap.ContainsKey($cacheMapKey)) {
            [void]$skipped.Add([pscustomobject]@{ VMName=$name; VCenter=$vc; Cluster=$clusterName; Status='SKIPPED'; Remarks=("Cluster [{0}] not found in cache" -f $clusterName) })
            continue
        }

        $clusterInfo = $mergedClusterMap[$cacheMapKey]
        $sourceSite  = [string]$info.SourceSite
        $targetSite  = if ($sourceSite -eq 'site01') { 'site02' } else { 'site01' }
        $targetHostIds = if ($targetSite -eq 'site01') { @($clusterInfo.Site01HostIds) } else { @($clusterInfo.Site02HostIds) }
        if (-not $targetHostIds -or $targetHostIds.Count -eq 0) {
            [void]$skipped.Add([pscustomobject]@{ VMName=$name; VCenter=$vc; Cluster=$clusterName; Status='SKIPPED'; Remarks=("No host IDs found for target site [{0}] in cluster [{1}]" -f $targetSite, $clusterName) })
            continue
        }

        [void]$tasks.Add([pscustomobject]@{
            VMName          = [string]$name
            VCenter         = [string]$vc
            Cluster         = [string]$clusterName
            VmViewId        = [string]$info.VmViewId
            SourceSite      = [string]$sourceSite
            TargetSite      = [string]$targetSite
            TargetHostIds   = @($targetHostIds | Select-Object -Unique)
            SourceHostName  = $null
            SourceHostId    = $null
            TargetHostName  = $null
            TargetHostId    = $null
            TargetHostCpuPct = $null
            TargetHostMemPct = $null
            VmMemoryGB      = $null
            BatchNumber     = 0
            BatchId         = $null
            AffinityChangeStatus  = $null
            AffinityChangeRemarks = $null
            Status          = 'QUEUED'
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
        Write-VMwareLog -Function $funcName -Message 'No resolvable VMs found.' -Level 'WARN'
        return $null
    }

    Write-Host '  Resolving VM objects + host placement in bulk...' -ForegroundColor Yellow
    $tasksByVc = @{}
    foreach ($t in $tasks) {
        if (-not $tasksByVc.ContainsKey($t.VCenter)) { $tasksByVc[$t.VCenter] = @() }
        $tasksByVc[$t.VCenter] += $t
    }

    $vmObjMap   = @{}
    $hostObjMap = @{}

    foreach ($vc in $tasksByVc.Keys) {
        $viServer = $Global:VMwareSessions[$vc]
        if (-not $viServer -or -not $viServer.IsConnected) { continue }

        $vmIds = @($tasksByVc[$vc] | Select-Object -ExpandProperty VmViewId -Unique)
        $vmViews = @()
        try { $vmViews = @(Get-View -Server $viServer -Id $vmIds -Property Name,Runtime.Host,Config.Hardware.MemoryMB) } catch {}
        $vmViewById = @{}
        foreach ($v in $vmViews) { $vmViewById[[string]$v.Id] = $v }

        $hostIdsNeeded = @{}
        foreach ($v in $vmViews) {
            try { if ($v.Runtime -and $v.Runtime.Host) { $hostIdsNeeded[(New-ViewId -MoRef $v.Runtime.Host)] = $true } } catch {}
        }
        foreach ($t in $tasksByVc[$vc]) { foreach ($hid in $t.TargetHostIds) { $hostIdsNeeded[[string]$hid] = $true } }

        $hostViews = @()
        if ($hostIdsNeeded.Count -gt 0) {
            try { $hostViews = @(Get-View -Server $viServer -Id @($hostIdsNeeded.Keys) -Property Name,Runtime.InMaintenanceMode,Runtime.ConnectionState) } catch {}
        }
        $hostViewById = @{}
        foreach ($h in $hostViews) { $hostViewById[[string]$h.Id] = $h }

        foreach ($t in $tasksByVc[$vc]) {
            $vmViewKey = [string]$t.VmViewId
            if ($vmViewKey -notmatch '^VirtualMachine-') { $vmViewKey = 'VirtualMachine-' + $vmViewKey.Trim() }
            $vv = $null
            if ($vmViewById.ContainsKey($vmViewKey)) { $vv = $vmViewById[$vmViewKey] }
            if (-not $vv) {
                $t.Status='FAILED'; $t.Remarks=("VM not found via Get-View (VmViewId={0})" -f $t.VmViewId); continue
            }
            try { $vmObjMap[$vmViewKey] = Get-VIObjectByVIView -VIObject $vv -Server $viServer } catch { $t.Status='FAILED'; $t.Remarks=("Get-VIObjectByVIView failed: {0}" -f $_.Exception.Message); continue }
            try {
                if ($vv.Runtime -and $vv.Runtime.Host) {
                    $srcId = New-ViewId -MoRef $vv.Runtime.Host
                    $t.SourceHostId = [string]$srcId
                    if ($hostViewById.ContainsKey($srcId)) { $t.SourceHostName = [string]$hostViewById[$srcId].Name }
                }
            } catch {}
            $t.VmMemoryGB = Get-VmMemoryGBFromView -vmView $vv
        }

        Write-Host "  [$vc] Getting host CPU/MEM load..." -ForegroundColor Yellow
        $targetHostViewIds = @($tasksByVc[$vc] | ForEach-Object { $_.TargetHostIds } | Select-Object -Unique)
        try {
            $vmHostObjs = @(Get-VMHost -Server $viServer -Id $targetHostViewIds -ErrorAction SilentlyContinue)
            foreach ($h in $vmHostObjs) {
                $hid = New-ViewId -MoRef $h.ExtensionData.MoRef
                $cpu = $null; $mem = $null
                try { if ($h.CpuUsageMhz -ge 0 -and $h.CpuTotalMhz -gt 0) { $cpu = [math]::Round(($h.CpuUsageMhz / $h.CpuTotalMhz) * 100, 1) } } catch {}
                try { if ($h.MemoryUsageGB -ge 0 -and $h.MemoryTotalGB -gt 0) { $mem = [math]::Round(($h.MemoryUsageGB / $h.MemoryTotalGB) * 100, 1) } } catch {}
                $state = ''; $maint = $false
                try { $state = [string]$h.ConnectionState } catch {}
                try { $maint = [bool]$h.ExtensionData.Runtime.InMaintenanceMode } catch {}
                $hostObjMap[$hid] = [pscustomobject]@{ Id=$hid; Name=[string]$h.Name; Obj=$h; CpuPct=$cpu; MemPct=$mem; ConnectionState=$state; InMaintenanceMode=$maint }
            }
        } catch {
            Write-VMwareLog -Function $funcName -VC ([string]$vc) -Message ("Host load query failed: {0}" -f $_.Exception.Message) -Level 'WARN'
        }
    }

    $validTasks = @($tasks | Where-Object { $_.Status -eq 'QUEUED' })
    foreach ($t in @($tasks | Where-Object { $_.Status -ne 'QUEUED' })) {
        [void]$skipped.Add([pscustomobject]@{ VMName=$t.VMName; VCenter=$t.VCenter; Cluster=$t.Cluster; Status=$t.Status; Remarks=$t.Remarks })
    }

    $site01 = @($validTasks | Where-Object { $_.SourceSite -eq 'site01' })
    $site02 = @($validTasks | Where-Object { $_.SourceSite -eq 'site02' })
    $batchNum = 1
    for ($i = 0; $i -lt [math]::Max($site01.Count, $site02.Count); $i += $BatchSize) {
        $bId = 'Batch-{0:D3}' -f $batchNum
        foreach ($t in @($site01 | Select-Object -Skip $i -First $BatchSize)) { $t.BatchNumber = $batchNum; $t.BatchId = $bId }
        foreach ($t in @($site02 | Select-Object -Skip $i -First $BatchSize)) { $t.BatchNumber = $batchNum; $t.BatchId = $bId }
        $batchNum++
    }
    $totalBatches = $batchNum - 1

    $batches = New-Object System.Collections.Generic.List[object]
    for ($b = 1; $b -le $totalBatches; $b++) {
        $bId = 'Batch-{0:D3}' -f $b
        $bTasks = @($validTasks | Where-Object { $_.BatchNumber -eq $b })
        [void]$batches.Add([pscustomobject]@{ BatchNumber=$b; BatchId=$bId; VMCount=$bTasks.Count; Site01Count=@($bTasks | Where-Object { $_.SourceSite -eq 'site01' }).Count; Site02Count=@($bTasks | Where-Object { $_.SourceSite -eq 'site02' }).Count; Tasks=$bTasks; BatchStart=$null; BatchEnd=$null; BatchDurMin=$null })
    }

    Write-Host "[$funcName] Plan: $($validTasks.Count) VMs | $($skipped.Count) skipped | $totalBatches batch(es)" -ForegroundColor Cyan
    return @{ Batches=$batches; Skipped=$skipped; AllVCenters=$vcList; PlanTime=Get-Date; TotalVMs=$validTasks.Count; TotalBatches=$totalBatches; VmObjMap=$vmObjMap; HostObjMap=$hostObjMap }
}
