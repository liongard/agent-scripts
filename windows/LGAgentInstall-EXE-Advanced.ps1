#requires -Version 5.1
<#
    Liongard Agent deployment script for the EXE-based installer bundle.

    The EXE bundle wraps the Liongard Agent MSI, the Visual C++ redistributable, and
    Npcap, making it the right choice for hosts that will run the Liongard network
    discovery inspector, which depends on those components.

    The script performs:
      • Partner configuration validation.
      • Environment-name resolution against the Liongard API.
      • Install-state classification (Healthy / Stale / NotInstalled). Stale leftovers
        (folder, orphaned service, stored credentials) are cleaned up before a fresh
        install; the identity key HKLM\SOFTWARE\WOW6432Node\Liongard is never modified.
      • A version gate that installs only when the bundle is newer than a healthy agent
        already present on the host.
      • Post-install validation: roaragent.exe Running and the updater task present.
      • Proxy preflight handling for endpoints that route through a proxy.
      • Structured transcript logging.
      • Per-component (Agent / Visual C++ / Npcap) post-install validation.
      • Optional enablement of network discovery after installation.
      • A JSON run-summary artifact for RMM ingestion.

    To remove the agent, use the standalone Liongard Agent uninstall script.

    Liongard Partner Support
    Last updated: 2026-10-20
#>

# ================================
# Partner Configuration - Update these values
# ================================
$InstancePrefix             = "REPLACE_WITH_INSTANCE_PREFIX"     # Liongard instance prefix (e.g. us1, us2, eu1)
$ApiTokenKey                = "REPLACE_WITH_API_TOKEN_KEY"       # Liongard API token key
$ApiTokenSecret             = "REPLACE_WITH_API_TOKEN_SECRET"    # Liongard API token secret
$AgentTokenKey              = "REPLACE_WITH_AGENT_TOKEN_KEY"     # Liongard agent install key
$AgentTokenSecret           = "REPLACE_WITH_AGENT_TOKEN_SECRET"  # Liongard agent install secret
$Environment                = "REPLACE_WITH_ENVIRONMENT_NAME"    # Environment name (can be an RMM variable)
$AgentDescription           = ""                                 # Optional agent description; passed as LiongardDescription when set
$IncludeEnvironmentValue    = $true                              # Set to $false to omit the LiongardEnvironment value

# Network discovery: when $true, after a successful install (or when the agent is
# already present and up to date) the script flips the network discovery 'enabled'
# flag in network_discovery.yml from false to true. Requires administrative rights.
$EnableNetworkDiscovery     = $false

# EXE installer-specific settings
$Folder                     = $env:ProgramData                 # Parent folder; the script works in <Folder>\LiongardDeploy (SYSTEM/Administrators only)
$InstallerUrl               = "https://agents.static.liongard.com/LiongardAgent-lts.exe"
$InstallerFileName          = "LiongardAgent-lts.exe"          # File name only; the installer is staged in LiongardDeploy\Deploy\<guid>
$InstallNpcap               = $true
$EulaAccepted               = $true
$SuppressRestart            = $true
$PassiveMode                = $false
$InstallerLogPath           = ""                               # Deprecated and ignored: installer logs are always written to LiongardDeploy
$ProxyUrl                   = ""

# MSI argument: AUTOUPDATE. Use the public MSI property name so the EXE bundle can
# forward it without tripping the bundle's non-overridable variable handling.
$AutoUpdate                 = $null
$AutoUpdateArgumentName     = "AUTOUPDATE"
$ClearProxyEnvironmentForInstaller = $true

$script:TranscriptStarted = $false
$script:TranscriptPath = $null
$script:EnvironmentResolutionReason = $null
$script:RunWarnings = New-Object System.Collections.Generic.List[string]
$script:RunErrors = New-Object System.Collections.Generic.List[string]
$script:SummaryArtifactPath = $null
$script:CurrentSection = $null

function Convert-ToStringArray {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) { return @() }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @(
            $Value |
            ForEach-Object { if ($null -ne $_) { [string]$_ } } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    return @([string]$Value)
}

function Add-RunWarning {
    param([Parameter(Mandatory)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $script:RunWarnings.Add($Message) | Out-Null
    Write-Warning $Message
}

function Start-LogSection {
    param([Parameter(Mandatory)][string]$Name)

    $script:CurrentSection = $Name
    Write-Host ("=== {0} ===" -f $Name)
}

function Write-SectionValue {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter()][object]$Value
    )

    $text = Convert-ValidationDetailToText -Detail $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = '<none>'
    }

    Write-Host ("{0}: {1}" -f $Label, $text)
}

function Convert-ToPlainObject {
    param([Parameter()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [string] -or
        $Value -is [bool] -or
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [double] -or
        $Value -is [decimal]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = Convert-ToPlainObject -Value $Value[$key]
        }
        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(Convert-ToPlainObject -Value $item)
        }
        return @($items)
    }

    if ($Value.PSObject -and $Value.PSObject.Properties.Count -gt 0) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = Convert-ToPlainObject -Value $property.Value
        }
        return [pscustomobject]$result
    }

    return [string]$Value
}

function Complete-LogSection {
    if ($script:CurrentSection) {
        Write-Host ('=' * ([Math]::Max(20, $script:CurrentSection.Length + 8)))
        $script:CurrentSection = $null
    }
    else {
        Write-Host "============================"
    }
}

function Assert-ConfigurationValue {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -like 'REPLACE_WITH_*') {
        throw "Configuration value [$Name] must be provided before running this script."
    }
}

# ====================================================================
# BEGIN SHARED BLOCK: Liongard install-state functions
# Keep this block identical across LGAgentInstall-MSI-Advanced, LGAgentInstall-EXE-Advanced
# and LGAgentUninstall. Edit one copy, then copy it to the other scripts.
# ====================================================================

$script:LiongardServiceName       = 'roaragent.exe'
$script:LiongardUpdaterTaskName   = '\Liongard\LiongardAgentUpdater'
$script:LiongardInstallRoots      = @('C:\Program Files (x86)\LiongardInc', 'C:\Program Files\LiongardInc')
$script:LiongardLegacyProductCode = '{1D89F069-B48B-4191-8810-2364C29EC039}'   # Fallback only; the ProductCode changes per version.
$script:LiongardCredentialUser    = 'LiongardAgent\AgentKey'

# Persistent agent identity (MachineID). It must survive uninstall/reinstall so the agent
# re-attaches to its existing platform record. SOFTWARE\Liongard is listed too because a
# 32-bit PowerShell host is redirected from it to WOW6432Node\Liongard.
$script:LiongardProtectedRegistryPaths = @(
    'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Liongard',
    'HKEY_LOCAL_MACHINE\SOFTWARE\Liongard'
)

$script:LiongardCredentialStoreSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class LiongardCredentialStore
{
    private const int CRED_TYPE_GENERIC = 1;
    private const int ERROR_NOT_FOUND = 1168;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredEnumerate(string filter, int flags, out int count, out IntPtr credentials);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    // Returns target names of Generic credentials whose UserName equals userName exactly.
    // The credential blob (secret) is never read.
    public static string[] FindGenericTargets(string userName)
    {
        List<string> targets = new List<string>();
        int count;
        IntPtr buffer;

        if (!CredEnumerate(null, 0, out count, out buffer))
        {
            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_NOT_FOUND) { return targets.ToArray(); }
            throw new System.ComponentModel.Win32Exception(error);
        }

        try
        {
            for (int i = 0; i < count; i++)
            {
                IntPtr entry = Marshal.ReadIntPtr(buffer, i * IntPtr.Size);
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(entry, typeof(CREDENTIAL));
                if (credential.Type != CRED_TYPE_GENERIC) { continue; }

                string user = credential.UserName == IntPtr.Zero ? null : Marshal.PtrToStringUni(credential.UserName);
                if (!string.Equals(user, userName, StringComparison.Ordinal)) { continue; }

                string target = credential.TargetName == IntPtr.Zero ? null : Marshal.PtrToStringUni(credential.TargetName);
                if (!string.IsNullOrEmpty(target)) { targets.Add(target); }
            }
        }
        finally
        {
            CredFree(buffer);
        }

        return targets.ToArray();
    }

    // Returns 0 on success, otherwise the Win32 error code.
    public static int DeleteGeneric(string target)
    {
        return CredDelete(target, CRED_TYPE_GENERIC, 0) ? 0 : Marshal.GetLastWin32Error();
    }
}
'@

function Write-LiongardStateLog {
    param(
        [ValidateSet('INFO','WARN')][string]$Level = 'INFO',
        [string]$Message
    )

    $line = "[AgentState][$Level] $Message"
    if ($Level -eq 'WARN') { Write-Warning $line } else { Write-Host $line }
}

function ConvertTo-LiongardVersion {
    # Parses a version string into a four-part [version] so 5.5.0 and 5.5.0.0 compare equal.
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if (-not ([string]$Value -match '\d+(\.\d+){0,3}')) { return $null }

    $parts = @($Matches[0].Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return New-Object System.Version($parts[0], $parts[1], $parts[2], $parts[3])
}

function Get-LiongardInstalledProduct {
    # Enumerates the 64-bit and 32-bit uninstall registry views for DisplayName
    # 'Liongard Agent'. The legacy ProductCode is honored only as a fallback. Returns
    # MSI entries first, then bundle or code-less entries.
    $msiEntries   = New-Object System.Collections.Generic.List[object]
    $otherEntries = New-Object System.Collections.Generic.List[object]
    $seen         = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $subKeyPath   = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null
        $root = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $root = $base.OpenSubKey($subKeyPath)
            if (-not $root) { continue }

            foreach ($name in $root.GetSubKeyNames()) {
                $key = $root.OpenSubKey($name)
                if (-not $key) { continue }
                try {
                    $displayName = [string]$key.GetValue('DisplayName')
                    $isLegacy    = [string]::Equals($name, $script:LiongardLegacyProductCode, [System.StringComparison]::OrdinalIgnoreCase)
                    if ($displayName -ne 'Liongard Agent' -and -not $isLegacy) { continue }
                    if (-not $seen.Add($name)) { continue }

                    $uninstallString = [string]$key.GetValue('UninstallString')
                    $isBundle = ($null -ne $key.GetValue('BundleUpgradeCode')) -or ($null -ne $key.GetValue('BundleProviderKey'))
                    $productCode = $null
                    if (-not $isBundle) {
                        if ($name -match '^\{[0-9A-Fa-f\-]{36}\}$') {
                            $productCode = $name.ToUpperInvariant()
                        }
                        elseif ($uninstallString -match '(?i)msiexec.*?(?<code>\{[0-9A-F\-]{36}\})') {
                            $productCode = $Matches['code'].ToUpperInvariant()
                        }
                    }

                    $keyRoot = if ($view -eq [Microsoft.Win32.RegistryView]::Registry32 -and [Environment]::Is64BitOperatingSystem) {
                        'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
                    }
                    else {
                        'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
                    }

                    $entry = [pscustomobject]@{
                        DisplayName      = $displayName
                        ProductCode      = $productCode
                        DisplayVersion   = [string]$key.GetValue('DisplayVersion')
                        InstallLocation  = [string]$key.GetValue('InstallLocation')
                        UninstallString  = $uninstallString
                        IsBundle         = $isBundle
                        IsLegacyFallback = ($isLegacy -and $displayName -ne 'Liongard Agent')
                        RegistryView     = [string]$view
                        KeyPath          = "$keyRoot\$name"
                    }

                    if ($productCode) { $msiEntries.Add($entry) } else { $otherEntries.Add($entry) }
                }
                finally {
                    $key.Close()
                }
            }
        }
        catch {
            Write-LiongardStateLog WARN ("Unable to read uninstall entries ({0} view): {1}" -f $view, $_.Exception.Message)
        }
        finally {
            if ($root) { $root.Close() }
            if ($base) { $base.Close() }
        }
    }

    return @($msiEntries.ToArray()) + @($otherEntries.ToArray())
}

function ConvertFrom-LiongardImagePath {
    # Extracts the executable path from a service ImagePath (quoted or unquoted, with arguments).
    param([string]$ImagePath)

    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }

    $text = [Environment]::ExpandEnvironmentVariables($ImagePath.Trim())
    if ($text.StartsWith('\??\')) { $text = $text.Substring(4) }

    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -gt 1) { return $text.Substring(1, $end - 1) }
        return $text.Trim('"')
    }

    if ($text -match '^(?<exe>.+?\.exe)(\s|$)') { return $Matches['exe'] }
    return $text
}

function Get-LiongardServiceInfo {
    # Reads the roaragent.exe service registration directly from the registry so an
    # orphaned registration (binary deleted) is still visible, then adds live status.
    $info = [ordered]@{
        Name         = $script:LiongardServiceName
        Exists       = $false
        Status       = $null
        ImagePath    = $null
        BinaryPath   = $null
        BinaryExists = $false
    }

    $base = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key  = $base.OpenSubKey("SYSTEM\CurrentControlSet\Services\$($script:LiongardServiceName)")
        if ($key) {
            try {
                $info.Exists     = $true
                $info.ImagePath  = [string]$key.GetValue('ImagePath')
                $info.BinaryPath = ConvertFrom-LiongardImagePath -ImagePath $info.ImagePath
                if ($info.BinaryPath) {
                    $info.BinaryExists = Test-Path -LiteralPath $info.BinaryPath -PathType Leaf
                }
            }
            finally {
                $key.Close()
            }
        }
    }
    catch {
        Write-LiongardStateLog WARN "Unable to read service registration for '$($script:LiongardServiceName)': $($_.Exception.Message)"
    }
    finally {
        if ($base) { $base.Close() }
    }

    $service = Get-Service -Name $script:LiongardServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $info.Exists = $true
        $info.Status = [string]$service.Status
    }

    return [pscustomobject]$info
}

