<#
_author_ = Ng Zhi Hua <zhihuang@dbs.com>
_version_ = 1.0

Copyright (c) 2020, DBS Bank, Inc.

This software is licensed to you under the GNU General Public License,
version 2 (GPLv2). There is NO WARRANTY for this software, express or
implied, including the implied warranties of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. You should have received a copy of GPLv2
along with this software; if not, see
http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
#>




<#
.Synopsis
   Cmdlet used to get iDRAC Firmware versions.
.DESCRIPTION
   Cmdlet using Redfish API with OEM extension to get iDRAC remote service status. The output will return LC (Lifecycle controller) status, RT (real time monitoring) status, server status (examples, in POST or in in BIOS boot manager) and overall status. 
   - idrac_ip: Pass in iDRAC IP address
   - idrac_username: Pass in iDRAC username
   - idrac_password: Pass in iDRAC username password
.EXAMPLE
   .\Get-IdracRemoteServiceApiStatusREDFISH -idrac_ip 192.168.0.120 -username root -password calvin 
   This example will return remote services status for the iDRAC. 
#>

function Get-IdracFirmwareVersionREDFISH {

param(
    [Parameter(Mandatory=$True)]
    [string]$idrac_ip,
    [Parameter(Mandatory=$True)]
    [string]$idrac_username,
    [Parameter(Mandatory=$True)]
    [string]$idrac_password
    )

# Function to ignore SSL certs

function Ignore-SSLCertificates
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

$global:get_powershell_version = $null

function get_powershell_version 
{
$get_host_info = Get-Host
$major_number = $get_host_info.Version.Major
$global:get_powershell_version = $major_number
}

get_powershell_version


[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::TLS12
$user = $idrac_username
$pass= $idrac_password
$secpasswd = ConvertTo-SecureString $pass -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($user, $secpasswd)



$JsonBody = @{'UserName'= $idrac_username; 'Password'= $idrac_password} | ConvertTo-Json -Compress
$uri = "https://$idrac_ip/redfish/v1/Sessions "

try {
    if ($global:get_powershell_version -gt 5)
    {
        $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
        Ignore-SSLCertificates
        $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
        $location = $post_result.headers.Location
        $token = $post_result.headers.'X-Auth-Token'
    }
} catch {
    Write-Host
    $RespErr
    return
}

$uri = "https://$idrac_ip/redfish/v1/UpdateService/FirmwareInventory/"
$header = @{'Location' = $location; 'X-Auth-Token'= $token; "Accept"="application/json"}

try
{
    if ($global:get_powershell_version -gt 5)
    {
        $get_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Headers $header -Method Get -ContentType 'application/json' -ErrorVariable RespErr
    }
    else
    {
        Ignore-SSLCertificates
        $get_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Get -Headers $header -ContentType 'application/json' -ErrorVariable RespErr
    }
}
catch
{
    Write-Host
    $RespErr
    return
} 

if ($get_result.StatusCode -eq 200 -or $get_result.StatusCode -eq 200)
{
    #Write-Host "- PASS, POST command passed to get iDRAC remote service API status"
}
else
{
    [String]::Format("- FAIL, POST command failed to get iDRAC remote service API status, statuscode {0} returned. Detail error message: {1}",$get_result.StatusCode, $get_result)
    return
}

$firmware_versions = New-Object System.Data.DataTable
$col1 = New-Object System.Data.DataColumn("Name")
$col2 = New-Object System.Data.DataColumn("Id")
$col3 = New-Object System.Data.DataColumn("Version")
$firmware_versions.Columns.Add($col1)
$firmware_versions.Columns.Add($col2)
$firmware_versions.Columns.Add($col3)
$firmware_url = ($get_result.Content | ConvertFrom-Json).members
$firmware_url = $firmware_url | Where-Object { $_.'@odata.id' -match 'Installed' }
ForEach ($component in $firmware_url){
    $component_link = $component.'@odata.id'
    $uri = "https://$idrac_ip$component_link"
    try{
        If ($global:get_powershell_version -gt 5){
            $get_component_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Headers $header -Method Get -ContentType 'application/json' -ErrorVariable RespErr    
        }
        Else{
            Ignore-SSLCertificates
            $get_component_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $header -Method Get -ContentType 'application/json' -ErrorVariable RespErr    
        }
        $component_details = $get_component_result.Content | ConvertFrom-Json
        $row = $firmware_versions.NewRow()
        $row["Name"] = $component_details.Name
        $row["Id"] = $component_details.Id
        $row["Version"] = $component_details.Version
        $firmware_versions.rows.Add($row)
    }catch{
        Write-Host
        $RespErr
        return
    }
}
return $firmware_versions
}




<#
_author_ = Texas Roemer <Texas_Roemer@Dell.com>
_version_ = 5.0

Copyright (c) 2020, Dell, Inc.

This software is licensed to you under the GNU General Public License,
version 2 (GPLv2). There is NO WARRANTY for this software, express or
implied, including the implied warranties of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. You should have received a copy of GPLv2
along with this software; if not, see
http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
#>




<#
.Synopsis
   iDRAC cmdlet using Redfish API to manage iDRAC job queue.
.DESCRIPTION
   iDRAC cmdlet using Redfish API with OEM extension to manage iDRAC job queue. Supported operations are get current job queue, delete single job ID, clear complete job queue or clear complete job queue/restart Lifecycle Controller services. 
   - idrac_ip: Pass in iDRAC IP address
   - idrac_username: Pass in iDRAC username
   - idrac_password: Pass in iDRAC username password
   - x_auth_token: Pass in iDRAC X-Auth token session to execute cmdlet instead of username / password (recommended)
   - get_job_queue: Pass in 'y' to get current job queue
   - delete_job_id: Delete one job ID, pass in the job ID
   - delete_job_queue: Clear the complete job queue, pass in value 'y'
   - delete_job_queue_restart_LC_services: Clear the complete job queue and restart Lifecycle Controller services, pass in value 'y'. Note: By selecting this option, it will take a few minutes for the Lifecycle Controller to be back in Ready state Note: Use this option as a last resort when iDRAC is in a bad state where you are not allowed to set pending or create new jobs. Note: Also recommended once iDRAC is back up is to reboot the iDRAC, put it back into a known good state.
.EXAMPLE
   Invoke-IdracJobQueueManagementREDFISH -idrac_ip 192.168.0.120 -username root -password calvin -get_job_queue y
   This example will get current iDRAC job queue.
.EXAMPLE
   Invoke-IdracJobQueueManagementREDFISH -idrac_ip 192.168.0.120 -get_job_queue y
   This example will first prompt to enter iDRAC username/password using Get-Credential, then get current iDRAC job queue.
.EXAMPLE
   Invoke-IdracJobQueueManagementREDFISH -idrac_ip 192.168.0.120 -get_job_queue y -x_auth_token 7bd9bb9a8727ec366a9cef5bc83b2708
   This example will get current iDRAC job queue using iDRAC X-auth token session. 
.EXAMPLE
   Invoke-IdracJobQueueManagementREDFISH -idrac_ip 192.168.0.120 -username root -password calvin -delete_job_id JID_735345376228
   This example will delete job id JID_735345376228 from the job queue
.EXAMPLE
   Invoke-IdracJobQueueManagementREDFISH -idrac_ip 192.168.0.120 -username root -password calvin -delete_job_queue y 
   This example will clear the complete iDRAC job queue.
.EXAMPLE
   Invoke-IdracJobQueueManagementREDFISH -idrac_ip 192.168.0.120 -username root -password calvin -delete_job_queue_restart_LC_services y 
   This example will clear the complete iDRAC job queue and restart Lifecycle Controller services.
#>

function Invoke-IdracJobQueueManagementREDFISH {

param(
    [Parameter(Mandatory=$True)]
    [string]$idrac_ip,
    [Parameter(Mandatory=$False)]
    [string]$idrac_username,
    [Parameter(Mandatory=$False)]
    [string]$idrac_password,
    [Parameter(Mandatory=$False)]
    [string]$x_auth_token,
    [Parameter(Mandatory=$False)]
    [string]$get_job_queue,
    [Parameter(Mandatory=$False)]
    [string]$delete_job_id,
    [Parameter(Mandatory=$False)]
    [string]$delete_job_queue,
    [Parameter(Mandatory=$False)]
    [string]$delete_job_queue_restart_LC_services
    )

# Function to ignore SSL certs

function Ignore-SSLCertificates
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

$global:get_powershell_version = $null

function get_powershell_version 
{
$get_host_info = Get-Host
$major_number = $get_host_info.Version.Major
$global:get_powershell_version = $major_number
}


function setup_idrac_creds
{

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::TLS12

if ($x_auth_token)
{
$global:x_auth_token = $x_auth_token
}
elseif ($idrac_username -and $idrac_password)
{
$user = $idrac_username
$pass= $idrac_password
$secpasswd = ConvertTo-SecureString $pass -AsPlainText -Force
$global:credential = New-Object System.Management.Automation.PSCredential($user, $secpasswd)
}
else
{
$get_creds = Get-Credential
$global:credential = New-Object System.Management.Automation.PSCredential($get_creds.UserName, $get_creds.Password)
}
}


function get_iDRAC_version 

{
$query_param = '?$select=FirmwareVersion'
$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1$query_param"
   if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}
$get_content = $result.Content | ConvertFrom-Json
$get_iDRAC_version = $get_content.FirmwareVersion.Split(".")[0]
$global:get_iDRAC_major_number = [int]$get_iDRAC_version
}


function get_job_queue
{
$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

if ($result.StatusCode -eq 200)
{
    #Write-Host "- PASS, GET request passed to get job queue"
}
else
{
    [String]::Format("`n- FAIL, GET request failed to get job queue, statuscode {0} returned",$result.StatusCode)
    return
}

$get_result=$result.Content | ConvertFrom-Json
$get_member_array = $get_result.Members

if ($get_member_array.count -gt 0)
{
Write-Host "`n- Complete job queue details for iDRAC $idrac_ip -`n"
Start-Sleep 5
}
else
{
Write-Host "`n- INFO, current iDRAC job queue is already cleared, no existing job IDs`n"
return
}



foreach ($i in $get_result.Members)
{
$odata="@odata.id"
$job_id_uri = $i.$odata
$uri = "https://$idrac_ip$job_id_uri"
    if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

$get_result=$result.Content | ConvertFrom-Json
$get_result
}


}


function delete_job_id 
{

if ($global:get_iDRAC_major_number -le 2)
{
$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/$delete_job_id"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Delete -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Delete -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Delete -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Delete -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}
   

    if ($result1.StatusCode -eq 200)
    {
    $status_code = $result1.StatusCode
    Write-Host "`n- PASS, DELETE action passed to delete job ID $delete_job_id"
    return
    }
    else
    {
    $status_code = $result1.StatusCode
    Write-Host "- FAIL, DELETE command failed to delete job ID URI $uri, status code $status_code returned"
    return
    }
    return
    }

$JsonBody = @{"JobID"=$delete_job_id} | ConvertTo-Json -Compress
$uri = "https://$idrac_ip/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($post_result.StatusCode -eq 200 -or $post_result.StatusCode -eq 200)
{
Write-Host "`n- PASS, POST command passed to successfully delete job ID $delete_job_id`n"
}
else
{
[String]::Format("- FAIL, POST command failed to delete job ID, statuscode {0} returned. Detail error message: {1}",$post_result.StatusCode, $post_result)
return
}
}

function delete_job_queue_restart_LC_services
{

if ($global:get_iDRAC_major_number -le 2)
{
Write-Host "`n- WARNING, this feature is not supported by Redfish for iDRAC 7/8"
return
}


Write-Host "`n- INFO, clearing job queue and restarting LC services for iDRAC $idrac_ip, this may take a few minutes for LC services to be back in ready state`n"
Start-Sleep 5
$JsonBody = @{"JobID"="JID_CLEARALL_FORCE"} | ConvertTo-Json -Compress
$uri = "https://$idrac_ip/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($post_result.StatusCode -eq 200 -or $post_result.StatusCode -eq 200)
{
Write-Host "- PASS, POST command passed to successfully clear the job queue and restart LC services.`n"
}
else
{
[String]::Format("- FAIL, POST command failed to clear job queue, statuscode {0} returned. Detail error message: {1}",$post_result.StatusCode, $post_result)
return
}

Start-Sleep 10
Write-Host "- INFO, script will now loop checking LC status until its back in Ready state`n"
$count = 0
while ($lc_status -ne "Ready")
{
if ($count -eq 30)
{
Write-Host "- FAIL, max retry count has been hit before detecting LC status is ready. Check iDRAC LC logs to debug issue"
return
}

$JsonBody = @{} | ConvertTo-Json -Compress
$uri = "https://$idrac_ip/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellLCService/Actions/DellLCService.GetRemoteServicesAPIStatus"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($post_result.StatusCode -eq 200 -or $post_result.StatusCode -eq 200)
{
#Write-Host "- PASS, POST command passed to get iDRAC remote service API status"
}
else
{
[String]::Format("- FAIL, POST command failed to get iDRAC remote service API status, statuscode {0} returned. Detail error message: {1}",$post_result.StatusCode, $post_result)
return
}

$get_post_result = $post_result.Content | ConvertFrom-Json
$lc_status = $get_post_result.LCStatus

Write-Host "- INFO, LC status not in ready state, checking status again"
$count++
Start-Sleep 10
}


$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

if ($result.StatusCode -eq 200)
{
    #Write-Host "- PASS, GET request passed to get job queue"
}
else
{
    [String]::Format("`n- FAIL, GET request failed to get job queue, statuscode {0} returned",$result.StatusCode)
    return
}

$get_result=$result.Content | ConvertFrom-Json
$get_member_array = $get_result.Members

if ($get_member_array.count -gt 0)
{
Write-Host "- FAIL, job ID not successfully cleared, manually check iDRAC job queue`n"
return
}
else
{
Write-Host "- PASS, iDRAC job queue successfully cleared and LC services back in Ready state`n"
return
}
}



function delete_job_queue 
{

if ($global:get_iDRAC_major_number -le 2)
{
Write-Host "`n- INFO, iDRAC 7/8 detected, this process may take several minutes to complete depending on how many jobs in the job queue"
$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

$get_result = $result.Content | ConvertFrom-Json
$odata = "@odata.id"
if ($get_result.Members.$odata.Count -eq 0)
{
Write-Host "`n- INFO, job queue empty, no jobs to delete"
return
}
foreach ($uri_index in $get_result.Members.$odata)
{
$uri = "https://$idrac_ip$uri_index"
if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Delete -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Delete -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Delete -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Delete -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}
   

    if ($result1.StatusCode -ne 200)
    {
    $status_code = $result1.StatusCode
    Write-Host "- FAIL, DELETE command failed to delete job ID URI $uri, status code $status_code returned"
    return
    }
    
}
Start-Sleep 10

$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

$get_result = $result.Content | ConvertFrom-Json
$odata = "@odata.id"

if ($get_result.Members.$odata.Count -eq 0)
{
Write-Host "`n- PASS, job queue successfully deleted"
}
else
{
Write-Host "- WARNING, job ID(s) still detected in job queue, please manually check the job queue and Lifecycle logs to debug the issue"
return
}

return
}

Write-Host "`n- INFO, clearing job queue for iDRAC $idrac_ip, this may take several minutes to complete depending on how many jobs are in the job queue`n"
Start-Sleep 5
$JsonBody = @{"JobID"="JID_CLEARALL"} | ConvertTo-Json -Compress
$uri = "https://$idrac_ip/redfish/v1/Dell/Managers/iDRAC.Embedded.1/DellJobService/Actions/DellJobService.DeleteJobQueue"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $post_result = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $post_result = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($post_result.StatusCode -eq 200 -or $post_result.StatusCode -eq 200)
{
Write-Host "- PASS, POST command passed to successfully clear the job queue`n"
}
else
{
[String]::Format("- FAIL, POST command failed to clear job queue, statuscode {0} returned. Detail error message: {1}",$post_result.StatusCode, $post_result)
return
}

Start-Sleep 10
$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1/Jobs"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

if ($result.StatusCode -eq 200)
{
    #Write-Host "- PASS, GET request passed to get job queue"
}
else
{
    [String]::Format("`n- FAIL, GET request failed to get job queue, statuscode {0} returned",$result.StatusCode)
    return
}

$get_result=$result.Content | ConvertFrom-Json
$get_member_array = $get_result.Members

if ($get_member_array.count -gt 0)
{
Write-Host "- FAIL, job ID not successfully cleared, manually check iDRAC job queue`n"
return
}
else
{
Write-Host "- PASS, iDRAC job queue successfully cleared`n"
return
}
}



