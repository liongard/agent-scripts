<#
.SYNOPSIS
Self-contained test for LGAgentIdentity.ps1. Uses only HKCU:\Software\LiongardIdentityTest and a temp folder.
#>
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

$Script = Join-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'windows') 'LGAgentIdentity.ps1'
$Exe = (Get-Process -Id $PID).Path
$TestKey = 'Software\LiongardIdentityTest'
$Root = "HKCU:\$TestKey"
$Temp = Join-Path ([IO.Path]::GetTempPath()) ("liongard-identity-test-" + [Guid]::NewGuid().ToString('N'))
$OsGuid = '11111111-2222-3333-4444-555555555555'
$AgentGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$OtherGuid = '99999999-8888-7777-6666-555555555555'
$FakeSecret = 'FAKE-SECRET-DO-NOT-PRINT'
$script:Failures = 0
$script:Passes = 0

function Assert([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:Passes++; Write-Host "PASS  $Name" }
    else { $script:Failures++; Write-Host "FAIL  $Name $Detail" -ForegroundColor Red }
}

function Invoke-Tool([string[]]$Arguments) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments + @('-RegistryRoot', $Root)
    $output = & $Exe @all 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
}

function Open-TestKey([string]$SubPath) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry32)
    return $base.CreateSubKey("$TestKey\$SubPath")
}

function Set-TestValue([string]$SubPath, [string]$Name, [string]$Value) {
    $key = Open-TestKey $SubPath
    try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Close() }
}

function Get-TestAgentGuid {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry32)
    $key = $base.OpenSubKey("$TestKey\Software\Liongard\LiongardAgent\MachineID")
    if ($null -eq $key) { return $null }
    try { return $key.GetValue('AgentGuid') } finally { $key.Close() }
}

function Reset-State([string]$WithAgentGuid) {
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Set-TestValue 'SOFTWARE\Microsoft\Cryptography' 'MachineGuid' $OsGuid
    if ($WithAgentGuid) { Set-TestValue 'Software\Liongard\LiongardAgent\MachineID' 'AgentGuid' $WithAgentGuid }
}

function Get-BackupDir([string]$Parent) {
    return @(Get-ChildItem -LiteralPath $Parent -Directory | Where-Object { $_.Name -like 'liongard-identity-*' })[0].FullName
}

function New-Backup([string]$Name, [string]$WithAgentGuid) {
    Reset-State $WithAgentGuid
    $parent = Join-Path $Temp $Name
    New-Item -ItemType Directory -Path $parent | Out-Null
    $r = Invoke-Tool @('-Action', 'Backup', '-OutputPath', $parent)
    if ($r.Code -ne 0) { throw "Backup for $Name failed: $($r.Output)" }
    return Get-BackupDir $parent
}

function Set-ManifestValue([string]$Dir, [string]$Name, [string]$Value) {
    $path = Join-Path $Dir 'manifest.txt'
    $lines = [IO.File]::ReadAllLines($path) | ForEach-Object { if ($_ -like "$Name=*") { "$Name=$Value" } else { $_ } }
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"))
}

function Get-FileSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