function Test-LiongardUpdaterTask {
    # Uses schtasks.exe because Get-ScheduledTask has been observed to hang on endpoints.
    $ErrorActionPreference = 'Continue'
    $null = & schtasks.exe /query /tn $script:LiongardUpdaterTaskName 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Get-LiongardInstallFolders {
    # Returns existing agent folders: <root>\LiongardAgent for each known root, plus a
    # registered InstallLocation only when it sits directly under a known root.
    param([object[]]$Products = @())

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $script:LiongardInstallRoots) {
        $candidates.Add((Join-Path -Path $root -ChildPath 'LiongardAgent'))
    }

    foreach ($product in $Products) {
        if ([string]::IsNullOrWhiteSpace($product.InstallLocation)) { continue }
        $location = $product.InstallLocation.Trim().TrimEnd('\')
        $parent   = Split-Path -Path $location -Parent
        if ($script:LiongardInstallRoots -contains $parent) { $candidates.Add($location) }
    }

    $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    return @($candidates | Where-Object { $unique.Add($_) -and (Test-Path -LiteralPath $_ -PathType Container) })
}

function Get-LiongardInstallState {
    # Healthy      = uninstall entry AND roaragent.exe service AND its binary exists on disk.
    # NotInstalled = no uninstall entry, no service and no install folder.
    # Stale        = any other combination (folder only, orphaned service, entry without binaries).
    $products    = @(Get-LiongardInstalledProduct)
    $service     = Get-LiongardServiceInfo
    $folders     = @(Get-LiongardInstallFolders -Products $products)
    $roots       = @($script:LiongardInstallRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $taskPresent = Test-LiongardUpdaterTask

    $evidence = New-Object System.Collections.Generic.List[string]
    if ($products.Count -eq 0) {
        $evidence.Add('Uninstall entry: none') | Out-Null
    }
    foreach ($product in $products) {
        $kind = if ($product.IsBundle) { 'bundle' } elseif ($product.IsLegacyFallback) { 'legacy-code fallback' } else { 'msi' }
        $evidence.Add(("Uninstall entry: '{0}' version={1} code={2} type={3} key={4}" -f $product.DisplayName, $product.DisplayVersion, $product.ProductCode, $kind, $product.KeyPath)) | Out-Null
    }

    if ($service.Exists) {
        $evidence.Add(("Service '{0}': status={1} image={2} binaryExists={3}" -f $service.Name, $service.Status, $service.ImagePath, $service.BinaryExists)) | Out-Null
    }
    else {
        $evidence.Add("Service '$($service.Name)': not registered") | Out-Null
    }

    foreach ($folder in $folders) { $evidence.Add("Install folder present: $folder") | Out-Null }
    foreach ($root in $roots)     { $evidence.Add("Install root present: $root") | Out-Null }
    if ($folders.Count -eq 0 -and $roots.Count -eq 0) { $evidence.Add('Install folder: none') | Out-Null }
    $evidence.Add("Updater task '$($script:LiongardUpdaterTaskName)' present: $taskPresent") | Out-Null

    $state = if ($products.Count -gt 0 -and $service.Exists -and $service.BinaryExists) {
        'Healthy'
    }
    elseif ($products.Count -eq 0 -and -not $service.Exists -and $folders.Count -eq 0 -and $roots.Count -eq 0) {
        'NotInstalled'
    }
    else {
        'Stale'
    }

    return [pscustomobject]@{
        State       = $state
        Products    = $products
        Service     = $service
        Folders     = $folders
        TaskPresent = $taskPresent
        Evidence    = $evidence.ToArray()
    }
}

function Write-LiongardInstallState {
    param([Parameter(Mandatory)][pscustomobject]$State)

    Write-LiongardStateLog INFO "Install state classification: $($State.State)"
    foreach ($line in $State.Evidence) {
        Write-LiongardStateLog INFO "  - $line"
    }
}

function ConvertTo-LiongardRegistryPath {
    # Normalizes PowerShell registry paths (HKLM:\..., Registry::..., PSPath) to
    # HKEY_xxx\Sub\Key form. Returns $null for non-registry paths.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $text = $Path.Trim() -replace '^(?i)Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^(?i)Registry::', ''
    if (-not ($text -match '^(?i)(?<hive>HKEY_LOCAL_MACHINE|HKLM|HKEY_CLASSES_ROOT|HKCR|HKEY_CURRENT_USER|HKCU|HKEY_USERS|HKU):?(\\(?<rest>.*))?$')) {
        return $null
    }

    $hiveName = $Matches['hive'].ToUpperInvariant()
    $rest     = ([string]$Matches['rest'] -replace '\\+', '\').Trim('\')
    $hive = switch ($hiveName) {
        'HKLM'  { 'HKEY_LOCAL_MACHINE' }
        'HKCR'  { 'HKEY_CLASSES_ROOT' }
        'HKCU'  { 'HKEY_CURRENT_USER' }
        'HKU'   { 'HKEY_USERS' }
        default { $hiveName }
    }

    if ($rest) { return "$hive\$rest" }
    return $hive
}

function Assert-NotProtectedPath {
    # Throws when a removal would touch the persistent agent identity key, its children,
    # or any parent of it. Every registry/file removal in these scripts goes through here.
    param([Parameter(Mandatory)][string]$Path)

    $normalized = ConvertTo-LiongardRegistryPath -Path $Path
    if (-not $normalized) { return }

    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
    foreach ($protected in $script:LiongardProtectedRegistryPaths) {
        if ($normalized.Equals($protected, $ignoreCase) -or
            $normalized.StartsWith($protected + '\', $ignoreCase) -or
            $protected.StartsWith($normalized + '\', $ignoreCase)) {
            throw "Refusing to modify protected Liongard identity path [$Path]."
        }
    }
}

function Remove-LiongardPathSafe {
    # Single choke point for registry and file removals.
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [switch]$Recurse
    )

    Assert-NotProtectedPath -Path $LiteralPath
    Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force -ErrorAction Stop
}

function Stop-LiongardProcesses {
    # Stops processes running from a Liongard install root (agent, updater, and the
    # node.exe/prowl.exe job children that otherwise lock the folder). Win32_Process is
    # used so 64-bit process paths are readable from a 32-bit PowerShell host.
    $ErrorActionPreference = 'Continue'
    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
    $stopped = 0

    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
            $exe = $_.ExecutablePath
            $exe -and @($script:LiongardInstallRoots | Where-Object { $exe.StartsWith($_ + '\', $ignoreCase) }).Count -gt 0
        })
    }
    catch {
        Write-LiongardStateLog WARN "Unable to enumerate processes via CIM ($($_.Exception.Message)); falling back to agent process names."
        $processes = @(Get-Process -Name 'LiongardAgentSVC','LiongardAgent','LiongardAgentUpdater','roaragent' -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id; Name = $_.ProcessName; ExecutablePath = $null } })
    }

    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            $stopped++
            Write-LiongardStateLog INFO ("Stopped process {0} (PID {1}) {2}" -f $process.Name, $process.ProcessId, $process.ExecutablePath)
        }
        catch {
            Write-LiongardStateLog WARN ("Failed to stop process {0} (PID {1}): {2}" -f $process.Name, $process.ProcessId, $_.Exception.Message)
        }
    }

    if ($stopped -gt 0) { Start-Sleep -Seconds 2 }
    return $stopped
}

function Remove-LiongardServiceRegistration {
    # Stops and deletes a service registration. Returns $true when the service is gone
    # or marked for deletion.
    param([string]$Name = $script:LiongardServiceName)

    $ErrorActionPreference = 'Continue'
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-LiongardStateLog INFO "Service '$Name' not present."
        return $true
    }

    $serviceName = $service.Name
    Assert-NotProtectedPath -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"

    if ($service.Status -ne 'Stopped') {
        try {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            Write-LiongardStateLog INFO "Service '$serviceName' stopped."
        }
        catch {
            Write-LiongardStateLog WARN "Service '$serviceName' did not stop cleanly: $($_.Exception.Message)"
        }
    }

    $output = & sc.exe delete $serviceName 2>&1
    switch ($LASTEXITCODE) {
        0       { Write-LiongardStateLog INFO "Service '$serviceName' deleted."; return $true }
        1072    { Write-LiongardStateLog INFO "Service '$serviceName' is already marked for deletion."; return $true }
        1060    { Write-LiongardStateLog INFO "Service '$serviceName' does not exist."; return $true }
        default {
            Write-LiongardStateLog WARN ("sc.exe delete '{0}' returned {1}: {2}" -f $serviceName, $LASTEXITCODE, (($output | Out-String).Trim()))
            return $false
        }
    }
}