# Run code

get_powershell_version
setup_idrac_creds
get_iDRAC_version


if ($get_job_queue)
{
get_job_queue
}
elseif ($delete_job_id)
{
delete_job_id
}
elseif ($delete_job_queue)
{
delete_job_queue
}
elseif ($delete_job_queue_restart_LC_services)
{
delete_job_queue_restart_LC_services
}
else
{
Write-Host "- FAIL, either missing or incorrect parameters passed in"
return
}


}







<#
_author_ = Texas Roemer <Texas_Roemer@Dell.com>
_version_ = 13.0

Copyright (c) 2020, Dell, Inc.

This software is licensed to you under the GNU General Public License,
version 2 (GPLv2). There is NO WARRANTY for this software, express or
implied, including the implied warranties of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. You should have received a copy of GPLv2
along with this software; if not, see
http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
#>

<#
.Synopsis
   iDRAC cmdlet using Redfish DMTF action SimpleUpdate to update device firmware using a firmware image stored locally.
.DESCRIPTION
   iDRAC cmdlet used to update firmware for one supported server device which uses a local image file. For updating devices, you will be using Dell Windows Update Packages (DUP) with .EXE extension. NOTE: If executing cmdlet on iDRAC 7/8, to download the firmware image, curl command will be used. If using iDRAC 9 or newer, Invoke-WebRequest command will be used. NOTE: Curl command is natively installed in newer versions of Windows (Examples: Windows 10 or Windows Server 2019). If using older version of Windows with iDRAC 7/8, please install curl command before executing the cmdlet. 

   Supported parameters to pass in for cmdlet:
   
   - idrac_ip: Pass in iDRAC IP
   - idrac_username: Pass in iDRAC username
   - idrac_password: Pass in iDRAC password
   - x_auth_token: Pass in iDRAC X-Auth token session to execute cmdlet instead of username / password (recommended)
   - image_directory_path: Pass in the directory path where the upload image is. Example: "C:\firmware_directory"
   - image_filename: Pass in the name of the upload image. Example: "H330_SAS-RAID_Firmware_03NXN_WN64_25.5.2.0001_A07.EXE"
   - reboot_server: Pass in "y" to automatically reboot the server to apply the update or "n" to not reboot the server. Passing in "n" means the update job will still get scheduled and will execute on next server manual reboot. NOTE: There are devices which perform an update immediately and devices that need a reboot to apply the update. For more details on this behavior, refer to Lifecycle Controller User Guide update section.
   - view_fw_inventory_only: this will return only the firmware inventory of devices on the system iDRAC supports for updates.

