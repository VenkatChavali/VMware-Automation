# =================================================
# VMwareSiteAffinity.psm1 - COMPILED BUILD
# Version : 1.0.0  Built: 09-Apr-2026 10:03
# DO NOT EDIT
# =================================================

# =================================================
# Module       : VMwareSiteAffinity
# Author       : Venkat Praveen Kumar Chavali
# Date         : 24-Mar-2026
# Version      : 1.0
# Purpose      : VMware DRS site affinity change + vMotion automation.
#                Mirrors the FusionComputeCLI module architecture.
# Compatibility: PS 5.1, VMware.PowerCLI required
# =================================================

#Requires -Version 5.1

# ---- Resolve module root ----
$ModuleRoot = $PSScriptRoot
if (-not $ModuleRoot) {
    try { $ModuleRoot = $ExecutionContext.SessionState.Module.ModuleBase } catch {}
}
if (-not $ModuleRoot) {
    try { $ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
}

# ---- Verify PowerCLI is available ----
$powerCLIAvailable = $false
try {
    if (Get-Module -ListAvailable -Name "VMware.PowerCLI" -ErrorAction SilentlyContinue) {
        $powerCLIAvailable = $true
    } elseif (Get-Module -ListAvailable -Name "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue) {
        $powerCLIAvailable = $true
    }
} catch {}

if (-not $powerCLIAvailable) {
    Write-Warning "[VMwareSiteAffinity] VMware.PowerCLI is not installed. Install it with: Install-Module VMware.PowerCLI"
}

# ---- Base path resolution ----
#   Priority: VMWARE_SA_BASE_PATH env var -> <ModuleRoot>\Data -> Documents
if (-not $Global:VMwareSABasePath) {
    if (-not [string]::IsNullOrWhiteSpace($env:VMWARE_SA_BASE_PATH)) {
        $Global:VMwareSABasePath = $env:VMWARE_SA_BASE_PATH.Trim()
    } elseif ($ModuleRoot) {
        $Global:VMwareSABasePath = Join-Path $ModuleRoot 'Data'
    } else {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $Global:VMwareSABasePath = if ($docs) { Join-Path $docs 'VMwareSiteAffinityData' } else { Join-Path $env:TEMP 'VMwareSiteAffinityData' }
    }
}

# ---- Session map ----
if (-not $Global:VMwareSessions)   { $Global:VMwareSessions   = @{} }
if (-not $Global:VMwareSACache)    { $Global:VMwareSACache     = @{} }


# PRIVATE

# --- Get-VMwareMigrationPlan.ps1 ---
# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 09-Apr-2026
# Version       : 3.0
# Script Type   : Private
# Purpose       : Build VMware migration plan from VM list.
#                 Optimised cache build:
#                 - 1 Get-DrsClusterGroup per cluster (not 4)
#                 - No Get-View for VMs (MoRef direct from DRS group)
#                 - No source host lookup (not needed for migration)
#                 - No VmMemoryGB (not needed for migration)
#                 - Bulk Get-VM after cluster scan
#                 - Bulk Get-VMHost for target hosts only
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
    function Get-MoRefId { param($MoRef)
        if (-not $MoRef) { return $null }
        return "$($MoRef.Type)-$($MoRef.Value)"
    }

    # ----------------------------------------------------------------
    # 2. Build or load cache per vCenter
    # ----------------------------------------------------------------
    if (-not $Global:VMwareSACache) { $Global:VMwareSACache = @{} }

    $mergedVmLookup   = @{}   # vmNameLower -> entry
    $mergedClusterMap = @{}   # "vc|clusterName" -> cluster info

    foreach ($vc in $vcList) {
        $viServer = $null
        try { $viServer = $Global:VMwareSessions[$vc] } catch {}

        if (-not $viServer -or -not $viServer.IsConnected) {
            Write-VMwareLog -Function $funcName -VC $vc -Message "Not connected - reconnecting..." -Level "WARN"
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
                    Write-VMwareLog -Function $funcName -VC $vc -Message "Cache expired - rebuilding" -Level "WARN"
                }
            }
        }

        if ($needBuild) {
            Write-Host "  [$vc] Building DRS cache..." -ForegroundColor Yellow
            $t0 = Get-Date

            $clusterMap = @{}   # clusterName -> { Site01HostIds, Site02HostIds }
            $vmLookup   = @{}   # vmNameLower -> { VMName, ClusterName, SourceSite, VmMoRefId, VmMoRefType, VmMoRefVal }

            # -- Step 1: Get all clusters (1 API call) --
            $allClusters = @()
            try { $allClusters = @(Get-Cluster -Server $viServer -ErrorAction Stop) } catch {
                Write-VMwareLog -Function $funcName -VC $vc -Message "Get-Cluster failed: $($_.Exception.Message)" -Level "ERROR"
                continue
            }
            Write-Host "    $($allClusters.Count) cluster(s) found" -ForegroundColor Gray

            # -- Step 2: Per cluster - 1 Get-DrsClusterGroup call, filter in memory --
            foreach ($cluster in $allClusters) {
                $allGroups = @()
                try {
                    $allGroups = @(Get-DrsClusterGroup -Cluster $cluster -Server $viServer -ErrorAction Stop)
                } catch {
                    Write-VMwareLog -Function $funcName -VC $vc -Message "DRS groups failed for $($cluster.Name): $($_.Exception.Message)" -Level "WARN"
                    continue
                }

                # Filter in memory - zero extra API calls
                $s01vm = $allGroups | Where-Object { $_.Name -eq "site01_vms"   } | Select-Object -First 1
                $s02vm = $allGroups | Where-Object { $_.Name -eq "site02_vms"   } | Select-Object -First 1
                $s01h  = $allGroups | Where-Object { $_.Name -eq "site01_hosts" } | Select-Object -First 1
                $s02h  = $allGroups | Where-Object { $_.Name -eq "site02_hosts" } | Select-Object -First 1

                # Host IDs for target host selection
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

                # VM membership - MoRef direct from DRS group, no Get-View needed
                foreach ($grp in @(
                    @{ Group=$s01vm; Site="site01" },
                    @{ Group=$s02vm; Site="site02" }
                )) {
                    if ($grp.Group -and $grp.Group.Member) {
                        foreach ($vm in @($grp.Group.Member)) {
                            if ($vm -and $vm.Name -and $vm.ExtensionData -and $vm.ExtensionData.MoRef) {
                                $moRefId = Get-MoRefId -MoRef $vm.ExtensionData.MoRef
                                $vmLookup[$vm.Name.ToLowerInvariant()] = @{
                                    VMName      = $vm.Name
                                    ClusterName = $cluster.Name
                                    SourceSite  = $grp.Site
                                    VmMoRefId   = $moRefId
                                    VmMoRefType = $vm.ExtensionData.MoRef.Type
                                    VmMoRefVal  = $vm.ExtensionData.MoRef.Value
                                    VCenter     = $vc
                                }
                            }
                        }
                    }
                }

                $s01c = if ($s01vm -and $s01vm.Member) { @($s01vm.Member).Count } else { 0 }
                $s02c = if ($s02vm -and $s02vm.Member) { @($s02vm.Member).Count } else { 0 }
                $s01hc = $s01HostIds.Count; $s02hc = $s02HostIds.Count
                Write-Host ("    - {0,-30} VMs: site01={1} site02={2}  Hosts: site01={3} site02={4}" -f `
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
            Write-Host "  [$vc] Cache built in ${elapsed}s - $($vmLookup.Count) VMs, $($clusterMap.Count) clusters" -ForegroundColor Cyan
        }

        foreach ($key in $cache.VmLookup.Keys)  { $mergedVmLookup[$key]         = $cache.VmLookup[$key] }
        foreach ($key in $cache.ClusterMap.Keys) { $mergedClusterMap["$vc|$key"] = $cache.ClusterMap[$key] }
    }

    # ----------------------------------------------------------------
    # 3. Resolve VM names against cache
    # ----------------------------------------------------------------
    $tasks   = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $seen    = @{}

    $total = $VMNames.Count; $idx = 0
    foreach ($rawName in $VMNames) {
        $idx++
        $name    = $rawName.Trim()
        $nameLow = $name.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($name) -or $seen.ContainsKey($nameLow)) { continue }
        $seen[$nameLow] = $true

        Write-Progress -Id 1 -Activity "[$funcName] Resolving VMs" `
            -Status "[$idx/$total] $name" -PercentComplete ([math]::Round(($idx/$total)*100))

        if (-not $mergedVmLookup.ContainsKey($nameLow)) {
            [void]$skipped.Add([pscustomobject]@{
                VMName=$name; VCenter="UNKNOWN"; Cluster="UNKNOWN"
                Status="FAILED"
                Remarks="Not found in site01_vms/site02_vms on: $($vcList -join ', ')"
            })
            continue
        }

        $info        = $mergedVmLookup[$nameLow]
        $vc          = $info.VCenter
        $cacheMapKey = "$vc|$($info.ClusterName)"

        if (-not $mergedClusterMap.ContainsKey($cacheMapKey)) {
            [void]$skipped.Add([pscustomobject]@{
                VMName=$name; VCenter=$vc; Cluster=$info.ClusterName
                Status="SKIPPED"; Remarks="Cluster not in cache"
            })
            continue
        }

        $clusterInfo   = $mergedClusterMap[$cacheMapKey]
        $targetSite    = if ($info.SourceSite -eq "site01") { "site02" } else { "site01" }
        $targetHostIds = if ($targetSite -eq "site01") { @($clusterInfo.Site01HostIds) } else { @($clusterInfo.Site02HostIds) }

        if (-not $targetHostIds -or $targetHostIds.Count -eq 0) {
            [void]$skipped.Add([pscustomobject]@{
                VMName=$name; VCenter=$vc; Cluster=$info.ClusterName
                Status="SKIPPED"
                Remarks="No hosts in target site [$targetSite] for cluster [$($info.ClusterName)]"
            })
            continue
        }

        [void]$tasks.Add([pscustomobject]@{
            VMName        = $info.VMName
            VCenter       = $vc
            Cluster       = $info.ClusterName
            VmMoRefId     = $info.VmMoRefId
            VmMoRefType   = $info.VmMoRefType
            VmMoRefVal    = $info.VmMoRefVal
            SourceSite    = $info.SourceSite
            TargetSite    = $targetSite
            TargetHostIds = $targetHostIds
            SourceHostName= $null
            TargetHostName= $null
            TargetHostCpu = $null
            TargetHostMem = $null
            VmMemoryGB    = $null
            BatchNumber   = 0
            BatchId       = $null
            Status        = "QUEUED"
            RetryCount    = 0
            TaskId        = $null
            StartTime     = $null
            EndTime       = $null
            DurationMin   = $null
            Remarks       = $null
            AffinityStatus= $null
            AffinityRemark= $null
            VerifyStatus  = $null
            VerifyRemark  = $null
        })
    }

    Write-Progress -Id 1 -Activity "[$funcName] Resolving VMs" -Completed

    if ($tasks.Count -eq 0) {
        Write-VMwareLog -Function $funcName -Message "0 VMs planned, $($skipped.Count) skipped" -Level "WARN"
        return $null
    }

    # ----------------------------------------------------------------
    # 4. Bulk resolve VM PowerCLI objects + bulk host objects
    #    Only fetch what we actually need for migration
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

    $vmObjMap  = @{}   # VmMoRefId -> VM PowerCLI object
    $hostObjMap = @{}  # hostMoRefId -> host info

    foreach ($vc in $tasksByVc.Keys) {
        $viServer = $Global:VMwareSessions[$vc]
        $vcTasks  = @($tasksByVc[$vc])

        # -- Bulk Get-VM using MoRef IDs (one API call) --
        $allMoRefIds = @($vcTasks | ForEach-Object { $_.VmMoRefId } | Select-Object -Unique)
        Write-Host "  [$vc] Fetching $($allMoRefIds.Count) VM object(s)..." -ForegroundColor Gray

        $vmObjs = @()
        try {
            $vmObjs = @(Get-VM -Server $viServer -Id $allMoRefIds -ErrorAction Stop)
        } catch {
            # Fallback: fetch one by one
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

        # Index by MoRef ID - store multiple key formats for reliable lookup
        foreach ($vo in $vmObjs) {
            $moType = [string]$vo.ExtensionData.MoRef.Type
            $moVal  = [string]$vo.ExtensionData.MoRef.Value
            # Primary key: "VirtualMachine-vm-76616"
            $vid = "$moType-$moVal"
            $vmObjMap[$vid] = $vo
            # Also index by just value "vm-76616" as fallback
            $vmObjMap[$moVal] = $vo
        }

        # Mark tasks where VM object not found
        foreach ($t in $vcTasks) {
            if (-not $vmObjMap.ContainsKey($t.VmMoRefId)) {
                $t.Status  = "FAILED"
                $t.Remarks = "VM object not found (MoRef: $($t.VmMoRefId))"
            }
        }

        # -- Bulk Get-VMHost for target hosts only (one API call) --
        $targetHidSet = @{}
        foreach ($t in $vcTasks) {
            foreach ($hid in $t.TargetHostIds) { $targetHidSet[$hid] = $true }
        }
        $targetHostIds = @($targetHidSet.Keys)
        Write-Host "  [$vc] Fetching $($targetHostIds.Count) host object(s) + CPU/MEM..." -ForegroundColor Gray

        if ($targetHostIds.Count -gt 0) {
            try {
                $hostObjs = @(Get-VMHost -Server $viServer -Id $targetHostIds -ErrorAction SilentlyContinue)
                foreach ($h in $hostObjs) {
                    $hid    = "$($h.ExtensionData.MoRef.Type)-$($h.ExtensionData.MoRef.Value)"
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
                Write-Host "  [$vc] Hosts resolved - $(($hostObjs | Measure-Object).Count) found" -ForegroundColor Gray
            } catch {
                Write-VMwareLog -Function $funcName -VC $vc -Message "Get-VMHost failed: $($_.Exception.Message)" -Level "WARN"
            }
        }
    }

    # Move failed resolve tasks to skipped
    $validTasks = @($tasks | Where-Object { $_.Status -eq "QUEUED" })
    foreach ($t in @($tasks | Where-Object { $_.Status -ne "QUEUED" })) {
        [void]$skipped.Add([pscustomobject]@{
            VMName=$t.VMName; VCenter=$t.VCenter; Cluster=$t.Cluster
            Status=$t.Status; Remarks=$t.Remarks
        })
    }

    # ----------------------------------------------------------------
    # 5. Assign batches - interleaved site01/site02
    # ----------------------------------------------------------------
    $site01   = @($validTasks | Where-Object { $_.SourceSite -eq "site01" })
    $site02   = @($validTasks | Where-Object { $_.SourceSite -eq "site02" })
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
    Write-Host "[$funcName] Plan complete - $($validTasks.Count) VMs | $($skipped.Count) skipped | $totalBatches batch(es)" -ForegroundColor Cyan

    return @{
        Batches      = $batches
        Skipped      = $skipped
        AllVCenters  = $vcList
        TotalVMs     = $validTasks.Count
        TotalBatches = $totalBatches
        VmObjMap     = $vmObjMap
        HostObjMap   = $hostObjMap
    }
}

# --- Show-VMwareMigrationInputDialog.ps1 ---
# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : VM input dialog - textbox paste + CSV file browse.
#                 Replaces Get-VMNamesFromTextBox from original script.
# Name          : Show-VMwareMigrationInputDialog.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Show-VMwareMigrationInputDialog {
    [CmdletBinding()]
    param(
        [string[]]$ConnectedVCenters = @(),
        [int]$MaxObjects = 10000
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing       | Out-Null

    $vcLabel = if ($ConnectedVCenters -and $ConnectedVCenters.Count -gt 0) {
        "Connected vCenters: " + ($ConnectedVCenters -join "  |  ")
    } else {
        "No vCenters specified - all connected sessions will be searched"
    }

    function Parse-VMNames { param([string]$Raw)
        if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
        return @(
            ($Raw -replace "`r","" -split "`n") |
            ForEach-Object { ($_ -replace '[",]','').Trim() } |
            Where-Object { $_ -and $_ -notmatch '^(?i)vmname$' } |
            Select-Object -Unique
        )
    }

    $form               = New-Object System.Windows.Forms.Form
    $form.Text          = "VMware Site Affinity Migration - VM Input"
    $form.StartPosition = "CenterScreen"
    $form.Size          = New-Object System.Drawing.Size(680, 620)
    $form.MinimumSize   = New-Object System.Drawing.Size(520, 500)
    $form.BackColor     = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Tag           = $null

    # Header
    $header           = New-Object System.Windows.Forms.Panel
    $header.Dock      = "Top"; $header.Height = 70
    $header.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 60)
    $form.Controls.Add($header)

    $lblTitle         = New-Object System.Windows.Forms.Label
    $lblTitle.Text    = "Site Affinity Migration - VM Input"
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Font    = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoSize = $true; $lblTitle.Location = New-Object System.Drawing.Point(16, 8)
    $header.Controls.Add($lblTitle)

    $lblVcs           = New-Object System.Windows.Forms.Label
    $lblVcs.Text      = $vcLabel
    $lblVcs.ForeColor = [System.Drawing.Color]::FromArgb(190, 230, 210)
    $lblVcs.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblVcs.AutoSize  = $true; $lblVcs.Location = New-Object System.Drawing.Point(18, 42)
    $header.Controls.Add($lblVcs)

    # Info strip
    $strip            = New-Object System.Windows.Forms.Panel
    $strip.Dock       = "Top"; $strip.Height = 32
    $strip.BackColor  = [System.Drawing.Color]::FromArgb(210, 240, 225)
    $form.Controls.Add($strip)

    $lblInfo          = New-Object System.Windows.Forms.Label
    $lblInfo.Text     = "  Paste VM names (one per line) OR browse to a CSV/TXT file. Max $MaxObjects VMs."
    $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 40)
    $lblInfo.Font     = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblInfo.Dock     = "Fill"; $lblInfo.TextAlign = "MiddleLeft"
    $strip.Controls.Add($lblInfo)

    # Toolbar
    $toolPanel           = New-Object System.Windows.Forms.Panel
    $toolPanel.Dock      = "Top"; $toolPanel.Height = 38
    $toolPanel.BackColor = [System.Drawing.Color]::FromArgb(235, 245, 240)
    $form.Controls.Add($toolPanel)

    $btnBrowse           = New-Object System.Windows.Forms.Button
    $btnBrowse.Text      = "Browse CSV / TXT..."
    $btnBrowse.Size      = New-Object System.Drawing.Size(140, 28)
    $btnBrowse.Location  = New-Object System.Drawing.Point(8, 5)
    $btnBrowse.FlatStyle = "Flat"
    $btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 60)
    $btnBrowse.ForeColor = [System.Drawing.Color]::White
    $btnBrowse.FlatAppearance.BorderSize = 0
    $toolPanel.Controls.Add($btnBrowse)

    $btnClear            = New-Object System.Windows.Forms.Button
    $btnClear.Text       = "Clear"
    $btnClear.Size       = New-Object System.Drawing.Size(70, 28)
    $btnClear.Location   = New-Object System.Drawing.Point(156, 5)
    $btnClear.FlatStyle  = "Flat"
    $toolPanel.Controls.Add($btnClear)

    $lblFile             = New-Object System.Windows.Forms.Label
    $lblFile.Text        = ""
    $lblFile.ForeColor   = [System.Drawing.Color]::FromArgb(0, 120, 60)
    $lblFile.Font        = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblFile.AutoSize    = $true; $lblFile.Location = New-Object System.Drawing.Point(236, 10)
    $toolPanel.Controls.Add($lblFile)

    # TextBox
    $txtBox              = New-Object System.Windows.Forms.TextBox
    $txtBox.Multiline    = $true; $txtBox.ScrollBars = "Vertical"
    $txtBox.Font         = New-Object System.Drawing.Font("Consolas", 9)
    $txtBox.AcceptsReturn = $true
    $txtBox.Location     = New-Object System.Drawing.Point(14, 154)
    $txtBox.Size         = New-Object System.Drawing.Size(640, 360)
    $txtBox.Anchor       = "Top,Left,Right,Bottom"
    $form.Controls.Add($txtBox)

    # Count + warn labels
    $lblCount            = New-Object System.Windows.Forms.Label
    $lblCount.Text       = "Objects entered: 0"
    $lblCount.Font       = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblCount.ForeColor  = [System.Drawing.Color]::FromArgb(80,80,80)
    $lblCount.AutoSize   = $true; $lblCount.Location = New-Object System.Drawing.Point(16, 520)
    $lblCount.Anchor     = "Bottom,Left"
    $form.Controls.Add($lblCount)

    $lblWarn             = New-Object System.Windows.Forms.Label
    $lblWarn.Text        = ""
    $lblWarn.ForeColor   = [System.Drawing.Color]::Firebrick
    $lblWarn.Font        = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $lblWarn.AutoSize    = $true; $lblWarn.Location = New-Object System.Drawing.Point(200, 520)
    $lblWarn.Anchor      = "Bottom,Left"
    $form.Controls.Add($lblWarn)

    # Bottom buttons
    $btnPanel            = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock       = "Bottom"; $btnPanel.Height = 52
    $btnPanel.BackColor  = [System.Drawing.Color]::FromArgb(235,238,243)
    $form.Controls.Add($btnPanel)

    $btnOK               = New-Object System.Windows.Forms.Button
    $btnOK.Text          = "Start Migration"
    $btnOK.Size          = New-Object System.Drawing.Size(130, 32)
    $btnOK.Location      = New-Object System.Drawing.Point(410, 10)
    $btnOK.BackColor     = [System.Drawing.Color]::FromArgb(0, 140, 60)
    $btnOK.ForeColor     = [System.Drawing.Color]::White
    $btnOK.FlatStyle     = "Flat"; $btnOK.FlatAppearance.BorderSize = 0
    $btnOK.Font          = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnPanel.Controls.Add($btnOK)

    $btnCancel           = New-Object System.Windows.Forms.Button
    $btnCancel.Text      = "Cancel"
    $btnCancel.Size      = New-Object System.Drawing.Size(90, 32)
    $btnCancel.Location  = New-Object System.Drawing.Point(550, 10)
    $btnCancel.FlatStyle = "Flat"
    $btnPanel.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOK; $form.CancelButton = $btnCancel

    # Events
    $txtBox.Add_TextChanged({
        $names = Parse-VMNames -Raw $txtBox.Text
        $count = $names.Count
        $lblCount.Text = "Objects entered: $count"
        if ($count -gt $MaxObjects) {
            $lblWarn.Text = "  ⚠ Limit is $MaxObjects - first $MaxObjects will be used"
            $lblCount.ForeColor = [System.Drawing.Color]::Firebrick
        } else {
            $lblWarn.Text = ""; $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(80,80,80)
        }
    })

    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = "Select VM list file"
        $ofd.Filter = "CSV / Text files (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $txtBox.Text = Get-Content -LiteralPath $ofd.FileName -Raw -Encoding UTF8
                $lblFile.Text = "Loaded: " + [System.IO.Path]::GetFileName($ofd.FileName)
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Failed to read file:`n$($_.Exception.Message)","File Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }
    })

    $btnClear.Add_Click({ $txtBox.Text = ""; $lblFile.Text = "" })

    $btnOK.Add_Click({
        $names = Parse-VMNames -Raw $txtBox.Text
        if ($names.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No VM names entered.","No Input",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($names.Count -gt $MaxObjects) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "$($names.Count) VMs found. Limit is $MaxObjects. Use first $MaxObjects?","Limit Exceeded",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $names = $names | Select-Object -First $MaxObjects
        }
        $form.Tag = [string[]]$names
        $form.Close()
    })

    $btnCancel.Add_Click({ $form.Close() })

    [void]$form.ShowDialog()
    if ($form.Tag -and $form.Tag.Count -gt 0) { return [string[]]$form.Tag }
    return $null
}

# --- VmwareCredentialHelpers.ps1 ---
# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : Save and load vCenter credentials using
#                 DPAPI-encrypted Export-Clixml (same Windows
#                 user only - same approach as FusionComputeCLI).
# Name          : VmwareCredentialHelpers.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Get-VMwareCredPath {
    param([Parameter(Mandatory=$true)][string]$VCenter)

    $safe = ($VCenter.Trim().ToLowerInvariant() -replace '[^a-z0-9\.\-]','_')
    $dir  = Join-Path (Get-VMwareBasePath) 'Credentials'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir "cred_$safe.xml"
}

function Export-VMwareCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$VCenter,
        [Parameter(Mandatory=$true)][pscredential]$Credential
    )
    $path = Get-VMwareCredPath -VCenter $VCenter
    $tmp  = "$path.tmp"
    try {
        $Credential | Export-Clixml -Path $tmp -Force
        Move-Item -Path $tmp -Destination $path -Force
        Write-VMwareLog -Function "Export-VMwareCredential" -VC $VCenter -Message "Credential saved: $path"
    } catch {
        Write-VMwareLog -Function "Export-VMwareCredential" -VC $VCenter -Message "Failed to save credential: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Import-VMwareCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$VCenter)

    $path = Get-VMwareCredPath -VCenter $VCenter
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $cred = Import-Clixml -LiteralPath $path
        if ($cred -is [pscredential]) {
            Write-VMwareLog -Function "Import-VMwareCredential" -VC $VCenter -Message "Credential loaded: $path"
            return $cred
        }
        return $null
    } catch {
        Write-VMwareLog -Function "Import-VMwareCredential" -VC $VCenter -Message "Failed to load credential: $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}

# --- VmwarePathHelpers.ps1 ---
# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : Path resolution for VMware module.
#                 Priority: env var -> module-relative -> Documents
# Name          : VmwarePathHelpers.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Get-VMwareBasePath {
    # Priority:
    #   1. Already set in session
    #   2. Environment variable VMWARE_SA_BASE_PATH
    #   3. Module-relative: <ModuleRoot>\Data\
    #   4. MyDocuments\VMwareSiteAffinityData  (last resort)

    if (-not [string]::IsNullOrWhiteSpace($Global:VMwareSABasePath)) {
        return $Global:VMwareSABasePath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:VMWARE_SA_BASE_PATH)) {
        $Global:VMwareSABasePath = $env:VMWARE_SA_BASE_PATH.Trim()
        return $Global:VMwareSABasePath
    }

    $modBase = $null
    try {
        $modBase = $ExecutionContext.SessionState.Module.ModuleBase
    } catch {}

    if ($modBase) {
        $Global:VMwareSABasePath = Join-Path $modBase 'Data'
    } else {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        if (-not [string]::IsNullOrWhiteSpace($docs)) {
            $Global:VMwareSABasePath = Join-Path $docs 'VMwareSiteAffinityData'
        } else {
            $Global:VMwareSABasePath = Join-Path $env:TEMP 'VMwareSiteAffinityData'
        }
    }

    return $Global:VMwareSABasePath
}

function Get-VMwareDirs {
    $base = Get-VMwareBasePath
    $dirs = @{
        Root        = $base
        Logs        = Join-Path $base 'Logs'
        Reports     = Join-Path $base 'Reports'
        Cache       = Join-Path $base 'Cache'
        Credentials = Join-Path $base 'Credentials'
        Temp        = Join-Path $base 'Temp'
    }
    foreach ($d in $dirs.Values) {
        if (-not (Test-Path -LiteralPath $d)) {
            try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch {}
        }
    }
    return $dirs
}

function Resolve-VMwareReportDir {
    $dirs = $null
    try { $dirs = Get-VMwareDirs } catch {}
    if ($dirs -and $dirs.Reports -and (Test-Path -LiteralPath $dirs.Reports)) {
        return $dirs.Reports
    }
    $fallback = Join-Path $env:TEMP 'VMwareSiteAffinity_Reports'
    if (-not (Test-Path -LiteralPath $fallback)) {
        try { New-Item -ItemType Directory -Path $fallback -Force | Out-Null } catch {}
    }
    return $fallback
}

# --- Write-VMwareLog.ps1 ---
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

# PUBLIC

# --- Connect-VMwareVC.ps1 ---
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
                Write-VMwareLog -Function $funcName -VC $vc -Message "Already connected - skipping (use -Force to re-authenticate)"
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

# --- Get-VMwareMigrationReport.ps1 ---
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
            Write-Host "  Invalid - enter 0-$($candidates.Count)" -ForegroundColor Yellow
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
            $s = if ($starts.Count -gt 0) { $starts[0].ToString("HH:mm:ss") } else { "-" }
            $e = if ($ends.Count   -gt 0) { $ends[0].ToString("HH:mm:ss")   } else { "-" }
            $d = if ($starts.Count -gt 0 -and $ends.Count -gt 0) { "$([math]::Round(($ends[0]-$starts[0]).TotalMinutes,1)) min" } else { "-" }
            Write-Host ("  {0,-12} {1,6} {2,8} {3,8} {4,10} {5,10} {6,12}" -f $bg.Name, $rows.Count, $ok, $fail, $s, $e, $d) -ForegroundColor $(if ($fail -gt 0) {"Yellow"} else {"Green"})
        }
    }

    if ($StatusFilter -and $filtered.Count -gt 0) {
        Write-Host ""
        $filtered | Select-Object BatchId,VMName,VCenter,Cluster,MigrationStatus,VerifyStatus,Remarks,VerifyRemarks | Format-Table -AutoSize
    }

    if ($PassThru) { return $filtered }
}

# --- Invoke-VMwareSiteAffinityMigration.ps1 ---
# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 08-Apr-2026
# Version       : 2.0
# Module Type   : Public
# Purpose       : End-to-end VMware DRS affinity change + vMotion.
#                 Sequential execution - no RunspacePool, no GUI.
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
        [int]$BatchSize               = 500,
        [int]$MaxConcurrentPerVC      = 500,
        [int]$MaxConcurrentPerCluster = 50,
        [int]$MaxGlobalConcurrent     = 1000,
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

    $overallStart = Get-Date

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
        Write-Host ("  {0}  - {1,3} VM(s)  [site01:{2} site02:{3}]" -f `
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
        $hostCheck = Select-TargetHost -task $task
        if (-not $hostCheck) {
            $task.Status  = "FAILED"
            $task.Remarks = "No host under $MaxHostAllocatedPct% in [$($task.TargetSite)]"
            return $false
        }

        $vmObj = $null
        if ($plan.VmObjMap.ContainsKey($task.VmMoRefId)) {
            $vmObj = $plan.VmObjMap[$task.VmMoRefId]
        } elseif ($plan.VmObjMap.ContainsKey($task.VmMoRefVal)) {
            $vmObj = $plan.VmObjMap[$task.VmMoRefVal]
        }
        if (-not $vmObj) {
            $task.Status  = "FAILED"
            $task.Remarks = "VM object not in plan map (MoRef: $($task.VmMoRefId))"
            return $false
        }

        try {
            Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
            $pTask = Move-VM -VM $vmObj -Destination $hostCheck.Obj -RunAsync -Confirm:$false -ErrorAction Stop

            $task.TaskId         = [string]$pTask.Id
            $task.TargetHostName = $hostCheck.Name
            $task.TargetHostCpu  = $hostCheck.CpuPct
            $task.TargetHostMem  = $hostCheck.MemPct
            $task.Status         = "RUNNING"
            $task.StartTime      = Get-Date
            $task.Remarks        = "Dispatched -> $($hostCheck.Name) [CPU:$($hostCheck.CpuPct)% MEM:$($hostCheck.MemPct)%]"

            if (-not $VcRunning.ContainsKey($task.VCenter))  { $VcRunning[$task.VCenter]  = 0 }
            if (-not $ClRunning.ContainsKey($task.Cluster))  { $ClRunning[$task.Cluster]  = 0 }
            $VcRunning[$task.VCenter]++
            $ClRunning[$task.Cluster]++
            $TotalRunning.Value++

            Write-Host ("    → {0,-38} -> {1} [CPU:{2}% MEM:{3}%]" -f `
                $task.VMName, $hostCheck.Name, $hostCheck.CpuPct, $hostCheck.MemPct) -ForegroundColor Cyan
            return $true
        } catch {
            $task.Status  = "FAILED"
            $task.Remarks = "Move-VM error: $($_.Exception.Message)"
            Write-Host ("    ✗ {0,-38} {1}" -f $task.VMName, $task.Remarks) -ForegroundColor Red
            return $false
        }
    }

    function Poll-RunningTasks {
        # Bulk Get-Task for all running tasks at once - one API call instead of N
        # Also handles purged tasks (null return) and per-task timeout
        param(
            [object[]]$Tasks,
            [hashtable]$VcRunning,
            [hashtable]$ClRunning,
            [ref]$TotalRunning,
            $ViServer,
            [System.Collections.Generic.List[object]]$RunningList,
            [int]$TaskTimeoutMinutes = 30
        )

        $toScan = if ($RunningList -and $RunningList.Count -gt 0) {
            @($RunningList)
        } else {
            @($Tasks | Where-Object { $_.Status -eq "RUNNING" -and $_.TaskId })
        }

        if ($toScan.Count -eq 0) { return }

        $completed = New-Object System.Collections.Generic.List[object]

        # Bulk Get-Task - one API call for all running task IDs
        $taskIds   = @($toScan | ForEach-Object { $_.TaskId } | Where-Object { $_ })
        $taskIndex = @{}   # TaskId -> PowerCLI task object

        if ($taskIds.Count -gt 0) {
            try {
                $allPTasks = @(Get-Task -Id $taskIds -ErrorAction SilentlyContinue)
                foreach ($pt in $allPTasks) {
                    if ($pt -and $pt.Id) { $taskIndex[[string]$pt.Id] = $pt }
                }
            } catch {}
        }

        foreach ($t in $toScan) {
            $pt  = if ($taskIndex.ContainsKey($t.TaskId)) { $taskIndex[$t.TaskId] } else { $null }
            $now = Get-Date

            # Determine if task is done:
            # 1. PowerCLI says Success/Error
            # 2. Task purged from vCenter (null) - check VM current host to verify
            # 3. Task running longer than TaskTimeoutMinutes - force complete
            $isDone   = $false
            $isSuccess = $false
            $errMsg   = ""
            $endTime  = $now

            if ($pt -and $pt.State -in @("Success","Error")) {
                $isDone    = $true
                $isSuccess = ($pt.State -eq "Success")
                $endTime   = if ($pt.FinishTime) { $pt.FinishTime } else { $now }
                if (-not $isSuccess) {
                    try { if ($pt.ExtensionData -and $pt.ExtensionData.Error) { $errMsg = $pt.ExtensionData.Error.LocalizedMessage } } catch {}
                }
            } elseif (-not $pt) {
                # Task purged from vCenter - verify by checking VM's current host
                $isDone = $true
                try {
                    $vc    = $t.VCenter
                    $viSrv = $Global:VMwareSessions[$vc]
                    if ($viSrv -and $viSrv.IsConnected) {
                        $vmNow = Get-VM -Server $viSrv -Id $t.VmMoRefId -ErrorAction SilentlyContinue
                        if (-not $vmNow) { $vmNow = Get-VM -Server $viSrv -Id $t.VmMoRefVal -ErrorAction SilentlyContinue }
                        if ($vmNow) {
                            $curHid = "$($vmNow.VMHost.ExtensionData.MoRef.Type)-$($vmNow.VMHost.ExtensionData.MoRef.Value)"
                            $isSuccess = $t.TargetHostIds -contains $curHid
                            if (-not $isSuccess) { $errMsg = "Task purged - VM on $($vmNow.VMHost.Name) (not in target site)" }
                        } else {
                            $isSuccess = $false; $errMsg = "Task purged - VM not found"
                        }
                    } else {
                        $isSuccess = $false; $errMsg = "Task purged - vCenter not connected"
                    }
                } catch {
                    $isSuccess = $false; $errMsg = "Task purged - verify failed: $($_.Exception.Message)"
                }
            } elseif ($t.StartTime -and ((New-TimeSpan -Start $t.StartTime -End $now).TotalMinutes -gt $TaskTimeoutMinutes)) {
                # Still Running but exceeded per-task timeout
                $isDone = $true; $isSuccess = $false
                $errMsg = "Task timeout after $TaskTimeoutMinutes min - still showing Running in vCenter"
            }

            if ($isDone) {
                $t.EndTime = $endTime
                try { $t.DurationMin = [math]::Round(((New-TimeSpan -Start $t.StartTime -End $endTime).TotalMinutes),2) } catch {}

                if (-not $VcRunning.ContainsKey($t.VCenter)) { $VcRunning[$t.VCenter] = 0 }
                if (-not $ClRunning.ContainsKey($t.Cluster))  { $ClRunning[$t.Cluster]  = 0 }
                $VcRunning[$t.VCenter] = [math]::Max(0, $VcRunning[$t.VCenter] - 1)
                $ClRunning[$t.Cluster]  = [math]::Max(0, $ClRunning[$t.Cluster]  - 1)
                $TotalRunning.Value     = [math]::Max(0, $TotalRunning.Value - 1)

                if ($isSuccess) {
                    $t.Status  = "SUCCESS"
                    $t.Remarks = "SUCCESS -> $($t.TargetHostName) [CPU:$($t.TargetHostCpu)% MEM:$($t.TargetHostMem)%] $($t.DurationMin) min"
                    Write-Host ("    - {0,-38} $($t.DurationMin) min -> $($t.TargetHostName)" -f $t.VMName) -ForegroundColor Green
                } else {
                    $t.Status  = "FAILED_PENDING_RETRY"
                    $t.Remarks = "FAILED ($errMsg) - queued for retry"
                    Write-Host ("    ✗ {0,-38} $errMsg" -f $t.VMName) -ForegroundColor Yellow
                }
                [void]$completed.Add($t)
            }
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

        Write-Host "`n===== $bId - $($tasks.Count) VM(s) =====" -ForegroundColor Cyan

        # ---- Step A: DRS affinity change (batch per cluster) ----
        $stepAStart = Get-Date
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
            $cTasks = $clustersByVc[$ck].Tasks.ToArray()
            $viSrv = $Global:VMwareSessions[$vc]

            try {
                $clObj = Get-Cluster -Name $cln -Server $viSrv -ErrorAction Stop
                $s01g  = Get-DrsClusterGroup -Cluster $clObj -Name "site01_vms" -Server $viSrv -ErrorAction SilentlyContinue
                $s02g  = Get-DrsClusterGroup -Cluster $clObj -Name "site02_vms" -Server $viSrv -ErrorAction SilentlyContinue

                $toSite01 = New-Object System.Collections.Generic.List[object]
                $toSite02 = New-Object System.Collections.Generic.List[object]

                foreach ($t in $cTasks) {
                    # Try multiple key formats - VmMoRefId, VmMoRefVal, then scan
                    $vmObj = $null
                    if ($plan.VmObjMap.ContainsKey($t.VmMoRefId)) {
                        $vmObj = $plan.VmObjMap[$t.VmMoRefId]
                    } elseif ($plan.VmObjMap.ContainsKey($t.VmMoRefVal)) {
                        $vmObj = $plan.VmObjMap[$t.VmMoRefVal]
                    } else {
                        # Last resort: scan for matching value suffix
                        foreach ($k in $plan.VmObjMap.Keys) {
                            if ($k -like "*$($t.VmMoRefVal)*") { $vmObj = $plan.VmObjMap[$k]; break }
                        }
                    }
                    if (-not $vmObj) {
                        Write-Host ("      ⚠ $($t.VMName) - VM object not in map (MoRef: $($t.VmMoRefId))") -ForegroundColor Yellow
                        $t.AffinityStatus = "FAILED"; $t.AffinityRemark = "VM object not found in plan map"
                        continue
                    }
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
                Write-Host ("    - $cln  - site01->site02: $($toSite02.Count)  site02->site01: $($toSite01.Count)") -ForegroundColor Green
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
        $stepASec = [math]::Round(((Get-Date) - $stepAStart).TotalSeconds, 1)
        Write-Host ("  Affinity done - ✅ $afOk  ❌ $afFail  Time: ${stepASec}s") -ForegroundColor Cyan

        # ---- Step B: vMotion dispatch ----
        $stepBStart = Get-Date
        Write-Host "`n  [Step B] vMotion dispatch..." -ForegroundColor Yellow

        $vcRunning    = @{}
        $clRunning    = @{}
        $totalRunning = 0
        $trRef        = [ref]$totalRunning
        $viServerMap  = @{}
        foreach ($vc in $vcList) { $viServerMap[$vc] = $Global:VMwareSessions[$vc] }

        # RunningList - only tracks RUNNING tasks, avoids scanning all 3000+ tasks
        $runningList           = New-Object System.Collections.Generic.List[object]
        $completedSinceRefresh = 0
        $lastRefresh           = [datetime]::MinValue

        foreach ($t in @($tasks | Where-Object { $_.AffinityStatus -eq "SUCCESS" -and $_.Status -eq "QUEUED" })) {

            # Wait for slot - scan only running list, not all tasks
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

                # Refresh host load during dispatch - matters for target host selection
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
        $stepBSec = [math]::Round(((Get-Date) - $stepBStart).TotalSeconds, 1)
        $dispatchedCount = @($tasks | Where-Object { $_.Status -in @("RUNNING","SUCCESS","FAILED","FAILED_PENDING_RETRY") }).Count
        Write-Host ("  Dispatch done - $dispatchedCount VM(s) dispatched in ${stepBSec}s") -ForegroundColor Cyan
        $stepCStart = Get-Date
        Write-Host "`n  [Step C] Monitoring..." -ForegroundColor Yellow
        $deadline = (Get-Date).AddMinutes($MaxMonitorMinutes)
        $completedSinceRefresh = 0
        $lastRefresh = [datetime]::MinValue

        do {
            Start-Sleep -Seconds $PollIntervalSeconds

            # Step C - no host refresh needed, all VMs already dispatched
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

        $stepCSec = [math]::Round(((Get-Date) - $stepCStart).TotalSeconds, 1)
        Write-Host ("  Monitoring done in ${stepCSec}s") -ForegroundColor Gray

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
                $vmId    = if ($plan.VmObjMap.ContainsKey($t.VmMoRefId)) { $t.VmMoRefId } else { $t.VmMoRefVal }
                $vmNow   = Get-VM -Server $viSrv -Id $vmId -ErrorAction Stop
                $curHost = $vmNow.VMHost.Name
                $curHid  = "$($vmNow.VMHost.ExtensionData.MoRef.Type)-$($vmNow.VMHost.ExtensionData.MoRef.Value)"
                $inTarget = $t.TargetHostIds -contains $curHid
                if ($inTarget) {
                    $t.VerifyStatus  = "OK"
                    $t.VerifyRemark  = "On $curHost - confirmed in $($t.TargetSite)"
                    Write-Host ("    - {0,-38} on $curHost" -f $t.VMName) -ForegroundColor Green
                } else {
                    $t.VerifyStatus  = "WRONG_HOST"
                    $t.VerifyRemark  = "On $curHost - NOT in $($t.TargetSite) host group"
                    Write-Host ("    ⚠ {0,-38} on $curHost (wrong site!)" -f $t.VMName) -ForegroundColor Yellow
                }
            } catch {
                $t.VerifyStatus = "ERROR"; $t.VerifyRemark = $_.Exception.Message
            }
        }

        # ---- Batch summary ----
        $bSuccess = @($tasks | Where-Object { $_.Status -eq "SUCCESS" }).Count
        $bFailed  = @($tasks | Where-Object { $_.Status -notin @("SUCCESS","QUEUED") }).Count
        $bDur       = [math]::Round(((Get-Date) - $bStart).TotalMinutes, 2)
        $bThroughput = if ($bDur -gt 0) { [math]::Round($bSuccess / $bDur, 1) } else { 0 }
        $bColor     = if ($bFailed -eq 0) { "Green" } else { "Yellow" }
        Write-Host ("`n  $bId complete - ✅ $bSuccess  ❌ $bFailed  Duration: $bDur min  Throughput: $bThroughput VMs/min") -ForegroundColor $bColor

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

    $overallDur        = [math]::Round(((Get-Date) - $overallStart).TotalMinutes, 2)
    $overallThroughput = if ($overallDur -gt 0) { [math]::Round($totalSuccess / $overallDur, 1) } else { 0 }

    Write-Host "`n===== $funcName SUMMARY =====" -ForegroundColor Cyan
    Write-Host "  Total VMs  : $($allTasks.Count)"
    Write-Host "  Success    : $totalSuccess" -ForegroundColor Green
    $failColor = if ($totalFailed -gt 0) { "Red" } else { "Green" }
    Write-Host "  Failed     : $totalFailed" -ForegroundColor $failColor
    Write-Host "  Duration   : $overallDur min"
    Write-Host "  Throughput : $overallThroughput VMs/min"

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

Export-ModuleMember -Function @(
    'Connect-VMwareVC',
    'Disconnect-VMwareVC',
    'Get-VMwareMigrationReport',
    'Get-VMwareVC',
    'Invoke-VMwareSiteAffinityMigration'
)
