<#
.SYNOPSIS
Saves and restores a Liongard Agent identity so a rebuilt Windows host re-attaches to its Agent record.

.DESCRIPTION
The platform re-attaches a fresh install to the same Agent record when the registration carries
the same tenant key (ServiceProviderID), the same MachineGuid, and the same environment.
This script saves that MachineGuid before a rebuild and writes it back before the reinstall.

Backup  Saves the identity into a new folder liongard-identity-<COMPUTERNAME>-<UTC timestamp>
        inside -OutputPath (default: your Desktop). The folder holds no access key or secret.
Restore Writes the saved identity to the AgentGuid registry value the installer reads.
        Run it on the rebuilt host before you install the agent. Needs an elevated session.
Show    Prints the current identity, its source, and the non-secret agent fields.

The identity source is the AgentGuid value (agents registered by 5.3.0 or later). When no
AgentGuid exists, the source is the Windows MachineGuid, which agents registered before
5.3.0 sent. Credentials stay with the old install: run the installer with your tenant
access key and secret as usual. A deleted Agent record never re-attaches.

Exit codes: 0 success, 1 error, 2 usage error.

.PARAMETER Action
Backup, Restore, or Show.

.PARAMETER OutputPath
Backup only. Existing parent folder for the new backup folder. Default: your Desktop.

.PARAMETER From
Restore only. The backup folder that Backup created.

.PARAMETER Force
Restore only. Write the identity even when the agent is installed or a different AgentGuid exists.

.PARAMETER DryRun
Restore only. Validate and print every action, but write nothing.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\LGAgentIdentity.ps1 -Action Backup

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\LGAgentIdentity.ps1 -Action Restore -From C:\Temp\liongard-identity-HOST-20261010T120000Z -DryRun

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\LGAgentIdentity.ps1 -Action Show
#>
param(
    [string]$Action,
    [string]$OutputPath,
    [string]$From,
    [switch]$Force,
    [switch]$DryRun,
    [string]$RegistryRoot = 'HKLM:'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$FormatVersion = '1'
$MachineIdKeyPath = 'Software\Liongard\LiongardAgent\MachineID'
$AgentGuidValueName = 'AgentGuid'
$RoarAgentKeyPath = 'Software\Liongard\RoarAgent'
$CryptographyKeyPath = 'SOFTWARE\Microsoft\Cryptography'
$ServiceKeyPath = 'SYSTEM\CurrentControlSet\Services\roaragent.exe'
$UpgradeCode = '088da427-038f-4cad-a5a6-29acd707ff61'
$GuidFileName = 'machine-guid.txt'
$ManifestFileName = 'manifest.txt'
$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path

function Write-Info([string]$Message) { Write-Host $Message }
function Write-Warn([string]$Message) { Write-Warning $Message }

function Exit-Error([string]$Message) {
    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

function Exit-Usage([string]$Message) {
    [Console]::Error.WriteLine("Error: $Message")
    [Console]::Error.WriteLine("Run 'Get-Help .\$ScriptName -Full' for usage.")
    exit 2
}

if ($args.Count -gt 0) { Exit-Usage "Unknown argument(s): $($args -join ' ')" }
if ([string]::IsNullOrEmpty($Action)) { Exit-Usage '-Action is required: Backup, Restore, or Show.' }
if (@('Backup', 'Restore', 'Show') -notcontains $Action) { Exit-Usage "Unknown -Action '$Action'. Use Backup, Restore, or Show." }

# Test hook: HKLM: is production; anything else maps every path below it into a throwaway key.
if ($RegistryRoot -match '^(HKLM|HKCU):\\?(.*)$') {
    $Hive = if ($Matches[1] -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    $RootPrefix = $Matches[2].Trim('\')
} else {
    Exit-Usage "Unsupported -RegistryRoot '$RegistryRoot'."
}
$IsProductionRoot = ($Hive -eq [Microsoft.Win32.RegistryHive]::LocalMachine -and $RootPrefix -eq '')

function Get-FullKeyPath([string]$SubPath) {
    if ($RootPrefix) { return "$RootPrefix\$SubPath" }
    return $SubPath
}

function Get-RegistryString([string]$SubPath, [string]$Name, [Microsoft.Win32.RegistryView]$View) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    try {
        $key = $base.OpenSubKey((Get-FullKeyPath $SubPath), $false)
        if ($null -eq $key) { return $null }
        try {
            $value = $key.GetValue($Name)
            if ($null -eq $value) { return $null }
            return $value.ToString()
        } finally { $key.Close() }
    } finally { $base.Close() }
}

function Test-RegistryKey([string]$SubPath, [Microsoft.Win32.RegistryView]$View) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
    try {
        $key = $base.OpenSubKey((Get-FullKeyPath $SubPath), $false)
        if ($null -eq $key) { return $false }
        $key.Close()
        return $true
    } finally { $base.Close() }
}

# Same rules as AgentGuidService.IsValidGuid / NormalizeGuid.
function Test-ValidGuid([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref]$parsed)
}

function ConvertTo-NormalizedGuid([string]$Value) {
    return [Guid]::Parse($Value).ToString()
}

# AgentGuidService reads only the 32-bit view (WOW6432Node on x64).
function Get-RawAgentGuid {
    return Get-RegistryString $MachineIdKeyPath $AgentGuidValueName ([Microsoft.Win32.RegistryView]::Registry32)
}

# Same read order as AgentGuidService.ReadWindowsMachineGuid: 64-bit view first, 32-bit view wins.
function Get-WindowsMachineGuid {
    $machineGuid = $null
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        try {
            $value = Get-RegistryString $CryptographyKeyPath 'MachineGuid' $view
            if (-not [string]::IsNullOrEmpty($value)) { $machineGuid = $value }
        } catch { }
    }
    if (Test-ValidGuid $machineGuid) { return $machineGuid }
    return $null
}