.EXAMPLE
   Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip 192.168.0.120 -idrac_username root -idrac_password calvin -view_fw_inventory_only 
   This example will only return Firmware inventory for all devices in the server. If needed, you can redirect output into a variable allowing you to get only specific properties.
.EXAMPLE
   Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip 192.168.0.120 -view_fw_inventory_only 
   This example will first prompt for iDRAC username/password using Get-Credential, then return Firmware inventory for all devices in the server.
.EXAMPLE
   Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip 192.168.0.120 -view_fw_inventory_only -x_auth_token 7bd9bb9a8727ec366a9cef5bc83b2708
   This example will only return Firmware inventory for all devices in the server using iDRAC X-auth token session. 
.EXAMPLE
   Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip 192.168.0.120 -idrac_username root -idrac_password calvin -image_directory_path C:\Downloads -image_filename BIOS_8G2RV_WN64_2.4.8.EXE -reboot_server y
   This example will download BIOS firmware and reboot the server now to perform the update 
.EXAMPLE
   Set-DeviceFirmwareSimpleUpdateREDFISH.ps1 -idrac_ip 192.168.0.120 -idrac_username root -idrac_password calvin -image_directory_path C:\Downloads -image_filename iDRAC-with-Lifecycle-Controller_Firmware_4JCPK_WN64_4.00.00.00_A00.EXE
   This example will update iDRAC firmware and get applied immediately. Since this device gets update immediately, no server reboot is needed.