function Invoke-LiongardMsiUninstallByCode {
    # Always builds 'msiexec /x {ProductCode}' itself instead of replaying the registered
    # UninstallString, which can be 'MsiExec.exe /I{code}' (a repair) on some builds.
    param(
        [Parameter(Mandatory)][string]$ProductCode,
        [string]$LogPath
    )

    if ($ProductCode -notmatch '^\{[0-9A-Fa-f\-]{36}\}$') {
        Write-LiongardStateLog WARN "Invalid ProductCode '$ProductCode'; MSI uninstall skipped."
        return $null
    }

    $msiArgs = @('/x', $ProductCode, '/qn', '/norestart')
    if ($LogPath) { $msiArgs += @('/L*V', "`"$LogPath`"") }

    Write-LiongardStateLog INFO "Running: msiexec.exe $($msiArgs -join ' ')"
    try {
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -WindowStyle Hidden
        $code = $process.ExitCode
    }
    catch {
        Write-LiongardStateLog WARN "Failed to launch msiexec for $($ProductCode): $($_.Exception.Message)"
        return $null
    }

    switch ($code) {
        0       { Write-LiongardStateLog INFO "MSI uninstall of $ProductCode succeeded." }
        3010    { Write-LiongardStateLog INFO "MSI uninstall of $ProductCode succeeded (restart required)." }
        1605    { Write-LiongardStateLog INFO "MSI uninstall of $ProductCode returned 1605 (product not registered with Windows Installer)." }
        default { Write-LiongardStateLog WARN "MSI uninstall of $ProductCode returned exit code $code." }
    }
    return $code
}

function Remove-LiongardStoredCredentials {
    # Deletes the agent's stored secrets from Windows Credential Manager so a fresh install
    # cannot reuse them. Matches ONLY Generic credentials whose UserName is exactly
    # 'LiongardAgent\AgentKey'; target names are random and are never used for matching.
    # Secret values are never read or logged.
    # TODO: Pending developer confirmation that a fresh install always issues new
    # credentials, so removing these entries can never strand a working agent.
    $found   = 0
    $removed = 0
    $failed  = 0

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.User -or $identity.User.Value -ne 'S-1-5-18') {
        Write-LiongardStateLog WARN ("Not running as SYSTEM (current: {0}). The agent's Credential Manager entries are only visible to SYSTEM; skipping credential cleanup." -f $identity.Name)
        return [pscustomobject]@{ Status = 'Skipped'; Found = 0; Removed = 0; Failed = 0 }
    }

    try {
        if (-not ('LiongardCredentialStore' -as [type])) {
            Add-Type -TypeDefinition $script:LiongardCredentialStoreSource -Language CSharp -ErrorAction Stop
        }
        $store   = 'LiongardCredentialStore' -as [type]
        $targets = @($store::FindGenericTargets($script:LiongardCredentialUser))
    }
    catch {
        Write-LiongardStateLog WARN "Unable to enumerate Credential Manager entries: $($_.Exception.Message)"
        return [pscustomobject]@{ Status = 'Failed'; Found = 0; Removed = 0; Failed = 0 }
    }

    $found = $targets.Count
    foreach ($target in $targets) {
        $errorCode = $store::DeleteGeneric($target)
        if ($errorCode -eq 0 -or $errorCode -eq 1168) { $removed++ }
        else {
            $failed++
            Write-LiongardStateLog WARN "CredDelete failed with Win32 error $errorCode for one '$($script:LiongardCredentialUser)' entry."
        }
    }

    $status = if ($found -eq 0) { 'NoneFound' } elseif ($failed -eq 0) { 'Removed' } else { 'Failed' }
    Write-LiongardStateLog INFO ("Credential Manager cleanup: found {0}, removed {1}, failed {2} Generic entries for user '{3}'." -f $found, $removed, $failed, $script:LiongardCredentialUser)
    return [pscustomobject]@{ Status = $status; Found = $found; Removed = $removed; Failed = $failed }
}

function Invoke-LiongardStaleCleanup {
    # Cleans up a Stale install before a fresh install. Never call this for a Healthy
    # install; a normal upgrade must stay a normal upgrade.
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [string]$LogFolder
    )

    if ($State.State -ne 'Stale') {
        throw "Invoke-LiongardStaleCleanup called for install state '$($State.State)'; refusing."
    }

    Write-LiongardStateLog INFO 'Stale install detected. Cleaning up before a fresh install.'
    $issues = New-Object System.Collections.Generic.List[string]

    # 1. Orphaned service registration.
    if ($State.Service.Exists) {
        $null = Stop-LiongardProcesses
        if (-not (Remove-LiongardServiceRegistration -Name $script:LiongardServiceName)) { $issues.Add('service') | Out-Null }
    }

    # 2. Stale uninstall entry: attempt msiexec /x with its ProductCode (failure tolerated).
    foreach ($product in $State.Products) {
        if ($product.IsBundle -or -not $product.ProductCode) {
            Write-LiongardStateLog INFO "Skipping MSI uninstall for non-MSI entry '$($product.DisplayName)' ($($product.KeyPath))."
            continue
        }
        $msiLog = if ($LogFolder) { Join-Path -Path $LogFolder -ChildPath ("StaleUninstall_{0}_{1}.log" -f $product.ProductCode.Trim('{}'), (Get-Date -Format 'yyyyMMdd_HHmmss')) } else { $null }
        if ($msiLog) { Register-LiongardDeployLog -Label 'Stale uninstall log' -Path $msiLog -Redact }
        $code = Invoke-LiongardMsiUninstallByCode -ProductCode $product.ProductCode -LogPath $msiLog
        if ($null -eq $code -or ($code -ne 0 -and $code -ne 3010 -and $code -ne 1605)) {
            $issues.Add("msi:$($product.ProductCode)=$code") | Out-Null
        }
    }

    # 3. Rename the install folder so its appsettings-override.config cannot be reused.
    $null = Stop-LiongardProcesses
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($folder in @(Get-LiongardInstallFolders -Products $State.Products)) {
        $newName = '{0}.stale-{1}' -f (Split-Path -Path $folder -Leaf), $stamp
        try {
            Assert-NotProtectedPath -Path $folder
            Rename-Item -LiteralPath $folder -NewName $newName -ErrorAction Stop
            Write-LiongardStateLog INFO "Renamed stale install folder '$folder' to '$newName'."
        }
        catch {
            Write-LiongardStateLog WARN "Rename of '$folder' failed ($($_.Exception.Message)); falling back to deletion."
            try {
                Remove-LiongardPathSafe -LiteralPath $folder -Recurse
                Write-LiongardStateLog WARN "Deleted stale install folder '$folder' because it could not be renamed."
            }
            catch {
                Write-LiongardStateLog WARN "Failed to delete stale install folder '$folder': $($_.Exception.Message)"
                $issues.Add("folder:$folder") | Out-Null
            }
        }
    }

    # 4. Stored credentials.
    $credentials = Remove-LiongardStoredCredentials
    if ($credentials.Status -eq 'Failed') { $issues.Add('credentials') | Out-Null }

    if ($issues.Count -eq 0) {
        Write-LiongardStateLog INFO 'Stale-install cleanup completed.'
    }
    else {
        Write-LiongardStateLog WARN ("Stale-install cleanup completed with issues: {0}" -f ($issues -join ', '))
    }

    return [pscustomobject]@{
        Issues      = $issues.ToArray()
        Credentials = $credentials
    }
}

function Test-LiongardPostInstall {
    # Post-install validation: roaragent.exe Running (retried up to $TimeoutSeconds) AND
    # the \Liongard\LiongardAgentUpdater scheduled task registered.
    param(
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds    = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $status   = 'NotFound'
    while ($true) {
        $service = Get-Service -Name $script:LiongardServiceName -ErrorAction SilentlyContinue
        $status  = if ($service) { [string]$service.Status } else { 'NotFound' }
        if ($status -eq 'Running' -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    $taskPresent = Test-LiongardUpdaterTask
    $serviceInfo = Get-LiongardServiceInfo
    $healthy     = ($status -eq 'Running' -and $taskPresent)

    Write-LiongardStateLog INFO ("Post-install validation: service '{0}' status={1}; binary={2} (exists={3}); updater task present={4}; result={5}" -f $script:LiongardServiceName, $status, $serviceInfo.BinaryPath, $serviceInfo.BinaryExists, $taskPresent, $(if ($healthy) { 'PASS' } else { 'FAIL' }))

    return [pscustomobject]@{
        Healthy        = $healthy
        ServiceStatus  = $status
        ServiceRunning = ($status -eq 'Running')
        TaskPresent    = $taskPresent
        BinaryPath     = $serviceInfo.BinaryPath
    }
}

function Write-LiongardIdentityStatus {
    # Logs that the identity key was preserved and whether MachineID exists. Never logs its value.
    $keyExists        = $false
    $machineIdPresent = $false
    $base = $null
    try {
        # Registry32 maps to SOFTWARE\WOW6432Node on 64-bit Windows.
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
        $identityKey = $base.OpenSubKey('SOFTWARE\Liongard')
        if ($identityKey) {
            $keyExists = $true
            $identityKey.Close()
        }
        $agentKey = $base.OpenSubKey('SOFTWARE\Liongard\LiongardAgent')
        if ($agentKey) {
            try {
                $machineIdPresent = ($agentKey.GetSubKeyNames() -contains 'MachineID') -or ($agentKey.GetValueNames() -contains 'MachineID')
            }
            finally {
                $agentKey.Close()
            }
        }
    }
    catch {
        Write-LiongardStateLog WARN "Unable to read the Liongard identity key: $($_.Exception.Message)"
    }
    finally {
        if ($base) { $base.Close() }
    }

    Write-LiongardStateLog INFO ("Identity key HKLM\SOFTWARE\WOW6432Node\Liongard preserved (not modified by this script). Key present: {0} | MachineID present: {1}" -f $keyExists, $machineIdPresent)
}

# ====================================================================
# END SHARED BLOCK
# ====================================================================

# ====================================================================
# BEGIN SHARED BLOCK: Liongard deploy-folder functions
# Keep this block identical across LGAgentInstall-MSI-Simple, LGAgentInstall-MSI-Advanced,
# LGAgentInstall-EXE-Simple, LGAgentInstall-EXE-Advanced and LGAgentUninstall.
# Edit one copy, then copy it to the other scripts.
#
# Every run works in <Folder>\LiongardDeploy. Before anything is written there, the folder
# is created (or checked) and locked down to SYSTEM and Administrators. Installers are staged
# in Deploy\<guid>\ and deleted afterwards, installer logs are redacted in place, the five
# most recent logs of each type are kept, and leftovers in the legacy C:\Liongard folder are
# removed. $env:ProgramData\Liongard belongs to the agent and is never touched.
# ====================================================================

$script:LiongardDeploy = @{
    Root      = $null
    Stamp     = (Get-Date -Format 'yyyyMMdd_HHmmss')
    Stage     = $null
    Secrets   = @()
    Pending   = New-Object System.Collections.Generic.List[string]
    Logs      = New-Object System.Collections.Generic.List[object]
    Deleted   = @{}
    Completed = $false
}
$script:LiongardSystemSid     = 'S-1-5-18'
$script:LiongardAdminsSid     = 'S-1-5-32-544'
$script:LiongardLegacyFolder  = 'C:\Liongard'
$script:LiongardSecretPattern = '(?i)(ACCESS(KEY|SECRET)\S*\s*[=:]\s*)("[^"]*"|\S+)'
$script:LiongardLogRetention  = @(
    '^AgentInstall_(\d{8}_\d{6})(_.+)?\.log$',
    '^StaleUninstall_[0-9A-Fa-f-]+_(\d{8}_\d{6})\.log$',
    '^LGAgentScript_(\d{8}_\d{6})\.log$',
    '^LGAgentScript_EXE_(\d{8}_\d{6})\.log$',
    '^LGAgentUninstall_(\d{8}_\d{6})\.log$',
    '^LGAgentSummary_(\d{8}_\d{6})\.json$'
)

function Write-LiongardDeployLog {
    # Write-Host on purpose: RMM consoles capture the host stream, and output here must not
    # leak into function return values.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string]$Message)

    Write-Host "[LiongardDeploy] $Message"
}

function Hide-LiongardSecretText {
    # The one masking rule for every script: masks ACCESSKEY/ACCESSSECRET-style values, then any
    # literal key or secret registered for this run.
    param(
        [AllowNull()][string]$Text,
        [string[]]$Secret = $script:LiongardDeploy.Secrets
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text -replace $script:LiongardSecretPattern, '$1****'
    foreach ($value in @($Secret)) {
        if (-not [string]::IsNullOrEmpty($value) -and $value.Length -ge 4) { $result = $result.Replace($value, '****') }
    }
    return $result
}

function Get-LiongardPathAttribute {
    # Attributes of the path itself (links are not followed), or $null when nothing is there.
    param([Parameter(Mandatory)][string]$Path)

    try { return [System.IO.File]::GetAttributes($Path) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $null }
}

function Assert-LiongardPlainFolder {
    # $false when the path does not exist; $true for a normal folder; throws for a file or reparse point.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $attributes = Get-LiongardPathAttribute -Path $Path
    if ($null -eq $attributes) { return $false }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label [$Path] is a reparse point (symlink, junction or mount point). Refusing to use it." }
    if (($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) { throw "$Label [$Path] is a file, not a folder. Refusing to use it." }
    return $true
}

function Get-LiongardDeploySecurity {
    # Inheritance disabled with no inherited rules copied, Full Control for SYSTEM and Administrators
    # only (this folder, subfolders and files), owner Administrators.
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in $script:LiongardSystemSid, $script:LiongardAdminsSid) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
    }
    $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:LiongardAdminsSid)))
    return $security
}

function Test-LiongardDeploySecurity {
    # Reads the ACL back: protected, owner Administrators, and only Full Control allow rules for
    # SYSTEM and Administrators.
    param([Parameter(Mandatory)][string]$Path)

    $acl   = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if (-not $acl.AreAccessRulesProtected -or $owner -ne $script:LiongardAdminsSid) { return $false }
    $seen = @{}
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or $rule.AccessControlType -ne 'Allow' -or $sid -notin $script:LiongardSystemSid, $script:LiongardAdminsSid) { return $false }
        if (($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) { return $false }
        $seen[$sid] = $true
    }
    return ($seen.Count -eq 2)
}

function Find-LiongardReparsePoint {
    # Walks a folder without following links and returns the first reparse point inside it.
    param([Parameter(Mandatory)][string]$Path)

    foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($Path)) {
        $attributes = [System.IO.File]::GetAttributes($entry)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $entry }
        if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
            $found = Find-LiongardReparsePoint -Path $entry
            if ($found) { return $found }
        }
    }
    return $null
}

function Clear-LiongardDeployTree {
    # Deletes a folder tree. Links inside it are removed without being followed.
    param([Parameter(Mandatory)][string]$Path)

    $attributes = Get-LiongardPathAttribute -Path $Path
    if ($null -eq $attributes) { return }
    if (($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) { [System.IO.File]::Delete($Path); return }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($Path)) { Clear-LiongardDeployTree -Path $entry }
    }
    [System.IO.Directory]::Delete($Path, $false)
}

function Initialize-LiongardDeployFolder {
    # Creates and hardens <Folder>\LiongardDeploy. Throws (fail closed) before anything is written
    # when the folder cannot be trusted. The ACL of <Folder> itself is never changed.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Folder,
        [string[]]$Secret
    )

    $script:LiongardDeploy.Secrets = @($Secret | Where-Object { -not [string]::IsNullOrEmpty($_) })

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin  = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole((New-Object System.Security.Principal.SecurityIdentifier($script:LiongardAdminsSid)))
    if ($identity.User.Value -ne $script:LiongardSystemSid -and -not $isAdmin) {
        throw "Run this script as SYSTEM or from an elevated administrator session (current identity: $($identity.Name))."
    }

    $value = "$Folder".Trim()
    if ($value -notmatch '^[A-Za-z]:\\') { throw "Folder [$Folder] must be an absolute local path such as C:\ProgramData." }
    $parent = [System.IO.Path]::GetFullPath($value)
    $root   = [System.IO.Path]::Combine($parent, 'LiongardDeploy')

    $agentData = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($env:ProgramData, 'Liongard')).TrimEnd('\')
    $rootCheck = $root.TrimEnd('\')
    if ($rootCheck.Equals($agentData, [System.StringComparison]::OrdinalIgnoreCase) -or $rootCheck.StartsWith("$agentData\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Folder [$Folder] is inside the agent's own folder [$agentData]. Choose a different folder."
    }

    if (-not (Assert-LiongardPlainFolder -Path $parent -Label 'Folder')) {
        New-Item -Path $parent -ItemType Directory -Force -ErrorAction Stop | Out-Null
        [void](Assert-LiongardPlainFolder -Path $parent -Label 'Folder')
    }

    $security = Get-LiongardDeploySecurity
    if (Assert-LiongardPlainFolder -Path $root -Label 'Deploy folder') {
        $recovery = "To recover, delete the folder as an administrator (for example: rmdir /s /q `"$root`") and rerun the script."
        try { $owner = (Get-Acl -LiteralPath $root).GetOwner([System.Security.Principal.SecurityIdentifier]).Value }
        catch { throw "Unable to read the owner of the existing deploy folder [$root]: $($_.Exception.Message). $recovery" }
        if ($owner -notin $script:LiongardSystemSid, $script:LiongardAdminsSid) {
            throw "The existing deploy folder [$root] is owned by $owner, not SYSTEM or Administrators, so it may have been created by another user. $recovery"
        }
    }
    else {
        try { [void][System.IO.Directory]::CreateDirectory($root, $security) }
        catch { New-Item -Path $root -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        # CreateDirectory returns an existing folder silently, so check it again.
        [void](Assert-LiongardPlainFolder -Path $root -Label 'Deploy folder')
    }

    Set-Acl -LiteralPath $root -AclObject $security -ErrorAction Stop
    if (-not (Test-LiongardDeploySecurity -Path $root)) { throw "The permissions on [$root] could not be restricted to SYSTEM and Administrators." }
    $link = Find-LiongardReparsePoint -Path $root
    if ($link) { throw "The deploy folder contains a reparse point [$link]. Refusing to use it." }

    $script:LiongardDeploy.Root = $root
    Write-LiongardDeployLog "Deploy folder [$root] is restricted to SYSTEM and Administrators."
    return $root
}

function Get-LiongardDeployLogPath {
    # <deploy folder>\<Prefix>_<run timestamp><Extension>
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$Extension = '.log'
    )

    return (Join-Path -Path $script:LiongardDeploy.Root -ChildPath ("{0}_{1}{2}" -f $Prefix, $script:LiongardDeploy.Stamp, $Extension))
}

function Register-LiongardDeployLog {
    # Records a log for the end-of-run path list. -Redact also queues it (and, for an EXE bundle
    # log, its per-package logs) for redaction.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Redact
    )

    $script:LiongardDeploy.Logs.Add([pscustomobject]@{ Label = $Label; Path = $Path; Redact = [bool]$Redact })
    if ($Redact -and -not $script:LiongardDeploy.Pending.Contains($Path)) { $script:LiongardDeploy.Pending.Add($Path) }
}

function Get-LiongardRelatedLog {
    # The log itself plus any EXE bundle per-package logs (<name>_*.log) next to it.
    param([Parameter(Mandatory)][string]$Path)

    $folder = Split-Path -Path $Path -Parent
    $base   = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $files  = @()
    if ($null -ne (Get-LiongardPathAttribute -Path $Path)) { $files += $Path }
    if ($null -ne (Get-LiongardPathAttribute -Path $folder)) {
        $files += @([System.IO.Directory]::GetFiles($folder, "$($base)_*.log") | Sort-Object)
    }
    return $files
}

function Protect-LiongardInstallerLog {
    # Redacts a log in place (same encoding), then checks that no registered key or secret is left.
    # If any step fails, the log is deleted instead.
    param([Parameter(Mandatory)][string]$Path)

    [void]$script:LiongardDeploy.Pending.Remove($Path)
    foreach ($file in @(Get-LiongardRelatedLog -Path $Path)) {
        try {
            $attributes = [System.IO.File]::GetAttributes($file)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'the log is a reparse point' }
            $bytes = $null
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try { $bytes = [System.IO.File]::ReadAllBytes($file); break }
                catch [System.IO.IOException] { if ($attempt -eq 5) { throw }; Start-Sleep -Seconds 2 }
            }

            $encoding = [System.Text.Encoding]::Default
            $skip = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $encoding = New-Object System.Text.UTF8Encoding($true); $skip = 3 }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $encoding = New-Object System.Text.UnicodeEncoding($false, $true); $skip = 2 }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $encoding = New-Object System.Text.UnicodeEncoding($true, $true); $skip = 2 }
            else {
                # UTF-16LE without a BOM: most odd bytes are zero.
                $sample = [Math]::Min($bytes.Length, 4096); $zeros = 0
                for ($i = 1; $i -lt $sample; $i += 2) { if ($bytes[$i] -eq 0) { $zeros++ } }
                if ($sample -ge 2 -and $zeros -gt ($sample / 4)) { $encoding = New-Object System.Text.UnicodeEncoding($false, $false) }
            }

            $text  = $encoding.GetString($bytes, $skip, $bytes.Length - $skip)
            $clean = Hide-LiongardSecretText -Text $text
            if (-not [string]::Equals($clean, $text, [System.StringComparison]::Ordinal)) {
                $body = $encoding.GetBytes($clean)
                $out  = New-Object byte[] ($skip + $body.Length)
                [System.Array]::Copy($bytes, 0, $out, 0, $skip)
                [System.Array]::Copy($body, 0, $out, $skip, $body.Length)
                [System.IO.File]::WriteAllBytes($file, $out)
            }

            # Check the raw bytes for each value in UTF-8/ANSI and UTF-16 form, whatever encoding was detected.
            $latin1 = [System.Text.Encoding]::GetEncoding(28591)
            $raw = $latin1.GetString([System.IO.File]::ReadAllBytes($file))
            foreach ($value in $script:LiongardDeploy.Secrets) {
                if ($value.Length -lt 4) { continue }
                foreach ($form in [System.Text.Encoding]::UTF8, [System.Text.Encoding]::Unicode, [System.Text.Encoding]::BigEndianUnicode) {
                    if ($raw.Contains($latin1.GetString($form.GetBytes($value)))) { throw 'a key or secret is still present after redaction' }
                }
            }
            Write-LiongardDeployLog "Redacted installer log [$file]."
        }
        catch {
            Write-LiongardDeployLog "WARNING: could not redact installer log [$file] ($($_.Exception.Message)). Deleting it."
            try {
                [System.IO.File]::Delete($file)
                $script:LiongardDeploy.Deleted[$file] = 'deleted because it could not be redacted'
                Write-LiongardDeployLog "Deleted unredacted installer log [$file]."
            }
            catch {
                $script:LiongardDeploy.Deleted[$file] = 'COULD NOT BE REDACTED OR DELETED; it may contain the agent secret. Delete it manually'
                Write-LiongardDeployLog "ERROR: could not delete unredacted installer log [$file]: $($_.Exception.Message). Delete it manually."
            }
        }
    }
}

function Initialize-LiongardDeployStage {
    # Creates Deploy\<guid>\ for this run's installer and clears staging folders older than a day.
    $deploy = Join-Path -Path $script:LiongardDeploy.Root -ChildPath 'Deploy'
    if (-not (Assert-LiongardPlainFolder -Path $deploy -Label 'Staging folder')) {
        New-Item -Path $deploy -ItemType Directory -Force -ErrorAction Stop | Out-Null
        [void](Assert-LiongardPlainFolder -Path $deploy -Label 'Staging folder')
    }
    foreach ($old in [System.IO.Directory]::GetFileSystemEntries($deploy)) {
        try {
            if ([System.IO.Directory]::GetLastWriteTimeUtc($old) -lt [DateTime]::UtcNow.AddDays(-1)) {
                Clear-LiongardDeployTree -Path $old
                Write-LiongardDeployLog "Removed leftover staging folder [$old]."
            }
        }
        catch { Write-LiongardDeployLog "WARNING: could not remove leftover staging folder [$old]: $($_.Exception.Message)" }
    }

    $stage = Join-Path -Path $deploy -ChildPath ([guid]::NewGuid().ToString())
    New-Item -Path $stage -ItemType Directory -Force -ErrorAction Stop | Out-Null
    [void](Assert-LiongardPlainFolder -Path $stage -Label 'Staging folder')
    $script:LiongardDeploy.Stage = $stage
    return $stage
}

