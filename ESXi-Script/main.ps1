## Date       : 08-August-2024
## Purpose    : DELL firmware upgrade and ESXi patch / version upgrade - 8.x
## Written by : Venkat Praveen Kumar Chavali (VPCOPS)
## Version    : 1.0
## Reviewers  : Zhi Hua NG, Siva Prasad, Karthik Kommineni

## Script Workflow:
   # Input to the script : ESXi Host Name/s, VCENTER Server, DELL OME
   # Script will identify the cluster managing the ESXi host 
   # Check for any VMs with DRS overrides (vSphere DRS automation level disabled / manual). If there is an override, migrate the VM/s manually before initiating upgrade
   # Do health checks on ESXi host. If health checks are good, proceed with next steps below
   # If there are no VM overrides, place the ESXi host in Maintenance Mode
   # Disable alarms on the ESXi host
   # Ensure the relevant Firmware binaries are available and copied to script directory for the various H/W models in use
   # Get the device details and retrieve the firmware binaries based on the device / hardware models
   # If any of the firmware baseline update fails, rerun the baseline update at the end
   # Post firmware update attempt, proceed with ESXi upgrade
   # If ESXi upgrade is successful, perform post upgrade activities and health checks -> take server out of Maintenance mode -> enable alarms
   # If the firmware / patch updates fail, alert the SA and stop executing the script
   # If post update health checks fail, do not take the host out of Maintenance mode. Alert the SA to validate


# Start Upgrade Function #