.EXAMPLE
   Set-DeviceFirmwareSimpleUpdateREDFISH -idrac_ip 192.168.0.120 -idrac_username root -idrac_password calvin -image_directory_path C:\Downloads -image_filename BIOS_8G2RV_WN64_2.4.8.EXE -reboot_server n
   This example will download BIOS firmware and NOT reboot the server to apply the update. The update job will still get scheduled and will execute on next manual server reboot.
#>

function Set-DeviceFirmwareSimpleUpdateREDFISH {

# Required, optional parameters needed to be passed in when cmdlet is executed

param(
    [Parameter(Mandatory=$True)]
    [string]$idrac_ip,
    [Parameter(Mandatory=$False)]
    [string]$idrac_username,
    [Parameter(Mandatory=$False)]
    [string]$idrac_password,
    [Parameter(Mandatory=$False)]
    [string]$x_auth_token,
    [Parameter(Mandatory=$False)]
    [string]$image_directory_path,
    [Parameter(Mandatory=$False)]
    [string]$image_filename,
    [Parameter(Mandatory=$False)]
    [string]$reboot_server,
    [Parameter(Mandatory=$False)]
    [switch]$view_fw_inventory_only
    )


# Function to ignore SSL certs

function Ignore-SSLCertificates
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

# Function to set up iDRAC credentials 

function setup_idrac_creds
{

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::TLS12

if ($x_auth_token)
{
$global:x_auth_token = $x_auth_token
}
elseif ($idrac_username -and $idrac_password)
{
$user = $idrac_username
$pass= $idrac_password
$secpasswd = ConvertTo-SecureString $pass -AsPlainText -Force
$global:credential = New-Object System.Management.Automation.PSCredential($user, $secpasswd)
}
else
{
$get_creds = Get-Credential
$global:credential = New-Object System.Management.Automation.PSCredential($get_creds.UserName, $get_creds.Password)
}
}

$global:get_powershell_version = $null

function get_powershell_version 
{
$get_host_info = Get-Host
$major_number = $get_host_info.Version.Major
$global:get_powershell_version = $major_number
}

get_powershell_version


# Function get current firmware versions

function get_firmware_versions
{
Write-Host
Write-Host "--- Getting Firmware Inventory For iDRAC $idrac_ip ---"
Write-Host

$expand_query ='?$expand=*($levels=1)'
$uri = "https://$idrac_ip/redfish/v1/UpdateService/FirmwareInventory$expand_query"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}
    $get_fw_inventory = $result.Content | ConvertFrom-Json
    $get_fw_inventory.Members
    return
}