function Invoke-LiongardLegacyCleanup {
    # Removes known script leftovers from the top level of C:\Liongard (never recursively), then
    # the folder itself only when nothing else is left in it.
    param([string[]]$InstallerName)

    $legacy = $script:LiongardLegacyFolder
    try {
        $attributes = Get-LiongardPathAttribute -Path $legacy
        if ($null -eq $attributes) { return }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
            Write-LiongardDeployLog "Legacy folder [$legacy] is not a plain folder; skipped."
            return
        }

        $patterns = @('LiongardAgent*.msi', 'LiongardAgent*.exe', 'AgentInstall*.log', 'LGAgentSummary_*.json', 'LGAgentScript_*.log',
                      'LGAgentScript_EXE_*.log', 'StaleUninstall_*.log', 'LGAgentUninstall_*.log') + @($InstallerName | Where-Object { $_ })
        foreach ($file in [System.IO.Directory]::GetFiles($legacy)) {
            $name = [System.IO.Path]::GetFileName($file)
            if (-not @($patterns | Where-Object { $name -like $_ }).Count) { continue }
            try {
                [System.IO.File]::Delete($file)
                Write-LiongardDeployLog "Removed legacy file [$file]."
            }
            catch { Write-LiongardDeployLog "WARNING: could not remove legacy file [$file]: $($_.Exception.Message)" }
        }

        $left = @([System.IO.Directory]::GetFileSystemEntries($legacy)).Count
        if ($left -eq 0) {
            [System.IO.Directory]::Delete($legacy, $false)
            Write-LiongardDeployLog "Removed empty legacy folder [$legacy]."
        }
        else {
            Write-LiongardDeployLog "Legacy folder [$legacy] kept: $left other item(s) remain."
        }
    }
    catch { Write-LiongardDeployLog "WARNING: legacy folder cleanup failed: $($_.Exception.Message)" }
}

function Invoke-LiongardLogRetention {
    # Keeps the newest $Keep runs of each log type in the deploy folder (by the timestamp in the
    # name); an EXE bundle log and its per-package logs count as one run.
    param([int]$Keep = 5)

    if (-not $script:LiongardDeploy.Root) { return }
    $files = @([System.IO.Directory]::GetFiles($script:LiongardDeploy.Root) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    foreach ($pattern in $script:LiongardLogRetention) {
        $runs = @($files | Where-Object { $_ -match $pattern } | Group-Object { [regex]::Match($_, $pattern).Groups[1].Value } | Sort-Object Name -Descending)
        foreach ($run in @($runs | Select-Object -Skip $Keep)) {
            foreach ($name in $run.Group) {
                $file = Join-Path -Path $script:LiongardDeploy.Root -ChildPath $name
                try {
                    [System.IO.File]::Delete($file)
                    Write-LiongardDeployLog "Removed old log [$file]."
                }
                catch { Write-LiongardDeployLog "WARNING: could not remove old log [$file]: $($_.Exception.Message)" }
            }
        }
    }
}

function Complete-LiongardDeployRun {
    # Runs once at the end of every run, success or failure: redacts queued installer logs,
    # deletes this run's staging folder and applies log retention.
    if ($script:LiongardDeploy.Completed) { return }
    $script:LiongardDeploy.Completed = $true

    foreach ($log in @($script:LiongardDeploy.Pending)) { Protect-LiongardInstallerLog -Path $log }
    if ($script:LiongardDeploy.Stage) {
        try {
            Clear-LiongardDeployTree -Path $script:LiongardDeploy.Stage
            Write-LiongardDeployLog "Removed installer staging folder [$($script:LiongardDeploy.Stage)]."
        }
        catch { Write-LiongardDeployLog "WARNING: could not remove staging folder [$($script:LiongardDeploy.Stage)]: $($_.Exception.Message)" }
    }
    try { Invoke-LiongardLogRetention -Keep 5 }
    catch { Write-LiongardDeployLog "WARNING: log retention failed: $($_.Exception.Message)" }
}

function Write-LiongardDeployLogList {
    # Prints the full path of every log from this run to stdout.
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($log in $script:LiongardDeploy.Logs) {
        $paths = @($log.Path)
        if ($log.Redact) {
            $prefix = Join-Path -Path (Split-Path -Path $log.Path -Parent) -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($log.Path))
            $paths += @(Get-LiongardRelatedLog -Path $log.Path)
            $paths += @($script:LiongardDeploy.Deleted.Keys | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) })
        }
        foreach ($path in @($paths | Sort-Object -Unique)) {
            if ($script:LiongardDeploy.Deleted.ContainsKey($path)) { $lines.Add(("{0}: {1} ({2})" -f $log.Label, $path, $script:LiongardDeploy.Deleted[$path])) }
            elseif ($null -ne (Get-LiongardPathAttribute -Path $path)) { $lines.Add(("{0}: {1}" -f $log.Label, $path)) }
        }
    }
    Write-Output '=== Liongard log files ==='
    if ($lines.Count -eq 0) { Write-Output 'No log files were written.' }
    foreach ($line in $lines) { Write-Output $line }
}

# ====================================================================
# END SHARED BLOCK: Liongard deploy-folder functions
# ====================================================================

function Get-InstalledAgentVersion {
    # Returns the DisplayVersion of the installed Liongard Agent MSI (found by DisplayName,
    # not a hardcoded ProductCode) as a four-part [version], or $null when none is registered.
    $product = @(Get-LiongardInstalledProduct | Where-Object { -not $_.IsBundle }) | Select-Object -First 1
    if ($product) { return ConvertTo-LiongardVersion -Value $product.DisplayVersion }
    return $null
}

function Get-InstallerBundleVersion {
    # Reads the bundle version from the downloaded EXE's file version info. The WiX
    # bootstrapper bundle exposes its version via ProductVersion/FileVersion. Returns
    # a [version] object, or $null when the value is missing or cannot be parsed.
    # NOTE: the bundle version may differ slightly from the agent MSI's DisplayVersion,
    # so the EXE's own downgrade protection (exit code 1638) remains the real backstop.
    param([Parameter(Mandatory)][string]$Path)

    try {
        $info = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
        foreach ($candidate in @($info.ProductVersion, $info.FileVersion)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if ($candidate -match '\d+(\.\d+){1,3}') {
                $parsed = ConvertTo-LiongardVersion -Value $Matches[0]
                if ($parsed) { return $parsed }
            }
        }
    }
    catch {
        Write-Warning "Unable to read installer bundle version from [$Path]: $($_.Exception.Message)"
    }

    return $null
}

function Get-ExitCodeText {
    param([int]$Code)
    switch ($Code) {
        0     { 'Success' }
        3010  { 'Success, restart required' }
        1602  { 'User cancelled' }
        1603  { 'Fatal error during installation' }
        1618  { 'Another install in progress' }
        1638  { 'Another version is already installed' }
        1619  { 'Could not open installation package' }
        1622  { 'Error opening installation log file' }
        default { 'Unknown / check installer log' }
    }
}

function Start-LiongardTranscript {
    param([Parameter(Mandatory)][string]$TargetFolder)

    if (-not (Test-Path -LiteralPath $TargetFolder)) {
        try {
            New-Item -Path $TargetFolder -ItemType Directory -Force | Out-Null
        }
        catch {
            Write-Warning "Unable to create folder [$TargetFolder] for transcript logging: $($_.Exception.Message)"
            return
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:TranscriptPath = Join-Path -Path $TargetFolder -ChildPath ("LGAgentScript_EXE_{0}.log" -f $timestamp)
    Register-LiongardDeployLog -Label 'Script transcript' -Path $script:TranscriptPath

    try {
        Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
        $script:TranscriptStarted = $true
        Write-Host "Script transcript logging enabled at [$script:TranscriptPath]."
    }
    catch {
        Write-Warning "Unable to start transcript logging at [$script:TranscriptPath]: $($_.Exception.Message)"
        $script:TranscriptPath = $null
    }
}

function Stop-LiongardTranscript {
    # Also the end-of-run hook: redacts installer logs, removes the staging folder, applies log
    # retention and, after the transcript closes, prints the log paths.
    Complete-LiongardDeployRun

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
            if ($script:TranscriptPath) {
                Write-Host "Script transcript saved to [$script:TranscriptPath]."
            }
        }
        catch {
            Write-Warning "Failed to finalize transcript logging: $($_.Exception.Message)"
        }
        finally {
            $script:TranscriptStarted = $false
            $script:TranscriptPath = $null
        }
    }

    Write-LiongardDeployLogList
}

function Write-RegistryLog {
    param(
        [ValidateSet('INFO','STEP','OK','WARN','ERROR')]
        [string]$Level,
        [string]$Message
    )

    $line = "[Registry][$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Warning $line }
        'ERROR' { Write-Error   $line }
        default { Write-Host    $line }
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter()][object]$Object,
        [Parameter()][string]$Name,
        [Parameter()][object]$Default = $null
    )

    if ($null -eq $Object -or [string]::IsNullOrEmpty($Name)) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Ensure-RegistryDrive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root
    )

    if (Get-PSDrive -Name $Name -ErrorAction SilentlyContinue) { return }

    try {
        New-PSDrive -Name $Name -PSProvider Registry -Root $Root -Scope Script -ErrorAction Stop | Out-Null
        Write-RegistryLog INFO "Mounted registry drive '${Name}:' at $Root for enumeration."
    }
    catch {
        Write-RegistryLog WARN "Failed to mount registry drive '${Name}:' ($Root): $($_.Exception.Message)"
    }
}

function Get-UninstallEntries {
    param(
        [string[]]$Names,
        [pscustomobject[]]$ProductCodes
    )

    $tokens = $Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() }
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $roots = @(
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall';             Scope = 'Machine' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall';             Scope = 'CurrentUser' },
        @{ Path = 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'CurrentUser' }
    )

    Ensure-RegistryDrive -Name 'HKU' -Root 'HKEY_USERS'

    try {
        $userRoots = Get-ChildItem HKU: -ErrorAction Stop | Where-Object { $_.PSChildName -match '^S-1-5-21' }
        foreach ($sid in $userRoots) {
            $sidBase = "HKU:\$($sid.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall"
            $roots += @{ Path = $sidBase; Scope = "User:$($sid.PSChildName)" }
            $roots += @{ Path = "$sidBase\WOW6432Node"; Scope = "User:$($sid.PSChildName)" }
        }
    }
    catch {
        Write-RegistryLog WARN "Unable to enumerate HKU hives: $($_.Exception.Message)"
    }

    $found = @()
    foreach ($root in $roots) {
        $path = $root.Path
        if (-not (Test-Path $path)) { continue }

        try {
            $keys = Get-ChildItem -Path $path -ErrorAction Stop
        }
        catch {
            Write-RegistryLog WARN "Skipping uninstall root '$path' due to access error: $($_.Exception.Message)"
            continue
        }

        foreach ($k in $keys) {
            try {
                $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
            }
            catch {
                Write-RegistryLog WARN "Skipping uninstall key due to read error: $($_.Exception.Message)"
                continue
            }

            $display = Get-ObjectPropertyValue -Object $props -Name 'DisplayName'
            $keyName = $k.PSChildName
            $haystack = @($display, $keyName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $haystackLower = $haystack | ForEach-Object { $_.ToLowerInvariant() }

            $isMatch = $false
            foreach ($token in $tokens) {
                if ($haystackLower | Where-Object { $_ -like "*$token*" }) {
                    $isMatch = $true
                    break
                }
            }

            if (-not $isMatch) { continue }

            $friendlyName = if ($display) { $display } elseif ($keyName) { $keyName } else { '(Unnamed entry)' }
            if (-not $seenPaths.Add($k.PSPath)) { continue }

            $found += [pscustomobject]@{
                DisplayName = $display
                Name        = $friendlyName
                Quiet       = Get-ObjectPropertyValue -Object $props -Name 'QuietUninstallString'
                Normal      = Get-ObjectPropertyValue -Object $props -Name 'UninstallString'
                KeyPath     = $k.PSPath
                KeyName     = $keyName
                Scope       = $root.Scope
                ProductCode = if ($keyName -and $keyName -match '^\{[0-9A-F\-]+\}$') { $keyName } else { $null }
            }
        }
    }

    foreach ($pc in $ProductCodes) {
        if (-not $pc.Code) { continue }
        $code = $pc.Code
        $candidatePaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$code",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"
        )

        foreach ($kp in $candidatePaths) {
            try {
                if (-not (Test-Path -LiteralPath $kp)) { continue }
                $item = Get-Item -LiteralPath $kp -ErrorAction Stop
                $props = Get-ItemProperty -LiteralPath $kp -ErrorAction Stop
                $display = Get-ObjectPropertyValue -Object $props -Name 'DisplayName'
                $friendlyName = if ($display) { $display } elseif ($pc.Name) { $pc.Name } else { "$code (MSI)" }
                $scope = if ($kp -like 'HKLM:\*') { 'Machine (known)' } else { 'User (known)' }

                if (-not $seenPaths.Add($item.PSPath)) { continue }

                Write-RegistryLog INFO "Including known uninstall entry fallback: $friendlyName -> $kp"

                $found += [pscustomobject]@{
                    DisplayName = $display
                    Name        = $friendlyName
                    Quiet       = Get-ObjectPropertyValue -Object $props -Name 'QuietUninstallString'
                    Normal      = Get-ObjectPropertyValue -Object $props -Name 'UninstallString'
                    KeyPath     = $item.PSPath
                    KeyName     = $item.PSChildName
                    Scope       = $scope
                    ProductCode = $code
                }
            }
            catch {
                Write-RegistryLog WARN "Failed to evaluate known uninstall key '$kp': $($_.Exception.Message)"
            }
        }
    }

    return $found
}

function Get-LiongardAuthHeader {
    param(
        [string]$ApiTokenKey,
        [string]$ApiTokenSecret
    )

    $token = "$ApiTokenKey`:$ApiTokenSecret"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($token)
    $encoded = [System.Convert]::ToBase64String($bytes)
    return @{
        'X-ROAR-API-KEY' = $encoded
        'User-Agent'     = 'LiongardAgentInstallerEXE/1.1'
    }
}

function Mask-SecretValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value.Length -le 8) { return ('*' * $Value.Length) }

    $prefix = $Value.Substring(0, 4)
    $suffix = $Value.Substring($Value.Length - 4, 4)
    return "$prefix****$suffix"
}

function Hide-ProxyCredential {
    # Replaces the password in every user:pass@ pair with ****, whatever the scheme
    # (http, https, socks5) or with no scheme at all (user:pass@host:port).
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return ($Text -replace '(?<user>[^:/@\s,;="]+):[^@/\s,;"]*@', '${user}:****@')
}

function Mask-ProxyValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '<empty>' }

    return (Hide-ProxyCredential -Text $Value)
}

