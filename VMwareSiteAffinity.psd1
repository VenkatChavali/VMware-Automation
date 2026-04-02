@{
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Venkat Praveen Kumar Chavali'
    Description       = 'VMware DRS site affinity change and vMotion automation with manual batch dispatch'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @(
        'Connect-VMwareVC'
        'Disconnect-VMwareVC'
        'Get-VMwareVC'
        'Invoke-VMwareSiteAffinityMigration'
        'Get-VMwareMigrationReport'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('VMware','vSphere','DRS','vMotion','SiteAffinity')
        }
    }
}