# Function download image payload

function download_image_payload
{

$uri = "https://$idrac_ip/redfish/v1/UpdateService/FirmwareInventory"

if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $get_result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    $ETag=[string]$get_result.Headers.ETag
    }
    else
    {
    Ignore-SSLCertificates
    $get_result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    $ETag=$get_result.Headers.ETag
    }
    }
    catch
    {
    $RespErr
    return
    }
}


else
{
try
{
if ($global:get_powershell_version -gt 5)
    {
    $get_result = Invoke-WebRequest -SkipCertificateCheck -Uri $uri -Credential $credential -Method Get -UseBasicParsing -Headers @{"Accept"="application/json"} -SkipHeaderValidation
    $ETag=[string]$get_result.Headers.ETag
    }
    else
    {
    Ignore-SSLCertificates
    $get_result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    $ETag=$get_result.Headers.ETag
    }
}
catch
{
Write-Host
$RespErr
break
}
}

$uri = "https://$idrac_ip/redfish/v1/Managers/iDRAC.Embedded.1"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

$get_content = $result.Content | ConvertFrom-Json
if ($get_content.Model.Contains("12G") -or $get_content.Model.Contains("13G"))
{

Write-Host "`n- INFO, downloading firmware package payload to iDRAC, this may take a few minutes depending of the size of the image.`n"

$FilePath = $image_directory_path + "\" + $image_filename
$CurlExecutable = "curl.exe"
$idrac_username_password = $idrac_username+":"+$idrac_password 
$execute_post_output = & $CurlExecutable --request POST https://$idrac_ip/redfish/v1/UpdateService/FirmwareInventory --header "If-Match: $ETag" --header "content-type: multipart/form-data" --form file=@$FilePath --insecure -u $idrac_username_password
$execute_post_output = [string]$execute_post_output
$get_version = [regex]::Match($execute_post_output, 'Available.+?,').captures.groups[0].value
$get_version = $get_version.Replace(",","")
$get_version = $get_version.Replace('"',"")
$global:available_entry = "/redfish/v1/UpdateService/FirmwareInventory/"+$get_version


if ($execute_post_output.Contains("Package successfully downloaded"))
{
Write-Host "`n- INFO, package firmware successfully downloaded"
}
else
{
Write-Host "- FAIL, firmware package failed to download, detailed error results:"
$execute_post_output
exit
}

}