function Write-ConfigurationSnapshot {
    Start-LogSection -Name 'Config Snapshot'
    Write-SectionValue -Label 'InstancePrefix' -Value $InstancePrefix
    Write-SectionValue -Label 'ApiTokenKey (masked)' -Value (Mask-SecretValue -Value $ApiTokenKey)
    Write-SectionValue -Label 'ApiTokenSecret (masked)' -Value (Mask-SecretValue -Value $ApiTokenSecret)
    Write-SectionValue -Label 'AgentTokenKey (masked)' -Value (Mask-SecretValue -Value $AgentTokenKey)
    Write-SectionValue -Label 'AgentTokenSecret (masked)' -Value (Mask-SecretValue -Value $AgentTokenSecret)
    Write-SectionValue -Label 'Environment' -Value $Environment
    Write-SectionValue -Label 'AgentDescription' -Value $AgentDescription
    Write-SectionValue -Label 'IncludeEnvironmentValue' -Value $IncludeEnvironmentValue
    Write-SectionValue -Label 'Folder' -Value $Folder
    Write-SectionValue -Label 'InstallerUrl' -Value $InstallerUrl
    Write-SectionValue -Label 'InstallerFileName' -Value $InstallerFileName
    Write-SectionValue -Label 'InstallNpcap' -Value $InstallNpcap
    Write-SectionValue -Label 'EnableNetworkDiscovery' -Value $EnableNetworkDiscovery
    Write-SectionValue -Label 'EulaAccepted' -Value $EulaAccepted
    Write-SectionValue -Label 'SuppressRestart' -Value $SuppressRestart
    Write-SectionValue -Label 'PassiveMode' -Value $PassiveMode
    Write-SectionValue -Label 'InstallerLogPath' -Value $InstallerLogPath
    Write-SectionValue -Label 'ProxyUrl' -Value (Mask-ProxyValue -Value $ProxyUrl)
    Write-SectionValue -Label 'AutoUpdate' -Value $AutoUpdate
    Write-SectionValue -Label 'AutoUpdateArgumentName' -Value $AutoUpdateArgumentName
    Write-SectionValue -Label 'ClearProxyEnvironmentForInstaller' -Value $ClearProxyEnvironmentForInstaller
    Write-SectionValue -Label 'RawLogWarning' -Value 'Raw bundle/MSI logs may contain secrets. This transcript only prints masked installer arguments and summary data.'
    Complete-LogSection
}

function Get-HttpErrorDetail {
    param([System.Exception]$Exception)

    if ($null -eq $Exception) { return $null }

    try {
        $response = $Exception.Response
        if ($null -eq $response) { return $null }

        $stream = $response.GetResponseStream()
        if ($null -eq $stream) { return $null }

        $reader = New-Object System.IO.StreamReader($stream)
        try {
            $body = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($body)) {
            return $body.Trim()
        }
    }
    catch { }

    return $null
}

function Normalize-EnvironmentName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $trimmed = $Value.Trim()
    $trimmed = $trimmed -replace '^(?i)\s*(the|a|an)\s+', ''
    $trimmed = $trimmed -replace '&', ' and '
    $trimmed = $trimmed -replace '(?i)\band\b', ' '

    $formD = $trimmed.Normalize([Text.NormalizationForm]::FormD)
    $chars = $formD.ToCharArray() | Where-Object {
        [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark
    }
    $folded = -join $chars

    $normalized = ($folded -replace '[^0-9a-zA-Z]', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    return $normalized
}

function Get-LiongardEnvironmentNameValue {
    param($Environment)

    foreach ($key in @('Name','DisplayName','EnvironmentName','Environment')) {
        $prop = $Environment.PSObject.Properties[$key]
        if ($prop -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
            return [string]$prop.Value
        }
    }

    return $null
}

function Get-LiongardEnvironments {
    param(
        [Parameter(Mandatory)][string]$InstancePrefix,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $uri = "https://$InstancePrefix.app.liongard.com/api/v1/environments"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop
    }
    catch {
        $detail = Get-HttpErrorDetail -Exception $_.Exception
        if ($detail) {
            Write-Warning "Unable to retrieve Liongard environments: $($_.Exception.Message) | Response: $detail"
        }
        else {
            Write-Warning "Unable to retrieve Liongard environments: $($_.Exception.Message)"
        }
        return @()
    }

    # The /environments endpoint returns a bare JSON array; the fallback below is
    # defensive only and will not fire under normal operation.
    if ($null -eq $response) { return @() }
    if ($response -is [System.Array]) { return $response }
    return @($response)
}

function Resolve-LiongardEnvironmentName {
    param(
        [Parameter(Mandatory)][string]$InputName,
        [Parameter(Mandatory)][string]$InstancePrefix,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $script:EnvironmentResolutionReason = 'Unknown'
    $minNormalizedLength = 4
    $inputNormalized = Normalize-EnvironmentName -Value $InputName
    if (-not $inputNormalized) { return $null }

    if ($inputNormalized.Length -lt $minNormalizedLength) {
        $script:EnvironmentResolutionReason = 'TooShort'
        Write-Warning ("Provided environment value '{0}' normalized to '{1}', which is too short to match reliably (min {2})." -f $InputName, $inputNormalized, $minNormalizedLength)
        return $null
    }

    $environments = Get-LiongardEnvironments -InstancePrefix $InstancePrefix -Headers $Headers
    if (-not $environments -or $environments.Count -eq 0) {
        $script:EnvironmentResolutionReason = 'NoEnvironmentsReturned'
        return $null
    }

    $exact = $environments |
        Where-Object {
            $name = Get-LiongardEnvironmentNameValue -Environment $_
            [string]::Equals($name, $InputName, [System.StringComparison]::InvariantCultureIgnoreCase)
        } |
        Select-Object -First 1

    if ($exact) {
        $script:EnvironmentResolutionReason = 'ExactMatch'
        $exactName = Get-LiongardEnvironmentNameValue -Environment $exact
        if (-not [string]::IsNullOrWhiteSpace($exactName)) {
            return $exactName
        }
    }

    $normalizedCandidates = @()
    foreach ($env in $environments) {
        $name = Get-LiongardEnvironmentNameValue -Environment $env
        $normalized = Normalize-EnvironmentName -Value $name
        $normalizedCandidates += [pscustomobject]@{
            Name       = $name
            Normalized = $normalized
            Data       = $env
        }
    }

    $normalizedMatches = @($normalizedCandidates | Where-Object { $_.Normalized -and $_.Normalized -eq $inputNormalized })
    if ($normalizedMatches.Count -eq 1) {
        $script:EnvironmentResolutionReason = 'NormalizedMatch'
        return $normalizedMatches[0].Name
    }
    elseif ($normalizedMatches.Count -gt 1) {
        $script:EnvironmentResolutionReason = 'AmbiguousNormalized'
        $sample = ($normalizedMatches | Select-Object -First 3).Name -join '; '
        Write-Warning ("Multiple Liongard environments match provided name '{0}' after normalization; candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
        return $null
    }

    $prefixMatches = @(
        $normalizedCandidates |
        Where-Object {
            $_.Normalized -and (
                $_.Normalized.StartsWith($inputNormalized) -or
                $inputNormalized.StartsWith($_.Normalized)
            )
        }
    )

    if ($prefixMatches.Count -eq 1) {
        $script:EnvironmentResolutionReason = 'PrefixMatch'
        Write-Host ("Normalized environment prefix match: '{0}' -> '{1}'" -f $InputName, $prefixMatches[0].Name)
        return $prefixMatches[0].Name
    }
    elseif ($prefixMatches.Count -gt 1) {
        $script:EnvironmentResolutionReason = 'AmbiguousPrefix'
        $sample = ($prefixMatches | Select-Object -First 3).Name -join '; '
        Write-Warning ("Multiple Liongard environments partially match provided name '{0}' after normalization; candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
        return $null
    }

    # Substring contains match. Both sides must meet a minimum length to avoid spurious
    # hits from short environment names (e.g. "IT" matching "SMITH IT SERVICES").
    $containsMinLength = 6
    if ($inputNormalized.Length -ge $containsMinLength) {
        $containsMatches = @(
            $normalizedCandidates |
            Where-Object {
                $_.Normalized -and
                $_.Normalized.Length -ge $containsMinLength -and (
                    $_.Normalized.Contains($inputNormalized) -or
                    $inputNormalized.Contains($_.Normalized)
                )
            }
        )

        if ($containsMatches.Count -eq 1) {
            $script:EnvironmentResolutionReason = 'ContainsMatch'
            Write-Host ("Normalized environment contains match: '{0}' -> '{1}'" -f $InputName, $containsMatches[0].Name)
            return $containsMatches[0].Name
        }
        elseif ($containsMatches.Count -gt 1) {
            $script:EnvironmentResolutionReason = 'AmbiguousContains'
            $sample = ($containsMatches | Select-Object -First 3).Name -join '; '
            Write-Warning ("Multiple Liongard environments partially match provided name '{0}' after normalization (contains); candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
            return $null
        }
    }

    $script:EnvironmentResolutionReason = 'NoMatch'
    $knownNames = ($normalizedCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | Select-Object -ExpandProperty Name)
    $sampleNames = ($knownNames | Select-Object -First 5) -join '; '
    Write-Warning ("No Liongard environment matched provided name '{0}' (normalized '{1}'). Known environments: {2}" -f $InputName, $inputNormalized, $sampleNames)
    return $null
}

function Resolve-InstancePrefix {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "InstancePrefix must be provided."
    }

    $sanitized = $Value.Trim()
    if ($sanitized -match '^https?://') {
        $uri = [Uri]$sanitized
        $sanitized = $uri.Host
    }

    if ($sanitized -match '\.app\.liongard\.com$') {
        return ($sanitized -split '\.')[0]
    }

    return $sanitized
}

function Get-LocalHostnameVariants {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrimaryName
    )

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::InvariantCultureIgnoreCase)

    foreach ($entry in @(
            $PrimaryName,
            [System.Net.Dns]::GetHostName()
        )) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            $names.Add($entry) | Out-Null
        }
    }

    try {
        $cimHost = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DNSHostName
        if (-not [string]::IsNullOrWhiteSpace($cimHost)) {
            $names.Add($cimHost) | Out-Null
        }
    }
    catch { }

    try {
        $fqdn = [System.Net.Dns]::GetHostEntry('localhost').HostName
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) {
            $names.Add($fqdn) | Out-Null
        }
    }
    catch { }

    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $names.Add("$PrimaryName.$env:USERDNSDOMAIN") | Out-Null
    }

    $existing = @($names)
    foreach ($value in $existing) {
        if ($value.Length -gt 15) {
            $names.Add($value.Substring(0, 15)) | Out-Null
        }
    }

    return @($names)
}

function Get-LiongardInstaller {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MinimumBytes = 1048576,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (Test-Path -LiteralPath $DestinationPath) {
            try { Remove-LiongardPathSafe -LiteralPath $DestinationPath } catch { }
        }

        Write-Host ("Downloading Liongard Agent installer (attempt {0}/{1}) to [{2}]..." -f $attempt, $MaxAttempts, $DestinationPath)
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Write-Warning "Installer download failed: $($_.Exception.Message)"
            continue
        }

        try {
            $file = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
            if ($file.Length -lt $MinimumBytes) {
                Write-Warning ("Downloaded installer size {0} bytes is below expected threshold; retrying..." -f $file.Length)
                continue
            }

            Write-Host ("Installer download verified ({0:N0} bytes)." -f $file.Length)
            return $true
        }
        catch {
            Write-Warning "Unable to validate installer at [$DestinationPath]: $($_.Exception.Message)"
        }
    }

    return $false
}

function Convert-BoolToBundleValue {
    param([bool]$Value)
    if ($Value) { return '1' }
    return '0'
}

function Get-ExeInstallArguments {
    param(
        [Parameter(Mandatory)][string]$LiongardHost,
        [Parameter(Mandatory)][string]$AgentTokenKey,
        [Parameter(Mandatory)][string]$AgentTokenSecret,
        [Parameter(Mandatory)][string]$AgentName,
        [string]$Environment,
        [string]$AgentDescription,
        [bool]$EulaAccepted,
        [bool]$InstallNpcap,
        [bool]$SuppressRestart,
        [bool]$PassiveMode,
        [string]$LogPath,
        [string]$ProxyUrl,
        [Nullable[bool]]$AutoUpdate,
        [string]$AutoUpdateArgumentName
    )

    $arguments = New-Object System.Collections.Generic.List[string]

    if ($PassiveMode) { $arguments.Add('/passive') } else { $arguments.Add('/quiet') }
    if ($SuppressRestart) { $arguments.Add('/norestart') }
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $arguments.Add('/log')
        $arguments.Add("`"$LogPath`"")
    }

    $arguments.Add("EulaAccepted=$(Convert-BoolToBundleValue -Value $EulaAccepted)")
    $arguments.Add("InstallNpcap=$(Convert-BoolToBundleValue -Value $InstallNpcap)")
    $arguments.Add("LiongardUrl=$LiongardHost")
    $arguments.Add("LiongardAccessKey=$AgentTokenKey")
    $arguments.Add("LiongardAccessSecret=$AgentTokenSecret")
    $arguments.Add("LiongardAgentName=`"$AgentName`"")
    if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
        $arguments.Add("ProxyUrl=`"$ProxyUrl`"")
    }

    if (-not [string]::IsNullOrWhiteSpace($Environment)) {
        $arguments.Add("LiongardEnvironment=`"$Environment`"")
    }

    if (-not [string]::IsNullOrWhiteSpace($AgentDescription)) {
        $arguments.Add("LiongardDescription=`"$AgentDescription`"")
    }

    if ($null -ne $AutoUpdate -and -not [string]::IsNullOrWhiteSpace($AutoUpdateArgumentName)) {
        $arguments.Add("$AutoUpdateArgumentName=$((Convert-BoolToBundleValue -Value ([bool]$AutoUpdate)))")
    }

    return ,$arguments.ToArray()
}

function Get-MaskedInstallArguments {
    param([string[]]$Arguments)

    $masked = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $Arguments) {
        if ($arg -match '^LiongardAccessKey=') {
            $value = $arg.Substring('LiongardAccessKey='.Length).Trim('"')
            $masked.Add("LiongardAccessKey=$(Mask-SecretValue -Value $value)")
        }
        elseif ($arg -match '^LiongardAccessSecret=') {
            $value = $arg.Substring('LiongardAccessSecret='.Length).Trim('"')
            $masked.Add("LiongardAccessSecret=$(Mask-SecretValue -Value $value)")
        }
        elseif ($arg -match '^ProxyUrl=') {
            $value = $arg.Substring('ProxyUrl='.Length).Trim('"')
            if ([string]::IsNullOrWhiteSpace($value)) {
                $masked.Add('ProxyUrl="<empty>"')
            }
            else {
                $masked.Add("ProxyUrl=$(Mask-SecretValue -Value $value)")
            }
        }
        else {
            $masked.Add($arg)
        }
    }

    return $masked.ToArray()
}

function Get-ProxyEnvironmentSnapshot {
    $entries = New-Object System.Collections.Generic.List[object]
    $proxyNames = @(
        'HTTP_PROXY',
        'HTTPS_PROXY',
        'ALL_PROXY',
        'http_proxy',
        'https_proxy',
        'all_proxy',
        'NO_PROXY',
        'no_proxy'
    )

    foreach ($name in $proxyNames) {
        try {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
            }
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = [Environment]::GetEnvironmentVariable($name, 'User')
            }

            # Keep only the masked value. This snapshot is written to the JSON
            # summary, so the raw value (which can hold user:pass) must not be stored.
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $entries.Add([pscustomobject]@{
                    Name   = $name
                    Masked = $(if ($name -match 'proxy') { Mask-ProxyValue -Value $value } else { Mask-SecretValue -Value $value })
                }) | Out-Null
            }
        }
        catch { }
    }

    return $entries.ToArray()
}

function Start-LiongardInstallerProcess {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][bool]$ClearProxyEnvironment,
        [Parameter()][string]$ExplicitProxyUrl
    )

    if (-not $ClearProxyEnvironment) {
        return Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru
    }

    $argumentText = [string]::Join(' ', $Arguments)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $InstallerPath
    $startInfo.Arguments = $argumentText
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    foreach ($proxyName in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy','NO_PROXY','no_proxy')) {
        if ($startInfo.EnvironmentVariables.ContainsKey($proxyName)) {
            $null = $startInfo.EnvironmentVariables.Remove($proxyName)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitProxyUrl)) {
        $startInfo.EnvironmentVariables['HTTP_PROXY'] = $ExplicitProxyUrl
        $startInfo.EnvironmentVariables['HTTPS_PROXY'] = $ExplicitProxyUrl
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $process.WaitForExit()
    return $process
}

function Hide-LiongardLogSecret {
    # Masks installer log lines before they are printed or written to the run summary:
    # proxy credentials ("PROXYURL = http://user:pass@host"), then the shared
    # Hide-LiongardSecretText rule (ACCESSKEY/ACCESSSECRET values and the literal key and secret).
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $Line }
    return (Hide-LiongardSecretText -Text (Hide-ProxyCredential -Text $Line))
}

function Read-InstallerLogSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxWaitSeconds = 30
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Found       = $false
            StatusLine  = $null
            ErrorLine   = $null
            Tail        = @()
        }
    }

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    do {
        try {
            $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
        }
        catch {
            $lines = @()
        }

        if ($lines.Count -gt 0) {
            $trimmed = @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $statusLine = $null
            $errorLine = $null

            for ($index = $trimmed.Count - 1; $index -ge 0; $index--) {
                $line = $trimmed[$index]
                if (-not $statusLine -and $line -match '(?i)(success|completed|return value 0|exit code:? 0)') {
                    $statusLine = $line
                }
                if (-not $errorLine -and $line -match '(?i)(error|failed|fatal|return value 3|exception)') {
                    $errorLine = $line
                }
                if ($statusLine -or $errorLine) { break }
            }

            if ($statusLine -or $errorLine) {
                return [pscustomobject]@{
                    Found      = $true
                    StatusLine = Hide-LiongardLogSecret -Line $statusLine
                    ErrorLine  = Hide-LiongardLogSecret -Line $errorLine
                    Tail       = @($trimmed | Select-Object -Last 10 | ForEach-Object { Hide-LiongardLogSecret -Line $_ })
                }
            }
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Found      = $false
        StatusLine = $null
        ErrorLine  = $null
        Tail       = @($lines | Select-Object -Last 10 | ForEach-Object { Hide-LiongardLogSecret -Line $_ })
    }
}

function Get-TextFileContent {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $encodings = @('UTF8','Unicode','BigEndianUnicode','Default')
    foreach ($encoding in $encodings) {
        try {
            $content = Get-Content -LiteralPath $Path -Raw -Encoding $encoding -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                return $content -replace "`0", ''
            }
        }
        catch { }
    }

    return $null
}