function Resolve-Identity {
    $raw = Get-RawAgentGuid
    if (Test-ValidGuid $raw) {
        return [pscustomobject]@{ Guid = (ConvertTo-NormalizedGuid $raw); Source = 'agent_guid'; Warning = $null }
    }
    $osGuid = Get-WindowsMachineGuid
    if ($null -eq $osGuid) { return $null }
    $reason = if ([string]::IsNullOrEmpty($raw)) { 'No AgentGuid exists' } else { "The AgentGuid value '$raw' is not a valid GUID" }
    $warning = "$reason. Using the Windows MachineGuid instead: agents registered before 5.3.0 used it, and the installer seeds AgentGuid from it on a pre-5.3.0 upgrade. If this agent was registered by 5.3.0 or later with a different AgentGuid, this backup will not re-attach."
    return [pscustomobject]@{ Guid = (ConvertTo-NormalizedGuid $osGuid); Source = 'windows_machine_guid'; Warning = $warning }
}

function Get-InstallLocation {
    return Get-RegistryString $RoarAgentKeyPath 'INSTALLLOCATION' ([Microsoft.Win32.RegistryView]::Registry32)
}

# Windows Installer stores an UpgradeCode as a "packed" GUID: groups reversed, last two groups nibble-swapped per byte.
function Get-PackedGuid([string]$Value) {
    $hex = ([Guid]$Value).ToString('N').ToUpperInvariant()
    $out = -join $hex.Substring(0, 8).ToCharArray()[7..0]
    $out += -join $hex.Substring(8, 4).ToCharArray()[3..0]
    $out += -join $hex.Substring(12, 4).ToCharArray()[3..0]
    for ($i = 16; $i -lt 32; $i += 2) { $out += [string]$hex[$i + 1] + [string]$hex[$i] }
    return $out
}

