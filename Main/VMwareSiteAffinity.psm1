#Requires -Version 5.1

$ModuleRoot = $PSScriptRoot
if (-not $ModuleRoot) {
    try { $ModuleRoot = $ExecutionContext.SessionState.Module.ModuleBase } catch {}
}

$privateFiles = @(
    'Private\VmwarePathHelpers.ps1',
    'Private\Write-VMwareLog.ps1',
    'Private\VmwareCredentialHelpers.ps1',
    'Private\Show-VMwareMigrationInputDialog.ps1',
    'Private\Get-VMwareMigrationPlan.ps1'
)

foreach ($rel in $privateFiles) {
    $path = Join-Path $ModuleRoot $rel
    if (Test-Path -LiteralPath $path) { . $path } else { Write-Warning "[VMwareSiteAffinity] Missing private file: $path" }
}

$publicFiles = @(
    'Public\Connect-VMwareVC.ps1',
    'Public\Invoke-VMwareSiteAffinityMigration.ps1',
    'Public\Get-VMwareMigrationReport.ps1'
)
$exported = @()
foreach ($rel in $publicFiles) {
    $path = Join-Path $ModuleRoot $rel
    if (Test-Path -LiteralPath $path) {
        . $path
        $names = Select-String -LiteralPath $path -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        $exported += $names
    } else {
        Write-Warning "[VMwareSiteAffinity] Missing public file: $path"
    }
}

if (-not $Global:VMwareSessions) { $Global:VMwareSessions = @{} }
if (-not $Global:VMwareSACache)  { $Global:VMwareSACache  = @{} }

Export-ModuleMember -Function $exported