New-Item -ItemType Directory -Path $Temp | Out-Null
try {
    # Backup with AgentGuid, plus a fake install whose config holds a secret that must never be copied.
    Reset-State '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
    $install = Join-Path $Temp 'install'
    New-Item -ItemType Directory -Path $install | Out-Null
    [IO.File]::WriteAllText((Join-Path $install 'appsettings-override.config'),
        "<appSettings>`n  <add key=`"URL`" value=`"acme.app.liongard.com`" />`n  <add key=`"AGENT_ID`" value=`"4242`" />`n  <add key=`"AGENT_NAME`" value=`"acme-dc01`" />`n  <add key=`"AWS_SECRET_ACCESS_KEY`" value=`"$FakeSecret`" />`n</appSettings>`n")
    Set-TestValue 'Software\Liongard\RoarAgent' 'INSTALLLOCATION' "$install\"
    Set-TestValue 'Software\Liongard\RoarAgent' 'ProductVersion' '5.5.0'
    $parent = Join-Path $Temp 'b1'
    New-Item -ItemType Directory -Path $parent | Out-Null
    $r = Invoke-Tool @('-Action', 'Backup', '-OutputPath', $parent)
    Assert ($r.Code -eq 0) 'backup with AgentGuid exits 0' $r.Output
    $dir = Get-BackupDir $parent
    $guidText = ([IO.File]::ReadAllText((Join-Path $dir 'machine-guid.txt'))).Trim()
    $manifest = [IO.File]::ReadAllText((Join-Path $dir 'manifest.txt'))
    Assert ($guidText -eq $AgentGuid) 'backup saves the normalized AgentGuid' $guidText
    Assert ($manifest -match '(?m)^identity_source=agent_guid$') 'manifest identity_source=agent_guid'
    Assert ($manifest -match '(?m)^os=windows$' -and $manifest -match '(?m)^format_version=1$') 'manifest os and format_version'
    Assert ($manifest -match '(?m)^agent_id=4242$' -and $manifest -match '(?m)^agent_name=acme-dc01$' -and $manifest -match '(?m)^url=acme.app.liongard.com$') 'manifest non-secret fields'
    Assert ($manifest -match '(?m)^agent_version=5\.5\.0$') 'manifest agent_version'
    Assert ($manifest -match "(?m)^sha256_machine_guid=$(Get-FileSha (Join-Path $dir 'machine-guid.txt'))$") 'manifest sha256 matches'
    Assert (-not ($manifest + $r.Output).Contains($FakeSecret)) 'no secret in manifest or output'
    $acl = Get-Acl -LiteralPath $dir
    Assert ($acl.AreAccessRulesProtected -and @($acl.Access).Count -eq 2) 'backup folder ACL is private' (@($acl.Access | ForEach-Object { $_.IdentityReference }) -join ',')

    $r = Invoke-Tool @('-Action', 'Show')
    Assert ($r.Code -eq 0 -and $r.Output -match "identity=$AgentGuid") 'show prints identity' $r.Output
    Assert (-not $r.Output.Contains($FakeSecret)) 'show prints no secret'

    $r = Invoke-Tool @('-Action', 'Restore', '-From', $dir)
    Assert ($r.Code -eq 1 -and $r.Output -match 'installed') 'restore refused while the agent is installed' $r.Output

    # Fallback: no AgentGuid, so the Windows MachineGuid is used with a warning.
    Reset-State $null
    $parent = Join-Path $Temp 'b2'
    New-Item -ItemType Directory -Path $parent | Out-Null
    $r = Invoke-Tool @('-Action', 'Backup', '-OutputPath', $parent)
    $dir = Get-BackupDir $parent
    Assert ($r.Code -eq 0) 'fallback backup exits 0' $r.Output
    Assert ($r.Output -match 'WARNING' -and $r.Output -match 'No AgentGuid exists') 'fallback prints a warning' $r.Output
    Assert (([IO.File]::ReadAllText((Join-Path $dir 'machine-guid.txt'))).Trim() -eq $OsGuid) 'fallback saves the Windows MachineGuid'
    Assert ([IO.File]::ReadAllText((Join-Path $dir 'manifest.txt')) -match '(?m)^identity_source=windows_machine_guid$') 'fallback identity_source'

    $good = New-Backup 'good' $AgentGuid

    Reset-State $null
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $good)
    Assert ($r.Code -eq 0) 'restore on a clean host exits 0' $r.Output
    Assert ((Get-TestAgentGuid) -eq $AgentGuid) 'restore writes AgentGuid'
    Assert ($r.Output -match "DeviceGuid=$AgentGuid" -and $r.Output -match '/install') 'restore prints the DeviceGuid route'
    Assert ($r.Output -match 'deleted Agent record' -and $r.Output -match 'environment') 'restore prints the re-attach caveats'

    $r = Invoke-Tool @('-Action', 'Restore', '-From', $good)
    Assert ($r.Code -eq 0 -and $r.Output -match 'already holds') 'restore with the same AgentGuid is a no-op' $r.Output

    Reset-State $OtherGuid
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $good)
    Assert ($r.Code -eq 1) 'restore refused when AgentGuid differs' $r.Output
    Assert ((Get-TestAgentGuid) -eq $OtherGuid) 'refused restore leaves AgentGuid unchanged'

    $r = Invoke-Tool @('-Action', 'Restore', '-From', $good, '-Force')
    Assert ($r.Code -eq 0 -and (Get-TestAgentGuid) -eq $AgentGuid) 'restore -Force replaces a different AgentGuid' $r.Output

    Reset-State $null
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $good, '-DryRun')
    Assert ($r.Code -eq 0 -and $r.Output -match 'Dry run') 'restore -DryRun exits 0' $r.Output
    Assert ($null -eq (Get-TestAgentGuid)) 'restore -DryRun writes nothing'

    Set-TestValue 'SYSTEM\CurrentControlSet\Services\roaragent.exe' 'ImagePath' 'C:\fake\LiongardAgent.exe'
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $good)
    Assert ($r.Code -eq 1 -and $null -eq (Get-TestAgentGuid)) 'restore refused when the service exists' $r.Output
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $good, '-Force')
    Assert ($r.Code -eq 0 -and (Get-TestAgentGuid) -eq $AgentGuid) 'restore -Force proceeds when the service exists' $r.Output

    $tampered = New-Backup 'tamper' $AgentGuid
    [IO.File]::WriteAllText((Join-Path $tampered 'machine-guid.txt'), "$OtherGuid`n")
    Reset-State $null
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $tampered)
    Assert ($r.Code -eq 1 -and $r.Output -match 'Checksum mismatch' -and $null -eq (Get-TestAgentGuid)) 'checksum tamper is refused' $r.Output

    $wrongOs = New-Backup 'wrongos' $AgentGuid
    Set-ManifestValue $wrongOs 'os' 'linux'
    Reset-State $null
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $wrongOs)
    Assert ($r.Code -eq 1 -and $r.Output -match 'not windows' -and $null -eq (Get-TestAgentGuid)) 'wrong os is refused' $r.Output

    $invalid = New-Backup 'invalid' $AgentGuid
    $guidFile = Join-Path $invalid 'machine-guid.txt'
    [IO.File]::WriteAllText($guidFile, "not-a-guid`n")
    Set-ManifestValue $invalid 'sha256_machine_guid' (Get-FileSha $guidFile)
    Reset-State $null
    $r = Invoke-Tool @('-Action', 'Restore', '-From', $invalid)
    Assert ($r.Code -eq 1 -and $r.Output -match 'not a valid GUID' -and $null -eq (Get-TestAgentGuid)) 'invalid GUID is refused' $r.Output

    $r = Invoke-Tool @()
    Assert ($r.Code -eq 2) 'missing -Action is a usage error' $r.Output
    $r = Invoke-Tool @('-Action', 'Bogus')
    Assert ($r.Code -eq 2) 'unknown -Action is a usage error' $r.Output
    $r = Invoke-Tool @('-Action', 'Restore')
    Assert ($r.Code -eq 2) 'restore without -From is a usage error' $r.Output
} catch {
    $script:Failures++
    Write-Host "FAIL  unexpected: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$($script:Passes) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
