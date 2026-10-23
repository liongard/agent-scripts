# Tests LGAgentUninstall-Advanced.ps1's identity collection and platform-record removal against a mocked registry and API.
# Usage: pwsh -NoProfile -File tests/Test-RemoteDeletion.ps1 [-Script <path to LGAgentUninstall-Advanced.ps1>]
param([string]$Script = (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows') 'LGAgentUninstall-Advanced.ps1'))

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script), [ref]$null, [ref]$null)
$names = 'Get-ObjectPropertyValue', 'Get-LiongardRestResult', 'Invoke-LiongardApiGet', 'Get-LiongardAgentsFiltered', 'Get-LiongardQueryForm',
    'Get-LiongardGuidQueryForm', 'ConvertTo-LiongardIdKey', 'Test-LiongardJunkId', 'Add-LiongardIdentifier', 'New-LiongardIdentity',
    'Get-LiongardAgentIdentity', 'Get-LiongardEnvironmentId', 'Get-LiongardAgentRow', 'Get-LiongardRowVerdict', 'Select-LiongardCandidate',
    'Remove-LiongardAgentRecord', 'Remove-LiongardSingleMatch', 'Remove-LiongardPlatformRecord'
foreach ($name in $names) {
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Function $name not found in $Script" }
    Invoke-Expression $fn.Extent.Text
}

$script:Log = New-Object System.Collections.Generic.List[string]
function Write-UninstallLog { param($Level, $Message) $script:Log.Add("$Level $Message") }
function Write-LiongardLog { param($Level, $Message) $script:Log.Add("$Level $Message") }
function Write-Host { param($Object) $script:Log.Add("HOST $Object") }

# Mocked registry: "<subkey>|<value>|<view>" -> string.
$script:Registry = @{}
function Get-LiongardRegistryString { param([string]$SubPath, [string]$Name, $View) $script:Registry["$SubPath|$Name|$View"] }