else
{
Write-Host "`n- INFO, downloading firmware package payload to iDRAC, this may take a few minutes depending of the size of the image.`n"

$uri = "https://$idrac_ip/redfish/v1/UpdateService/FirmwareInventory"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $get_result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    $ETag=[string]$get_result.Headers.ETag
    }
    else
    {
    Ignore-SSLCertificates
    $get_result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    $ETag=$get_result.Headers.ETag
    }
    }
    catch
    {
    $RespErr
    return
    }
}


else
{
try
{
if ($global:get_powershell_version -gt 5)
    {
    $get_result = Invoke-WebRequest -SkipCertificateCheck -Uri $uri -Credential $credential -Method Get -UseBasicParsing -Headers @{"Accept"="application/json"} -SkipHeaderValidation
    $ETag=[string]$get_result.Headers.ETag
    }
    else
    {
    Ignore-SSLCertificates
    $get_result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    $ETag=$get_result.Headers.ETag
    }
}
catch
{
Write-Host
$RespErr
break
}
}


$complete_path=$image_directory_path + "\" + $image_filename
$headers = @{"If-Match" = $ETag; "Accept"="application/json"}


# Code to read the image file for download to the iDRAC

$CODEPAGE = "iso-8859-1"
$fileBin = [System.IO.File]::ReadAllBytes($complete_path)
$enc = [System.Text.Encoding]::GetEncoding($CODEPAGE)
$fileEnc = $enc.GetString($fileBin)
$boundary = [System.Guid]::NewGuid().ToString()

$LF = "`r`n"
$body = (
        "--$boundary",
        "Content-Disposition: form-data; name=`"file`"; filename=`"$image_filename`"",
		"Content-Type: application/octet-stream$LF",
        $fileEnc,
        "--$boundary--$LF"
) -join $LF


# POST command to download the image payload to the iDRAC


try
{
    if ($global:get_powershell_version -gt 5)
    { 
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -ContentType "multipart/form-data; boundary=`"$boundary`"" -Headers $headers -SkipHeaderValidation -SkipHttpErrorCheck -Body $body -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -ContentType "multipart/form-data; boundary=`"$boundary`"" -Headers $headers -Body $body -ErrorVariable RespErr
    }
}
catch
{
Write-Host
$RespErr
break
} 



if ($result1.StatusCode -eq 201)
{
    [String]::Format("- PASS, statuscode {0} returned successfully for POST command to download payload image to iDRAC",$result1.StatusCode)
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned. Detail error message: {1}",$result1.StatusCode,$result1)
    return
}

$get_content=$result1.Content
$global:available_entry = $result1.Headers['Location']
}


}

#function to reboot the server to apply the firmware

function reboot_server
{
$uri = "https://$idrac_ip/redfish/v1/Systems/System.Embedded.1/"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

if ($result.StatusCode -eq 200)
{
    Write-Host
    [String]::Format("- PASS, statuscode {0} returned successfully to get current power state",$result.StatusCode)
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned",$result.StatusCode)
    break
}

$result_output = $result.Content | ConvertFrom-Json
$power_state = $result_output.PowerState

if ($power_state -eq "On")
{
Write-Host "- INFO, Server current power state is ON, performing graceful shutdown"



$JsonBody = @{ "ResetType" = "GracefulShutdown"
    } | ConvertTo-Json -Compress


$uri = "https://$idrac_ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($result1.StatusCode -eq 204)
{
    [String]::Format("- PASS, statuscode {0} returned to attempt graceful server shutdown",$result1.StatusCode)
    Start-Sleep 15
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned",$result1.StatusCode)
    break
}

$count = 1
while($true)
{
$uri = "https://$idrac_ip/redfish/v1/Systems/System.Embedded.1/"
if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

$result_output = $result.Content | ConvertFrom-Json
$power_state = $result_output.PowerState

if ($power_state -eq "Off")
{
Write-Host "- PASS, validated server in OFF state"
break
}
elseif ($count -eq 5)
{
Write-Host "- INFO, server did not accept graceful shutdown request, performing force off"

$JsonBody = @{ "ResetType" = "ForceOff"
    } | ConvertTo-Json -Compress


$uri = "https://$idrac_ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($result1.StatusCode -eq 204)
{
    [String]::Format("- PASS, statuscode {0} returned to force power OFF the server",$result1.StatusCode)
    Start-Sleep 15
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned",$result1.StatusCode)
    break
}

}
else
{
Write-Host "- INFO, server still in ON state waiting for graceful shutdown to complete, will check server status again in 1 minute"
$count++
Start-Sleep 60
continue
}
}

$JsonBody = @{ "ResetType" = "On"
    } | ConvertTo-Json -Compress

$uri = "https://$idrac_ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($result1.StatusCode -eq 204)
{
    [String]::Format("- PASS, statuscode {0} returned successfully to power ON the server",$result1.StatusCode)
    $power_state = "On"
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned",$result1.StatusCode)
    break
}
}


if ($power_state -eq "Off")
{
$JsonBody = @{ "ResetType" = "On"
    } | ConvertTo-Json -Compress


$uri = "https://$idrac_ip/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

# POST command to power ON the server

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result1 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result1 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}

if ($result1.StatusCode -eq 204)
{
    [String]::Format("- PASS, statuscode {0} returned successfully to power ON the server",$result1.StatusCode)
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned",$result1.StatusCode)
    break
}
}
}