function Get-ComponentValidationKind {
    param([string]$PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) { return $null }
    $token = $PackageId.ToLowerInvariant()

    if ($token -match 'npcap') { return 'Npcap' }
    if ($token -match 'visual|vcredist|vc_redist|vc\+\+|msvc|cpp') { return 'VisualCpp' }
    if ($token -match 'liongard|agent') { return 'AgentMsi' }

    return $null
}

function Get-InstallerBundlePackageSummary {
    param([Parameter(Mandatory)][string]$Path)

    $content = Get-TextFileContent -Path $Path
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }

    $packages = @{}
    $lines = $content -split "`r?`n"
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match 'Detected package:\s*(?<id>[^,]+),\s*state:\s*(?<state>[^,]+)(?:,\s*cached:\s*(?<cached>[^,]+))?') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].DetectedState = $Matches['state'].Trim()
            if ($Matches['cached']) { $packages[$id].Cached = $Matches['cached'].Trim() }
            continue
        }

        if ($line -match 'Planned package:\s*(?<id>[^,]+),\s*state:\s*(?<state>[^,]+).*?\bexecute:\s*(?<execute>[^,]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].PlannedState = $Matches['state'].Trim()
            $packages[$id].PlannedExecute = $Matches['execute'].Trim()
            continue
        }

        if ($line -match 'Applied execute package:\s*(?<id>[^,]+),\s*result:\s*(?<result>[^,]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].ApplyResult = $Matches['result'].Trim()
            continue
        }

        if ($line -match 'The process for package:\s*(?<id>[^,]+)\s+exited with code:\s*(?<code>0x[0-9A-Fa-f]+|\d+).*?type:\s*(?<type>[^ ]+)\s+and restart:\s*(?<restart>[^\.]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].ProcessExitCode = $Matches['code'].Trim()
            $packages[$id].ProcessExitType = $Matches['type'].Trim()
            $packages[$id].Restart = $Matches['restart'].Trim()
            continue
        }

        if ($line -match 'Package \(.*?\)\s*:\s*(?<id>[^,]+),\s*result:\s*(?<result>[^,]+)') {
            $id = $Matches['id'].Trim()
            if (-not $packages.ContainsKey($id)) {
                $packages[$id] = [ordered]@{ PackageId = $id; Kind = (Get-ComponentValidationKind -PackageId $id) }
            }
            $packages[$id].ApplyResult = $Matches['result'].Trim()
            continue
        }
    }

    return @(
        $packages.Values |
        Where-Object { $_.Kind } |
        ForEach-Object { [pscustomobject]$_ }
    )
}

function Get-BundlePackageRecord {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BundlePackages,
        [Parameter(Mandatory)][string]$PackageId
    )

    return ($BundlePackages | Where-Object { $_.PackageId -eq $PackageId } | Select-Object -First 1)
}

function Get-VcRuntimeRegistryStatus {
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($arch in @('X86','X64')) {
        $path = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$arch"
        $isInstalled = $false
        $version = $null

        try {
            if (Test-Path -LiteralPath $path) {
                $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
                $installedFlag = Get-ObjectPropertyValue -Object $item -Name 'Installed' -Default 0
                $version = Get-ObjectPropertyValue -Object $item -Name 'Version'
                $isInstalled = ($installedFlag -eq 1)
            }
        }
        catch { }

        $results.Add([pscustomobject]@{
            Architecture = $arch
            Installed    = $isInstalled
            Version      = $version
            Path         = $path
        }) | Out-Null
    }

    return $results.ToArray()
}

function Test-NpcapInstalled {
    foreach ($path in @(
            'C:\Windows\System32\drivers\npcap.sys',
            'C:\Windows\SysWOW64\Npcap\npcap.dll',
            'C:\Program Files\Npcap',
            'C:\Program Files (x86)\Npcap'
        )) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }

    foreach ($regPath in @(
            'HKLM:\SYSTEM\CurrentControlSet\Services\npcap',
            'HKLM:\SYSTEM\CurrentControlSet\Services\npf'
        )) {
        if (Test-Path -LiteralPath $regPath) {
            return $true
        }
    }

    $services = @('npcap','npcapwatchdog','npf')
    foreach ($serviceName in $services) {
        if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    $entries = @(Get-UninstallEntries -Names @('Npcap') -ProductCodes @())
    return ($entries.Count -gt 0)
}

function Get-VisualCppEntries {
    return @(Get-UninstallEntries -Names @('Microsoft Visual C++','Visual C++') -ProductCodes @() | Where-Object {
        $_.Name -match '(?i)redistributable' -and $_.Name -match '(?i)\((x86|x64)\)'
    })
}

function Get-NpcapDetectionDetails {
    $details = New-Object System.Collections.Generic.List[string]

    foreach ($serviceName in @('npcap','npcapwatchdog','npf')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $details.Add("Service '$serviceName' status=$($service.Status)") | Out-Null
        }
    }

    foreach ($regPath in @(
            'HKLM:\SYSTEM\CurrentControlSet\Services\npcap',
            'HKLM:\SYSTEM\CurrentControlSet\Services\npf'
        )) {
        if (Test-Path -LiteralPath $regPath) {
            $details.Add("Registry key present: $regPath") | Out-Null
        }
    }

    foreach ($path in @(
            'C:\Windows\System32\drivers\npcap.sys',
            'C:\Windows\SysWOW64\Npcap\npcap.dll',
            'C:\Program Files\Npcap',
            'C:\Program Files (x86)\Npcap'
        )) {
        if (Test-Path -LiteralPath $path) {
            $details.Add("Path present: $path") | Out-Null
        }
    }

    $entries = @(Get-UninstallEntries -Names @('Npcap') -ProductCodes @())
    foreach ($entry in ($entries | Select-Object -First 2)) {
        $details.Add("Uninstall entry: $($entry.Name)") | Out-Null
    }

    return $details.ToArray()
}

function Get-InstallerFailureHints {
    param([Parameter(Mandatory)][string]$LogPath)

    $content = Get-TextFileContent -Path $LogPath
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }

    $hints = New-Object System.Collections.Generic.List[string]

    if ($content -match '(?i)\(407\)\s+Proxy Authentication Required') {
        $hints.Add('Installer API validation failed with HTTP 407 Proxy Authentication Required. The MSI is attempting to use a proxy that is not accepted for this connection.') | Out-Null
    }
    if ($content -match '(?i)unable to contact the Liongard server with the URL and credentials provided') {
        $hints.Add('The Liongard MSI could not validate registration against the Liongard API endpoint.') | Out-Null
    }
    $proxyMatches = [regex]::Matches($content, '(?im)\bPROXYURL\s*=\s*(?:"(?<quoted>[^"]*)"|(?<plain>[^\s\r\n"]+))')
    foreach ($proxyMatch in $proxyMatches) {
        $proxyValue = if ($proxyMatch.Groups['quoted'].Success) {
            $proxyMatch.Groups['quoted'].Value
        }
        else {
            $proxyMatch.Groups['plain'].Value
        }

        $proxyValue = $proxyValue.Trim()
        $looksLikeProxyEndpoint = (
            $proxyValue -match '(?i)^(https?|socks[45]?)://' -or
            $proxyValue -match '^[A-Za-z0-9._-]+:\d{2,5}$'
        )

        if (-not [string]::IsNullOrWhiteSpace($proxyValue) -and $looksLikeProxyEndpoint) {
            $hints.Add("MSI runtime proxy value: $(Mask-ProxyValue -Value $proxyValue)") | Out-Null
        }
    }
    if ($content -match '(?i)\bRebootPending\s*=\s*1\b' -or $content -match '(?i)\bMsiSystemRebootPending\s*=\s*1\b') {
        $hints.Add('A pending reboot was detected during installation. This was not the primary failure in this run, but it can interfere with future installer attempts.') | Out-Null
    }

    return @($hints.ToArray() | Select-Object -Unique)
}

function Convert-ValidationDetailToText {
    param([Parameter()][object]$Detail)

    if ($null -eq $Detail) { return $null }

    if ($Detail -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Detail)) { return $null }
        return $Detail
    }

    if ($Detail -is [System.Collections.IEnumerable] -and -not ($Detail -is [string])) {
        $parts = @(
            $Detail |
            ForEach-Object { if ($null -ne $_) { [string]$_ } } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($parts.Count -eq 0) { return $null }
        return ($parts -join ' | ')
    }

    $text = [string]$Detail
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function New-BundlePackageSnapshot {
    param(
        [Parameter()][object]$Package,
        [Parameter(Mandatory)][string]$PackageId
    )

    if (-not $Package) {
        return [pscustomobject]@{
            PackageId      = $PackageId
            DetectedState  = $null
            PlannedState   = $null
            PlannedExecute = $null
            ApplyResult    = $null
            Restart        = $null
            ProcessExitCode = $null
            ProcessExitType = $null
        }
    }

    return [pscustomobject]@{
        PackageId       = $Package.PackageId
        DetectedState   = $Package.DetectedState
        PlannedState    = $Package.PlannedState
        PlannedExecute  = $Package.PlannedExecute
        ApplyResult     = $Package.ApplyResult
        Restart         = $Package.Restart
        ProcessExitCode = $Package.ProcessExitCode
        ProcessExitType = $Package.ProcessExitType
    }
}

function Get-LiongardAgentLocalValidation {
    # 'Installed' only when the install state is Healthy (uninstall entry + roaragent.exe
    # service + service binary on disk). A leftover folder or orphaned service no longer counts.
    $state = Get-LiongardInstallState
    $services = @()
    if ($state.Service.Exists) { $services += "$($state.Service.Name)=$($state.Service.Status)" }

    return [pscustomobject]@{
        Status   = $(if ($state.State -eq 'Healthy') { 'Installed' } else { 'NotDetected' })
        State    = $state.State
        Evidence = @($state.Evidence)
        Services = $services
    }
}

function Get-VisualCppLocalValidation {
    $entries = @(Get-VisualCppEntries)
    $runtimeKeys = @(Get-VcRuntimeRegistryStatus)
    $versions = @(
        $runtimeKeys |
        Where-Object { $_.Installed } |
        ForEach-Object {
            if ($_.Version) { "$($_.Architecture)=$($_.Version)" } else { "$($_.Architecture)=Installed" }
        }
    )

    $evidence = @()
    $evidence += @($entries | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)
    $evidence += $versions

    $status = if ($evidence.Count -gt 0) { 'Installed' } else { 'NotDetected' }

    return [pscustomobject]@{
        Status   = $status
        Evidence = @($evidence)
        Versions = @($versions)
    }
}

function Get-NpcapLocalValidation {
    $evidence = @(Get-NpcapDetectionDetails)
    $status = if (Test-NpcapInstalled) { 'Installed' } else { 'NotDetected' }

    return [pscustomobject]@{
        Status   = $status
        Evidence = @($evidence)
    }
}

function Resolve-FinalComponentStatus {
    param(
        [Parameter(Mandatory)][bool]$Requested,
        [Parameter(Mandatory)][pscustomobject]$Bundle,
        [Parameter(Mandatory)][pscustomobject]$Local,
        [string]$SkipStatus = 'SkippedByConfig'
    )

    if (-not $Requested) { return $SkipStatus }

    if ($Local.Status -eq 'Installed') {
        if ($Bundle.ApplyResult -eq '0x0' -or $Bundle.ProcessExitCode -eq '0x0') { return 'Installed' }
        if ($Bundle.DetectedState -eq 'Present' -and ($Bundle.PlannedExecute -eq 'None' -or -not $Bundle.PlannedExecute)) { return 'AlreadyPresent' }
        return 'Installed'
    }

    if ($Bundle.DetectedState -eq 'Present' -and ($Bundle.PlannedExecute -eq 'None' -or -not $Bundle.PlannedExecute)) {
        return 'AlreadyPresent'
    }
    if ($Bundle.ApplyResult -and $Bundle.ApplyResult -ne '0x0') {
        return 'Failed'
    }
    if ($Bundle.ProcessExitCode -and $Bundle.ProcessExitCode -ne '0x0') {
        return 'Failed'
    }
    if ($Bundle.PackageId -and ($Bundle.PlannedExecute -eq 'Install' -or $Bundle.DetectedState -or $Bundle.ApplyResult)) {
        return 'BundleOnly'
    }

    return 'NotDetected'
}

function New-ComponentValidationRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Requested,
        [Parameter(Mandatory)][pscustomobject]$Bundle,
        [Parameter(Mandatory)][pscustomobject]$Local,
        [string]$SkipStatus = 'SkippedByConfig'
    )

    $status = Resolve-FinalComponentStatus -Requested $Requested -Bundle $Bundle -Local $Local -SkipStatus $SkipStatus
    $evidence = @()
    $evidence += Convert-ToStringArray -Value $Local.Evidence

    return [pscustomobject]@{
        Name      = $Name
        Requested = $Requested
        Bundle    = $Bundle
        Local     = $Local
        Evidence  = @($evidence)
        Status    = $status
    }
}