# Mocked server: "=" is exact and case-sensitive, "like 'x%'" a case-sensitive prefix, as in roar-api.
# Unroll mimics PowerShell 7, which unrolls a one-item JSON array.
function Get-ServerAgent { @($script:Agents | Where-Object { $script:Deleted -notcontains [string]$_.ID }) }
function Out-Server([array]$Items) {
    if ($script:Unroll) { return $Items }
    return ,$Items
}
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec, $ErrorAction)
    $path = $Uri -replace '^https://[^/]+/api/v1', ''
    $script:Calls.Add($path)
    if ($script:FailGet -and $path -like "*$($script:FailGet)*") { throw 'mocked lookup failure' }
    if ($path -eq '/environments') { return Out-Server $script:Envs }
    if ($path -like '/agents?conditions=*') {
        $cond = [Uri]::UnescapeDataString($path.Substring('/agents?conditions='.Length))
        if ($cond -match "^(\w+) = '(.*)'$") {
            $field = $Matches[1]; $value = $Matches[2] -replace "''", "'"
            return Out-Server @(Get-ServerAgent | Where-Object { [string](Get-ObjectPropertyValue $_ $field) -ceq $value })
        }
        if ($cond -match "^(\w+) like '(.*)%'$") {
            $field = $Matches[1]; $value = $Matches[2] -replace "''", "'"
            return Out-Server @(Get-ServerAgent | Where-Object { ([string](Get-ObjectPropertyValue $_ $field)).StartsWith($value, [StringComparison]::Ordinal) })
        }
        throw "bad condition $cond"
    }
    if ($path -match '^/agents/(\d+)$') { $id = $Matches[1]; return Out-Server @(Get-ServerAgent | Where-Object { [string]$_.ID -eq $id }) }
    throw "unexpected path $path"
}
function Invoke-WebRequest {
    param($Uri, $Headers, $Method, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
    $id = ($Uri -split '/')[-1]
    $script:Calls.Add("DELETE $id")
    switch ($script:DeleteMode) {
        'ok'      { $script:Deleted.Add($id); return [pscustomobject]@{ StatusCode = 200 } }
        'timeout' { $script:Deleted.Add($id); throw 'The operation has timed out.' }
        'fail'    { throw 'Response status code does not indicate success: 500.' }
    }
}

function New-Identity([string]$AgentId = '', [string[]]$Agent = @(), [string[]]$Os = @()) {
    $identity = New-LiongardIdentity
    $identity.AgentId = $AgentId
    foreach ($v in $Agent) { Add-LiongardIdentifier -Identity $identity -Kind Agent -Source 'agent_guid' -Value $v }
    foreach ($v in $Os) { Add-LiongardIdentifier -Identity $identity -Kind Os -Source 'windows_machine_guid' -Value $v }
    return $identity
}
function Reset-Case([array]$Agents) {
    $script:Agents = @($Agents | ForEach-Object { $_ | ConvertFrom-Json })
    $script:Envs = @('{"ID":7,"Name":"Acme"}', '{"ID":8,"Name":"Other"}' | ForEach-Object { $_ | ConvertFrom-Json })
    $script:Deleted = New-Object System.Collections.Generic.List[string]
    $script:Calls = New-Object System.Collections.Generic.List[string]
    $script:Log.Clear()
    $script:FailGet = ''; $script:DeleteMode = 'ok'; $script:Unroll = $false
}

$pass = 0; $fail = 0
function Test-Check([string]$Name, [bool]$Ok) {
    if ($Ok) { $script:pass++; Write-Output "ok    $Name" }
    else { $script:fail++; Write-Output "FAIL  $Name"; $script:Log | ForEach-Object { Write-Output "        | $_" } }
}
function Test-Case([string]$Name, [string]$WantResult, [string]$WantDeleted, $Identity, [string]$Environment, [string[]]$Hostnames) {
    try { $got = Remove-LiongardPlatformRecord -InstancePrefix 'mock' -Headers @{} -Identity $Identity -Environment $Environment -LocalHostnames $Hostnames }
    catch { $got = 'Failed'; $script:Log.Add("THROWN $($_.Exception.Message)") }
    $deleted = $script:Deleted -join ' '
    if ($got -eq $WantResult -and $deleted -eq $WantDeleted) { $script:pass++; Write-Output "ok    $Name" }
    else {
        $script:fail++
        Write-Output "FAIL  ${Name}: result=$got (want $WantResult), deleted [$deleted] (want [$WantDeleted])"
        $script:Log | ForEach-Object { Write-Output "        | $_" }
    }
}

$A = '{"ID":101,"Name":"HOST1","Hostname":"host1","MachineGuid":"aaaa-1111","Environment":{"ID":7,"Name":"Acme"}}'
$B = '{"ID":102,"Name":"HOST1","Hostname":"host1","MachineGuid":"bbbb-2222","Environment":{"ID":7,"Name":"Acme"}}'
$C = '{"ID":103,"Name":"host1","Hostname":"host1","MachineGuid":"aaaa-1111","Environment":{"ID":8,"Name":"Other"}}'
$D = '{"ID":104,"Name":"host1","Hostname":"host1","MachineGuid":"","Environment":null}'

Reset-Case @()
$identity = New-Identity '' 'AAAA-1111', '{aaaa-1111}' 'aaaa-1111'
Test-Check 'Add-LiongardIdentifier dedupes across both lists, ignoring case and braces' ($identity.Agent.Count -eq 1 -and $identity.Os.Count -eq 0 -and $identity.Agent[0].Value -eq 'AAAA-1111')
$identity = New-Identity '' '', 'local', 'LOCAL', 'uninitialized', '00000000-0000-0000-0000-000000000000', '{00000000-0000-0000-0000-000000000000}', 'zzzz-yyyy', '----'
Test-Check '(e) junk identifiers are never added' ($identity.Agent.Count -eq 0)
Test-Check '(e) a real identifier is not junk' (-not (Test-LiongardJunkId '5f3c0a9e-1b2d-4c3e-8f00-123456789abc'))

# Identity collection against the mocked registry (defects d and f).
Reset-Case @()
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("lg-identity-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $tmp 'custom') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $tmp 'custom/appsettings-override.config') -Value '<configuration><appSettings><add key="AGENT_ID" value="4242"/><add key="ROAR_SECRET" value="NOPE"/></appSettings></configuration>'
$script:LiongardIdentityRoots = @(Join-Path $tmp 'nowhere')
$script:Registry = @{
    'SOFTWARE\Liongard\LiongardAgent\MachineID|AgentGuid|Registry32' = '{3F2B6C1E-8A4D-4F7E-9B21-0C5D7E8F9A10}'
    'SOFTWARE\Microsoft\Cryptography|MachineGuid|Registry64'          = 'c0ffee00-1111-2222-3333-444455556666'
    'SOFTWARE\Microsoft\Cryptography|MachineGuid|Registry32'          = 'C0FFEE00-1111-2222-3333-444455556666'
    'SOFTWARE\Liongard\RoarAgent|INSTALLLOCATION|Registry64'          = (Join-Path $tmp 'custom')
}
$identity = Get-LiongardAgentIdentity -AgentPresent $true
Test-Check '(f) INSTALLLOCATION from the 64-bit view finds the settings file' ($identity.AgentId -eq '4242')
Test-Check '(d) the Windows MachineGuid is an OS identifier, listed once for both views' ($identity.Os.Count -eq 1 -and $identity.Os[0].Key -eq 'c0ffee00-1111-2222-3333-444455556666')
Test-Check '(d) the AgentGuid keeps its raw registry form' ($identity.Agent.Count -eq 1 -and $identity.Agent[0].Value -ceq '{3F2B6C1E-8A4D-4F7E-9B21-0C5D7E8F9A10}' -and $identity.Value -eq '3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10')
$forms = @(Get-LiongardGuidQueryForm -Entry $identity.Agent[0])
Test-Check '(d) query forms are the raw form, its lowercase, and the bare key in both cases' (($forms -join ',') -ceq '{3F2B6C1E-8A4D-4F7E-9B21-0C5D7E8F9A10},{3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10},3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10,3F2B6C1E-8A4D-4F7E-9B21-0C5D7E8F9A10')
New-Item -ItemType Directory -Path (Join-Path $tmp 'pf86/LiongardInc/LiongardAgent') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $tmp 'pf86/LiongardInc/LiongardAgent/appsettings-override.config') -Value '<configuration><appSettings><add key="AGENT_ID" value="77"/></appSettings></configuration>'
$script:LiongardIdentityRoots = @(Join-Path $tmp 'pf86/LiongardInc')
$script:Registry = @{ 'SOFTWARE\Microsoft\Cryptography|MachineGuid|Registry64' = 'c0ffee00-1111-2222-3333-444455556666' }
$identity = Get-LiongardAgentIdentity -AgentPresent $false
Test-Check '(f) with no INSTALLLOCATION the settings file is found under an environment-derived root' ($identity.AgentId -eq '77')
Test-Check 'a pre-5.3.0 agent saves the Windows MachineGuid as its identity' ($identity.Value -eq 'c0ffee00-1111-2222-3333-444455556666' -and $identity.Source -eq 'windows_machine_guid')
Remove-Item -LiteralPath $tmp -Recurse -Force

Reset-Case $A, $B
Test-Case 'AgentID with matching MachineGuid is deleted' 'Deleted' '101' (New-Identity '101' 'aaaa-1111') 'Acme' 'host1'
Test-Check 'AgentID match runs no later lookups' (@($script:Calls | Where-Object { $_ -like '*conditions*' }).Count -eq 0)

Reset-Case $B
Test-Case 'AgentID whose MachineGuid differs is a conflict, not deleted' 'Failed' '' (New-Identity '102' 'aaaa-1111') 'Acme' 'host1'

Reset-Case '{"ID":110,"Name":"other-pc","Hostname":"other-pc","MachineGuid":"","Environment":{"ID":8,"Name":"Other"}}'
Test-Case '(a) AgentID record with no name and no environment match is refused' 'Failed' '' (New-Identity '110') 'Acme' 'host1'
Test-Check '(a) the refusal is logged with the record signals' (@($script:Log | Where-Object { $_ -like '*Agent ID 110:*neither a local name nor the environment matches*' }).Count -eq 1)

Reset-Case '{"ID":111,"Name":"HOST1","Hostname":"x","MachineGuid":"","Environment":{"ID":8,"Name":"Other"}}'
Test-Case '(a) AgentID record whose Name matches a local name is deleted' 'Deleted' '111' (New-Identity '111') 'Acme' 'host1'

Reset-Case '{"ID":112,"Name":"renamed","Hostname":"renamed","Data":{"FQDN":"host1.corp.example"},"MachineGuid":"","Environment":{"ID":8,"Name":"Other"}}'
Test-Case '(a) AgentID record whose FQDN matches a local name is deleted' 'Deleted' '112' (New-Identity '112') 'Acme' 'host1', 'host1.corp.example'

Reset-Case '{"ID":113,"Name":"renamed","Hostname":"renamed","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(a) AgentID record in the configured environment is deleted' 'Deleted' '113' (New-Identity '113') 'acme' 'host1'

Reset-Case '{"ID":114,"Name":"renamed","Hostname":"renamed","MachineGuid":"dddd-4444","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(e) AgentID record matched only by an OS identifier and no name is refused' 'Failed' '' (New-Identity '114' @() 'dddd-4444') 'Acme' 'host1'

Reset-Case $A, $B
Test-Case 'unknown AgentID falls back to one MachineGuid match (lowercase form queried)' 'Deleted' '101' (New-Identity '999' 'AAAA-1111') 'acme' 'host1'

Reset-Case '{"ID":115,"Name":"x","Hostname":"x","MachineGuid":"{3F2B6C1E-8A4D-4F7E-9B21-0C5D7E8F9A10}","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(d) a record stored in the raw registry form (braces, uppercase) is found' 'Deleted' '115' (New-Identity '' '{3F2B6C1E-8A4D-4F7E-9B21-0C5D7E8F9A10}') 'Acme' 'host1'

Reset-Case '{"ID":116,"Name":"x","Hostname":"x","MachineGuid":"3f2b6c1e-8a4d-4f7e-9b21-0c5d7e8f9a10","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(d) a record stored in the normalized form is found from a raw registry value' 'Deleted' '116' (New-Identity '' '{3F2B6C1E-8A4D-4F7E-9B21-0C5D7E8F9A10}') 'Acme' 'host1'

Reset-Case ('{"ID":120,"Name":"x","Hostname":"x","MachineGuid":"aaaa-1111\n","Environment":{"ID":7,"Name":"Acme"}}')
Test-Case '(c) a record MachineGuid with a trailing newline is found by like and matched trimmed' 'Deleted' '120' (New-Identity '' 'aaaa-1111') 'Acme' 'host1'
Test-Check '(c) the MachineGuid step queried with like' (@($script:Calls | Where-Object { $_ -like "*MachineGuid%20like%20%27aaaa-1111%25%27*" }).Count -gt 0)

Reset-Case '{"ID":121,"Name":"x","Hostname":"x","MachineGuid":"aaaa-1111-extra","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(c) a like hit with a longer MachineGuid is filtered out on the client' 'NotFound' '' (New-Identity '' 'aaaa-1111') 'Acme' 'host1'

Reset-Case $A, $C
Test-Case 'MachineGuid match is limited to the environment' 'Deleted' '101' (New-Identity '' 'aaaa-1111') 'Acme' 'host1'

Reset-Case $A, ($A -replace '101', '105')
Test-Case '(g) two MachineGuid matches are refused' 'Failed' '' (New-Identity '' 'aaaa-1111') 'Acme' 'host1'
Test-Check '(g) both candidates are logged' ((@($script:Log | Where-Object { $_ -like '*Agent ID 101:*' }).Count -eq 1) -and (@($script:Log | Where-Object { $_ -like '*Agent ID 105:*' }).Count -eq 1))

Reset-Case '{"ID":130,"Name":"clone","Hostname":"clone","MachineGuid":"eeee-5555","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(e) an OS identifier match without a name match is not deleted' 'NotFound' '' (New-Identity '' @() 'eeee-5555') 'Acme' 'host1'

Reset-Case '{"ID":131,"Name":"host1","Hostname":"host1","MachineGuid":"eeee-5555","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(e) an OS identifier match with a name match is deleted' 'Deleted' '131' (New-Identity '' @() 'eeee-5555') 'Acme' 'host1'

Reset-Case '{"ID":132,"Name":"host1","Hostname":"host1","MachineGuid":"local","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(e) a junk local identifier is never queried; the hostname step finds the record' 'Deleted' '132' (New-Identity '' 'local') 'Acme' 'host1'
Test-Check '(e) no MachineGuid query for a junk value' (@($script:Calls | Where-Object { $_ -like '*MachineGuid*' }).Count -eq 0)

Reset-Case $C, $B
Test-Case '(b) hostname step skips a record whose MachineGuid matches no local identifier' 'NotFound' '' (New-Identity '' 'aaaa-1111') 'Acme' 'host1'
Test-Check '(b) the skipped record is logged with the reason' (@($script:Log | Where-Object { $_ -like '*Agent ID 102:*MachineGuid is set and matches no local identifier*' }).Count -eq 1)

Reset-Case '{"ID":140,"Name":"host1","Hostname":"host1","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}}', '{"ID":141,"Name":"host1","Hostname":"host1","MachineGuid":"ffff-6666","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(b) hostname step keeps a record with no MachineGuid and drops the foreign one' 'Deleted' '140' (New-Identity '' 'aaaa-1111') 'Acme' 'host1'

Reset-Case '{"ID":142,"Name":"HOST1","Hostname":"host1","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}}', '{"ID":143,"Name":"host1","Hostname":"host1","MachineGuid":"","Environment":{"ID":7,"Name":"Acme"}}'
Test-Case '(g) two hostname matches are refused' 'Failed' '' (New-Identity) 'Acme' 'host1'

Reset-Case $A, $D
Test-Case 'blank environment matches only an agent with no environment' 'Deleted' '104' (New-Identity) '' 'host1'

Reset-Case $C
Test-Case 'no match anywhere returns NotFound' 'NotFound' '' (New-Identity) 'Acme' 'host1'

Reset-Case $A; $script:FailGet = 'MachineGuid'
Test-Case '(g) a failed MachineGuid lookup stops the removal' 'Failed' '' (New-Identity '' 'aaaa-1111') 'Acme' 'host1'

Reset-Case $A; $script:FailGet = '/agents/101'
Test-Case '(g) a failed AgentID lookup stops the removal' 'Failed' '' (New-Identity '101') 'Acme' 'host1'

Reset-Case $A; $script:FailGet = 'Hostname'
Test-Case '(g) a failed hostname lookup stops the removal' 'Failed' '' (New-Identity) 'Acme' 'host1'

Reset-Case $A; $script:DeleteMode = 'timeout'
Test-Case '(g) a delete that times out but removed the record counts as deleted (GET confirms)' 'Deleted' '101' (New-Identity '101' 'aaaa-1111') 'Acme' 'host1'

Reset-Case $A; $script:DeleteMode = 'fail'
Test-Case '(g) a delete that leaves the record is a failure' 'Failed' '' (New-Identity '101' 'aaaa-1111') 'Acme' 'host1'

Reset-Case '{"ID":106,"Name":"host1","Hostname":"host1","MachineGuid":"","EnvironmentID":7}'
Test-Case 'an environment given only by ID is resolved by name' 'Deleted' '106' (New-Identity) 'Acme' 'HOST1'

Reset-Case '{"ID":107,"Name":"o''brien","Hostname":"o''brien","Environment":null}'
Test-Case 'a hostname with a quote is escaped in the filter' 'Deleted' '107' (New-Identity) '' "o'brien"

Reset-Case $A
Test-Case 'a non-numeric local AgentID fails' 'Failed' '' (New-Identity '12x') 'Acme' 'host1'

Reset-Case $A, $B; $script:Unroll = $true
Test-Case 'a one-item response unrolled by PowerShell 7 still matches' 'Deleted' '101' (New-Identity '101' 'aaaa-1111') 'Acme' 'host1'

Write-Output "$pass passed, $fail failed"
if ($fail) { exit 1 }