$ESXiUpgrade = {

    param(
        
    $logPath,
    $vCenter,
    $esxiServer,
    $DEPCR,
    $StartDate,
    $opt,
    $licenseKey

    )

# Functions required for the firmware and ESXi version updates #

    Function Check-Network-Adapters($before, $after)
{
    If ($before.count -ne $after.count){
        return $false
    }
    
    ForEach($BeforeVmnic in $Before){
        ForEach($AfterVmnic in $After){
            If ($BeforeVmnic.Name -eq $AfterVmnic.Name){
                If ($BeforeVmnic.ExtensionData.LinkSpeed.SpeedMb -eq $AfterVmnic.ExtensionData.LinkSpeed.SpeedMb -and $BeforeVmnic.ExtensionData.LinkSpeed.Duplex -eq $AfterVmnic.ExtensionData.LinkSpeed.Duplex){
                    Break
                }
                Else{
                    return $false
                }
            }
        }
    }
    
    return $true
}

    Function Check-HBA-Aapters($before, $after)
{
    If ($before.count -ne $after.count){
        return $false
    }

    ForEach($BeforeHba in $before){
        ForEach($AfterHba in $after){
            If ($BeforeHba.Device -eq $AfterHba.Device){
                If ($BeforeHba.Status -eq $AfterHba.Status){
                    Break
                }
                Else{
                    return $false
                }
            }
        }
    }

    Return $true
}

    Function Check-VM-Override-Manual-DRS($vmhost)
{
    
    $vms = $vmhost | Get-VM | Where-Object {$_.DrsAutomationLevel -eq 'Manual' -or $_.DrsAutomationLevel -eq 'Disabled'}
    
    If ($vms.Length -gt 0){
        return $true
    }

    return $false
}

    Function Change-ESXi-Alarm($vmhost, $enable)
{
    $alarmMgr = Get-View AlarmManager
    $alarmMgr.EnableAlarmActions($vmhost.ExtensionData.MoRef, $enable)
}
 
    Function ESXi-Firmware-Update-iDrac($omeCreds, $omeDevice, $esxiServer, $logPath, $DEPCR)
{

$R6525 = @(

[PSCustomObject]@{Baseline = "Baseline0"; SourceName = "Integrated Dell Remote Access Controller"; Version = "7.10.50.00"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "BIOS"; Version = "2.15.2"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Backplane"; Version = "7.10"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Broadcom Adv"; Version = "22.92.06.10"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Disk"; Version = "B02A"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "X710"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Disk"; Version = "C10C"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "PERC H755"; Version = "52.26.0-5179"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom NetXtreme Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "QLE"; Version = "16.20.10"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "X550/I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "I350/X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "QLE"; Version = "16.20.10"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "Disk"; Version = "BA48"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "PERC H740P"; Version = "51.16.0-5150"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "PERC H745"; Version = "51.16.0-5150"}
[PSCustomObject]@{Baseline = "Baseline4"; SourceName = "System CPLD"; Version = "1.2.0"}
#[PSCustomObject]@{Baseline = "Baseline5"; SourceName = "QLE"; Version = "16.20.10"}

)

$R7425 = @(

[PSCustomObject]@{Baseline = "Baseline0"; SourceName = "Integrated Dell Remote Access Controller"; Version = "7.00.00.172"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "BIOS"; Version = "1.21.0"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Backplane"; Version = "2.52"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Disk"; Version = "B02A"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "PERC H745"; Version = "51.16.0-5150"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "PERC H740P"; Version = "51.16.0-5150"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "PERC H830"; Version = "25.5.9.0001"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Broadcom Adv"; Version = "22.92.06.10"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "QLE"; Version = "16.20.10"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "X550/I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "I350/X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom NetXtreme Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "PERC H840"; Version = "51.16.0-5148"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "Disk"; Version = "AS10"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "X710"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "QLE"; Version = "16.20.10"}
[PSCustomObject]@{Baseline = "Baseline4"; SourceName = "System CPLD"; Version = "1.0.11"}
#[PSCustomObject]@{Baseline = "Baseline5"; SourceName = "QLE"; Version = "16.20.10"}

)

$R6625 = @(

[PSCustomObject]@{Baseline = "Baseline0"; SourceName = "Integrated Dell Remote Access Controller"; Version = "7.10.50.00"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "BIOS"; Version = "1.8.3"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Backplane"; Version = "7.10"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Broadcom Adv"; Version = "22.92.06.10"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Disk"; Version = "2.0.1"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Disk"; Version = "C10C"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "X550/I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "I350/X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Disk"; Version = "BD48"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom NetXtreme Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "QLE"; Version = "16.20.10"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "X710"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "PERC H755"; Version = "52.26.0-5179"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "Disk"; Version = "EJ09"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline4"; SourceName = "System CPLD"; Version = "1.6.1"}

)

$R7625 = @(

[PSCustomObject]@{Baseline = "Baseline0"; SourceName = "Integrated Dell Remote Access Controller"; Version = "7.10.50.00"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "BIOS"; Version = "1.8.3"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Backplane"; Version = "7.10"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Broadcom Adv"; Version = "22.92.06.10"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "Disk"; Version = "2.0.1"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "X550/I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline1"; SourceName = "I350/X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Disk"; Version = "C10C"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom NetXtreme Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "Broadcom Gigabit Ethernet"; Version = "22.91.5"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "QLE"; Version = "16.20.10"}
[PSCustomObject]@{Baseline = "Baseline2"; SourceName = "X710"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "PERC H755"; Version = "52.26.0-5179"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "I350"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "X550"; Version = "22.5.7"}
[PSCustomObject]@{Baseline = "Baseline3"; SourceName = "Disk"; Version = "DSG8"}
[PSCustomObject]@{Baseline = "Baseline4"; SourceName = "System CPLD"; Version = "1.6.1"}

)
    
    try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}

    if($esxcli){
        
        try{$ErrorActionPreference = 'Stop'; $DeviceVendor =  $esxcli.hardware.platform.get.Invoke().VendorName} catch{}
        try{$ErrorActionPreference = 'Stop'; $omeDeviceModel1 =  $esxcli.hardware.platform.get.Invoke().ProductName} catch{}

        # 1. Check whether the hardware is DELL #

        if($DeviceVendor -like "Dell*"){

        try{$ErrorActionPreference = 'Stop'; $idracIP = $esxcli.hardware.ipmi.bmc.get.Invoke().IPV4Address} catch{}
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Hardware vendor: $DeviceVendor | Hardware Model: $omeDeviceModel1 | iDRAC IP : $idracIP"

        }

        else{
        
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Hardware vendor: $DeviceVendor | Hardware Model: $omeDeviceModel1 - Not a DELL server. Please upgrade firmware manually"
        return $true
        $fwPro = 0

        }

        # 1. End #

    if($fwPro -ne 0){

    if($DeviceVendor -like "Dell*" -and $idracIP){

        try{$ErrorActionPreference = 'Stop'; $omeDeviceModel =  $esxcli.hardware.platform.get.Invoke().ProductName.Split(" ")[1]} catch{}
        $idracU = $omeCreds.UserName
        $idracP = $omeCreds.GetNetworkCredential().Password

        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Gathering the details of mapped firmware baselines"

        $fwBinaryPath = "$logPath\Firmware-Binaries\$omeDeviceModel"
        $fwBaselines = (Get-ChildItem -Path $fwBinaryPath -ErrorAction Ignore).Name
        
        # 2. Check whether firmware baselines and binaries are available #

        if($fwBaselines){
            
            $finalFwUpdChk = 0

            if($omeDeviceModel -eq "R6525"){$fwVerCsv = $R6525}
            elseif($omeDeviceModel -eq "R6625"){$fwVerCsv = $R6625}
            elseif($omeDeviceModel -eq "R7425"){$fwVerCsv = $R7425}
            elseif($omeDeviceModel -eq "R7625"){$fwVerCsv = $R7625}
            else{$fwVerCsv = "NA"}

            $fwBaselineCount = $fwBaselines.Count
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - There are $fwBaselineCount firmware baselines mapped"

            try{$ErrorActionPreference = 'Stop'; $fwVerInv = Get-IdracFirmwareVersionREDFISH -idrac_ip $iDracIP -idrac_username $idracU -idrac_password $idracP -ErrorAction Ignore} catch{}
            if($fwVerInv -notlike "*error*" -and $fwVerInv -ne $null){} else{Start-Sleep -Seconds 60 ;try{$ErrorActionPreference = 'Stop'; $fwVerInv = Get-IdracFirmwareVersionREDFISH -idrac_ip $iDracIP -idrac_username $idracU -idrac_password $idracP -ErrorAction Ignore} catch{}}

            if($fwVerInv -notlike "*error*" -and $fwVerInv -ne $null -and $fwVerInv -notlike "*Unable to connect to the remote server*"){

            #$fwVerCsv = Import-Csv -Path "$logPath\Fw-Versions\$omeDeviceModel.csv"

            # 3. Iteration 1 - Compliance check of firmware versions as compared with the Baselines #

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR  -Message "$esxiServer - Performing a compliance check against the firmware baselines"

            $exclHwComp = @()

            foreach($fwBase in $fwBaselines){

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Getting hardware component details of the baseline $fwBase"

            $fwBaselineVer = $fwVerCsv | Where-Object{$_.Baseline -eq "$fwBase"}
            $fwBinaries = (Get-ChildItem -Path $fwBinaryPath\$fwBase).Name

                foreach($comp in $fwBaselineVer){

                $compName = $comp.SourceName
                $compVersion = $comp.Version
                
                if($fwVerInv | Where-Object{$_.Name -like "*$compName*"}){
                
                if($compName -eq "Backplane"){$fwUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*" -and $_.Name -notlike "Disk*" -and $_.Version -notlike "A*" -and $_.Version -notlike "B*" -and $_.Version -notlike "C*"}) | Select -Unique}

                else{
                
                $fwVersionUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*"}).Version | Select -Unique

                $fwVersionUniqueCount = $fwVersionUnique.Count

                if($fwVersionUniqueCount -eq 1){$fwUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*"}) | Get-Random} else{$fwUnique = "NotFound"}

                }

                if($fwUnique -ne "NotFound"){

                    if($compName -eq "Disk"){

                        if($fwUnique.Version -like "B0*"){$compVersion = "B02A"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*BA*"){$compVersion = "BA48"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*AS*"){$compVersion = "AS10"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*C*"){$compVersion = "C10C"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*E*"){$compVersion = "EJ09"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*BD*"){$compVersion = "BD48"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*DS*"){$compVersion = "DSG8"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "2*"){$compVersion = "2.0.1"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        else{$compVersion = "NotFound"}
                
                    }

                    else{$actVer = $fwUnique.Version; $actName = $fwUnique.Name}

                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Hardware Component: $actName | Baseline Version: $compVersion | Actual Version: $actVer"

                    if($compVersion -ne "NotFound" -and $compVersion -ne $actVer){

                    $compBaselineChk = $fwBinaries | Where-Object{$_ -like "*$compVersion*"}

                    if($compBaselineChk){$finalFwUpdChk += 1; Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message " Firmware for hardware component $actName is not up to date. Needs upgrade"} 
                    else{$exclHwComp += @([pscustomobject]@{Baseline="$fwBase";SourceName="$compName";Version="$compVersion"})}

                    }

                    elseif($compVersion -ne "NotFound" -and $compVersion -eq $actVer){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message " Firmware for hardware component $actName is up to date"; $exclHwComp += @([pscustomobject]@{Baseline="$fwBase";SourceName="$compName";Version="$compVersion"})}
             
                    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Firmware for hardware component $actName is not found"}
                }
                
                else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Could not find an appropriate firmware version for $actName"; $finalFwUpdChk += 1}

                }

                else{$exclHwComp += @([pscustomobject]@{Baseline="$fwBase";SourceName="$compName";Version="$compVersion"})}

                }

            }
            
            # 3. End #

            if($finalFwUpdChk -ge 1){

            # 4. Iteration 1 - Validate firmware version against baselines and update firmware on each hardware component, if required #

            <#

            $inclHwComp = @()

            foreach($obj in $fwVerCsv){
            
                $oldBaseline = $obj.Baseline
                $oldSourceName = $obj.SourceName
                $oldVersion = $obj.Version
                
                $chkObj = $exclHwComp | Where-Object{$_.Baseline -eq $oldBaseline -and $_.SourceName -eq $oldSourceName -and $_.Version -eq $oldVersion}
            
                if($chkObj){}
            
                else{
            
                $newBaseline = $oldBaseline
                $NewSourceName = $oldSourceName
                $newVersion = $oldVersion
                $inclHwComp += @([PSCustomObject]@{NewBaseline = $newBaseline; NewSourceName = $NewSourceName; NewVersion = $newVersion})
            
                }
            
            }

            #>
            
            $inclHwComp = ($fwVerCsv | Where-Object{$_.SourceName -notin $exclHwComp.SourceName}).Version
            $inclHwComp = $inclHwComp | Select -Unique

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Deleting iDRAC job queue and restarting iDRAC LC services"

            try{$ErrorActionPreference = 'Stop'; Invoke-IdracJobQueueManagementREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -delete_job_queue_restart_LC_services y -ErrorAction Continue} catch{}
            Start-Sleep -Seconds 300

            foreach($fwBase in $fwBaselines){

            [System.GC]::GetTotalMemory($true) | out-null

            $reboot = 0

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Validating firmware versions against the firmware images in the baseline $fwBase. Will upgrade the firmware of the applicable components"

            $fwBinaries = (Get-ChildItem -Path $fwBinaryPath\$fwBase).Name
            
            
            $inclFwComp = @()

                foreach($fwBinary in $fwBinaries){

                    foreach($inclHw in $inclHwComp){

                    #$inclHwVer = $inclHw.NewVersion

                    if($fwBinary -like "*$inclHw*"){$inclFwComp += $fwBinary} else{}

                    }

                }

                foreach($fwBinary in $fwBinaries){

                [System.GC]::GetTotalMemory($true) | out-null

                if($fwBinary | Where-Object{$inclFwComp -notcontains $_}){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Skipping firmware update using the image $fwBinary as the component is already up to date/image $fwBinary is for a component which is not present on the server"}
                else{ 
                        
                        $reboot += 1
                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Initiating firmware upgrade using the image $fwBinary"
                        
                        $randomSec = Get-Random -Minimum 30 -Maximum 90
                        Start-Sleep -Seconds $randomSec

                        $updateFirmware = $null
                        $updateErr = $null
                        

                        try{$ErrorActionPreference = 'Stop'; $updateFirmware = Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -image_directory_path "$logPath\Firmware-Binaries\$omeDeviceModel\$fwBase" -image_filename "$fwBinary" -reboot_server n -ErrorVariable updateErr} catch{}
                        if($updateErr){try{$ErrorActionPreference = 'Stop'; $errmsg = ($updateErr.ErrorDetails.Message | ConvertFrom-Json).Error.("@Message.ExtendedInfo").Message | Select -Unique} catch{}}

                        if($errmsg -and $errmsg -notlike "*Unable to complete the firmware upgrade operation because the specified firmware image is for a component that is not in the target system inventory or the component is disabled for performing the upgrade.*"){Start-Sleep -Seconds 60; try{$ErrorActionPreference = 'Stop'; $updateFirmware = Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -image_directory_path "$logPath\Firmware-Binaries\$omeDeviceModel\$fwBase" -image_filename "$fwBinary" -reboot_server n -ErrorVariable updateErr} catch{}} else{}

                        if($updateErr){try{$ErrorActionPreference = 'Stop'; $errmsg = ($updateErr.ErrorDetails.Message | ConvertFrom-Json).Error.("@Message.ExtendedInfo").Message | Select -Unique} catch{}}

                            if($updateFirmware -like "*202*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message " - $updateFirmware"} 
                    
                            elseif($errmsg){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message " - $errmsg"}

                            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message " - Failed to upload the firmware image. Unable to determine the error"}

                    }

                }

                if($reboot -ge 1){

                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Rebooting $esxiServer post the firmware upgrade of the hardware components in baseline $fwBase"

                Get-VMHost -Name $esxiServer | Restart-VMHost -Confirm:$false -ErrorAction Ignore -RunAsync
            
                    [System.GC]::GetTotalMemory($true) | out-null

                    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
            
                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                    Start-Sleep -Seconds 60
                    if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                    } until ($testConn -eq "NotOK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                    $stopwatch.Stop()

                    [System.GC]::GetTotalMemory($true) | out-null
                    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                    Start-Sleep -Seconds 60
                    if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                    } until ($testConn -eq "OK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                    $stopwatch.Stop()

                    [System.GC]::GetTotalMemory($true) | out-null

                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to get into Maintenance Mode"
                    Start-Sleep -Seconds 60
                    try{$esxiState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
                    } until ($esxiState -eq "Maintenance")

                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Deleting iDRAC job queue and restarting iDRAC LC services"

                    try{$ErrorActionPreference = 'Stop'; Invoke-IdracJobQueueManagementREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -delete_job_queue_restart_LC_services y -ErrorAction Continue} catch{}
                    Start-Sleep -Seconds 300

                } 
                
                else{} 

            }

            # 5. Iteration 2 - Compliance check of firmware versions as compared with the Baselines #

            $finalFwUpdChk = 0
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR  -Message "$esxiServer - Performing a compliance check against the firmware baselines"

            try{$ErrorActionPreference = 'Stop'; $fwVerInv = Get-IdracFirmwareVersionREDFISH -idrac_ip $iDracIP -idrac_username $idracU -idrac_password $idracP -ErrorAction Ignore} catch{}
            if($fwVerInv -notlike "*error*" -and $fwVerInv -ne $null){} else{Start-Sleep -Seconds 60 ;try{$ErrorActionPreference = 'Stop'; $fwVerInv = Get-IdracFirmwareVersionREDFISH -idrac_ip $iDracIP -idrac_username $idracU -idrac_password $idracP -ErrorAction Ignore} catch{}}

            if($fwVerInv -notlike "*error*" -and $fwVerInv -ne $null -and $fwVerInv -notlike "*Unable to connect to the remote server*"){

            #$fwVerCsv = Import-Csv -Path "$logPath\Fw-Versions\$omeDeviceModel.csv"

            if($fwVerInv -notlike "*error*" -and $fwVerInv -ne $null){

            $exclHwComp = @()

            foreach($fwBase in $fwBaselines){

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Getting details of hardware components in baseline $fwBase"

            $fwBaselineVer = $fwVerCsv | Where-Object{$_.Baseline -eq "$fwBase"}
            $fwBinaries = (Get-ChildItem -Path $fwBinaryPath\$fwBase).Name

                foreach($comp in $fwBaselineVer){

                $compName = $comp.SourceName
                $compVersion = $comp.Version
                
                if($fwVerInv | Where-Object{$_.Name -like "*$compName*"}){
                
                if($compName -eq "Backplane"){$fwUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*" -and $_.Name -notlike "Disk*" -and $_.Version -notlike "A*" -and $_.Version -notlike "B*" -and $_.Version -notlike "C*"}) | Select -Unique}

                else{
                
                $fwVersionUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*"}).Version | Select -Unique

                $fwVersionUniqueCount = $fwVersionUnique.Count

                if($fwVersionUniqueCount -eq 1){$fwUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*"}) | Get-Random} else{$fwUnique = "NotFound"}

                }

                if($fwUnique -ne "NotFound"){

                    if($compName -eq "Disk"){

                        if($fwUnique.Version -like "B0*"){$compVersion = "B02A"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*BA*"){$compVersion = "BA48"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*AS*"){$compVersion = "AS10"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*C*"){$compVersion = "C10C"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*E*"){$compVersion = "EJ09"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*BD*"){$compVersion = "BD48"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*DS*"){$compVersion = "DSG8"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "2*"){$compVersion = "2.0.1"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        else{$compVersion = "NotFound"}
                
                    }

                    else{$actVer = $fwUnique.Version; $actName = $fwUnique.Name}

                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Hardware Component: $actName | Baseline Version: $compVersion | Actual Version: $actVer"

                    if($compVersion -ne "NotFound" -and $compVersion -ne $actVer){

                    $compBaselineChk = $fwBinaries | Where-Object{$_ -like "*$compVersion*"}

                    if($compBaselineChk){$finalFwUpdChk += 1; Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message " Firmware for hardware component $actName is not up to date. Needs upgrade"} 
                    else{$exclHwComp += @([pscustomobject]@{Baseline="$fwBase";SourceName="$compName";Version="$compVersion"})}

                    }

                    elseif($compVersion -ne "NotFound" -and $compVersion -eq $actVer){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message " Firmware for hardware component $actName is up to date"; $exclHwComp += @([pscustomobject]@{Baseline="$fwBase";SourceName="$compName";Version="$compVersion"})}
             
                    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message " Firmware for hardware component $actName is not found"}
                }
                
                else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Could not find an appropriate firmware version for component $actName"; $finalFwUpdChk += 1}

                }

                else{$exclHwComp += @([pscustomobject]@{Baseline="$fwBase";SourceName="$compName";Version="$compVersion"})}

                }

            }

            }

            else{$finalFwUpdChk = 1}
            
            # 5. End #

            # 6. Iteration 2 - Validate firmware version against baselines and update firmware on each hardware component, if required #

            if($finalFwUpdChk -ge 1){

            <#

            $inclHwComp = @()

            foreach($obj in $fwVerCsv){
            
                $oldBaseline = $obj.Baseline
                $oldSourceName = $obj.SourceName
                $oldVersion = $obj.Version
                
                $chkObj = $exclHwComp | Where-Object{$_.Baseline -eq $oldBaseline -and $_.SourceName -eq $oldSourceName -and $_.Version -eq $oldVersion}
            
                if($chkObj){}
            
                else{
            
                $newBaseline = $oldBaseline
                $NewSourceName = $oldSourceName
                $newVersion = $oldVersion
                $inclHwComp += @([PSCustomObject]@{NewBaseline = $newBaseline; NewSourceName = $NewSourceName; NewVersion = $newVersion})
            
                }
            
            }

            #>

            $inclHwComp = ($fwVerCsv | Where-Object{$_.SourceName -notin $exclHwComp.SourceName}).Version
            $inclHwComp = $inclHwComp | Select -Unique

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Deleting iDRAC job queue and restarting iDRAC LC services"

            try{$ErrorActionPreference = 'Stop'; Invoke-IdracJobQueueManagementREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -delete_job_queue_restart_LC_services y -ErrorAction Continue} catch{}
            Start-Sleep -Seconds 300

            foreach($fwBase in $fwBaselines){

            [System.GC]::GetTotalMemory($true) | out-null

            $reboot = 0

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Validating firmware versions against the firmware images in baseline $fwBase. Will upgrade as appropriate"

            $fwBinaries = (Get-ChildItem -Path $fwBinaryPath\$fwBase).Name
            
            $inclFwComp = @()

                foreach($fwBinary in $fwBinaries){

                    foreach($inclHw in $inclHwComp){

                    #$inclHwVer = $inclHw.NewVersion

                    if($fwBinary -like "*$inclHw*"){$inclFwComp += $fwBinary} else{}

                    }

                }

                foreach($fwBinary in $fwBinaries){

                [System.GC]::GetTotalMemory($true) | out-null

                if($fwBinary | Where-Object{$inclFwComp -notcontains $_}){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Skipping firmware update using the image $fwBinary as the component is already up to date/image $fwBinary is for a component which is not present on the server"}
                else{ 
                        $reboot += 1
                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Initiating firmware upgrade using the image $fwBinary"
                        
                        $randomSec = Get-Random -Minimum 30 -Maximum 90
                        Start-Sleep -Seconds $randomSec
                        $updateFirmware = $null
                        $updateErr = $null
                        

                        try{$ErrorActionPreference = 'Stop'; $updateFirmware = Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -image_directory_path "$logPath\Firmware-Binaries\$omeDeviceModel\$fwBase" -image_filename "$fwBinary" -reboot_server n -ErrorVariable updateErr} catch{}
                        if($updateErr){try{$ErrorActionPreference = 'Stop'; $errmsg = ($updateErr.ErrorDetails.Message | ConvertFrom-Json).Error.("@Message.ExtendedInfo").Message | Select -Unique} catch{}}

                        if($errmsg -and $errmsg -notlike "*Unable to complete the firmware update operation because the specified firmware image is for a component that is not in the target system inventory or the component is disabled for performing the update.*"){Start-Sleep -Seconds 60; try{$ErrorActionPreference = 'Stop'; $updateFirmware = Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -image_directory_path "$logPath\Firmware-Binaries\$omeDeviceModel\$fwBase" -image_filename "$fwBinary" -reboot_server n -ErrorVariable updateErr} catch{}} else{}
                        if($updateErr){try{$ErrorActionPreference = 'Stop'; $errmsg = ($updateErr.ErrorDetails.Message | ConvertFrom-Json).Error.("@Message.ExtendedInfo").Message | Select -Unique} catch{}}

                            if($updateFirmware -like "*202*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message " - $updateFirmware"} 
                    
                            elseif($errmsg){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message " - $errmsg"}

                            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message " - Failed to upload the firmware image. Unable to determine the error"}

                    }

                }

                if($reboot -ge 1){

                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Rebooting $esxiServer post firmware upgrade of hardware components in baseline $fwBase"

                Get-VMHost -Name $esxiServer | Restart-VMHost -Confirm:$false -ErrorAction Ignore -RunAsync
            
                    [System.GC]::GetTotalMemory($true) | out-null

                    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
            
                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                    Start-Sleep -Seconds 60
                    if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                    } until ($testConn -eq "NotOK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                    $stopwatch.Stop()

                    [System.GC]::GetTotalMemory($true) | out-null
                    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                    Start-Sleep -Seconds 60
                    if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                    } until ($testConn -eq "OK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                    $stopwatch.Stop()

                    [System.GC]::GetTotalMemory($true) | out-null

                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to get into Maintenance Mode"
                    Start-Sleep -Seconds 60
                    try{$esxiState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
                    } until ($esxiState -eq "Maintenance")

                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Deleting iDRAC job queue and restarting iDRAC LC services"

                    try{$ErrorActionPreference = 'Stop'; Invoke-IdracJobQueueManagementREDFISH -idrac_ip $idracIP -idrac_username $idracU -idrac_password $idracP -delete_job_queue_restart_LC_services y -ErrorAction Continue} catch{}
                    Start-Sleep -Seconds 300


                } 
                
                else{} 
  
            }

            }

            else{}

            # 6. End #

            # 7. Final check of firmware versions as compared with the Baselines #
            
            $finalFwUpdChk = 0

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR  -Message "$esxiServer - Performing a final compliance check against the firmware baselines"

            try{$ErrorActionPreference = 'Stop'; $fwVerInv = Get-IdracFirmwareVersionREDFISH -idrac_ip $iDracIP -idrac_username $idracU -idrac_password $idracP -ErrorAction Ignore} catch{}
            if($fwVerInv -notlike "*error*" -and $fwVerInv -ne $null){} else{Start-Sleep -Seconds 60 ;try{$ErrorActionPreference = 'Stop'; $fwVerInv = Get-IdracFirmwareVersionREDFISH -idrac_ip $iDracIP -idrac_username $idracU -idrac_password $idracP -ErrorAction Ignore} catch{}}

            if($fwVerInv -notlike "*error*" -and $fwVerInv -ne $null -and $fwVerInv -notlike "*Unable to connect to the remote server*"){

            Remove-Item -Path "$logpath\ESXi-Update-Logs\$StartDate\$esxiServerName-Firmware-Versions.txt" -Force -Confirm:$false -ErrorAction Ignore

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR  -Message "$esxiServer - Exporting a text file with the firmware version information for review. Refer to $logpath\ESXi-Update-Logs\$StartDate\$esxiServerName-Firmware-Versions.txt in case of any compliance check failures"

            $fwVerInv | Out-File -FilePath "$logpath\ESXi-Update-Logs\$StartDate\$esxiServerName-Firmware-Versions.txt"

            #$fwVerCsv = Import-Csv -Path "$logPath\Fw-Versions\$omeDeviceModel.csv"

            $fwFailed = @()

            foreach($fwBase in $fwBaselines){

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Getting details of hardware components in baseline $fwBase"

            $fwBaselineVer = $fwVerCsv | Where-Object{$_.Baseline -eq "$fwBase"}

                foreach($comp in $fwBaselineVer){

                $compName = $comp.SourceName
                $compVersion = $comp.Version
                
                if($fwVerInv | Where-Object{$_.Name -like "*$compName*"}){
                
                if($compName -eq "Backplane"){$fwUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*" -and $_.Name -notlike "Disk*" -and $_.Version -notlike "A*" -and $_.Version -notlike "B*" -and $_.Version -notlike "C*"}) | Select -Unique}

                else{
                
                $fwVersionUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*"}).Version | Select -Unique

                $fwVersionUniqueCount = $fwVersionUnique.Count

                if($fwVersionUniqueCount -eq 1){$fwUnique = ($fwVerInv | Where-Object{$_.Name -like "*$compName*"}) | Get-Random} else{$fwUnique = "NotFound"}

                }

                if($fwUnique -ne "NotFound"){

                    if($compName -eq "Disk"){

                        if($fwUnique.Version -like "B0*"){$compVersion = "B02A"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*BA*"){$compVersion = "BA48"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*AS*"){$compVersion = "AS10"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*C*"){$compVersion = "C10C"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*E*"){$compVersion = "EJ09"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*BD*"){$compVersion = "BD48"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "*DS*"){$compVersion = "DSG8"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        elseif($fwUnique.Version -like "2*"){$compVersion = "2.0.1"; $actVer = $fwUnique.Version; $actName = $fwUnique.Name}
                        else{$compVersion = "NotFound"}
                
                    }

                    else{$actVer = $fwUnique.Version; $actName = $fwUnique.Name}

                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Hardware Component: $actName | Baseline Version: $compVersion | Actual Version: $actVer"

                    if($compVersion -ne "NotFound" -and $compVersion -ne $actVer){

                    $finalFwUpdChk += 1
                    $fwFailed += $actName

                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message " Failed to upgrade the Firmware of hardware component $actName. Please validate and take necessary action"

                    }

                    elseif($compVersion -ne "NotFound" -and $compVersion -eq $actVer){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message " Firmware for hardware component $actName is up to date"}
             
                    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message " Firmware for hardware component $actName is not found"; $finalFwUpdChk += 1; $fwFailed += $actName}
             
                }
                
                else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Could not find an appropriate firmware version for component $actName"; $finalFwUpdChk += 1}

                }

                else{}

                }

            }

            if($fwFailed.Count -gt 0){$fwFailed | Out-File "$logPath\ESXi-Update-Logs\$esxiServer-Failed-Firmware-List.txt"}
            else{}

            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to connect to iDRAC"; $finalFwUpdChk = 1}
            
            # 7. End #

            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to connect to iDRAC"; $finalFwUpdChk = 1}

            # 4. End #

            }

            else{}

            if($finalFwUpdChk -eq 0){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR  -Message "$esxiServer - Compliant against all the assigned firmware baselines."; return $true}
           else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Not compliant against the firmware baselines. Firmware upgrade of few components failed. Please validate and take necessary action"; return $false}

            }
        
            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to connect to iDRAC";return $false} 
        
        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Firmware baselines missing. Cannot proceed with the firmware upgrade"; return $false}
        
        # 2. End #
    }

    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - iDRAC details not found"; return $false}

    }

    else{return $true}

    }
    
    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to connect to esxcli namespace to get the hardware details. Cannot proceed with firmware upgrade"; return $false}


}

    Function ESXi-Enter-Maintenance-Mode($vmhost, $esxiServer, $logPath, $DEPCR)
{

    
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

    $vmhost = Get-VMHost -Name $esxiServer -ErrorAction Ignore
    $connState = $vmhost.ConnectionState
    $vmhostId = $vmhost.Id

    if($connState -ne "Connected" -and $connState -ne "Maintenance"){

    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting for the connection state to change to Connected or Maintenance"

    do{
           
           $TimeElapsed = [math]::Round($stopwatch.Elapsed.TotalMinutes,2)
           #$mmTask = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId" -and $_.Name -eq "EnterMaintenanceMode_Task"}
           $vmhost = Get-VMHost -Name $esxiServer -ErrorAction Ignore
           $connState = $vmhost.ConnectionState
           Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Connection State: $connState"
           If($TimeElapsed -gt 45){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Not in Maintenance Mode after $TimeElapsed minutes. This is unusual, please check manually"} else{}
           Start-Sleep -Seconds 60

        } until($connState -eq "Connected" -or $connState -eq "Maintenance")

    }

    else{}

    $vmhost = Get-VMHost -Name $esxiServer -ErrorAction Ignore
    $connState = $vmhost.ConnectionState

    if($connState -eq "Connected" -and $connState -ne "Maintenance"){

    try{$ErrorActionPreference = 'Stop'; Set-VMHost $vmhost -State Maintenance -Confirm:$false -Evacuate -RunAsync}
    
    catch{
        
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Unable to initiate the task to place host in Maintenance Mode. Waiting for 60 seconds for any exisiting task to complete"

        Start-Sleep -Seconds 60

        $chkMMTask = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId"}

        if($chkMMTask){

        $chkMMTaskState = $chkMMTask.State
    
            if($chkMMTaskState -eq "Running"){

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Another task is still running on this host. Waiting for the task to complete"

                $mmTaskDet = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId"}
                $mmTaskName = $mmTaskDet.Name
                $mmTaskId = $mmTaskDet.Id
                    
                    do{
           
                       $TimeElapsed = [math]::Round($stopwatch.Elapsed.TotalMinutes,2)
                       #$mmTask = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId" -and $_.Name -eq "EnterMaintenanceMode_Task"}
                       try{$mmTask = Get-Task -Id $mmTaskId -ErrorAction Ignore} catch{}
                       $mmTaskPerComplete = $mmTask.PercentComplete
                       $mmTaskState = $mmTask.State
                       Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - $mmTaskName ---- Status: $mmTaskState | Percent complete: $mmTaskPerComplete % | Time elapsed: $TimeElapsed minutes"y
                       If($TimeElapsed -gt 45){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Not in Maintenance Mode after $TimeElapsed minutes. This is unusual, please check manually"} else{}
                       Start-Sleep -Seconds 60

                    } until($mmTaskState -ne "Running")

            }

            else{}

        } else{}

    }

    Start-Sleep -Seconds 60
    $mmTaskDet = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId" -and $_.Name -eq "EnterMaintenanceMode_Task"}
    $mmTaskId = $mmTaskDet.Id
                    
        do{
           
           $TimeElapsed = [math]::Round($stopwatch.Elapsed.TotalMinutes,2)
           #$mmTask = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId" -and $_.Name -eq "EnterMaintenanceMode_Task"}
           try{$mmTask = Get-Task -Id $mmTaskId -ErrorAction Ignore} catch{}
           $mmTaskPerComplete = $mmTask.PercentComplete
           $mmTaskState = $mmTask.State
           Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Maintenance Mode Task ---- Status: $mmTaskState | Percent complete: $mmTaskPerComplete % | Time elapsed: $TimeElapsed minutes"
           If($TimeElapsed -gt 45){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Not in Maintenance Mode after $TimeElapsed minutes. This is unusual, please check manually"} else{}
           Start-Sleep -Seconds 60

        } until($mmTaskState -ne "Running")

    }

    else{}

    $stopwatch.Stop()

}

    Function ESXi-Exit-Maintenance-Mode($vmhost, $esxiServer, $logPath, $DEPCR)
{

    $vmhostId = $vmhost.Id
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

    Set-VMHost $vmhost -State Connected -Confirm:$false -ErrorAction Inquire -RunAsync | Out-Null
    $mmTaskDet = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId" -and $_.Name -eq "ExitMaintenanceMode_Task"}
    $mmTaskId = $mmTaskDet.Id
                    
        do{
           
           Start-Sleep -Seconds 120
           $TimeElapsed = [math]::Round($stopwatch.Elapsed.TotalMinutes,2)
           #$mmTask = Get-Task | Where-Object{$_.ObjectId -eq "$vmhostId" -and $_.Name -eq "ExitMaintenanceMode_Task"}
           try{$mmTask = Get-Task -Id $mmTaskId -ErrorAction Ignore} catch{}
           $mmTaskPerComplete = $mmTask.PercentComplete
           $mmTaskState = $mmTask.State
           Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Exit Maintenance Mode Task ---- Status: $mmTaskState | Percent complete: $mmTaskPerComplete % | Time elapsed: $TimeElapsed minutes"

        } until($mmTaskState -ne "Running")

    $stopwatch.Stop()

}

    Function ESXi-Copy-Post-Update-Files($esxiServerName, $vmhost, $localDs, $logpath)
{
    if(Get-Datastore -Name $localDs){} else{$vmhost | Get-VMHostStorage -RescanAllHba -ErrorAction Ignore | Out-Null}

    if(Get-Datastore -Name $localDs){

    try{Remove-PSDrive -Name esxilocalds -Confirm:$false -ErrorAction Ignore} catch{}
    
    try{$ErrorActionPreference = 'Stop'; New-PSDrive -Location $localDs -Name esxilocalds -PSProvider VimDatastore -Root "\" | Out-Null} catch{}
    Set-Location esxilocalds:\ -ErrorAction Ignore
    $localDsLoc = Get-Location

    if($localDsLoc.Path -eq "esxilocalds:\"){

    $cipherPath = $esxiServerName + "_vmsa_static-ciphers-backup"

    if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-TempFiles" -ErrorAction Ignore){Remove-Item -Path "$localDsLoc\ESXi-Upgrade-TempFiles" -Recurse -Confirm:$false -ErrorAction Ignore} else{}
    if(Test-Path -Path "$localDsLoc\$cipherPath" -ErrorAction Ignore){Remove-Item -Path "$localDsLoc\$cipherPath" -Recurse -Confirm:$false -ErrorAction Ignore} else{}

    New-Item -Path "$localDsLoc\" -Name "ESXi-Upgrade-TempFiles" -ItemType Directory -Confirm:$false | Out-Null
    New-Item -Path "$localDsLoc\" -Name "$cipherPath" -ItemType Directory -Confirm:$false | Out-Null
    
    $chk = 0

    if((Test-Path -Path "$localDsLoc\ESXi-Upgrade-TempFiles" -ErrorAction Ignore) -and (Test-Path -Path "$localDsLoc\$cipherPath" -ErrorAction Ignore)){

    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Copying ESXi post upgrade files to the local datastore $localDs"

    Copy-DatastoreItem "$logpath\ESXi-Post-Update-Binaries\*" -Destination "$localDsLoc\ESXi-Upgrade-TempFiles" -Force -Recurse -Confirm:$false

    $esxiUpgFiles = (Get-ChildItem -Path "$logpath\ESXi-Post-Update-Binaries\*").Name
    
        foreach($esxiUpgFile in $esxiUpgFiles){

        if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-TempFiles\$esxiUpgFile" -ErrorAction Ignore){} else{$chk += 1}

        }

    } else{$chk += 1}

    Set-Location -Path $logpath

    try{Remove-PSDrive -Name esxilocalds -Confirm:$false -ErrorAction Ignore} catch{}

    if($chk -eq 0){return $true} else{return $false}

    }

    else{return $false}

    }

    else{return $false}
}

    Function ESXi-Copy-Offline-Upgrade-Files($esxiServerName, $vmhost, $localDs, $logpath, $DeviceVendor)
{

    if(Get-Datastore -Name $localDs){} else{$vmhost | Get-VMHostStorage -RescanAllHba -ErrorAction Ignore | Out-Null}

    if(Get-Datastore -Name $localDs){

    try{Remove-PSDrive -Name esxilocalds -Confirm:$false -ErrorAction Ignore} catch{}
    
    try{$ErrorActionPreference = 'Stop'; New-PSDrive -Location $localDs -Name esxilocalds -PSProvider VimDatastore -Root "\" | Out-Null} catch{}
    Set-Location esxilocalds:\ -ErrorAction Ignore
    $localDsLoc = Get-Location
    $chk = 0

    if($localDsLoc.Path -eq "esxilocalds:\"){

    if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -ErrorAction Ignore){Remove-Item -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -Recurse -Confirm:$false -ErrorAction Ignore} else{}

    New-Item -Path "$localDsLoc\" -Name "ESXi-Upgrade-OfflineBinaries" -ItemType Directory -Confirm:$false | Out-Null

    if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -ErrorAction Ignore){

    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Copying ESXi offline upgrade binaries to the local datastore $localDs"

    if($DeviceVendor -like "DELL*"){Copy-DatastoreItem "$logpath\Offline-Upgrade-Binaries\*DELL*" -Destination "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -Force -Recurse -Confirm:$false}
    elseif($DeviceVendor -like "HP*"){Copy-DatastoreItem "$logpath\Offline-Upgrade-Binaries\*HPE*" -Destination "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -Force -Recurse -Confirm:$false}
    elseif($DeviceVendor -like "Lenovo*"){Copy-DatastoreItem "$logpath\Offline-Upgrade-Binaries\*Lenovo*" -Destination "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -Force -Recurse -Confirm:$false}
    else{Copy-DatastoreItem "$logpath\Offline-Upgrade-Binaries\*" -Destination "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -Force -Recurse -Confirm:$false}

    $esxiUpgOfflineFiles = (Get-ChildItem -Path "$logpath\Offline-Upgrade-Binaries\*").Name
    
        foreach($esxiUpgOfflineFile in $esxiUpgOfflineFiles){

        if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries\$esxiUpgOfflineFile" -ErrorAction Ignore){} else{$chk += 1}

        }

    }

    else{$chk += 1}

    Set-Location -Path $logpath

    try{Remove-PSDrive -Name esxilocalds -Confirm:$false -ErrorAction Ignore} catch{}

    }

    else{$chk += 1}

    if($chk -eq 0){return $true} else{return $false}

    }

    else{return $false}

}

    Function Post-Update-Tasks($esxiServer, $logPath, $DEPCR, $upgFileCopy1)
{

Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Starting post upgrade tasks"

<#

if($esxcli){

        try{$ErrorActionPreference = 'Stop'; $curProfileChk = $esxcli.system.tls.server.get.Invoke().Profile} catch{$curProfileChk = "NotFound"}

        if($curProfileChk -eq "NotFound"){
        
        Start-Sleep -Seconds 300 
        try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}
        if($esxcli){try{$ErrorActionPreference = 'Stop'; $curProfileChk = $esxcli.system.tls.server.get.Invoke().Profile} catch{$curProfileChk = "NotFound"}} else{$curProfileChk = "NotFound"}
        
        } else{}

        if($curProfileChk -ne "NotFound"){

        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Existing TLS server profile --- $curProfileChk"

        if($curProfileChk -eq "NIST_2024"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Existing TLS server profile is as per the defined standards. No action necessary"}

        else{

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Existing TLS server profile is not as per the defined standards"
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Modifying TLS server profile to NIST_2024"

            $cypherArgs = $esxcli.system.tls.server.set.CreateArgs()
            $cypherArgs.profile = "NIST_2024"
            try{$ErrorActionPreference = 'Stop'; $esxcli.system.tls.server.set.Invoke($cypherArgs) | Out-Null} catch{}

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Rebooting the ESXi host"
            Get-VMHost -Name $esxiServer | Restart-VMHost -Confirm:$false -ErrorAction Ignore -RunAsync
                    
                [System.GC]::GetTotalMemory($true) | out-null

                $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                do{
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                Start-Sleep -Seconds 60
                if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                } until ($testConn -eq "NotOK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                $stopwatch.Stop()

                [System.GC]::GetTotalMemory($true) | out-null

                $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                do{
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                Start-Sleep -Seconds 60
                if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                } until ($testConn -eq "OK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                $stopwatch.Stop()

                [System.GC]::GetTotalMemory($true) | out-null

                do{
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to get into Maintenance Mode"
                Start-Sleep -Seconds 60
                try{$esxiState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
                } until ($esxiState -eq "Maintenance")
            
            try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}
            
            if($esxcli){

            try{$ErrorActionPreference = 'Stop'; $curProfileChk1 = $esxcli.system.tls.server.get.Invoke().Profile} catch{$curProfileChk = "NotFound"}

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - TLS server profile post update attempt --- $curProfileChk1"

            if($curProfileChk1 -eq "NIST_2024"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - TLS server profile is now as per the defined standards"}
            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - TLS server profile is not as per the defined standards. Update attempt failed. Will attempt to update again using plink"}

            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Unable to validate TLS server profile as connection failed to esxcli namespace. Will validate using plink"}

        }

        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Unable to connect to esxcli namespace. TLS server profile update failed. Will attempt to update using plink"}

}

else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Unable to connect to esxcli namespace. TLS server profile update will be attempted using plink"}

#>

Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Updating TLS profile to NIST_2024 and setting banner message"

if($upgFileCopy1 -eq $true){

    if(Test-Path -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml" -ErrorAction Ignore){

        $plinkPath = "$logPath\plink"

        $esxiUpgAccCredential = Import-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"
        $esxiUpgAccId = $esxiUpgAccCredential.UserName
        $esxiUpgAccCreds = $esxiUpgAccCredential.GetNetworkCredential().Password

        Set-Location $plinkPath

        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
        try{$ErrorActionPreference = 'SilentlyContinue'; $commRes = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password exit}} catch{}
        
        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
        try{$ErrorActionPreference = 'SilentlyContinue'; $comm3Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-set-banner.txt}} catch{}
        
        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
        try{$ErrorActionPreference = 'SilentlyContinue'; $comm5Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-tls-profile-get.txt}} catch{}

        if($comm5Res -like "*NIST_2024*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully set TLS server profile to NIST_2024"; $tlsprofile = 0}
        
        else{

        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
        try{$ErrorActionPreference = 'SilentlyContinue'; $comm4Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-tls-profile-update.txt}} catch{}

        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Wating for 5 minutes before rebooting the ESXi host post TLS server profile change"
        Start-Sleep -Seconds 300
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Rebooting the ESXi host post TLS server profile change"

        Get-VMHost -Name $esxiServer | Restart-VMHost -Confirm:$false -ErrorAction Ignore -RunAsync
                    
                [System.GC]::GetTotalMemory($true) | out-null

                $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                do{
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                Start-Sleep -Seconds 60
                if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                } until ($testConn -eq "NotOK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                $stopwatch.Stop()

                [System.GC]::GetTotalMemory($true) | out-null

                $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                do{
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                Start-Sleep -Seconds 60
                if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                } until ($testConn -eq "OK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                $stopwatch.Stop()

                [System.GC]::GetTotalMemory($true) | out-null

                do{
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to get into Maintenance Mode"
                Start-Sleep -Seconds 60
                try{$esxiState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
                } until ($esxiState -eq "Maintenance")
        
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting for 5 minutes before validating TLS server profile change"

        Start-Sleep -Seconds 300

        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
        try{$ErrorActionPreference = 'SilentlyContinue'; $commRes = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password exit}} catch{}

        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
        try{$ErrorActionPreference = 'SilentlyContinue'; $comm5Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-tls-profile-get.txt}} catch{}

        if($comm5Res -like "*NIST_2024*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully set TLS server profile to NIST_2024"; $tlsprofile = 0}

        else{

            try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}
            try{$ErrorActionPreference = 'Stop'; $curProfileChk = $esxcli.system.tls.server.get.Invoke().Profile} catch{$curProfileChk = "NotFound"}

            if($curProfileChk -like "*NIST_2024*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully set TLS server profile to NIST_2024"; $tlsprofile = 0}
            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to set TLS server profile to NIST_2024"}

        }

        Set-Location $logPath

        <#

        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
        try{$ErrorActionPreference = 'SilentlyContinue'; $comm31Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-get-banner.txt}} catch{}

        if($comm31Res){
        
        $comm31Res | Out-File "$plinkPath\bannercheck.txt"
        $a1 = Get-Content -Path "$plinkPath\master-issue.txt"
        $b1 = Get-Content -Path "$plinkPath\bannercheck.txt"

        $chkbanner = Compare-Object -ReferenceObject $a1 -DifferenceObject $b1
        if($chkbanner -eq $null){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully set banner message"; $banner = 0}
        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to set banner message"}
        
        } 
        
        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to set banner message"}

        #>

        }

    }

    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to get root credentials. Unable to complete post upgrade tasks"}

}

else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to copy post upgrade files. Unable to complete post upgrade tasks"}

if($tlsprofile -eq 0){$postUpd = 0} else{$postUpd = 1}
    
return $postUpd

}

    Function Ignore-SSLCertificates
{
    $Provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $Compiler = $Provider.CreateCompiler()
    $Params = New-Object System.CodeDom.Compiler.CompilerParameters
    $Params.GenerateExecutable = $false
    $Params.GenerateInMemory = $true
    $Params.IncludeDebugInformation = $false
    $Params.ReferencedAssemblies.Add("System.DLL") > $null
    $TASource=@'
        namespace Local.ToolkitExtensions.Net.CertificatePolicy
        {
            public class TrustAll : System.Net.ICertificatePolicy
            {
                public bool CheckValidationResult(System.Net.ServicePoint sp,System.Security.Cryptography.X509Certificates.X509Certificate cert, System.Net.WebRequest req, int problem)
                {
                    return true;
                }
            }
        }
'@ 
    $TAResults=$Provider.CompileAssemblyFromSource($Params,$TASource)
    $TAAssembly=$TAResults.CompiledAssembly
    $TrustAll = $TAAssembly.CreateInstance("Local.ToolkitExtensions.Net.CertificatePolicy.TrustAll")
    [System.Net.ServicePointManager]::CertificatePolicy = $TrustAll
}

# End of Functions #

[System.GC]::GetTotalMemory($true) | out-null

$ScriptStartTime = Get-Date

$UpdSnapshot = @()

try{$ErrorActionPreference = 'Stop'; Stop-Transcript} catch{}

if(Test-Path -Path "$logPath\ESXi-Update-Logs\$StartDate\Transcripts" -ErrorAction Ignore){}
else{New-Item -Path "$logPath\ESXi-Update-Logs\$StartDate" -ItemType Directory -Name "Transcripts" -Force -Confirm:$false}
$Date = Get-Date -Format dd-MM-yyy

Start-Transcript -Path "$logPath\ESXi-Update-Logs\$StartDate\Transcripts\$DEPCR-$esxiServer-Transcript-$Date.log"

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force|out-null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false|out-null
Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Confirm:$false|out-null
Set-PowerCLIConfiguration -WebOperationTimeoutSeconds -1 -Confirm:$false|out-null

# Update Workflow Begin #

Import-Module -Global "$logPath\Modules\Write-Log.psm1"
Import-Module -Global "$logPath\Modules\Set-DeviceFirmwareSimpleUpdateREDFISH.psm1"
Import-Module -Global "$logpath\Modules\Get-IdracFirmwareVersionREDFISH.psm1"
Import-Module -Global "$logpath\Modules\Invoke-IdracJobQueueManagementREDFISH.psm1"

$chkFwUpdate = 0
$chkesxiUpdate = 0
$chkPostUpdate = 0

$vcometable = @(

[PSCustomObject]@{Name = "v03g"; omeUser = "vpcidracadmin_cdhk@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v05g"; omeUser = "vpcidracadmin_cdcn@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v06g"; omeUser = "vpcidracadmin_cdin@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v07g"; omeUser = "vpcidracadmin_cdid@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v11g"; omeUser = "vpcidracadmin_cdtw@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v18g"; omeUser = "vpcidracadmin_cld@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v25g"; omeUser = "vpcidracadmin_cdsjv@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v18s"; omeUser = "vpcidracadmin_cldddc@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v01s"; omeUser = "vpcidracadmin_cldddc@reg1.1bank.dbs.com"}

)

$vcPre = $vCenter.Substring(0,4)
$omeUser = ($vcometable | Where-Object{$_.Name -eq $vcPre}).omeUser

if((Test-Path -Path "$logPath\Credentials\$StartDate\$vCenter-Creds.xml" -ErrorAction Ignore) -and (Test-Path -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml")){

$vcCreds = Import-Clixml -Path "$logPath\Credentials\$StartDate\$vCenter-Creds.xml"
$omeCreds = Import-Clixml -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"

#$webhookTeams = "https://dbs1bank.webhook.office.com/webhookb2/e36795b4-fdf1-4f2c-a2be-ecc8966e7e5d@278ad577-c008-4fc4-ad48-4467be94beb5/IncomingWebhook/5fa988c9a48141329c17a9b896603e77/ee34d3b9-e541-4731-893b-c412e9634bb2"

if(Connect-VIServer -Server $vCenter -Credential $vcCreds -ErrorAction Ignore){

$esxiServerName = $esxiServer.Split(".")[0]
$vmhost = Get-VMHost -Name $esxiServer
$vmhostState = $vmhost.State
$vmhostView = $vmhost  | Get-View
$localDs = $vmhost | Get-Datastore | Where-Object{$_.Name -eq "localds_$esxiServerName"}
$localDs = $localDs | Select-Object -Unique
$vmhostBuild = $vmhost.Build
$befNwAdapters = $vmhost | Get-VMHostNetworkAdapter
$befStorageAdapters = $vmhost | Get-VMHostHba
$cluster = $vmhost.Parent.Name

$omeDevice = $esxiServer.Split(".")[0] -ireplace "^v", "i"

try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}
try{$ErrorActionPreference = 'Stop'; $DeviceVendor =  $esxcli.hardware.platform.get.Invoke().VendorName} catch{}

Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Begin firmware and ESXi version upgrade"

Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Checking whether there are any VMs with DRS overrides"

$checkVmOverrides = Check-VM-Override-Manual-DRS -vmhost $vmhost

Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$cluster - Checking DRS Automation Level of the cluster"

$checkDrsAutomationLevel = (Get-Cluster -Name $cluster).DrsAutomationLevel

if($vmhostState -eq "Maintenance"){$proceed = "OK"}

else{
    
    if($checkVmOverrides -eq $false -and $checkDrsAutomationLevel -eq "FullyAutomated"){
    
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - There are no VMs with DRS overrides"
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$cluster - DRS Automation Level for cluster is $checkDrsAutomationLevel"
        $proceed = "OK"

    }

    else{$proceed = "Not OK"}
}

if($proceed -eq "OK"){

    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Proceeding with the upgrade. Placing in Maintenance Mode"

    try{$esxiServerState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}

    if($esxiServerState -eq "Maintenance"){} 
    else{ESXi-Enter-Maintenance-Mode -vmhost $vmhost -esxiServer $esxiServer -logPath $logPath -DEPCR $DEPCR}

    try{$esxiServerState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}

    if($esxiServerState -eq "Maintenance"){

        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Server in Maintenance Mode. Disabling alarms"
        Change-ESXi-Alarm -vmhost $vmhost -enable $false

        if($vmhostView.ConfigIssue.Fullformattedmessage -notcontains "*host configuration changes will not be saved to persistent storage*"){
    
            $upgFileCopy = ESXi-Copy-Offline-Upgrade-Files -esxiServerName $esxiServer -vmhost $vmhost -localDs $localDs -logpath $logPath
            $upgFileCopy1 = ESXi-Copy-Post-Update-Files -esxiServerName $esxiServer -vmhost $vmhost -localDs $localDs -logpath $logPath

        if($upgFileCopy -eq "$true" -and $upgFileCopy1 -eq "$true"){

        # Skipping reboot prior to upgrade #

            <#

            if($opt -eq "3"){}

            else{

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Initiating reboot prior to upgrade"

            Get-VMHost -Name $esxiServer | Restart-VMHost -Confirm:$false -ErrorAction Ignore -RunAsync
            
            [System.GC]::GetTotalMemory($true) | out-null

            $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

            do{
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
            Start-Sleep -Seconds 60
            if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
            } until ($testConn -eq "NotOK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

            $stopwatch.Stop()

            [System.GC]::GetTotalMemory($true) | out-null

            $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

            do{
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
            Start-Sleep -Seconds 60
            if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
            } until ($testConn -eq "OK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

            $stopwatch.Stop()

            [System.GC]::GetTotalMemory($true) | out-null

            do{
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to get into Maintenance Mode"
            Start-Sleep -Seconds 60
            try{$esxiState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
            } until ($esxiState -eq "Maintenance")

            }

            #>
        
        # End #

        try{$esxiServerState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
        
        # Option 1 or 4 #

        if($esxiServerState -eq "Maintenance"){
            
        if($opt -eq "1" -or $opt -eq "4"){

            # Install Broadcom firmare #

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Looking for the presence of Broadcom network adapters requiring a firmware upgrade"

            try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}

            if($esxcli){

            $createArgs = $esxcli.network.nic.get.CreateArgs()
            $createArgs.nicname = "vmnic6"
            $nicDr = $esxcli.network.nic.get.Invoke($createArgs).DriverInfo.Driver

            if($nicDr -notlike "bnx*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - No Broadcom network adapters found"; $brnetChk = 0; $brFw = "0"}
            else{$brnetChk = 1}
            
            }

            else{$brnetChk = 1}

            if($brnetChk -eq 1){

            if($upgFileCopy1 -eq $true){
                                
                if(Test-Path -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml" -ErrorAction Ignore){

                    # plink code to execute the shell scripts #

                    try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}

                    if($esxcli){

                    $createArgs = $esxcli.network.nic.get.CreateArgs()
                    $createArgs.nicname = "vmnic6"
                    $nicDr = $esxcli.network.nic.get.Invoke($createArgs).DriverInfo.Driver
                    $nicFwVer = $esxcli.network.nic.get.Invoke($createArgs).DriverInfo.FirmwareVersion.Split("/")[1]

                        if($nicDr -notlike "bnx*"){}

                        else{

                        if($nicDr -like "bnx*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom network adapters found. Validating firmware version"} else{}
                        if($nicfwVer -like "*229.1.123.0*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware version is $nicFwVer. Already up to date"; $brFw = "0"}
                        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware current version is $nicFwVer. Needs update"; $nicUpd = 1}
                    
                        }
                    
                    }

                    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Warning -DEPCR $DEPCR -Message "$esxiServer - Unable to determine the presence of Broadcom network devices using esxcli. Will proceed with using niccli utility to check for Broadcom network adapters and update firmware, if required"; $nicUpd = 1}

                    if($nicUpd -eq 1){

                    $plinkPath = "$logPath\plink"

                    $esxiUpgAccCredential = Import-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"
                    $esxiUpgAccId = $esxiUpgAccCredential.UserName
                    $esxiUpgAccCreds = $esxiUpgAccCredential.GetNetworkCredential().Password

                    Set-Location $plinkPath

                    Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                    try{$ErrorActionPreference = 'SilentlyContinue'; $commRes = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password exit}} catch{}
                    
                    Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                    try{$ErrorActionPreference = 'SilentlyContinue'; $comm7Res = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-niccli-checkbroadcompcicards.txt}} catch{}
                    
                    if($comm7Res -like "*Unable to discover any supported device*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - No supported devices found for Broadcom NetXtreme-C/E/S firmware";$nicFwReb = 0;$brFw = "0"}

                    else{

                    Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                    try{$ErrorActionPreference = 'SilentlyContinue'; $comm8Res = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-niccli-installbroadcomfirmware.txt}} catch{}

                    if($comm8Res-like "*FW package update SUCCESS*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware update completed using niccli utility. Will validate the version post reboot"; $nicFwReb = 1}

                    else{

                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware update failed using niccli utility. Attempting to install using bnxtnet utility"

                        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                        try{$ErrorActionPreference = 'SilentlyContinue'; $comm6Res = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-checkbroadcompcicards.txt}} catch{}

                        if($comm6Res -like "*not found*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - No supported devices found for Broadcom NetXtreme-C/E/S firmware"; $nicFwReb = 0; $brFw = "0"}
                        
                        else{

                        Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                        try{$ErrorActionPreference = 'SilentlyContinue'; $comm0Res = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-installbroadcomfirmware.txt}} catch{}

                        if($comm0Res -like "*Firmware update is completed*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware update completed using bnxtnet. Will validate the version post reboot"; $nicFwReb = 1}

                        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware update failed using bnxtnet utility"}

                        }

                    }

                    if($nicFwReb -eq 1){
                    
                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Initiating reboot"

                        Get-VMHost -Name $esxiServer | Restart-VMHost -Confirm:$false -ErrorAction Ignore -RunAsync
            
                        [System.GC]::GetTotalMemory($true) | out-null

                        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                        do{
                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                        Start-Sleep -Seconds 60
                        if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                        } until ($testConn -eq "NotOK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                        $stopwatch.Stop()

                        [System.GC]::GetTotalMemory($true) | out-null

                        $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                        do{
                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                        Start-Sleep -Seconds 60
                        if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                        } until ($testConn -eq "OK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                        $stopwatch.Stop()

                        [System.GC]::GetTotalMemory($true) | out-null

                        do{
                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to get into Maintenance Mode"
                        Start-Sleep -Seconds 60
                        try{$esxiState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
                        } until ($esxiState -eq "Maintenance")
                    
                    }

                    else{}

                    if($nicFwReb -eq 0){}

                    else{

                    if($esxcli){

                    $createArgs = $esxcli.network.nic.get.CreateArgs()
                    $createArgs.nicname = "vmnic6"
                    $nicFwVer = $esxcli.network.nic.get.Invoke($createArgs).DriverInfo.FirmwareVersion.Split("/")[1]

                    if($nicfwVer -like "*229.1.123.0*"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware update completed successfully to $nicFwVer"; $brfw = "0"}
                    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Broadcom NetXtreme-C/E/S firmware version post update attempt is $nicFwVer. Update attempt was unsuccessful. Please validate manually"}

                    }

                    else{}

                    }

                    }
                    
                    }

                    else{}
                    
                    }

                else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to find the encrypted xml file with root credentials. Cannot proceed with Broadcom NetXtreme-C/E/S firmware update"}

            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to copy Broadcom NetXtreme-C/E/S firmware to local datastore $localDsName. Cannot proceed with Broadcom NetXtreme-C/E/S firmware update"}

            } 

            else{$brFw = "0"}

            Set-Location $logPath
            
            # End #

        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Initiating firmware upgrade"

        $randomWait = Get-Random -Minimum 30 -Maximum 60
        
        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Waiting for $randomWait seconds before initiating firmware upgrade"
                        
        Start-Sleep -Seconds $randomWait

        if($DeviceVendor -like "*DELL*"){
			
		$fwUpdate = ESXi-Firmware-Update-iDrac -omeDevice $omeDevice -omeCreds $omeCreds -esxiServer $esxiServer -logPath $logPath -DEPCR $DEPCR
        if($fwUpdate -eq $true){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully completed firmware upgrade. Proceeding with ESXi version upgrade"}
        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Firmware upgrade failed. Please validate and take necessary action. Proceeding with ESXi upgrade"; $chkFwUpdate += 1}
		
		}
		
		else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Not a DELL server. Upgrade firmware manually. Proceeding with ESXi version upgrade";$chkFwUpdate5 = 0}
		
        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Skipping firmware upgrade"}

        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Not in Maintenance Mode. Cannot proceed with Firmware upgrade"; $chkFwUpdate += 1}

        # End #

        # Option 2 or 4 #

        try{$esxiServerState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}

        if($esxiServerState -eq "Maintenance"){
            
            if($opt -eq "2" -or $opt -eq "4"){

            $vmhostBefVersion = $vmhost.Version
            $vmhostBefBuild = $vmhost.Build
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Version details before initiating upgrade - Version: $vmhostBefVersion | Build: $vmhostBefBuild"

            if($vmhostBefVersion -like "8*" -and $vmhostBefBuild -like "*24022510*"){

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - ESXi version is already up to date"

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting for 5 minutes before initiating post upgrade tasks"
            Start-Sleep -Seconds 300

            $PostUpdate = Post-Update-Tasks -esxiServer $esxiServer -logPath $logPath -DEPCR $DEPCR -upgFileCopy1 $upgFileCopy1
                
                $plinkPath = "$logPath\plink"

                $esxiUpgAccCredential = Import-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"
                $esxiUpgAccId = $esxiUpgAccCredential.UserName
                $esxiUpgAccCreds = $esxiUpgAccCredential.GetNetworkCredential().Password

                Set-Location $plinkPath

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $commRes = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password exit}} catch{}
                
                <#

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $comm10Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-get-banner.txt}} catch{}
        
                if($comm10Res -like "*DBS BANK SINGAPORE*" -and $comm10Res -like "*This system is for the use of authorized users only*"){$banner = 0} else{$banner = 1}

                #>

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $comm11Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-tls-profile-get.txt}} catch{}
        
                if($comm11Res -like "*NIST_2024*"){$tlsprofile = 0} else{$tlsprofile = 1}

                Set-Location $logPath

            }

            else{

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Copying offline upgrade binaries to local datastore"

            if($upgFileCopy -eq "$true"){

            $localDsName = $localDs.Name

            try{$ErrorActionPreference = 'Stop'; $esxcli = Get-EsxCli -VMHost $esxiServer -V2} catch{}

            if($esxcli){
            
            try{$ErrorActionPreference = 'Stop'; $DeviceVendor =  $esxcli.hardware.platform.get.Invoke().VendorName} catch{}
            
            $argsInstall = $esxcli.software.profile.update.createargs()
            
            if($DeviceVendor -like "Dell*"){
                
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Offline upgrade bundle selected for ESXi upgrade - VMware-VMvisor-Installer-8.0.0.update03-24022510.x86_64-Dell_Customized-A00.zip"
                $argsInstall.depot = "/vmfs/volumes/$localDsName/ESXi-Upgrade-OfflineBinaries/VMware-VMvisor-Installer-8.0.0.update03-24022510.x86_64-Dell_Customized-A00.zip"
                $argsInstall.profile = "DEL-ESXi_803.24022510-A00"
                $argsInstall.force = $true
                $argsInstall.nohardwarewarning = $true
            }

            elseif($DeviceVendor -eq "Lenovo" -or $DeviceVendor -like "Lenovo*"){
                
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Offline upgrade bundle selected for ESXi upgrade - Lenovo-VMware-ESXi-8.0.3-24022510-LNV-S01-20240620.zip"
                $argsInstall.depot = "/vmfs/volumes/$localDsName/ESXi-Upgrade-OfflineBinaries/Lenovo-VMware-ESXi-8.0.3-24022510-LNV-S01-20240620.zip"
                $argsInstall.profile = "LVO_8.0.3-LVO.803.12.1"
                $argsInstall.force = $true
                $argsInstall.nohardwarewarning = $true
            }

            elseif($DeviceVendor -eq "HP" -or $DeviceVendor -like "HP*"){

                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Offline upgrade bundle selected for ESXi upgrade - VMware-ESXi-8.0.3-24022510-HPE-803.0.0.11.7.0.23-Jun2024-depot.zip"
                $argsInstall.depot = "/vmfs/volumes/$localDsName/ESXi-Upgrade-OfflineBinaries/VMware-ESXi-8.0.3-24022510-HPE-803.0.0.11.7.0.23-Jun2024-depot.zip"
                $argsInstall.profile = "HPE-Custom-AddOn_803.0.0.11.7.0-23"
                $argsInstall.force = $true
                $argsInstall.nohardwarewarning = $true

            }

            else{$swProfileUpd = 1}
            
            if($swProfileUpd -eq 1){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Could not find appropriate ESXi offline upgrade binaries for hardware by $DeviceVendor. Skipping ESXi profile update"}

            else{

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Initiating ESXi profile update"

            try{$ErrorActionPreference = 'SilentlyContinue'; $commPrUpdRes = $esxcli.software.profile.update.invoke($argsInstall)} catch{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Could not execute the ESXi profile update"}
            
            try{$ErrorActionPreference = 'Stop'; $prUpdMsg = $commPrUpdRes.Message} catch{$PrUpdMsg = "Could not get the result of profile upgrade"}
            try{$ErrorActionPreference = 'Stop'; $prUpdReboot = $commPrUpdRes.RebootRequired} catch{$prUpdReboot = "Could not get the result of profile upgrade"}
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Result of profile update - $PrUpdMsg | Reboot Required - $prUpdReboot"
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Rebooting ESXi host"
            Get-VMHost -Name $esxiServer | Restart-VMHost -Confirm:$false -ErrorAction Ignore -RunAsync
                    
                    [System.GC]::GetTotalMemory($true) | out-null

                    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                    Start-Sleep -Seconds 60
                    if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                    } until ($testConn -eq "NotOK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                    $stopwatch.Stop()

                    [System.GC]::GetTotalMemory($true) | out-null

                    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to restart"
                    Start-Sleep -Seconds 60
                    if(Test-Connection -ComputerName $esxiServer -Count 2 -ErrorAction Ignore){$testConn = "OK"} else{$testConn = "NotOK"}
                    } until ($testConn -eq "OK" -or $stopwatch.Elapsed.TotalMinutes -gt 15)

                    $stopwatch.Stop()

                    [System.GC]::GetTotalMemory($true) | out-null

                    do{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting to get into Maintenance Mode"
                    Start-Sleep -Seconds 60
                    try{$esxiState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
                    } until ($esxiState -eq "Maintenance")

            }

            $vmhost = Get-VMHost -Name $esxiServer
            $vmhostAftVersion = $vmhost.Version
            $vmhostAftBuild = $vmhost.Build

            Set-Location $logPath

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Post upgrade version details - Version: $vmhostAftVersion | Build: $vmhostAftBuild"

            if($vmhostAftVersion -like "8*" -and $vmhostAftBuild -like "*24022510*"){
            
                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - ESXi version upgrade to ESXi $vmhostAftVersion - $vmhostAftBuild is successful"
                
                if($licenseKey -ne "NA"){
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Attempting to assign a valid license key....."
                    try{$ErrorActionPreference = 'Stop'; Get-VMHost -Name $esxiServer | Set-VMHost -LicenseKey $licenseKey -Confirm:$false | Out-Null; $licAssign = "$esxiServer - License Assignment | Successfully assigned a valid license key"} 
                    catch{$licAssign = "$esxiServer - License Assignment | ERROR: Failed to assign a license key to the host. Please assign license manually"}
                }

                else{$licAssign = "$esxiServer - License Assignment | ERROR: No license keys available for assignment. Please assign license manually"}

                Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Waiting for 5 minutes before initiating post upgrade tasks"
                Start-Sleep -Seconds 300
                $PostUpdate = Post-Update-Tasks -esxiServer $esxiServer -logPath $logPath -DEPCR $DEPCR -upgFileCopy1 $upgFileCopy1
                
                $plinkPath = "$logPath\plink"

                $esxiUpgAccCredential = Import-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"
                $esxiUpgAccId = $esxiUpgAccCredential.UserName
                $esxiUpgAccCreds = $esxiUpgAccCredential.GetNetworkCredential().Password

                Set-Location $plinkPath

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $commRes = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password exit}} catch{}
        
                <#
                
                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $comm31Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-get-banner.txt}} catch{}

                if($comm31Res){
        
                $comm31Res | Out-File "$plinkPath\bannercheck.txt"
                $a1 = Get-Content -Path "$plinkPath\master-issue.txt"
                $b1 = Get-Content -Path "$plinkPath\bannercheck.txt"

                $chkbanner = Compare-Object -ReferenceObject $a1 -DifferenceObject $b1
                if($chkbanner -eq $null){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully set banner message"; $banner = 0}
                else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to set banner message"}
        
                }
                
                #> 

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $comm11Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-tls-profile-get.txt}} catch{}
        
                if($comm11Res -like "*NIST_2024*"){$tlsprofile = 0} else{$tlsprofile = 1}

                Set-Location $logPath

                # Check fdm agent and reinstall, if not the correct version #

                $esxcli = Get-EsxCli -VMHost $esxiServer -V2

                if($esxcli){

                    $fdmDet = $esxcli.software.vib.list.Invoke() | Where-Object{$_.Name -like "*fdm*"}
                    $fdmVersion = $fdmDet.Version

                    if($fdmVersion -eq "8.0.3-24022515"){}

                    else{
                        
                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Removing VMware HA agent as the version installed is $fdmVersion which does not match the required version of 8.0.3-24022515"
                        $fdmRem = $esxcli.software.vib.remove.CreateArgs()
                        $fdmRem.vibname = "vmware-fdm"
                        $fdmRem.force = $true
                        $esxcli.software.vib.remove.Invoke($fdmRem) | Out-Null

                        Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Waiting for 60 seconds before reinstalling VMware HA agent version 8.0.3-24022515"
                        Start-Sleep -Seconds 60

                        $fdmIns = $esxcli.software.vib.install.CreateArgs()
                        $fdmIns.viburl = "/vmfs/volumes/$localDs/ESXi-Upgrade-TempFiles/VMware_bootbank_vmware-fdm_8.0.3-24022515.vib"
                        $fdmIns.force = $true
                        $esxcli.software.vib.install.Invoke($fdmIns) | Out-Null

                        $fdmDet = $esxcli.software.vib.list.Invoke() | Where-Object{$_.Name -like "*fdm*"}
                        $fdmVersion = $fdmDet.Version

                        if($fdmVersion -eq "8.0.3-24022515"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully installed VMware HA agent version 8.0.3-24022515"}
                        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to install VMware HA agent version 8.0.3-24022515. Please install manually"}
                    
                    }

                }

                else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to install VMware HA agent version 8.0.3-24022515. Please install manually"}

                # End #

            } 
            
            else{$chkesxiUpdate += 1; $chkPostUpdate += 1}

            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to connect to esxcli namespace. Cannot proceed with ESXi upgrade"; $chkesxiUpdate += 1; $chkPostUpdate += 1}

            try{Remove-PSDrive -Name esxilocalds -Confirm:$false -ErrorAction Ignore} catch{}
    
            try{$ErrorActionPreference = 'Stop'; New-PSDrive -Location $localDs -Name esxilocalds -PSProvider VimDatastore -Root "\" | Out-Null} catch{}
            Set-Location esxilocalds:\ -ErrorAction Ignore
            $localDsLoc = Get-Location
            $chk = 0

            if($localDsLoc.Path -eq "esxilocalds:\"){

            if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -ErrorAction Ignore){Remove-Item -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -Recurse -Confirm:$false -ErrorAction Ignore} else{}
            if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-TempFiles" -ErrorAction Ignore){Remove-Item -Path "$localDsLoc\ESXi-Upgrade-TempFiles" -Recurse -Confirm:$false -ErrorAction Ignore} else{}

            } else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Please manually delete the offline upgrade binaries from ESXi-Upgrade-OfflineBinaries directory and post update files from ESXi-Upgrade-TempFiles directory on the localdatastore"}

            Set-Location $logPath

            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to copy offline upgrade binaries to local datastore"; $chkesxiUpdate += 1}

            }

            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Skipping ESXi version upgrade"}

        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Not in Maintenance Mode. Cannot proceed with ESXi upgrade"; $chkesxiUpdate += 1; $chkPostUpdate += 1}

        # End #

        # Option 3 #

        try{$esxiServerState = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).ConnectionState} catch{}
        
        if($esxiServerState -eq "Maintenance"){
        
            if($opt -eq "3"){
             
                $PostUpdate = Post-Update-Tasks -esxiServer $esxiServer -logPath $logPath -DEPCR $DEPCR -upgFileCopy1 $upgFileCopy1
            
                $plinkPath = "$logPath\plink"

                $esxiUpgAccCredential = Import-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"
                $esxiUpgAccId = $esxiUpgAccCredential.UserName
                $esxiUpgAccCreds = $esxiUpgAccCredential.GetNetworkCredential().Password

                Set-Location $plinkPath

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $commRes = Invoke-Command -ScriptBlock {echo y | .\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password exit}} catch{}
                
                <#

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $comm31Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-get-banner.txt}} catch{}

                if($comm31Res){
        
                $comm31Res | Out-File "$plinkPath\bannercheck.txt"
                $a1 = Get-Content -Path "$plinkPath\master-issue.txt"
                $b1 = Get-Content -Path "$plinkPath\bannercheck.txt"

                $chkbanner = Compare-Object -ReferenceObject $a1 -DifferenceObject $b1
                if($chkbanner -eq $null){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Successfully set banner message"; $banner = 0}
                else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to set banner message"}
        
                } 

                #>

                Get-VMHost -Name $esxiServer | Get-VMHostService | Where-Object{$_.Label -eq "SSH"} | Start-VMHostService -Confirm:$false | Out-Null
                try{$ErrorActionPreference = 'SilentlyContinue'; $comm11Res = Invoke-Command -ScriptBlock {.\plink.exe -ssh $esxiUpgAccId@$esxiServer -pw $esxiUpgAccCredential.GetNetworkCredential().Password -noagent -batch -m esxishell-tls-profile-get.txt}} catch{}
        
                if($comm11Res -like "*NIST_2024*"){$tlsprofile = 0} else{$tlsprofile = 1}

                Set-Location $logPath

            }
            
            else{}

        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Not in Maintenance Mode. Cannot proceed with post upgrade tasks"; $chkPostUpdate += 1}

        # End #

        if($opt -eq "1"){$tlsprofile = 0} else{}

        $aftNwAdapters = $vmhost | Get-VMHostNetworkAdapter
        $aftStorageAdapters = $vmhost | Get-VMHostHba

        $hcNwAdap = Check-Network-Adapters -before $befNwAdapters -after $aftNwAdapters
        $hcStAdap = Check-HBA-Aapters -before $befStorageAdapters -after $aftStorageAdapters

        <#

        if($chkesxiUpdate -eq 0 -and $chkFwUpdate -eq 0 -and $chkPostUpdate -eq 0 -and $banner -eq 0 -and $tlsprofile -eq 0){
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Firmware upgrade, ESXi Version-Patch upgrade and post upgrade tasks successfully completed"

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Performing health checks"

            Start-Sleep -Seconds 60

            $aftNwAdapters = $vmhost | Get-VMHostNetworkAdapter
            $aftStorageAdapters = $vmhost | Get-VMHostHba

            $hcNwAdap = Check-Network-Adapters -before $befNwAdapters -after $aftNwAdapters
            $hcStAdap = Check-HBA-Aapters -before $befStorageAdapters -after $aftStorageAdapters

            if($hcNwAdap -eq $true -and $hcStAdap -eq $true){
    
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Network and storage health checks successful"
                    if($vmhostState -eq "Maintenance"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Not placing out of Maintenance Mode as the host was in Maintenance Mode prior to upgrade"}
                    else{
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Placing out of Maintenance Mode"
                    ESXi-Exit-Maintenance-Mode -vmhost $vmhost -esxiServer $esxiServer -logPath $logPath -DEPCR $DEPCR
                    Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Enabling alarm actions"
                    Change-ESXi-Alarm -vmhost $vmhost -enable $true
                    }
            }

            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Network and storage health checks post upgrade have failed. Please validate and take necessary action. Server left in Maintenance Mode"}

        }
            
        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - One or more of the upgrade tasks failed. Please refer to logs for more details. Server left in Maintenance Mode for taking necessary action to fix the failed tasks"}
        
        #>

            if($chkFwUpdate5 -eq 0){$FwRemarks = "Not a DELL server. Please upgrade firmware manually, if required"}
            elseif($chkFwUpdate -eq 0 -and ($opt -eq "1" -or $opt -eq "4")){$FwRemarks = "Firmware upgrade successful"} 
            elseif($opt -eq "2" -or $opt -eq "3"){$FwRemarks = "Firmware upgrade skipped"}
            else{$FwRemarks = "ERROR: Firmware upgrade failed. Refer to logs for more details"}
    
            if($chkesxiUpdate -eq 0 -and ($opt -eq "2" -or $opt -eq "4")){$EsxiUpdRemarks = "ESXi upgrade successful"}
            elseif($opt -eq "1" -or $opt -eq "3"){$EsxiUpdRemarks = "ESXi upgrade skipped"}
            else{$EsxiUpdRemarks = "ERROR: ESXi upgrade failed. Refer to logs for more details"}

            if($tlsprofile -eq 0 -and ($opt -eq "3" -or $opt -eq "4")){$EsxiPostUpdRemarks = "ESXi post upgrade tasks successful"}
            elseif($opt -eq "1" -or $opt -eq "2"){$EsxiPostUpdRemarks = "ESXi post upgrade tasks skipped"}
            else{$EsxiPostUpdRemarks = "ERROR: ESXi post upgrade tasks failed. Refer to logs for more details"}

            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "****************************************************************************************************************************************"
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Snapshot of the upgrade tasks is given below" 
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "****************************************************************************************************************************************"
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "----------------------------------------------------------------------------------------------------------------------------------------"
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "----------------------------------------------------------------------------------------------------------------------------------------"

            if($brfw -eq "0"){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom Firmware Upgrade | Successfully upgraded Broadcom Firmware"}
            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Broadcom Firmware Upgrade | ERROR: Failed to upgrade Broadcom Firmware. Please remediate manually"}
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Firmware Upgrade | $FwRemarks"

            if(Test-Path -Path "$logPath\ESXi-Update-Logs\$esxiServer-Failed-Firmware-List.txt"){
            
                $failedFwComp = Get-Content -Path "$logPath\ESXi-Update-Logs\$esxiServer-Failed-Firmware-List.txt"
                
                foreach($failedComp in $failedFwComp){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message " -- Firmware upgrade failed for component - $failedComp"}

                Remove-Item -Path "$logPath\ESXi-Update-Logs\$esxiServer-Failed-Firmware-List.txt" -Confirm:$false -ErrorAction Ignore
            }

            else{}
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - ESXi Version Upgrade | $EsxiUpdRemarks"
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$licAssign"
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Post Upgrade Tasks | $EsxiPostUpdRemarks"
            
            if($hcNwAdap -eq $true){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Network LV post upgrade | Success"} 
            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Network LV post upgrade | ERROR: Network LV not successful"}
            
            if($hcStAdap -eq $true){Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Storage LV post upgrade | Success"}
            else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Storage LV post upgrade | ERROR: Storage LV not successful"}
            
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "----------------------------------------------------------------------------------------------------------------------------------------"
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "----------------------------------------------------------------------------------------------------------------------------------------"
            Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "$esxiServer - Server left in Maintenance Mode to fix any issues/failures during the upgrade and also to apply host profile manually."

            try{Remove-PSDrive -Name esxilocalds -Confirm:$false -ErrorAction Ignore} catch{}
    
            try{$ErrorActionPreference = 'Stop'; New-PSDrive -Location $localDs -Name esxilocalds -PSProvider VimDatastore -Root "\" | Out-Null} catch{}
            Set-Location esxilocalds:\ -ErrorAction Ignore
            $localDsLoc = Get-Location
            $chk = 0

            if($localDsLoc.Path -eq "esxilocalds:\"){

            if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -ErrorAction Ignore){Remove-Item -Path "$localDsLoc\ESXi-Upgrade-OfflineBinaries" -Recurse -Confirm:$false -ErrorAction Ignore} else{}
            if(Test-Path -Path "$localDsLoc\ESXi-Upgrade-TempFiles" -ErrorAction Ignore){Remove-Item -Path "$localDsLoc\ESXi-Upgrade-TempFiles" -Recurse -Confirm:$false -ErrorAction Ignore} else{}

            } else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Please manually delete the offline upgrade binaries from ESXi-Upgrade-OfflineBinaries directory and post update files from ESXi-Upgrade-TempFiles directory on the localdatastore"}

            Set-Location $logPath

        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Failed to copy offline upgrade and post update binaries and scripts. Cannot proceed with the upgrade task"; $chkFwUpdate += 1; $chkesxiUpdate += 1; $chkPostUpdate += 1}

        }

        else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Lost connectivity to the device backing the boot file sysem. As a result, host configuration changes will not be saved to persistent storage. Cannot proceed with the upgrade. Please fix the issue and re-run the script. Host is in Maintenance Mode"; $chkFwUpdate += 1; $chkesxiUpdate += 1; $chkPostUpdate += 1}
    
    }

    else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - Could not be placed in Maintenance Mode. Please check and re-initiate the upgrade once the host is placed in Maintenance Mode"; $chkFwUpdate += 1; $chkesxiUpdate += 1; $chkPostUpdate += 1}

}

else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$esxiServer - There are VMs with DRS overrides on $esxiServer or DRS Automation Level for cluster is $checkDrsAutomationLevel. Please fix the issues and re-initiate the upgrade"; $chkFwUpdate += 1; $chkesxiUpdate += 1; $chkPostUpdate += 1}

}

else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "$vCenter - Failed to connect to vCenter Server . Please check the credentials/connectivity to the vCenter Server"; $chkFwUpdate += 1; $chkesxiUpdate += 1; $chkPostUpdate += 1}

}

else{Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Error -DEPCR $DEPCR -Message "Count not find the XML files holding the vCenter Server and OME credentials in $logPath. Please validate"; $chkFwUpdate += 1; $chkesxiUpdate += 1; $chkPostUpdate += 1}

$ScriptEndTime = Get-Date

$TotalTimeInMin = [Math]::Round(($ScriptEndTime - $ScriptStartTime).TotalMinutes,2)

Write-Log -esxiServer $esxiServer -LogPath $logPath -StartDate $StartDate -Severity Information -DEPCR $DEPCR -Message "Total time taken for script execution - $TotalTimeInMin minutes"

try{$ErrorActionPreference = 'Stop'; Stop-Transcript} catch{}

    if($chkFwUpdate5 -eq 0){$FwRemarks = "Not a DELL server. Please upgrade firmware manually, if required"}
    elseif($chkFwUpdate -eq 0 -and ($opt -eq "1" -or $opt -eq "4")){$FwRemarks = "Firmware upgrade successful"} 
    elseif($opt -eq "2" -or $opt -eq "3"){$FwRemarks = "Firmware upgrade skipped"}
    else{$FwRemarks = "ERROR: Firmware upgrade failed. Refer to logs for more details"}
    
    if($chkesxiUpdate -eq 0 -and ($opt -eq "2" -or $opt -eq "4")){$EsxiUpdRemarks = "ESXi upgrade successful"}
    elseif($opt -eq "1" -or $opt -eq "3"){$EsxiUpdRemarks = "ESXi upgrade skipped"}
    else{$EsxiUpdRemarks = "ERROR: ESXi upgrade failed. Refer to logs for more details"}

    if($chkPostUpdate -eq 0 -and ($opt -eq "3" -or $opt -eq "4")){$EsxiPostUpdRemarks = "ESXi post upgrade tasks successful"}
    elseif($opt -eq "1" -or $opt -eq "2"){$EsxiPostUpdRemarks = "ESXi post upgrade tasks skipped"}
    else{$EsxiPostUpdRemarks = "ERROR: ESXi post upgrade tasks failed. Refer to logs for more details"}

    $MyObj = New-Object psobject -Property @{

    ESXiHostName = $esxiServer
    FirmwareUpdate = $FwRemarks
    ESXiUpdate = $EsxiUpdRemarks
    ESXiPostUpdate = $EsxiPostUpdRemarks
    TimeTakenForUpgradeInMinutes = $TotalTimeInMin

    }

    $UpdSnapshot += $MyObj

    if(Test-Path -Path "$logPath\ESXi-Update-Logs\$StartDate\Script-Run-Results-$StartDate" -ErrorAction Ignore){$UpdSnapshot | Select ESXiHostName, FirmwareUpdate, ESXiUpdate, ESXiPostUpdate, TimeTakenForUpgradeInMinutes | Export-Csv -Path "$logPath\ESXi-Update-Logs\$StartDate\Script-Run-Results-$StartDate\ESXiUpdate-results-for-script-run-at-$StartDate" -NoClobber -NoTypeInformation -Append -ErrorAction Ignore} else{}

}

# End #

# Ignore SSL certificates

    Function Ignore-SSLCertificates
{
    $Provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $Compiler = $Provider.CreateCompiler()
    $Params = New-Object System.CodeDom.Compiler.CompilerParameters
    $Params.GenerateExecutable = $false
    $Params.GenerateInMemory = $true
    $Params.IncludeDebugInformation = $false
    $Params.ReferencedAssemblies.Add("System.DLL") > $null
    $TASource=@'
        namespace Local.ToolkitExtensions.Net.CertificatePolicy
        {
            public class TrustAll : System.Net.ICertificatePolicy
            {
                public bool CheckValidationResult(System.Net.ServicePoint sp,System.Security.Cryptography.X509Certificates.X509Certificate cert, System.Net.WebRequest req, int problem)
                {
                    return true;
                }
            }
        }
'@ 
    $TAResults=$Provider.CompileAssemblyFromSource($Params,$TASource)
    $TAAssembly=$TAResults.CompiledAssembly
    $TrustAll = $TAAssembly.CreateInstance("Local.ToolkitExtensions.Net.CertificatePolicy.TrustAll")
    [System.Net.ServicePointManager]::CertificatePolicy = $TrustAll
}

# End #

# Show message box #

    Function Show-MsgBox ($Text,$Title="",[Windows.Forms.MessageBoxButtons]$Button = "OK",[Windows.Forms.MessageBoxIcon]$Icon="Information")
{
[Windows.Forms.MessageBox]::Show("$Text", "$Title", [Windows.Forms.MessageBoxButtons]::$Button, $Icon) | ?{(!($_ -eq "OK"))}
}

# End #

[System.GC]::GetTotalMemory($true) | out-null

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force|out-null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false|out-null
Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Confirm:$false|out-null

cls

#Get-Job | Where-Object{$_.State -notlike "Running"} | Stop-Job | Remove-Job

$Date1 = Get-Date
$userName = $env:USERNAME
$userDomain = $env:USERDNSDOMAIN
$hostName = hostname

Write-Host "########################################################################"
Write-Host "#                                                                      #"
Write-Host "#           ###################################################        #"
Write-Host "#           #                                                 #        #"
Write-Host "#           ###########   DBS BANK SINGAPORE     ##############        #"
Write-Host "#           #                                                 #        #"
Write-Host "#           ###################################################        #"
Write-Host "#                                                                      #"
Write-Host "#      This script is for the use of DBS VPCOPS team only.             #"
Write-Host "#      Individuals using this script are expected to be fully aware of #"
Write-Host "#      the DELL firmware upgrade procedures, ESXi version-patch        #" 
Write-Host "#      upgrade procedures and ESXi hardening procedures & guidelines.  #"
Write-Host "#                                                                      #"
Write-Host "#      NOTE: Under no circumstance shall this script be executed       #"
Write-Host "#      without a valid DEP (in UAT ENV) or Change Record (in PROD ENV).#"
Write-Host "#      Any unauthorized change to the VPC environment will lead to a   #"
Write-Host "#      disciplinary action being taken on the individual performing    #"
Write-Host "#      the change.                                                     #"
Write-Host "########################################################################"

Write-Host "`n`n-------------------------------------------------------------------------------------------------------------------------------------------`n"
Write-Host " Script Version        : 1.0"
Write-Host " Date                  : $Date1"
Write-Host " User                  : $userDomain\$userName"
Write-Host " Windows Host Name     : $hostName"
Write-Host "`n`n-------------------------------------------------------------------------------------------------------------------------------------------`n"


Write-Host "DO NOT EXECUTE THIS SCRIPT IF YOU ARE NOT AUTHORIZED TO USE IT. DO YOU WANT TO CONTINUE?`n" -ForegroundColor Yellow -BackgroundColor Black

Read-Host -Prompt "Press CTRL+C to quit or Enter/Return key to continue" | Out-Null

#cls

Write-Host "`nYou chose to continue. Proceeding with script execution. Please follow the prompts carefully and enter the correct data`n" -ForegroundColor Yellow -BackgroundColor Black

# Import Modules #

<#
$FileBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
  ShowNewFolderButton = $true
  Description = 'Select the directory where the ESXi upgrade scripts/modules are located...'
  RootFolder = 'Desktop'
}
if($FileBrowser.ShowDialog() -ne "OK") {
  exit
}

#>

#$logPath = $FileBrowser.SelectedPath

$logPath = Get-Location

Set-Location -Path $logPath

if((Test-Path -Path "$logPath\Modules\Write-Log.psm1") -and (Test-Path -Path "$logpath\Modules\SessionAuth.psm1") -and (Test-Path -Path "$logpath\Modules\Connect-OMEServer.psm1")){}
else{Write-Host "Selected invalid directory. No script files found. Please rerun the script. Will exit now"; Start-Sleep -Seconds 3; break}

#Get-Module -Name DELL* -ListAvailable | Import-Module -Force
Import-Module -Global "$logPath\Modules\Write-Log.psm1"
Import-Module -Global "$logpath\Modules\SessionAuth.psm1"
Import-Module -Global "$logpath\Modules\Connect-OMEServer.psm1"

# End of Import Modules #

$StartDate = Get-Date -Format "dd-MMM-yyyy-hh-mm"

if(Test-Path -Path "$logPath\ESXi-Update-Logs" -ErrorAction Ignore){} else{New-Item -Path "$logPath\ESXi-Update-Logs" -ItemType Directory -Confirm:$false | Out-Null}
if(Test-Path -Path "$logPath\ESXi-Update-Logs\$StartDate" -ErrorAction Ignore){} else{New-Item -Path "$logPath\ESXi-Update-Logs\$StartDate" -ItemType Directory -Confirm:$false | Out-Null}
if(Test-Path -Path "$logPath\ESXi-Update-Logs\Archive" -ErrorAction Ignore){} else{New-Item -Path "$logPath\ESXi-Update-Logs\Archive" -ItemType Directory -Confirm:$false | Out-Null}
if(Test-Path -Path "$logPath\ESXi-Update-Logs\$StartDate\Script-Run-Results-$StartDate" -ErrorAction Ignore){} else{New-Item -Path "$logPath\ESXi-Update-Logs\$StartDate\Script-Run-Results-$StartDate" -ItemType Directory -Confirm:$false | Out-Null}
if(Test-Path -Path "$logPath\ESXi-Update-Logs\$StartDate\Transcripts" -ErrorAction Ignore){} else{New-Item -Path "$logPath\ESXi-Update-Logs\$StartDate\Transcripts" -ItemType Directory -Confirm:$false | Out-Null}
if(Test-Path -Path "$logPath\Credentials" -ErrorAction Ignore){} else{New-Item -Path "$logPath\Credentials" -ItemType Directory -Confirm:$false | Out-Null}
if(Test-Path -Path "$logPath\Credentials\$StartDate" -ErrorAction Ignore){} else{New-Item -Path "$logPath\Credentials\$StartDate" -ItemType Directory -Confirm:$false | Out-Null}

Get-ChildItem -Path "$logPath\ESXi-Update-Logs\*" | Where-Object{$_.LastWriteTime -lt (Get-Date).AddHours(-24)} | Move-Item -Destination "$logPath\ESXi-Update-Logs\Archive\" -Force -Confirm:$false -ErrorAction Ignore | Out-Null
Get-ChildItem -Path "$logPath\Credentials\*" | Where-Object{$_.LastWriteTime -lt (Get-Date).AddHours(-24)} | Remove-Item -Recurse -Force -Confirm:$false -ErrorAction Ignore | Out-Null


#$DellOME = Read-Host "Enter the DELL OME FQDN or IP Address"
Start-Sleep -Seconds 1

$vcometable = @(

[PSCustomObject]@{Name = "v03g"; omeUser = "vpcidracadmin_cdhk@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v05g"; omeUser = "vpcidracadmin_cdcn@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v06g"; omeUser = "vpcidracadmin_cdin@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v07g"; omeUser = "vpcidracadmin_cdid@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v11g"; omeUser = "vpcidracadmin_cdtw@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v18g"; omeUser = "vpcidracadmin_cld@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v25g"; omeUser = "vpcidracadmin_cdsjv@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v18s"; omeUser = "vpcidracadmin_cldddc@reg1.1bank.dbs.com"}
[PSCustomObject]@{Name = "v01s"; omeUser = "vpcidracadmin_cldddc@reg1.1bank.dbs.com"}

)

### Text box to enter the list of VCENTERs as user input

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Enter the list of vCenter Servers'
    $form.Size = New-Object System.Drawing.Size(700,700)
    $form.StartPosition = 'CenterScreen' 
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $form.Topmost = $true

    $OKButton = New-Object System.Windows.Forms.Button
    $OKButton.Location = New-Object System.Drawing.Point(100,550)
    $OKButton.Size = New-Object System.Drawing.Size(75,23)
    $OKButton.Text = 'OK'
    $OKButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $OKButton
    $form.Controls.Add($OKButton)

    $CancelButton = New-Object System.Windows.Forms.Button
    $CancelButton.Location = New-Object System.Drawing.Point(10,550)
    $CancelButton.Size = New-Object System.Drawing.Size(75,23)
    $CancelButton.Text = 'Cancel'
    $CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $CancelButton
    $form.Controls.Add($CancelButton)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,10)
    $label.AutoSize = $True
    $Font = New-Object System.Drawing.Font("Arial",9,[System.Drawing.FontStyle]::Bold)
    $label.Font = $Font
    $label.Text = "Enter the FQDN of the vCenter Servers, one after/below the other. Ensure that there are no trailing spaces."
    $label.ForeColor = 'Red'
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(10,40)
    $textBox.Size = New-Object System.Drawing.Size(500,500)
    $textBox.Multiline = $true
    $textbox.AcceptsReturn = $true
    $textBox.ScrollBars = "Vertical"
    $textboxFont = New-Object System.Drawing.Font("Arial",10,[System.Drawing.FontStyle]::Bold)
    $textBox.Font = $textboxFont
    $form.Controls.Add($textBox)

    $form.Add_Shown({$textBox.Select()})
    $result = $form.ShowDialog()
 
    ### If the OK button is selected do the following
    if ($result -eq [System.Windows.Forms.DialogResult]::OK)
    {
        ### Removing all the spaces and extra lines
        $x = $textBox.Lines | Where{$_} | ForEach{ $_.Trim() }
        ### Putting the array together
        $array = @()
        ### Putting each entry into array as individual objects
        $array = $x -split "`r`n"
        ### Sending back the results while taking out empty objects
        $vCenters = $array | Where-Object {$_ -ne ''}
        #$InvalidVmList = $array | Where-Object {$_ -eq '' -or $_ -like "*.*" -or $_ -notmatch '\D'}

        if($vCenters.Length -eq 0){Write-Host "No vCenter servers entered. Exiting the script"; Start-Sleep -Seconds 2;break}
    }
 
    ### If the cancel button is selected do the following
    if ($result -eq [System.Windows.Forms.DialogResult]::Cancel)
    {
        Write-Host "User Canceled" -BackgroundColor Red -ForegroundColor White
        Write-Host "Exiting script..."
        Start-Sleep -Seconds 2
        break
    }

    ### End


### Text box to enter the list of ESXi servers as user input

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Enter the list of ESXi hosts'
    $form.Size = New-Object System.Drawing.Size(700,700)
    $form.StartPosition = 'CenterScreen' 
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $form.Topmost = $true

    $OKButton = New-Object System.Windows.Forms.Button
    $OKButton.Location = New-Object System.Drawing.Point(100,550)
    $OKButton.Size = New-Object System.Drawing.Size(75,23)
    $OKButton.Text = 'OK'
    $OKButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $OKButton
    $form.Controls.Add($OKButton)

    $CancelButton = New-Object System.Windows.Forms.Button
    $CancelButton.Location = New-Object System.Drawing.Point(10,550)
    $CancelButton.Size = New-Object System.Drawing.Size(75,23)
    $CancelButton.Text = 'Cancel'
    $CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $CancelButton
    $form.Controls.Add($CancelButton)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,10)
    $label.AutoSize = $True
    $Font = New-Object System.Drawing.Font("Arial",9,[System.Drawing.FontStyle]::Bold)
    $label.Font = $Font
    $label.Text = "Enter the FQDN of the ESXi hosts, one after/below the other"
    $label.ForeColor = 'Red'
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(10,40)
    $textBox.Size = New-Object System.Drawing.Size(500,500)
    $textBox.Multiline = $true
    $textbox.AcceptsReturn = $true
    $textBox.ScrollBars = "Vertical"
    $textboxFont = New-Object System.Drawing.Font("Arial",10,[System.Drawing.FontStyle]::Bold)
    $textBox.Font = $textboxFont
    $form.Controls.Add($textBox)

    $form.Add_Shown({$textBox.Select()})
    $result = $form.ShowDialog()
 
    ### If the OK button is selected do the following
    if ($result -eq [System.Windows.Forms.DialogResult]::OK)
    {
        ### Removing all the spaces and extra lines
        $x = $textBox.Lines | Where{$_} | ForEach{ $_.Trim() }
        ### Putting the array together
        $array = @()
        ### Putting each entry into array as individual objects
        $array = $x -split "`r`n"
        ### Sending back the results while taking out empty objects
        $esxiServers = $array | Where-Object {$_ -ne ''}
        #$InvalidVmList = $array | Where-Object {$_ -eq '' -or $_ -like "*.*" -or $_ -notmatch '\D'}

        if($esxiServers.Length -eq 0){Write-Host "No ESXi hosts entered. Exiting the script"; Start-Sleep -Seconds 2;break}
    }
 
    ### If the cancel button is selected do the following
    if ($result -eq [System.Windows.Forms.DialogResult]::Cancel)
    {
        Write-Host "User Canceled" -BackgroundColor Red -ForegroundColor White
        Write-Host "Exiting script..."
        Start-Sleep -Seconds 2
        break
    }

    ### End

# VCENTER credentials and corresponding DELL OME credentials capture and validation

$vcHostMap = @()
$esxiLicMap = @()
$exclESXi = @()

foreach($vCenter in $vCenters){
    
    
                Add-Type -AssemblyName System.Windows.Forms
                Add-Type -AssemblyName System.Drawing

                $form = New-Object System.Windows.Forms.Form
                $form.Text = "$vCenter"
                $form.Size = New-Object System.Drawing.Size(500,200)
                $form.StartPosition = 'CenterScreen'

                $okButton = New-Object System.Windows.Forms.Button
                $okButton.Location = New-Object System.Drawing.Point(75,120)
                $okButton.Size = New-Object System.Drawing.Size(75,23)
                $okButton.Text = 'OK'
                $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.AcceptButton = $okButton
                $form.Controls.Add($okButton)

                $cancelButton = New-Object System.Windows.Forms.Button
                $cancelButton.Location = New-Object System.Drawing.Point(150,120)
                $cancelButton.Size = New-Object System.Drawing.Size(75,23)
                $cancelButton.Text = 'Cancel'
                $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $form.CancelButton = $cancelButton
                $form.Controls.Add($cancelButton)

                $label = New-Object System.Windows.Forms.Label
                $label.Location = New-Object System.Drawing.Point(10,20)
                $label.Size = New-Object System.Drawing.Size(320,60)
                $label.Text = "Enter a valid DEP/CR number for the upgrade of ESXi hosts that are part of the vCenter $vCenter"
                $form.Controls.Add($label)

                $textBox = New-Object System.Windows.Forms.TextBox
                $textBox.Location = New-Object System.Drawing.Point(10,80)
                $textBox.Size = New-Object System.Drawing.Size(400,20)
                $form.Controls.Add($textBox)

                $form.Topmost = $true

                $form.Add_Shown({$textBox.Select()})
                $result = $form.ShowDialog()

                if ($result -eq [System.Windows.Forms.DialogResult]::OK)
                {
                $DEPCR = $textBox.Text
                }
                else{
                if($result -eq [System.Windows.Forms.DialogResult]::Cancel){$DEPCR = "NoDEPorCR"}
                else{}
                }

    #$DEPCR = Read-Host "Enter a valid and approved DEP/CR number that covers the current tasks for VCENTER $vCenter"
    $DEPCR = $DEPCR.Trim()
    $vcDepCrMap += @([PSCustomObject]@{VCENTER = "$vCenter"; DEPCR = "$DEPCR"})

    $vcPre = $vCenter.Substring(0,4)
    if($vcPre -eq "v18s" -or $vcPre -eq "v01s"){$DellOME = "p01scldmapp1a.cld.uat.dbs.com"} else{$DellOME = "p01gcldmapp1a.vpc.sgp.dbs.com"}

    $vcCreds = Get-Credential -Message "Enter the credentials that has admin privileges on $vCenter"
    Write-Host "`nValidating if the entered credentials are valid to access the vCenter $vCenter"

    if(Connect-VIServer -Server $vCenter -Credential $vcCreds -ErrorAction Ignore){$vcCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$vCenter-Creds.xml"; Write-Host "Successfully validated the entered credentials to access vCenter $vCenter" -ForegroundColor Green}
    
    else{

        Write-Host "Invalid credentials entered to access the vCenter $vCenter. Please re-enter" -ForegroundColor Red -BackgroundColor White
        Start-Sleep -Seconds 1
        $vcCreds = Get-Credential -Message "Enter the credentials to connect to $vCenter"
        Start-Sleep -Seconds 1
        Write-Host "Validating if the entered credentials are valid to access the vCenter $vCenter"

        if(Connect-VIServer -Server $vCenter -Credential $vcCreds -ErrorAction Ignore){$vcCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$vCenter-Creds.xml";Write-Host "Successfully validated the entered credentials to access vCenter $vCenter" -ForegroundColor Green}
    
        else{

        Write-Host "Invalid credentials entered to access the vCenter $vCenter. Please re-enter" -ForegroundColor Red -BackgroundColor White
        Start-Sleep -Seconds 1
        $vcCreds = Get-Credential -Message "Enter the credentials to connect to $vCenter"
        Start-Sleep -Seconds 1
        Write-Host "Validating if the entered credentials are valid to access the vCenter $vCenter"
    
            if(Connect-VIServer -Server $vCenter -Credential $vcCreds -ErrorAction Ignore){$vcCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$vCenter-Creds.xml";Write-Host "Successfully validated the entered credentials access vCenter $vCenter" -ForegroundColor Green}
            else{
        
            Write-Host "Invalid credentials entered to access the vCenter $vCenter. Excluding the ESXi hosts managed by this vCenter Server from upgrade" -ForegroundColor Yellow -BackgroundColor Black
            Start-Sleep -Seconds 3
            $vCenters = $vCenters | Where-Object{$_ -ne "$vCenter"}
        
            }
    
        }

    }

    Start-Sleep -Seconds 2

    $vcPre = $vCenter.Substring(0,4)
    $omeUser = ($vcometable | Where-Object{$_.Name -eq $vcPre}).omeUser

    if($omeUser){

    if(Test-Path -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"){Write-Host "Encrypted credential file to login to DELL OME $DellOME already exits" -ForegroundColor Green}

    else{

    $omeCreds = Get-Credential -Message "Enter the credentials to access the DELL OME/iDRAC" -UserName $omeUser
    Start-Sleep -Seconds 1
    $omeCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"
    
    $chkOmeCreds = 0
    
    <#

    Write-Host "`nValidating if the entered credentials are valid to access DELL OME $DellOME"

    try{$ErrorActionPreference = 'Stop'; Ignore-SSLCertificates} catch{}
    try{$ErrorActionPreference = 'Stop'; Connect-OMEServer -Name $DellOME -Credentials $omeCreds -IgnoreCertificateWarning; $chkOmeCreds = 0} catch{$chkOmeCreds = 1}
    if($chkOmeCreds -eq 1){try{$ErrorActionPreference = 'Stop'; Connect-OMEServer -Name $DellOME -Credentials $omeCreds; $chkOmeCreds = 0} catch{$chkOmeCreds = 1}}

        if($chkOmeCreds -eq 0){
        
        if(Test-Path -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"){} 
        else{Write-Host "Successfully validated the entered credentials to access DELL OME $DellOME" -ForegroundColor Green; $omeCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"}
        
        }

        else{

        $chkOmeCreds = $null
        Start-Sleep -Seconds 1
        Write-Host "Invalid credentials entered to access DELL OME/iDRAC credentials. Please re-enter" -ForegroundColor Red -BackgroundColor White
        Start-Sleep -Seconds 3
        $omeCreds = Get-Credential -Message "Enter the credentials to access the DELL OME/iDRAC" -UserName $omeUser
        Start-Sleep -Seconds 1
        Write-Host "Validating DELL OME $DellOME credentials"
        Write-Host "Validating if the entered credentials are valid to access DELL OME $DellOME"

        try{$ErrorActionPreference = 'Stop'; Ignore-SSLCertificates} catch{}
        try{$ErrorActionPreference = 'Stop'; Connect-OMEServer -Name $DellOME -Credentials $omeCreds -IgnoreCertificateWarning; $chkOmeCreds = 0} catch{$chkOmeCreds = 1}
        if($chkOmeCreds -eq 1){try{$ErrorActionPreference = 'Stop'; Connect-OMEServer -Name $DellOME -Credentials $omeCreds; $chkOmeCreds = 0} catch{$chkOmeCreds = 1}}

            if($chkOmeCreds -eq 0){
        
                if(Test-Path -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"){} 
                else{Write-Host "Successfully validated the entered credentials to access DELL OME $DellOME" -ForegroundColor Green; $omeCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"}
        
            }
        
            else{
            
                $chkOmeCreds = $null
                Start-Sleep -Seconds 1
                Write-Host "Invalid credentials entered to access DELL OME/iDRAC credentials. Please re-enter" -ForegroundColor Red -BackgroundColor White
                $omeCreds = Get-Credential -Message "Enter the credentials to access the DELL OME/iDRAC" -UserName $omeUser
                Start-Sleep -Seconds 3
                Write-Host "Validating if the entered credentials are valid to access DELL OME $DellOME"

                try{$ErrorActionPreference = 'Stop'; Ignore-SSLCertificates} catch{}
                try{$ErrorActionPreference = 'Stop'; Connect-OMEServer -Name $DellOME -Credentials $omeCreds -IgnoreCertificateWarning; $chkOmeCreds = 0} catch{$chkOmeCreds = 1}
                if($chkOmeCreds -eq 1){try{$ErrorActionPreference = 'Stop'; Connect-OMEServer -Name $DellOME -Credentials $omeCreds; $chkOmeCreds = 0} catch{$chkOmeCreds = 1}}          
            
                if($chkOmeCreds -eq 0){
        
                    if(Test-Path -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"){} 
                    else{Write-Host "Successfully validated the entered credentials to access DELL OME $DellOME" -ForegroundColor Green; $omeCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml"}
        
                }
            
                else{

                    $chkOmeCreds = $null
                    Start-Sleep -Seconds 1
                    Write-Host "Invalid $omeUser credentials entered to access DELL OME/iDRAC. Excluding the ESXi hosts managed the vCenter $vCenter from upgrades" -ForegroundColor Yellow -BackgroundColor Black
                    Start-Sleep -Seconds 3
                    $vCenters = $vCenters | Where-Object{$_ -ne $vCenter}

                }

            }

        }

        #>

    }

    }

    else{

    Write-Host "`nCould not find DELL OME/iDRAC user to access ESXi hosts in the vCenter $vCenter. Excluding the ESXi hosts managed the vCenter $vCenter from upgrades" -ForegroundColor Yellow -BackgroundColor Black
    Start-Sleep -Seconds 3
    $vCenters = $vCenters | Where-Object{$_ -ne $vCenter}

    }

    if((Test-Path -Path "$logPath\Credentials\$StartDate\$vCenter-Creds.xml" -ErrorAction Ignore) -and (Test-Path -Path "$logPath\Credentials\$StartDate\$omeUser-Creds.xml" -ErrorAction Ignore)){

    $vchostlist = (Get-VMHost -Server $vCenter).Name

        foreach($esxi in $vchostlist){

        $vcHostMap += @([PSCustomObject]@{VCENTER = "$vCenter"; ESXiHost = "$esxi"; DEPCR = "$DEPCR"})

        }

    }

    else{}

}

# End #

# ESXi hosts credential capture and validation

foreach($esxiServer in $esxiServers){

    if($vcHostMap.ESXiHost -contains $esxiServer){

    $esxiServerCreds = Get-Credential -Message "Enter the root credentials to access $esxiServer" -UserName root
    Write-Host "`nValidating root credentials of $esxiServer"

        if(Connect-VIServer -Server $esxiServer -Credential $esxiServerCreds -ErrorAction Ignore){$esxiServerCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml";Write-Host "Successfully validated the entered credentials to access $esxiServer" -ForegroundColor Green; Disconnect-VIServer -Server $esxiServer -Confirm:$false -ErrorAction Ignore}
    
        else{

            Write-Host "Invalid root credentials of $esxiServer. Please re-enter" -ForegroundColor Red -BackgroundColor White
            Start-Sleep -Seconds 1
            $esxiServerCreds = Get-Credential -Message "Enter the root credentials to access $esxiServer" -UserName root
            Start-Sleep -Seconds 1
            Write-Host "Validating root credentials of $esxiServer"

            if(Connect-VIServer -Server $esxiServer -Credential $esxiServerCreds -ErrorAction Ignore){$esxiServerCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"; Write-Host "Successfully validated the entered credentials to access $esxiServer" -ForegroundColor Green; Disconnect-VIServer -Server $esxiServer -Confirm:$false -ErrorAction Ignore}
    
            else{

            Write-Host "Invalid root credentials of $esxiServer. Please re-enter" -ForegroundColor Red -BackgroundColor White
            Start-Sleep -Seconds 1
            $esxiServerCreds = Get-Credential -Message "Enter the root credentials to access $esxiServer" -UserName root
            Start-Sleep -Seconds 1
            Write-Host "Validating root credentials of $esxiServer"
    
                if(Connect-VIServer -Server $esxiServer -Credential $esxiServerCreds -ErrorAction Ignore){$esxiServerCreds | Export-Clixml -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"; Write-Host "Successfully validated the entered credentials to access $esxiServer" -ForegroundColor Green; Disconnect-VIServer -Server $esxiServer -Confirm:$false -ErrorAction Ignore}
                
                else{
        
                Write-Host "Invalid root credentials for $esxiServer. Script will exclude this ESXi server from upgrade" -ForegroundColor Yellow -BackgroundColor Black
                Start-Sleep -Seconds 3
                $esxiServers = $esxiServers | Where-Object{$_ -ne "$esxiServer"}
                $Remark = $esxiServer + " - " + "excluded due to invalid root credentials"
                $exclESXi += $Remark
        
                }
    
            }

        }

        Start-Sleep -Seconds 2

        if(Test-path -Path "$logPath\Credentials\$StartDate\$esxiServer-rootCreds.xml"){
        
        try{$ErrorActionPreference = 'Stop'; $POD = (Get-VMHost -Name $esxiServer -ErrorAction Ignore).Parent.Name} catch{}
        
            if($POD){
        
                #$chkLicHost = Get-Cluster -Name $POD -ErrorAction Ignore | Get-VMHost | Where-Object{$_.Version -eq "8.0.3" -and $_.LicenseKey -ne "00000-00000-00000-00000-00000"} | Get-Random | Select -First 1
                $chkMMHosts = (Get-Cluster -Name $POD -ErrorAction Ignore | Get-VMHost | Where-Object{$_.ConnectionState -eq "Maintenance"}).Count

                #if($chkLicHost){$chkLicNo = $chkLicHost.LicenseKey} else{}

                #if($chkLicNo -and $chkLicNo -ne "00000-00000-00000-00000-00000"){$licKey = $chkLicNo}
                #elseif($esxiLicMap -and (($esxiLicMap | Where-Object{$_.POD -eq "$POD"}).License | Where-Object{$_ -notcontains "NA" -and $_ -ne $null -and $_ -ne ""})){$licKey = ($esxiLicMap | Where-Object{$_.POD -eq "$POD"}).License | Where-Object{$_ -notcontains "NA" -and $_ -ne $null -and $_ -ne ""} | Select -Unique} 

                Add-Type -AssemblyName System.Windows.Forms
                Add-Type -AssemblyName System.Drawing

                $form = New-Object System.Windows.Forms.Form
                $form.Text = "$esxiServer"
                $form.Size = New-Object System.Drawing.Size(500,200)
                $form.StartPosition = 'CenterScreen'

                $okButton = New-Object System.Windows.Forms.Button
                $okButton.Location = New-Object System.Drawing.Point(75,120)
                $okButton.Size = New-Object System.Drawing.Size(75,23)
                $okButton.Text = 'OK'
                $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.AcceptButton = $okButton
                $form.Controls.Add($okButton)

                $cancelButton = New-Object System.Windows.Forms.Button
                $cancelButton.Location = New-Object System.Drawing.Point(150,120)
                $cancelButton.Size = New-Object System.Drawing.Size(75,23)
                $cancelButton.Text = 'Cancel'
                $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $form.CancelButton = $cancelButton
                $form.Controls.Add($cancelButton)

                $label = New-Object System.Windows.Forms.Label
                $label.Location = New-Object System.Drawing.Point(10,20)
                $label.Size = New-Object System.Drawing.Size(320,60)
                $label.Text = "Enter a valid Licence Key for ESXi version 8.0.3`nor`nEnter `"NA`" if no license key is available"
                $form.Controls.Add($label)

                $textBox = New-Object System.Windows.Forms.TextBox
                $textBox.Location = New-Object System.Drawing.Point(10,80)
                $textBox.Size = New-Object System.Drawing.Size(400,20)
                $form.Controls.Add($textBox)

                $form.Topmost = $true

                $form.Add_Shown({$textBox.Select()})
                $result = $form.ShowDialog()

                if ($result -eq [System.Windows.Forms.DialogResult]::OK)
                {
                $licKey = $textBox.Text
                }
                else{
                if($result -eq [System.Windows.Forms.DialogResult]::Cancel){$licKey = "NA"}
                else{}
                }

                $esxiLicMap += @([PSCustomObject]@{ESXiHost = "$esxiServer"; License = "$licKey"; POD = "$POD"; HostsInMM = $chkMMHosts})
        
            }

            else{
        
            $esxiServers = $esxiServers | Where-Object{$_ -ne "$esxiServer"}
            $Remark = $esxiServer + " - " + "excluded as the script could not find the associated cluster / POD"
            $exclESXi += $Remark
            $licKey = "NA"
        
            }

        }

        else{
        
        $esxiServers = $esxiServers | Where-Object{$_ -ne "$esxiServer"}
        $Remark = $esxiServer + " - " + "excluded as encrypted root credential file is missing"
        $exclESXi += $Remark
        
        }

    }

    else{
    
    $esxiServers = $esxiServers | Where-Object{$_ -ne $esxiServer}
    $Remark = $esxiServer + " - " + "excluded due to invalid OME/vCenterServer credentials OR host not found in VCENTER"
    $exclESXi += $Remark

    }
}

# End #

if(!$esxiLicMap){Write-Host "None of the ESXi servers have been picked for upgrade. Please ensure the VCENTERs entered and corresponding credentials are correct. Script will exit now" -ForegroundColor Red -BackgroundColor White; break  }
else{}

$PODs = $esxiLicMap.POD | Select -Unique

# Exclude multiple hosts in same POD from upgrade, if selected by mistake #

foreach($POD in $PODs){

$PODCount = ($esxiLicMap | Where-Object{$_.POD -eq $POD}).Count
    
    if($PODCount -gt 1){
 
    $PodChk = Show-MsgBox -Text "There are $PODCount hosts selected for upgrade in POD $POD. Can possibly lead to a severe resource contention or performance issues for VMs in the POD. Do you want to continue?" -Title "ALERT !!! MULTIPLE ESXi HOST UPGRADES TRIGGERED IN SAME POD" -Button YesNo -Icon Warning
        
        if($PodChk -eq "Yes"){}
        
        else{
        
        $hostRem = ($esxiLicMap | Where-Object{$_.POD -eq $POD}).ESXiHost | Select -First ($PODCount - 1)

            foreach($hostR in $hostRem){

            $esxiServers = $esxiServers | Where-Object{$_ -ne "$hostR"}
            $Remark = $hostR + " - " + "excluded as more than 1 host was marked for upgrade in POD $POD"
            $exclESXi += $Remark

            }
        
        }

    }

    else{}
}

# End #

# Option to exclude ESXi hosts in a POD from upgrade, if any ESXi host in the POD is already in Maintenace Mode ###

foreach($POD in $PODs){

$HostsInMMCount = ($esxiLicMap | Where-Object{$_.POD -eq $POD}).HostsInMM | Select -Unique

    if($HostsInMMCount -gt 0){
 
    $PodChk = Show-MsgBox -Text "There is/are already $HostsInMMCount host/s in Maintenance Mode in POD $POD. Upgrading another host can possibly lead to a severe resource contention or performance issues for VMs in the POD. Do you want to continue?" -Title "ALERT !!! HOST/S ALREADY IN MAINTENANCE MODE IN SAME POD" -Button YesNo -Icon Warning
        
        if($PodChk -eq "Yes"){}
        
        else{
        
        $hostRem = ($esxiLicMap | Where-Object{$_.POD -eq $POD}).ESXiHost

            foreach($hostR in $hostRem){

            if($esxiServers -contains $hostR){

            $esxiServers = $esxiServers | Where-Object{$_ -ne "$hostR"}
            $Remark = $hostR + " - " + "excluded as 1 or more hosts are already in Maintenance Mode in POD $POD"
            $exclESXi += $Remark

            }

            }
        
        }

    }

    else{}
}

### End ###

$exclESXi | Out-File -FilePath "$logPath\ESXi-Update-Logs\$StartDate\Excluded-ESXiServer-List-$StartDate.txt"
#$esxiLicMap | Out-File -FilePath "$logPath\ESXi-Update-Logs\$StartDate\ESXiServer-License-Mapping-$StartDate.txt" -Force

Write-Host "`n`n"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Firmware and ESXi Version Upgrades'
$form.Size = New-Object System.Drawing.Size(500,200)
$form.StartPosition = 'CenterScreen'

$okButton = New-Object System.Windows.Forms.Button
$okButton.Location = New-Object System.Drawing.Point(75,120)
$okButton.Size = New-Object System.Drawing.Size(75,23)
$okButton.Text = 'OK'
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.AcceptButton = $okButton
$form.Controls.Add($okButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Location = New-Object System.Drawing.Point(150,120)
$cancelButton.Size = New-Object System.Drawing.Size(75,23)
$cancelButton.Text = 'Cancel'
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.CancelButton = $cancelButton
$form.Controls.Add($cancelButton)

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(10,20)
$label.Size = New-Object System.Drawing.Size(280,20)
$label.Text = 'Please select an option'
$form.Controls.Add($label)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Location = New-Object System.Drawing.Point(10,40)
$listBox.Size = New-Object System.Drawing.Size(450,100)
$listBox.Height = 80
$ListBox.Font = New-Object System.Drawing.Font("Microsoft Sans Serif",11,[System.Drawing.FontStyle]::Regular)

[void] $listBox.Items.Add('1. Firmware Upgrade (including Broadcom Net-Xtreme Firmware)')
[void] $listBox.Items.Add('2. ESXi Version Upgrade to 80U3-24022510')
[void] $listBox.Items.Add('3. ESXi Post Upgrade Tasks')
[void] $listBox.Items.Add('4. All')
$form.Controls.Add($listBox)

$form.Topmost = $true

$result = $form.ShowDialog()

if ($result -eq [System.Windows.Forms.DialogResult]::OK)
{
    $x = $listBox.SelectedItem
}

Write-Host "`n`n"

if($x -eq "1. Firmware Upgrade (including Broadcom Net-Xtreme Firmware)"){$opt = 1}
elseif($x -eq "2. ESXi Version Upgrade to 80U3-24022510"){$opt = 2}
elseif($x -eq "3. ESXi Post Upgrade Tasks"){$opt = 3}
elseif($x -eq "4. All"){$opt = 4}
else{Write-Host "Invalid option selected. Script will exit now"; Start-Sleep -Seconds 5; break}

cls

try{$ErrorActionPreference = 'Stop'; Disconnect-VIServer * -Confirm:$false} catch{}

#$test = @()

Write-Host "`nScript will now begin creating background jobs for upgrading each ESXi host in the list. Keep monitoring the console and log files to get the status of upgrade tasks`n"

foreach($esxiServer in $esxiServers){

$esxiServer = $esxiServer.Trim()
$vCenter = ($vcHostMap | Where-Object{$_.ESXiHost -contains $esxiServer}).VCENTER
$DEPCR = ($vcHostMap | Where-Object{$_.ESXiHost -contains $esxiServer}).DEPCR
$licenseKey = ($esxiLicMap | Where-Object{$_.ESXiHost -contains $esxiServer}).License
#$test += [PSCustomObject]@{VCENTER = "$vCenter"; ESXiHost = "$esxiServer"; DEPCR = "$DEPCR"; LicenseKey = "$licenseKey"}
$Job = Start-Job -ScriptBlock $ESXiUpgrade -ArgumentList "$logPath", "$vCenter", "$esxiServer", "$DEPCR", "$StartDate", "$opt", "$licenseKey" -Name "$esxiServer-Upgrade"
Start-Sleep -Seconds 60

}

do{

cls
Write-Host "`n DO NOT CLOSE THIS POWERSHELL CONSOLE/WINDOW.`n" -ForegroundColor White -BackgroundColor Red
Write-Host "`n ESXi upgrade tasks are in progress.....`n" -ForegroundColor Yellow
Write-Host "`n Open another PowerShell console and run Import-Csv command on the respective log file located in $logPath\ESXi-Update-Logs\$StartDate to check the upgrade logs of any ESXi host`n" -ForegroundColor Yellow
$Jobs =  Get-Job | Where-Object{$_.Name -like "*-Upgrade*"}
Write-Host "`n Status of ESXi upgrade tasks are shown below. Refreshes every 5 minutes...`n"
$RunningJobsCount = ($Jobs | Where-Object{$_.State -eq "Running"}).Count
$Jobs | Select Id, Name, State, PsJobTypeName | ft -AutoSize
Start-Sleep -Seconds 300
cls

} until($RunningJobsCount -eq 0)
