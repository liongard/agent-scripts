# Tests the Windows install-state rules and the environment check with mocked registry, services and API.
# Usage: pwsh -NoProfile -File tests/Test-InstallState.ps1
$windows = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows'

function Import-LiongardFunction([string]$File, [string[]]$Names) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $windows $File), [ref]$null, [ref]$null)
    foreach ($name in $Names) {
        $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name }, $true) | Select-Object -First 1
        if (-not $fn) { throw "Function $name not found in $File" }
        Invoke-Expression ($fn.Extent.Text -replace '^function ', 'function global:')
    }
}

$script:pass = 0; $script:fail = 0
function Test-Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:pass++; Write-Output "ok    $Name" } else { $script:fail++; Write-Output "FAIL  $Name" }
}
function Write-Host { }
function Write-Warning { }
function Write-LiongardStateLog { }
function Write-LGLog { }

# Shared install-state block (Advanced and Uninstall scripts).
Import-LiongardFunction 'LGAgentInstall-MSI-Advanced.ps1' 'Get-LiongardInstallState'
$script:LiongardInstallRoots = @('/nonexistent/LiongardInc')
$script:LiongardUpdaterTaskName = '\Liongard\LiongardAgentUpdater'
function Test-LiongardUpdaterTask { $script:Task }
function Get-LiongardInstallFolders { @($script:Folders) }
function Get-LiongardInstalledProduct { @($script:Products) }
function Get-LiongardServiceInfo { $script:Service }
function Set-Fixture($Products, $Exists, $Status, $Binary, $Folders = @(), $Task = $false) {
    $script:Products = $Products; $script:Folders = $Folders; $script:Task = $Task
    $script:Service = [pscustomobject]@{ Name = 'roaragent.exe'; Exists = $Exists; Status = $Status; ImagePath = 'x'; BinaryExists = $Binary }
}
$product = [pscustomobject]@{ DisplayName = 'Liongard Agent'; DisplayVersion = '5.5.0'; ProductCode = '{X}'; IsBundle = $false; IsLegacyFallback = $false; KeyPath = 'k' }
Set-Fixture @($product) $true 'Running' $true
Test-Check 'Advanced: entry, running service and binary is Healthy' ((Get-LiongardInstallState).State -eq 'Healthy')
Set-Fixture @($product) $true 'Stopped' $true
Test-Check 'Advanced: a stopped service is Stale (was Healthy before)' ((Get-LiongardInstallState).State -eq 'Stale')
Set-Fixture @() $false '' $false @('C:\Program Files (x86)\LiongardInc\LiongardAgent')
Test-Check 'Advanced: a folder only is Stale' ((Get-LiongardInstallState).State -eq 'Stale')
Set-Fixture @() $false '' $false
Test-Check 'Advanced: nothing present is NotInstalled' ((Get-LiongardInstallState).State -eq 'NotInstalled')

# The compact rules in the Simple scripts.
foreach ($file in 'LGAgentInstall-MSI-Simple.ps1', 'LGAgentInstall-EXE-Simple.ps1') {
    Import-LiongardFunction $file 'Get-LGState'
    $global:Roots = @('/nonexistent/LiongardInc')
    function global:Get-LGProduct { @($script:Products) }
    function global:Get-LGServiceInfo { $script:Service }
    function global:Get-LGFolder { @($script:Folders) }
    Set-Fixture @([pscustomobject]@{ Key = '{X}'; Code = '{X}'; Version = '5.5.0'; Location = ''; Bundle = $false }) $true 'Running' $true
    Test-Check "${file}: running agent is Healthy" ((Get-LGState).State -eq 'Healthy')
    Set-Fixture @([pscustomobject]@{ Key = '{X}'; Code = '{X}'; Version = '5.5.0'; Location = ''; Bundle = $false }) $true 'Stopped' $true
    Test-Check "${file}: stopped agent is Stale" ((Get-LGState).State -eq 'Stale')
    Set-Fixture @() $false '' $false
    Test-Check "${file}: nothing present is NotInstalled" ((Get-LGState).State -eq 'NotInstalled')

    $text = Get-Content -LiteralPath (Join-Path $windows $file) -Raw
    $main = $text.Substring($text.IndexOf('# ---- Main ----'))
    Test-Check "${file}: Stale exits 8 before the download" ($main.IndexOf('Exit-LG 8') -gt 0 -and $main.IndexOf('Exit-LG 8') -lt $main.IndexOf('Invoke-WebRequest'))
    Test-Check "${file}: no cleanup code remains" ($text -notmatch 'Invoke-LGStaleCleanup|sc\.exe delete|msiexec\.exe -ArgumentList .?/x')
    Test-Check "${file}: unreadable versions exit 5" ($main -match "can't be compared")
}

# Environment check (shared block in both Advanced scripts).
Import-LiongardFunction 'LGAgentInstall-MSI-Advanced.ps1' 'ConvertTo-LiongardEnvironmentKey', 'Resolve-LiongardEnvironment'
$script:EnvResponse = $null
function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec, $ErrorAction) if ($script:EnvFail) { throw 'mocked failure' }; return ,$script:EnvResponse }
function Test-Env([string]$Name, [string]$Given, [string[]]$Envs, [string]$WantStatus, [string]$WantName = $null, [string]$WantReason = $null) {
    $script:EnvResponse = @($Envs | ForEach-Object { [pscustomobject]@{ ID = 1; Name = $_ } })
    $r = Resolve-LiongardEnvironment -InputName $Given -Uri 'https://mock/api/v1/environments' -Headers @{}
    $ok = $r.Status -eq $WantStatus -and (-not $WantName -or $r.Name -ceq $WantName) -and (-not $WantReason -or $r.Reason -eq $WantReason)
    Test-Check "environment: $Name ($($r.Status) $($r.Name) $($r.Reason))" $ok
}
$script:EnvFail = $false
Test-Env 'exact match' 'Acme' 'Acme', 'ACME Two' 'Found' 'Acme' 'Exact'
Test-Env 'case-insensitive match' 'ACME' 'Acme', 'Other' 'Found' 'Acme' 'CaseInsensitive'
Test-Env 'normalized match' 'acme inc' 'Acme, Inc.', 'Other' 'Found' 'Acme, Inc.' 'Normalized'
Test-Env 'accented normalized match' 'Cafe & Bar' 'Café and Bar' 'Found' 'Café and Bar' 'Normalized'
Test-Env 'prefix match with 6+ characters' 'Acme Corp' 'Acme Corporation Ltd', 'Other' 'Found' 'Acme Corporation Ltd' 'Prefix'
Test-Env 'contains match with 6+ characters' 'Holdings' 'Big Holdings Group', 'Other' 'Found' 'Big Holdings Group' 'Contains'
Test-Env 'short names never partially match' 'Smith' 'IT', 'Smith IT Services' 'NotFound'
Test-Env 'two prefix matches are ambiguous' 'SmithIT' 'Smith IT Services', 'Smith IT Solutions' 'Ambiguous' $null 'AmbiguousPrefix'
Test-Env 'no environments returned is not found' 'Acme' @() 'NotFound'
$script:EnvFail = $true
Test-Env 'a failed lookup is LookupFailed, never a pass' 'Acme' 'Acme' 'LookupFailed'
$script:EnvFail = $false

Write-Output "$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