function Get-ComponentValidationResults {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][bool]$InstallNpcapRequested
    )

    $bundlePackages = @(Get-InstallerBundlePackageSummary -Path $LogPath)
    if (-not $bundlePackages) { $bundlePackages = @() }

    $agentBundleRecord = Get-BundlePackageRecord -BundlePackages $bundlePackages -PackageId 'LiongardAgentMsi'
    $vcBundleRecord = Get-BundlePackageRecord -BundlePackages $bundlePackages -PackageId 'VC_redist.x86.exe'
    $npcapBundleRecord = Get-BundlePackageRecord -BundlePackages $bundlePackages -PackageId 'Npcap'

    $agentBundle = New-BundlePackageSnapshot -Package $agentBundleRecord -PackageId 'LiongardAgentMsi'
    $vcBundle = New-BundlePackageSnapshot -Package $vcBundleRecord -PackageId 'VC_redist.x86.exe'
    $npcapBundle = New-BundlePackageSnapshot -Package $npcapBundleRecord -PackageId 'Npcap'

    $results = @(
        New-ComponentValidationRecord -Name 'Liongard Agent MSI' -Requested $true -Bundle $agentBundle -Local (Get-LiongardAgentLocalValidation)
        New-ComponentValidationRecord -Name 'Visual C++ Runtime' -Requested $true -Bundle $vcBundle -Local (Get-VisualCppLocalValidation)
        New-ComponentValidationRecord -Name 'Npcap' -Requested $InstallNpcapRequested -Bundle $npcapBundle -Local (Get-NpcapLocalValidation) -SkipStatus 'SkippedByConfig'
    )

    return [pscustomobject]@{
        BundlePackages = @($bundlePackages)
        Components     = @($results)
    }
}

function Write-BundlePackageResults {
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$BundlePackages)

    Start-LogSection -Name 'Bundle Results'
    foreach ($package in $BundlePackages) {
        Write-Host "Package: $($package.PackageId)"
        Write-SectionValue -Label 'Detected State' -Value $package.DetectedState
        Write-SectionValue -Label 'Planned State' -Value $package.PlannedState
        Write-SectionValue -Label 'Planned Action' -Value $package.PlannedExecute
        Write-SectionValue -Label 'Result' -Value $package.ApplyResult
        Write-SectionValue -Label 'Process Exit Code' -Value $package.ProcessExitCode
        Write-SectionValue -Label 'Process Exit Type' -Value $package.ProcessExitType
        Write-SectionValue -Label 'Restart' -Value $package.Restart
        Write-Host "-----------------------------"
    }
    Complete-LogSection
}

function Write-ComponentValidationSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]]$Components)

    Start-LogSection -Name 'Component Validation'
    foreach ($result in $Components) {
        Write-Host ("Component: {0}" -f $result.Name)
        Write-SectionValue -Label 'Requested' -Value $result.Requested
        Write-SectionValue -Label 'Bundle Package' -Value $result.Bundle.PackageId
        Write-SectionValue -Label 'Bundle Detected State' -Value $result.Bundle.DetectedState
        Write-SectionValue -Label 'Bundle Planned Action' -Value $result.Bundle.PlannedExecute
        Write-SectionValue -Label 'Bundle Result' -Value $result.Bundle.ApplyResult
        Write-SectionValue -Label 'Bundle Restart' -Value $result.Bundle.Restart
        Write-SectionValue -Label 'Local Validation' -Value $result.Local.Status
        Write-SectionValue -Label 'Supporting Evidence' -Value $result.Evidence
        Write-SectionValue -Label 'Final Component Status' -Value $result.Status
        Write-Host "-----------------------------"
    }
    Complete-LogSection
}

function Get-FinalRunStatus {
    param(
        [Parameter(Mandatory)][int]$InstallerExitCode,
        [Parameter(Mandatory)][bool]$AgentDetected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][pscustomobject[]]$Components,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    if ($null -eq $Components) { $Components = @() }
    if ($null -eq $Warnings) { $Warnings = @() }
    if ($null -eq $Errors) { $Errors = @() }

    if ($Errors.Count -gt 0 -and ($InstallerExitCode -ne 0 -and $InstallerExitCode -ne 3010)) {
        return 'Failed'
    }

    $agentComponent = @($Components | Where-Object { $_.Name -eq 'Liongard Agent MSI' } | Select-Object -First 1)
    if (($InstallerExitCode -ne 0 -and $InstallerExitCode -ne 3010) -or -not $AgentDetected -or ($agentComponent.Status -eq 'Failed')) {
        return 'Failed'
    }

    $problemComponents = @($Components | Where-Object { $_.Status -in @('Failed','BundleOnly','NotDetected') })
    if ($problemComponents.Count -gt 0) {
        return 'PartialValidation'
    }

    if ($Warnings.Count -gt 0) {
        return 'SuccessWithWarnings'
    }

    return 'Success'
}

function Export-RunSummaryArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Summary
    )

    try {
        $folderPath = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $folderPath)) {
            New-Item -Path $folderPath -ItemType Directory -Force | Out-Null
        }

        $Summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
        Write-SectionValue -Label 'Summary Artifact' -Value $Path
    }
    catch {
        Add-RunWarning "Failed to write JSON summary artifact: $($_.Exception.Message)"
    }
}

function Set-NetworkDiscoveryEnabled {
    # Flips the network discovery 'enabled' flag from false to true in the agent's
    # network_discovery.yml. Requires administrative rights (the install directory is
    # under Program Files). Returns a status object for logging and the run summary.
    param(
        [string[]]$CandidatePaths = @(
            'C:\Program Files (x86)\LiongardInc\LiongardAgent\network_discovery.yml',
            'C:\Program Files\LiongardInc\LiongardAgent\network_discovery.yml'
        ),
        [string]$SearchRoot = 'C:\Program Files (x86)\LiongardInc'
    )

    # The agent's network_discovery.yml uses a flat 'enabled' key. Update this only
    # if the Liongard dev team renames it in a future agent build.
    $KeyName = 'enabled'

    $ymlPath = $CandidatePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

    if (-not $ymlPath -and -not [string]::IsNullOrWhiteSpace($SearchRoot) -and (Test-Path -LiteralPath $SearchRoot)) {
        $ymlPath = Get-ChildItem -LiteralPath $SearchRoot -Recurse -Filter 'network_discovery.yml' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $ymlPath) {
        return [pscustomobject]@{ Status = 'FileNotFound'; Path = $null; Detail = 'network_discovery.yml was not located under the agent install directory.' }
    }

    try {
        $content = [System.IO.File]::ReadAllText($ymlPath)
    }
    catch {
        return [pscustomobject]@{ Status = 'Failed'; Path = $ymlPath; Detail = "Unable to read file: $($_.Exception.Message)" }
    }

    # Match an indented "<key>: false" line. Notes on the construction:
    #   • The key may be nested under a parent block, so indentation is expected;
    #     indent is restricted to spaces/tabs so the match cannot span across lines.
    #   • The value may be bare or wrapped in matching single or double quotes
    #     (\x22 = ", \x27 = '); \k<q> requires the closing quote to match the opening.
    #   • The trailing group absorbs an optional carriage return: the file uses CRLF
    #     line endings and .NET's $ anchors to \n only, so the \r must be consumed
    #     (and preserved) for the line to match.
    $escapedKey = [regex]::Escape($KeyName)
    $pattern = "(?im)^(?<indent>[ \t]*)(?<key>$escapedKey)(?<sep>[ \t]*:[ \t]*)(?<q>[\x22\x27]?)(?<value>true|false)\k<q>(?<trail>[ \t]*(#[^\r\n]*)?\r?)$"
    $match = [regex]::Match($content, $pattern)

    if (-not $match.Success) {
        return [pscustomobject]@{ Status = 'KeyNotFound'; Path = $ymlPath; Detail = "Key '$KeyName' (set to true/false) was not found in the file." }
    }

    if ($match.Groups['value'].Value -match '(?i)true') {
        return [pscustomobject]@{ Status = 'AlreadyEnabled'; Path = $ymlPath; Detail = "'$KeyName' is already set to true." }
    }

    # Preserve original indentation, separator spacing, any quote style, and trailing comment.
    $quote = $match.Groups['q'].Value
    $newLine = $match.Groups['indent'].Value + $match.Groups['key'].Value + $match.Groups['sep'].Value + $quote + 'true' + $quote + $match.Groups['trail'].Value
    $updated = $content.Remove($match.Index, $match.Length).Insert($match.Index, $newLine)

    try {
        # Write back as UTF-8 without a BOM to avoid tripping the agent's YAML parser.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ymlPath, $updated, $utf8NoBom)
    }
    catch {
        return [pscustomobject]@{ Status = 'Failed'; Path = $ymlPath; Detail = "Unable to write file: $($_.Exception.Message)" }
    }

    return [pscustomobject]@{ Status = 'Enabled'; Path = $ymlPath; Detail = "Set '$KeyName' to true." }
}