# Function install image payload, query job status, reboot server

function install_image_payload_query_job_status_reboot_server

{

$uri = "https://$idrac_ip/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate"
$image_uri = [string]$global:available_entry
$JsonBody = @{'ImageURI'= $image_uri} | ConvertTo-Json -Compress

if ($x_auth_token)
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result2 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result2 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}


else
{
try
    {
    if ($global:get_powershell_version -gt 5)
    {
    
    $result2 = Invoke-WebRequest -UseBasicParsing -SkipHeaderValidation -SkipCertificateCheck -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    else
    {
    Ignore-SSLCertificates
    $result2 = Invoke-WebRequest -UseBasicParsing -Uri $uri -Credential $credential -Method Post -Body $JsonBody -ContentType 'application/json' -Headers @{"Accept"="application/json"} -ErrorVariable RespErr
    }
    }
    catch
    {
    Write-Host
    $RespErr
    return
    } 
}
 

if ($result2.StatusCode -eq 202)
{
    $job_id_search=$result2.Headers['Location']
    $job_id=$job_id_search.Split("/")[-1]
    [String]::Format("- PASS, statuscode {0} returned successfully for POST command to create update job ID {1}",$result2.StatusCode, $job_id)
    Write-Host
}
else
{
    [String]::Format("- FAIL, statuscode {0} returned. Detail error message: {1}",$result2.StatusCode,$result2)
    break
}

# Loop job status until marked completed or scheduled 

$get_time_old = Get-Date -DisplayHint Time
$start_time = Get-Date
$end_time = $start_time.AddMinutes(30)
$force_count=0
Write-Host "- INFO, script will now loop polling the job status every 5 seconds until marked either scheduled or completed`n"
while ($true)
{
#$loop_time = Get-Date

$uri ="https://$idrac_ip/redfish/v1/TaskService/Tasks/$job_id"

if ($x_auth_token)
{
 try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept" = "application/json"; "X-Auth-Token" = $x_auth_token}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"; "X-Auth-Token" = $x_auth_token}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

else
{
    try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    $RespErr
    return
    }
}

$overall_job_output=$result.Content | ConvertFrom-Json

if ($overall_job_output.Messages.Message.Contains("Lifecycle Controller in use") -or $overall_job_output.Messages.Message.Contains("Fail") -or $overall_job_output.Messages.Message.Contains("Failed") -or $overall_job_output.Messages.Message.Contains("fail") -or $overall_job_output.Messages.Message.Contains("failed") -or $overall_job_output.Messages.Message.Contains("Job for this device is already present") -or $overall_job_output.Messages.Message.Contains("Unable") -or $overall_job_output.Messages.Message.Contains("unable"))
{
Write-Host
[String]::Format("- FAIL, job id $job_id marked as failed, error message: {0}",$overall_job_output.Messages.Message)
return
}
elseif ($loop_time -gt $end_time)
{
Write-Host "- FAIL, timeout of 30 minutes has been reached before marking the job completed"
return
}

if ($overall_job_output.TaskState -eq "UserIntervention" -and $overall_job_output.PercentComplete -eq 100)
{
$pending_message = $overall_job_output.Messages.Message
Write-Host "- INFO, job ID $job_id marked completed but user invention is needed, final job message: $pending_message"

    if ($reboot_server.ToLower() -eq "y")
    {
        if ($overall_job_output.Messages.Message.ToLower().Contains("reboot"))
        {
        Write-Host "- INFO, user selected to reboot the server now for the new firmware to become effective"
        reboot_server
        return
        }
        elseif ($overall_job_output.Messages.Message.ToLower().Contains("virtual"))
        {
        Write-Host "- INFO, server virtual a/c cycle is needed for the new firmware installed to become effective"
        return
        }
    }
    elseif ($reboot_server.ToLower() -eq "n")
    {
    Write-Host "- INFO, user selected to not reboot the server now but reboot server is still needed for new firmware installed to become effective"
    return
    }
    else
    {
    Write-Host "- WARNING, -reboot_server argument not detected, refer to final job status message to complete the firmware update process"
    return
    }

}


elseif ($overall_job_output.Messages.Message -eq "Task successfully scheduled.")
{ 
    if ($schedule_job_status_count -eq 1)
    {
    Start-Sleep 15
    $schedule_job_status_count += 1
    continue
    }
    else
    {
    Write-Host "`n- PASS, job ID '$job_id' successfully marked as scheduled"
    $job_completed = "no"
    break
    }
}

elseif ($overall_job_output.Messages.Message -eq "The specified job has completed successfully." -or $overall_job_output.Messages.Message -eq  "Job completed successfully." -or $overall_job_output.Messages.Message.Contains("complete"))
{
$get_current_time = Get-Date -DisplayHint Time
$final_time = $get_current_time-$get_time_old
$final_completion_time = $final_time | select Minutes,Seconds
Write-Host "`n- PASS, job ID '$job_id' successfully marked as completed"
Write-Host "`nFirmware update job execution time:"
$final_completion_time
return
}
else
{
$job_query_message = $overall_job_output.Messages.Message
Write-Host "- Job ID '$job_id' not marked completed, current status: $job_query_message"
Start-Sleep 5
}

}