# Same signals the MSI uses: its UpgradeCode, the roaragent.exe service (FINDLIONGARDSERVICE), the override config (FINDAPPSETTINGSOVERRIDE).
function Get-InstalledSignals {
    $signals = @()
    if (Test-RegistryKey "SOFTWARE\Classes\Installer\UpgradeCodes\$(Get-PackedGuid $UpgradeCode)" ([Microsoft.Win32.RegistryView]::Registry64)) {
        $signals += 'Windows Installer lists the Liongard Agent product'
    }
    $imagePath = Get-RegistryString $ServiceKeyPath 'ImagePath' ([Microsoft.Win32.RegistryView]::Registry32)
    if (-not [string]::IsNullOrEmpty($imagePath)) { $signals += 'the roaragent.exe service is registered' }
    $settingsPath = Get-AppSettingsPath
    if ($settingsPath -and (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { $signals += "$settingsPath exists" }
    return , $signals
}

function Get-AppSettingsPath {
    $location = Get-InstallLocation
    if ([string]::IsNullOrWhiteSpace($location)) { return $null }
    return Join-Path $location 'appsettings-override.config'
}

# Reads only the named non-secret keys; access keys and secrets in the file are never read into a variable.
function Get-AgentFields {
    $fields = [ordered]@{ agent_id = ''; agent_name = ''; url = ''; agent_version = '' }
    $fields.agent_version = [string](Get-RegistryString $RoarAgentKeyPath 'ProductVersion' ([Microsoft.Win32.RegistryView]::Registry32))
    $settingsPath = Get-AppSettingsPath
    if ($settingsPath -and (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        try {
            [xml]$doc = Get-Content -LiteralPath $settingsPath -Raw
            $wanted = @{ 'AGENT_ID' = 'agent_id'; 'AGENT_NAME' = 'agent_name'; 'URL' = 'url' }
            foreach ($node in $doc.SelectNodes('//add[@key]')) {
                $name = $node.GetAttribute('key')
                if ($wanted.ContainsKey($name)) { $fields[$wanted[$name]] = $node.GetAttribute('value') }
            }
        } catch {
            Write-Warn "Unable to read $settingsPath ($($_.Exception.Message)); agent fields left blank."
        }
    }
    foreach ($k in @($fields.Keys)) { $fields[$k] = ([string]$fields[$k]) -replace '[\r\n]', ' ' }
    return $fields
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-Elevated {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-PrivateAcl([string]$Path) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    foreach ($sid in @($user, $admins)) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ($sid, $full, $inherit, $none, $allow)))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-AsciiFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Invoke-Backup {
    if ($From -or $Force -or $DryRun) { Exit-Usage '-From, -Force, and -DryRun apply to Restore only.' }
    $identity = Resolve-Identity
    if ($null -eq $identity) { Exit-Error 'No AgentGuid and no Windows MachineGuid found; nothing to back up.' }
    if ($identity.Warning) { Write-Warn $identity.Warning }

    $parent = $OutputPath
    if ([string]::IsNullOrEmpty($parent)) {
        $parent = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrEmpty($parent)) { Exit-Error 'This account has no Desktop folder. Pass -OutputPath.' }
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Exit-Error "Output folder $parent does not exist." }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
    $hostName = $env:COMPUTERNAME
    $dest = Join-Path $parent "liongard-identity-$hostName-$stamp"
    if (Test-Path -LiteralPath $dest) { Exit-Error "$dest already exists; refusing to overwrite." }

    New-Item -ItemType Directory -Path $dest | Out-Null
    try {
        Set-PrivateAcl $dest
        $guidFile = Join-Path $dest $GuidFileName
        Write-AsciiFile $guidFile ($identity.Guid + "`n")
        $fields = Get-AgentFields
        $lines = @(
            "format_version=$FormatVersion",
            'os=windows',
            "hostname=$hostName",
            "created_utc=$stamp",
            "identity_source=$($identity.Source)",
            "agent_id=$($fields.agent_id)",
            "agent_name=$($fields.agent_name)",
            "url=$($fields.url)",
            "agent_version=$($fields.agent_version)",
            "sha256_machine_guid=$(Get-Sha256 $guidFile)"
        )
        Write-AsciiFile (Join-Path $dest $ManifestFileName) (($lines -join "`n") + "`n")
    } catch {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        Exit-Error "Backup failed: $($_.Exception.Message)"
    }

    Write-Info "Saved the agent identity to $dest"
    Write-Info "  identity=$($identity.Guid)"
    Write-Info "  identity_source=$($identity.Source)"
    Write-Info "  agent_id=$($fields.agent_id)"
    Write-Info 'Copy this folder off the host before you rebuild it. It holds no access key or secret.'
}

function Read-Manifest([string]$Path) {
    $map = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { Exit-Error "Malformed manifest line: $line" }
        $map[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim()
    }
    return $map
}

function Invoke-Restore {
    if ($OutputPath) { Exit-Usage '-OutputPath applies to Backup only.' }
    if ([string]::IsNullOrEmpty($From)) { Exit-Usage 'Restore needs -From <backup folder>.' }
    # The test root under HKCU needs no elevation; the real HKLM write does.
    if ($IsProductionRoot -and -not (Test-Elevated)) { Exit-Error 'Restore needs an elevated PowerShell session (Run as administrator).' }
    if (-not (Test-Path -LiteralPath $From -PathType Container)) { Exit-Error "Backup folder $From does not exist." }

    $manifestPath = Join-Path $From $ManifestFileName
    $guidPath = Join-Path $From $GuidFileName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Exit-Error "$manifestPath is missing." }
    if (-not (Test-Path -LiteralPath $guidPath -PathType Leaf)) { Exit-Error "$guidPath is missing." }

    $manifest = Read-Manifest $manifestPath
    if ($manifest['format_version'] -ne $FormatVersion) { Exit-Error "Unsupported manifest format_version '$($manifest['format_version'])' (expected $FormatVersion)." }
    if ($manifest['os'] -ne 'windows') { Exit-Error "This backup is for os '$($manifest['os'])', not windows." }
    if ([string]::IsNullOrEmpty($manifest['sha256_machine_guid'])) { Exit-Error 'The manifest has no sha256_machine_guid.' }
    if ((Get-Sha256 $guidPath) -ne $manifest['sha256_machine_guid'].ToLowerInvariant()) { Exit-Error "Checksum mismatch for $guidPath; the backup is damaged or was edited." }

    $saved = ([IO.File]::ReadAllText($guidPath)).Trim()
    if (-not (Test-ValidGuid $saved)) { Exit-Error "The saved identity '$saved' is not a valid GUID." }
    $guid = ConvertTo-NormalizedGuid $saved

    $installed = Get-InstalledSignals
    if ($installed.Count -gt 0) {
        $why = 'The Liongard Agent is installed: ' + ($installed -join '; ') + '.'
        if (-not $Force) { Exit-Error "$why Uninstall it first, or pass -Force." }
        Write-Warn "$why Continuing because of -Force. The running agent keeps its current credentials."
    }

    $existing = Get-RawAgentGuid
    $alreadySet = $false
    if (-not [string]::IsNullOrEmpty($existing)) {
        if ((Test-ValidGuid $existing) -and (ConvertTo-NormalizedGuid $existing) -eq $guid) {
            $alreadySet = $true
        } elseif (Test-ValidGuid $existing) {
            if (-not $Force) { Exit-Error "A different AgentGuid ($existing) already exists. Pass -Force to replace it." }
            Write-Warn "Replacing the existing AgentGuid $existing because of -Force."
        } else {
            Write-Warn "The existing AgentGuid '$existing' is not a valid GUID; the installer would ignore it. Replacing it."
        }
    }

    $target = $(if ($Hive -eq [Microsoft.Win32.RegistryHive]::LocalMachine) { 'HKLM' } else { 'HKCU' }) + " (32-bit view)\$(Get-FullKeyPath $MachineIdKeyPath)\$AgentGuidValueName"
    Write-Info "Backup: host=$($manifest['hostname']) agent_id=$($manifest['agent_id']) source=$($manifest['identity_source']) created=$($manifest['created_utc'])"
    if ($alreadySet) {
        Write-Info "AgentGuid already holds $guid; nothing to write."
    } elseif ($DryRun) {
        Write-Info "Dry run: would write $guid to $target. Nothing was written."
    } else {
        # Direct write, as AgentGuidService.ReplaceAgentGuid does, then verify-after-write.
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Registry32)
        try {
            $key = $base.CreateSubKey((Get-FullKeyPath $MachineIdKeyPath))
            if ($null -eq $key) { Exit-Error "Unable to open or create $target." }
            try { $key.SetValue($AgentGuidValueName, $guid, [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Close() }
        } catch {
            Exit-Error "Writing $target failed: $($_.Exception.Message)"
        } finally { $base.Close() }
        $persisted = Get-RawAgentGuid
        if (-not (Test-ValidGuid $persisted) -or (ConvertTo-NormalizedGuid $persisted) -ne $guid) { Exit-Error "The write to $target did not persist." }
        Write-Info "Wrote $guid to $target."
    }

    Write-Info ''
    Write-Info 'Next step: run the Liongard Agent installer as usual, with your tenant access key and secret.'
    Write-Info 'The installer keeps an existing AgentGuid and registers with it, so the platform re-attaches the same Agent record.'
    Write-Info 'Equivalent route on a clean host (skip the restore and pass the identity to the bundle):'
    Write-Info "  LiongardAgentInstaller.exe /install /quiet /norestart DeviceGuid=$guid LiongardUrl=... LiongardAccessKey=... LiongardAccessSecret=... EulaAcceptCheckbox=1"
    Write-Info '  Keep the /install verb: without it the bundle can default to uninstall.'
    Write-Info 'Re-attach needs the same tenant access key and the same environment as the original install.'
    Write-Info 'A deleted Agent record never re-attaches; the install then creates a new record.'
}

function Invoke-Show {
    if ($OutputPath -or $From -or $Force -or $DryRun) { Exit-Usage 'Show takes no other parameters.' }
    $raw = Get-RawAgentGuid
    $osGuid = Get-WindowsMachineGuid
    $identity = Resolve-Identity
    $fields = Get-AgentFields
    $installed = Get-InstalledSignals

    Write-Info "hostname=$env:COMPUTERNAME"
    Write-Info "identity=$(if ($identity) { $identity.Guid } else { '' })"
    Write-Info "identity_source=$(if ($identity) { $identity.Source } else { 'none' })"
    Write-Info "agent_guid=$(if ($raw) { $raw } else { '' })"
    Write-Info "windows_machine_guid=$(if ($osGuid) { $osGuid } else { '' })"
    foreach ($k in $fields.Keys) { Write-Info "$k=$($fields[$k])" }
    Write-Info "installed=$(if ($installed.Count -gt 0) { 'yes' } else { 'no' })"
    if ($identity -and $identity.Warning) { Write-Warn $identity.Warning }
}

try {
    switch ($Action) {
        'Backup' { Invoke-Backup }
        'Restore' { Invoke-Restore }
        'Show' { Invoke-Show }
    }
} catch {
    Exit-Error $_.Exception.Message
}
exit 0