function Invoke-NetworkDiscoveryStep {
    # Logs a 'Network Discovery' section and returns the resulting status string.
    param(
        [Parameter(Mandatory)][bool]$Enable
    )

    Start-LogSection -Name 'Network Discovery'
    Write-SectionValue -Label 'Enable Requested' -Value $Enable

    if (-not $Enable) {
        Write-SectionValue -Label 'Status' -Value 'SkippedByConfig'
        Complete-LogSection
        return 'SkippedByConfig'
    }

    $result = Set-NetworkDiscoveryEnabled
    Write-SectionValue -Label 'YAML Path' -Value $result.Path
    Write-SectionValue -Label 'Status' -Value $result.Status
    Write-SectionValue -Label 'Detail' -Value $result.Detail

    switch ($result.Status) {
        'Enabled'        { Write-Host "Network discovery enabled in [$($result.Path)]. A service restart or the agent's next reload cycle may be required for it to take effect." }
        'AlreadyEnabled' { Write-Host "Network discovery was already enabled; no change made." }
        default          { Add-RunWarning "Network discovery was not enabled ($($result.Status)): $($result.Detail)" }
    }

    Complete-LogSection
    return $result.Status
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 renders a progress bar for Invoke-WebRequest that slows large
# downloads dramatically; suppress it.
$ProgressPreference = 'SilentlyContinue'

$componentValidation = $null
$finalStatus = 'Failed'
$exitCode = -1
$agentDetected = $false
$logPath = $null
$environmentInput = $Environment
$environmentNormalized = Normalize-EnvironmentName -Value $Environment
$resolvedEnvironmentValue = $null
$localFqdn = $null
$proxyEnvironmentSnapshot = @()
$installedAgentVersion = $null
$installerBundleVersion = $null
$networkDiscoveryStatus = $null
$installStateValue = $null
$postInstall = $null

try {
    # Lock down the deploy folder before anything (including the transcript) is written.
    $deployFolder = Initialize-LiongardDeployFolder -Folder $Folder -Secret $AgentTokenKey, $AgentTokenSecret, $ApiTokenKey, $ApiTokenSecret

    Assert-ConfigurationValue -Name 'InstancePrefix' -Value $InstancePrefix
    Assert-ConfigurationValue -Name 'ApiTokenKey' -Value $ApiTokenKey
    Assert-ConfigurationValue -Name 'ApiTokenSecret' -Value $ApiTokenSecret
    Assert-ConfigurationValue -Name 'AgentTokenKey' -Value $AgentTokenKey
    Assert-ConfigurationValue -Name 'AgentTokenSecret' -Value $AgentTokenSecret
    if ($IncludeEnvironmentValue) {
        Assert-ConfigurationValue -Name 'Environment' -Value $Environment
    }

    if ($InstancePrefix -match '[?*\[\]]') {
        throw "InstancePrefix '$InstancePrefix' contains a placeholder character. Provide a valid instance prefix (e.g. us1, eu2)."
    }
    if ([string]::IsNullOrWhiteSpace($InstallerFileName) -or $InstallerFileName -ne [System.IO.Path]::GetFileName($InstallerFileName)) {
        throw "InstallerFileName '$InstallerFileName' must be a file name only, with no folder."
    }

    Start-LiongardTranscript -TargetFolder $deployFolder
    $script:SummaryArtifactPath = Get-LiongardDeployLogPath -Prefix 'LGAgentSummary' -Extension '.json'
    Register-LiongardDeployLog -Label 'Run summary' -Path $script:SummaryArtifactPath
    Write-ConfigurationSnapshot
    Invoke-LiongardLegacyCleanup -InstallerName $InstallerFileName

    Write-Host "Proceeding with Liongard Agent (EXE bundle) installation..."

    $instancePrefix = Resolve-InstancePrefix -Value $InstancePrefix
    $liongardHost = "$instancePrefix.app.liongard.com"
    $localHostname = $env:COMPUTERNAME
    $localHostnames = Get-LocalHostnameVariants -PrimaryName $localHostname
    $localFqdn = ($localHostnames | Where-Object { $_ -match '\.' } | Select-Object -First 1)

    Start-LogSection -Name 'Host Identity'
    Write-SectionValue -Label 'Resolved Liongard Host' -Value $liongardHost
    Write-SectionValue -Label 'Local Hostname' -Value $localHostname
    Write-SectionValue -Label 'Local FQDN' -Value $localFqdn
    Write-SectionValue -Label 'Host Identifiers Considered' -Value ($localHostnames -join ', ')
    Complete-LogSection

    $proxyEnvironmentSnapshot = @(Get-ProxyEnvironmentSnapshot)
    Start-LogSection -Name 'Proxy Preflight'
    Write-SectionValue -Label 'Configured ProxyUrl' -Value $(if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { '<empty>' } else { Mask-ProxyValue -Value $ProxyUrl })
    Write-SectionValue -Label 'Clear Proxy Environment For Installer' -Value $ClearProxyEnvironmentForInstaller
    if ($proxyEnvironmentSnapshot.Count -gt 0) {
        Write-Host "Detected proxy-related environment variables that the MSI may import at runtime:"
        foreach ($proxyEntry in $proxyEnvironmentSnapshot) {
            Write-SectionValue -Label $proxyEntry.Name -Value $proxyEntry.Masked
        }

        if ($ClearProxyEnvironmentForInstaller -and [string]::IsNullOrWhiteSpace($ProxyUrl)) {
            Write-Host "Installer child process will have proxy-related environment variables removed so the MSI does not repopulate PROXYURL from environment."
        }
        elseif ($ClearProxyEnvironmentForInstaller -and -not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
            Write-Host "Installer child process will have inherited proxy variables removed and replaced with the explicit ProxyUrl value."
        }
        else {
            Add-RunWarning "Proxy-related environment variables are present and may override a blank PROXYURL inside the MSI."
        }
    }
    else {
        Write-Host "No proxy-related environment variables were detected."
    }
    Complete-LogSection

    $headers = Get-LiongardAuthHeader -ApiTokenKey $ApiTokenKey -ApiTokenSecret $ApiTokenSecret

    Start-LogSection -Name 'Environment Resolution'
    Write-SectionValue -Label 'Environment Input' -Value $environmentInput
    Write-SectionValue -Label 'Environment Input Normalized' -Value $environmentNormalized
    if ($IncludeEnvironmentValue -and -not [string]::IsNullOrWhiteSpace($Environment)) {
        $script:EnvironmentResolutionReason = $null
        $resolvedEnvironment = Resolve-LiongardEnvironmentName -InputName $Environment -InstancePrefix $instancePrefix -Headers $headers
        if ($resolvedEnvironment -and -not [string]::Equals($resolvedEnvironment, $Environment, [System.StringComparison]::Ordinal)) {
            Write-Host ("Matched provided environment to Liongard: '{0}' -> '{1}' (Reason: {2})" -f $Environment, $resolvedEnvironment, $script:EnvironmentResolutionReason)
            $Environment = $resolvedEnvironment
        }
        elseif ($resolvedEnvironment) {
            Write-Host ("Environment confirmed in Liongard: '{0}' (Reason: {1})" -f $Environment, $script:EnvironmentResolutionReason)
        }
        else {
            $normalizedEnv = Normalize-EnvironmentName -Value $Environment
            $reasonLabel = if ($script:EnvironmentResolutionReason) { $script:EnvironmentResolutionReason } else { 'Unknown' }
            if ($reasonLabel -eq 'NoEnvironmentsReturned') {
                Add-RunWarning ("Environment lookup API did not return environments for host '{0}'. Continuing with the supplied LiongardEnvironment value '{1}' without API confirmation." -f $liongardHost, $Environment)
            }
            else {
                throw ("Environment '{0}' (normalized '{1}') could not be resolved in Liongard. Reason: {2}. Aborting installation because LiongardEnvironment is required." -f $Environment, $normalizedEnv, $reasonLabel)
            }
        }
    }
    $resolvedEnvironmentValue = $Environment
    Write-SectionValue -Label 'Resolution Reason' -Value $script:EnvironmentResolutionReason
    Write-SectionValue -Label 'Resolved Environment' -Value $resolvedEnvironmentValue
    Complete-LogSection

    Start-LogSection -Name 'Installer Download / Path Verification'
    # Stage the installer in a per-run folder; it is deleted at the end of the run.
    $installerPath = Join-Path -Path (Initialize-LiongardDeployStage) -ChildPath $InstallerFileName
    if (-not (Get-LiongardInstaller -Uri $InstallerUrl -DestinationPath $installerPath -MinimumBytes 1048576 -MaxAttempts 3)) {
        throw "Failed to download installer from [$InstallerUrl] after multiple attempts."
    }
    Write-SectionValue -Label 'Installer Path' -Value $installerPath

    if (-not [string]::IsNullOrWhiteSpace($InstallerLogPath)) {
        Add-RunWarning "InstallerLogPath is deprecated and ignored; installer logs are always written to [$deployFolder]."
    }
    $logPath = Get-LiongardDeployLogPath -Prefix 'AgentInstall'
    Register-LiongardDeployLog -Label 'Installer log' -Path $logPath -Redact
    Write-SectionValue -Label 'Bootstrapper Log Path' -Value $logPath
    Complete-LogSection

    # Classify the existing install. Stale leftovers (folder only, orphaned service, uninstall
    # entry without binaries) are cleaned up first so the new install cannot reuse an old
    # appsettings-override.config or stored credentials. A Healthy install is never cleaned
    # up; it goes through the normal version gate / upgrade path.
    Start-LogSection -Name 'Install State'
    $installState = Get-LiongardInstallState
    $installStateValue = $installState.State
    Write-LiongardInstallState -State $installState
    if ($installState.State -eq 'Stale') {
        $staleCleanup = Invoke-LiongardStaleCleanup -State $installState -LogFolder $deployFolder
        foreach ($issue in $staleCleanup.Issues) {
            Add-RunWarning "Stale-install cleanup issue: $issue"
        }
    }
    Complete-LogSection

    # Version gate: compare the downloaded bundle against a Healthy installed agent. Proceed
    # only when no healthy agent is present, or the bundle is strictly newer.
    Start-LogSection -Name 'Version Gate'
    $installedAgentVersion = if ($installState.State -eq 'Healthy') { Get-InstalledAgentVersion } else { $null }
    $installerBundleVersion = Get-InstallerBundleVersion -Path $installerPath
    Write-SectionValue -Label 'Installed Agent Version' -Value $(if ($installedAgentVersion) { $installedAgentVersion.ToString() } else { '<none>' })
    Write-SectionValue -Label 'Installer Bundle Version' -Value $(if ($installerBundleVersion) { $installerBundleVersion.ToString() } else { '<unknown>' })

    if ($installedAgentVersion -and $installerBundleVersion -and $installerBundleVersion -le $installedAgentVersion) {
        $agentDetected = $true
        $exitCode = 0
        $finalStatus = 'SkippedUpToDate'
        Write-SectionValue -Label 'Decision' -Value ("Installed version {0} is at or above bundle version {1}; skipping installation." -f $installedAgentVersion, $installerBundleVersion)
        Write-Host ("Liongard Agent {0} is already installed and the bundle ({1}) is not newer. Skipping installation." -f $installedAgentVersion, $installerBundleVersion)
        Complete-LogSection
        $networkDiscoveryStatus = Invoke-NetworkDiscoveryStep -Enable $EnableNetworkDiscovery
        exit 0
    }
    elseif ($installedAgentVersion -and -not $installerBundleVersion) {
        Write-SectionValue -Label 'Decision' -Value 'Bundle version unavailable; proceeding and relying on the installer''s built-in downgrade protection.'
        Add-RunWarning "Could not read the installer bundle version; proceeding with installation. The EXE refuses a downgrade (exit code 1638) if the installed agent is newer."
    }
    elseif ($installedAgentVersion) {
        Write-SectionValue -Label 'Decision' -Value ("Bundle version {0} is newer than installed {1}; proceeding with upgrade." -f $installerBundleVersion, $installedAgentVersion)
    }
    elseif ($installState.State -eq 'Stale') {
        Write-SectionValue -Label 'Decision' -Value 'Stale install was cleaned up; proceeding with a fresh installation.'
    }
    else {
        Write-SectionValue -Label 'Decision' -Value 'No existing Liongard Agent detected; proceeding with a fresh installation.'
    }
    Complete-LogSection

    $exeArguments = Get-ExeInstallArguments `
        -LiongardHost $liongardHost `
        -AgentTokenKey $AgentTokenKey `
        -AgentTokenSecret $AgentTokenSecret `
        -AgentName $localHostname `
        -Environment $(if ($IncludeEnvironmentValue) { $Environment } else { $null }) `
        -AgentDescription $AgentDescription `
        -EulaAccepted $EulaAccepted `
        -InstallNpcap $InstallNpcap `
        -SuppressRestart $SuppressRestart `
        -PassiveMode $PassiveMode `
        -LogPath $logPath `
        -ProxyUrl $ProxyUrl `
        -AutoUpdate $AutoUpdate `
        -AutoUpdateArgumentName $AutoUpdateArgumentName

    $maskedArguments = Get-MaskedInstallArguments -Arguments $exeArguments

    Start-LogSection -Name 'Installer Launch'
    Write-Host "Launching EXE installer..."
    Write-SectionValue -Label 'Masked Command' -Value ("`"{0}`" {1}" -f $installerPath, ($maskedArguments -join ' '))

    $process = Start-LiongardInstallerProcess -InstallerPath $installerPath -Arguments $exeArguments -ClearProxyEnvironment $ClearProxyEnvironmentForInstaller -ExplicitProxyUrl $ProxyUrl
    $exitCode = if ($process) { $process.ExitCode } else { $LASTEXITCODE }

    Write-SectionValue -Label 'Installer Exit Code' -Value "$exitCode ($(Get-ExitCodeText -Code $exitCode))"

    if (Test-Path -LiteralPath $logPath) {
        $logFile = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
        if ($logFile) {
            Write-SectionValue -Label 'Installer Log Path' -Value ("{0} ({1:N0} bytes)" -f $logPath, $logFile.Length)
        }
        else {
            Write-SectionValue -Label 'Installer Log Path' -Value $logPath
        }
    }
    else {
        Add-RunWarning "Installer log path was not found: $logPath"
    }

    $summary = Read-InstallerLogSummary -Path $logPath -MaxWaitSeconds 30
    Protect-LiongardInstallerLog -Path $logPath
    if ($summary.Found) {
        if ($summary.StatusLine) {
            Write-SectionValue -Label 'Installer Log Status' -Value $summary.StatusLine
        }
        if ($summary.ErrorLine) {
            Add-RunWarning "Installer log error hint: $($summary.ErrorLine)"
        }
    }
    elseif ($summary.Tail -and $summary.Tail.Count -gt 0) {
        Write-Host "Installer log tail:"
        foreach ($line in $summary.Tail) {
            Write-Host " - $line"
        }
    }
    Complete-LogSection

    try {
        $componentValidation = Get-ComponentValidationResults -LogPath $logPath -InstallNpcapRequested $InstallNpcap
        Write-BundlePackageResults -BundlePackages $componentValidation.BundlePackages
        Write-ComponentValidationSummary -Components $componentValidation.Components
        $failureHints = @(Get-InstallerFailureHints -LogPath $logPath)
        if ($failureHints.Count -gt 0) {
            Start-LogSection -Name 'Installer Failure Hints'
            foreach ($hint in $failureHints) {
                Add-RunWarning ([string]$hint)
            }
            Complete-LogSection
        }
    }
    catch {
        Add-RunWarning "Post-install validation summary encountered an error but the installer itself completed successfully: $($_.Exception.Message)"
    }

    # Post-install validation: roaragent.exe Running (retried ~60s) and the updater task registered.
    $agentDetected = $false
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        Start-LogSection -Name 'Post-Install Validation'
        $postInstall = Test-LiongardPostInstall -TimeoutSeconds 60
        Write-SectionValue -Label 'Service Status' -Value $postInstall.ServiceStatus
        Write-SectionValue -Label 'Service Binary' -Value $postInstall.BinaryPath
        Write-SectionValue -Label 'Updater Task Present' -Value $postInstall.TaskPresent
        Complete-LogSection
        $agentDetected = [bool]$postInstall.Healthy
    }

    if (($exitCode -eq 0 -or $exitCode -eq 3010) -and $agentDetected) {
        $networkDiscoveryStatus = Invoke-NetworkDiscoveryStep -Enable $EnableNetworkDiscovery
        $finalStatus = Get-FinalRunStatus -InstallerExitCode $exitCode -AgentDetected $agentDetected -Components $(if ($componentValidation) { $componentValidation.Components } else { @() }) -Warnings @($script:RunWarnings) -Errors @($script:RunErrors)
        Start-LogSection -Name 'Final Outcome'
        Write-SectionValue -Label 'Final Status' -Value $finalStatus
        Write-SectionValue -Label 'Installer Exit Code' -Value "$exitCode ($(Get-ExitCodeText -Code $exitCode))"
        Write-SectionValue -Label 'Agent Detected' -Value $agentDetected
        Write-SectionValue -Label 'Warnings' -Value @($script:RunWarnings)
        Write-SectionValue -Label 'Errors' -Value @($script:RunErrors)
        Write-Host "Liongard Agent installation verified successfully."
        Complete-LogSection
        exit 0
    }

    if (($exitCode -eq 0 -or $exitCode -eq 3010) -and -not $agentDetected) {
        Add-RunWarning ("Installer returned success, but post-install validation failed (service '{0}' status: {1}; updater task present: {2})." -f $script:LiongardServiceName, $postInstall.ServiceStatus, $postInstall.TaskPresent)
        throw "Post-install validation failed after installer exit code $exitCode ($(Get-ExitCodeText -Code $exitCode))."
    }

    Add-RunWarning "Liongard Agent installation failed."

    throw "Installer returned exit code $exitCode ($(Get-ExitCodeText -Code $exitCode))."
}
catch {
    $finalStatus = 'Failed'
    $script:RunErrors.Add($_.Exception.Message) | Out-Null
    Start-LogSection -Name 'Final Outcome'
    Write-SectionValue -Label 'Final Status' -Value $finalStatus
    Write-SectionValue -Label 'Installer Exit Code' -Value $(if ($exitCode -ge 0) { "$exitCode ($(Get-ExitCodeText -Code $exitCode))" } else { '<not reached>' })
    Write-SectionValue -Label 'Warnings' -Value @($script:RunWarnings)
    Write-SectionValue -Label 'Errors' -Value @($script:RunErrors)
    Complete-LogSection
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    try {
        $componentList = if ($componentValidation) { @($componentValidation.Components) } else { @() }
        $agentComponent = @($componentList | Where-Object { $_.Name -eq 'Liongard Agent MSI' } | Select-Object -First 1)
        $visualCppComponent = @($componentList | Where-Object { $_.Name -eq 'Visual C++ Runtime' } | Select-Object -First 1)
        $npcapComponent = @($componentList | Where-Object { $_.Name -eq 'Npcap' } | Select-Object -First 1)
        if ($finalStatus -eq 'Failed' -and ($exitCode -eq 0 -or $exitCode -eq 3010) -and $agentDetected) {
            $finalStatus = Get-FinalRunStatus -InstallerExitCode $exitCode -AgentDetected $agentDetected -Components $componentList -Warnings @($script:RunWarnings) -Errors @($script:RunErrors)
        }

        $summary = [ordered]@{
            hostname                    = $env:COMPUTERNAME
            fqdn                        = $localFqdn
            environmentInput            = $environmentInput
            environmentResolved         = $resolvedEnvironmentValue
            environmentResolutionReason = $script:EnvironmentResolutionReason
            installState                = $installStateValue
            installedAgentVersion       = if ($installedAgentVersion) { $installedAgentVersion.ToString() } else { $null }
            installerBundleVersion      = if ($installerBundleVersion) { $installerBundleVersion.ToString() } else { $null }
            installerExitCode           = $exitCode
            bundlePackageResults        = if ($componentValidation) { @(Convert-ToPlainObject -Value $componentValidation.BundlePackages) } else { @() }
            liongardAgentStatus         = if ($agentComponent) { $agentComponent.Status } else { $null }
            visualCppStatus             = if ($visualCppComponent) { $visualCppComponent.Status } else { $null }
            visualCppVersions           = if ($visualCppComponent) { @(Convert-ToStringArray -Value $visualCppComponent.Local.Versions) } else { @() }
            npcapStatus                 = if ($npcapComponent) { $npcapComponent.Status } else { $null }
            serviceStatus               = if ($postInstall) { $postInstall.ServiceStatus } else { $null }
            updaterTaskPresent          = if ($postInstall) { $postInstall.TaskPresent } else { $null }
            networkDiscoveryStatus      = $networkDiscoveryStatus
            proxyEnvironmentDetected    = @(Convert-ToPlainObject -Value $proxyEnvironmentSnapshot)
            finalStatus                 = $finalStatus
            warnings                    = @(Convert-ToStringArray -Value $script:RunWarnings)
            errors                      = @(Convert-ToStringArray -Value $script:RunErrors)
        }

        if ($script:SummaryArtifactPath) {
            Start-LogSection -Name 'Summary Artifact'
            Export-RunSummaryArtifact -Path $script:SummaryArtifactPath -Summary $summary
            Complete-LogSection
        }
    }
    catch {
        Write-Warning "Failed during summary artifact finalization: $($_.Exception.Message)"
    }
    Write-LiongardIdentityStatus
    Stop-LiongardTranscript
}