# Reboot server

if ($reboot_server.ToLower() -eq "n" -and $job_completed -eq "no")
{
Write-Host "- INFO, user selected to not automatically reboot the server. Update job is scheduled and will be applied on next server manual reboot"
break
}

elseif ($reboot_server.ToLower() -eq "y" -and $job_completed -eq "yes")
{
Write-Host "- INFO, no server reboot is needed since job ID is already marked completed, immediate update was performed"
break
}

elseif ($reboot_server.ToLower() -eq "y")
{
Write-Host "- INFO, user selected to reboot the server now to apply the firmware update"
reboot_server
}


# Loop job status until marked completed 

$get_time_old = Get-Date -DisplayHint Time
$start_time = Get-Date
$end_time = $start_time.AddMinutes(50)
$force_count=0
Write-Host "- INFO, script will now loop polling the job status every 30 seconds until marked completed`n"
while ($true)
{
$loop_time = Get-Date
$uri ="https://$idrac_ip/redfish/v1/TaskService/Tasks/$job_id"

try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    Write-Host
    $RespErr
    break
    }

$overall_job_output=$result.Content | ConvertFrom-Json
$current_job_message = "$overall_job_output.Messages.Message"

if ($overall_job_output.Messages.Message.Contains("Fail") -or $overall_job_output.Messages.Message.Contains("Failed") -or $overall_job_output.Messages.Message.Contains("fail") -or $overall_job_output.Messages.Message.Contains("failed"))
{
Write-Host
[String]::Format("- FAIL, job id $job_id marked as failed, error message: {0}",$overall_job_output.Messages.Message)
break
}
elseif ($loop_time -gt $end_time)
{
Write-Host "- FAIL, timeout of 50 minutes has been reached before marking the job completed"
break
}
elseif ($overall_job_output.Messages.Message -eq "The specified job has completed successfully." -or $overall_job_output.Messages.Message -eq  "Job completed successfully." -or $overall_job_output.Messages.Message.Contains("complete"))
{
$get_current_time=Get-Date -DisplayHint Time
$final_time=$get_current_time-$get_time_old
$final_completion_time=$final_time | select Minutes,Seconds
Write-Host "`n- PASS, job ID '$job_id' successfully marked as completed"
Write-Host "`nFirmware update job execution time:"
$final_completion_time
break
}
else
{
Write-Host "- Job ID '$job_id' not marked completed, checking job status again"
Start-Sleep 30
}

}

}

# Run cmdlet

get_powershell_version
setup_idrac_creds

# Code to check for supported iDRAC version installed

$query_parameter = "?`$expand=*(`$levels=1)" 
$uri = "https://$idrac_ip/redfish/v1/UpdateService/FirmwareInventory$query_parameter"

try
    {
    if ($global:get_powershell_version -gt 5)
    {
    $result = Invoke-WebRequest -SkipCertificateCheck -SkipHeaderValidation -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    else
    {
    Ignore-SSLCertificates
    $result = Invoke-WebRequest -Uri $uri -Credential $credential -Method Get -UseBasicParsing -ErrorVariable RespErr -Headers @{"Accept"="application/json"}
    }
    }
    catch
    {
    Write-Host "`n- INFO, iDRAC version detected does not support this feature using Redfish API or incorrect iDRAC user credentials passed in.`n"
    $RespErr
    return
    }



if ($view_fw_inventory_only)
{
get_firmware_versions
}

elseif ($image_directory_path -and $image_filename)
{
download_image_payload
install_image_payload_query_job_status_reboot_server
}

else
{
Write-Host "- FAIL, either incorrect parameter(s) used or missing required parameters(s)"
}


}














