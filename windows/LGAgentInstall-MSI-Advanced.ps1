#requires -Version 5.1
<#
    Liongard Agent deployment script that:
      • Validates partner-supplied config values.
      • Resolves the target Liongard environment name via the API.
      • Downloads the MSI installer and compares its version against any currently installed agent.
      • Classifies any existing install as Healthy / Stale / NotInstalled. Stale leftovers
        (folder, orphaned service, stored credentials) are cleaned up before a fresh install;
        the identity key HKLM\SOFTWARE\WOW6432Node\Liongard is never modified.
      • Installs the agent when no prior installation is found, or upgrades it when the downloaded
        version is strictly newer than what is installed.
      • Validates that the roaragent.exe service is Running and the updater task exists.
      • Summarizes the result using AgentInstall.log plus transcript logging.

    Written by David Chapman, Manager of Partner Support.
    Last updated: 2026-10-10
#>

# ================================
# Partner Configuration - Update these values
# ================================
# Replace every placeholder string below with your tenant-specific values
# before distributing or executing the script.
$InstancePrefix          = "REPLACE_WITH_INSTANCE_PREFIX"     # Example: us1, us2, us3, eu1, etc.
$ApiTokenKey             = "REPLACE_WITH_API_TOKEN_KEY"       # Liongard API token key
$ApiTokenSecret          = "REPLACE_WITH_API_TOKEN_SECRET"    # Liongard API token secret
$AgentTokenKey           = "REPLACE_WITH_AGENT_TOKEN_KEY"     # Liongard agent install key
$AgentTokenSecret        = "REPLACE_WITH_AGENT_TOKEN_SECRET"  # Liongard agent install secret
$Environment             = "REPLACE_WITH_ENVIRONMENT_NAME"    # Environment name (can be an RMM variable)
$AgentDescription        = ""                                 # Optional agent description; when set, passed as LIONGARDDESCRIPTION
$IncludeEnvironmentValue = $true                              # Set to $false to omit the LIONGARDENVIRONMENT MSI property

# Optional: adjust installation path or installer URL if required.
# These rarely change but are exposed here for completeness.
$Folder       = "C:\Liongard"
$InstallerUrl = "https://agents.static.liongard.com/LiongardAgent-lts.msi"

# ================================
# Functions
# ================================

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
# Keep this block identical across LGAgentInstall_MSI_Advanced, LGAgentInstall_EXE_Advanced
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
        $msiLog = if ($LogFolder) { Join-Path -Path $LogFolder -ChildPath ("StaleUninstall_{0}.log" -f $product.ProductCode.Trim('{}')) } else { $null }
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

function Get-InstalledAgentVersion {
    # Returns the DisplayVersion of the installed Liongard Agent MSI (found by DisplayName,
    # not a hardcoded ProductCode) as a four-part [version], or $null when none is registered.
    $product = @(Get-LiongardInstalledProduct | Where-Object { -not $_.IsBundle }) | Select-Object -First 1
    if ($product) { return ConvertTo-LiongardVersion -Value $product.DisplayVersion }
    return $null
}

function Get-MsiProductVersion {
    # Opens the downloaded MSI via the Windows Installer COM interface and returns
    # its ProductVersion as a four-part [version] object, or $null on any failure.
    param([Parameter(Mandatory)][string]$Path)

    $installer = $null
    $db        = $null
    $view      = $null
    $record    = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $db,
            @("SELECT Value FROM Property WHERE Property = 'ProductVersion'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)

        if ($record) {
            $ver = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
            if (-not [string]::IsNullOrWhiteSpace($ver)) {
                return ConvertTo-LiongardVersion -Value $ver
            }
        }
    }
    catch {
        Write-Warning "Unable to read ProductVersion from MSI [$Path]: $($_.Exception.Message)"
    }
    finally {
        # Close the view and release COM references so the MSI file is not held open
        # when msiexec runs against it.
        if ($view) {
            try { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) } catch { }
        }
        foreach ($comObject in @($record, $view, $db, $installer)) {
            if ($comObject) {
                try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) } catch { }
            }
        }
    }

    return $null
}

function Get-MsiResultText {
    param([int]$Code)
    switch ($Code) {
        0     { 'Success' }
        3010  { 'Success, restart required' }
        1602  { 'User cancelled' }
        1603  { 'Fatal error during installation' }
        1618  { 'Another install in progress' }
        1638  { 'Another version is already installed' }
        1619  { 'Could not open installation package' }
        1612  { 'Installation source not available' }
        1620  { 'Could not open installation UI' }
        1622  { 'Error opening installation log file' }
        1625  { 'Installation forbidden by policy' }
        default { 'Unknown / see log' }
    }
}

function Read-MsiLogSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxWaitSeconds = 60
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Found = $false; Code = $null; Line = $null; InvalidMsg = $null }
    }

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)

    do {
        try {
            $logText = Get-Content -LiteralPath $Path -Encoding Unicode -Raw -ErrorAction Stop
        }
        catch {
            $logText = $null
        }

        if (-not $logText) {
            Start-Sleep -Milliseconds 400
            continue
        }

        $code       = $null
        $line       = $null
        $invalidMsg = $null

        $lines = $logText -split "`r?`n"
        for ($index = $lines.Length - 1; $index -ge 0; $index--) {
            $currentLine = $lines[$index].Trim()
            if (-not $currentLine) { continue }

            if (-not $invalidMsg -and $currentLine -match 'INVALIDMSG\s*=\s*(?<msg>.+)') {
                $invalidMsg = $Matches['msg'].Trim()
            }

            if (-not $code) {
                if ($currentLine -match 'MainEngineThread\s+is\s+returning\s+(?<code>\d+)') {
                    $code = [int]$Matches['code']
                    $line = $currentLine
                    if ($invalidMsg) { break }
                    continue
                }

                if ($currentLine -match 'Installation\s+success\s+or\s+error\s+status:\s+(?<code>\d+)') {
                    $code = [int]$Matches['code']
                    if ($invalidMsg) { break }
                    continue
                }

                if ($currentLine -match 'Product:\s.*?--\s*(?<msg>Installation\s+(completed\s+successfully|failed)\.?)') {
                    $line = $currentLine
                    $code = if ($Matches['msg'] -match 'success') { 0 } else { 1603 }
                    if ($invalidMsg) { break }
                    continue
                }
            }
        }

        if ($null -ne $code -or $invalidMsg) {
            return [pscustomobject]@{
                Found      = ($null -ne $code)
                Code       = $code
                Line       = $line
                InvalidMsg = $invalidMsg
            }
        }

        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{ Found = $false; Code = $null; Line = $null; InvalidMsg = $null }
}

$script:TranscriptStarted = $false
$script:TranscriptPath    = $null
$script:EnvironmentResolutionReason = $null

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
    $script:TranscriptPath = Join-Path -Path $TargetFolder -ChildPath ("LGAgentScript_{0}.log" -f $timestamp)

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
    if (-not $script:TranscriptStarted) { return }

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
        $script:TranscriptPath    = $null
    }
}

function Get-LiongardAuthHeader {
    # Builds the HTTP header required to authenticate with the Liongard REST API.
    param(
        [string]$ApiTokenKey,
        [string]$ApiTokenSecret
    )

    $token   = "$ApiTokenKey`:$ApiTokenSecret"
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($token)
    $encoded = [System.Convert]::ToBase64String($bytes)
    return @{
        'X-ROAR-API-KEY' = $encoded
        'User-Agent'     = 'LiongardAgentInstaller/1.0'
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

function Write-ConfigurationSnapshot {
    Write-Host "=== Liongard Agent Config Snapshot ==="
    Write-Host ("InstancePrefix          : {0}" -f $InstancePrefix)
    Write-Host ("ApiTokenKey (masked)    : {0}" -f (Mask-SecretValue -Value $ApiTokenKey))
    Write-Host ("ApiTokenSecret (masked) : {0}" -f (Mask-SecretValue -Value $ApiTokenSecret))
    Write-Host ("AgentTokenKey (masked)  : {0}" -f (Mask-SecretValue -Value $AgentTokenKey))
    Write-Host ("AgentTokenSecret(masked): {0}" -f (Mask-SecretValue -Value $AgentTokenSecret))
    Write-Host ("Environment             : {0}" -f $Environment)
    Write-Host ("AgentDescription        : {0}" -f $AgentDescription)
    Write-Host ("IncludeEnvironmentValue : {0}" -f $IncludeEnvironmentValue)
    Write-Host ("Folder                  : {0}" -f $Folder)
    Write-Host ("InstallerUrl            : {0}" -f $InstallerUrl)
    Write-Host "======================================"
}

function Normalize-EnvironmentName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $trimmed = $Value.Trim()
    # Strip leading articles to improve matching when environments differ by "The/A/An".
    $trimmed = $trimmed -replace '^(?i)\s*(the|a|an)\s+', ''
    # Treat "&" and the standalone word "and" as equivalent.
    $trimmed = $trimmed -replace '&', ' and '
    $trimmed = $trimmed -replace '(?i)\band\b', ' '

    # Remove diacritics before stripping punctuation to improve matching of accented names.
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

    foreach ($key in @('Name', 'DisplayName', 'EnvironmentName', 'Environment')) {
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
        Write-Warning "Unable to retrieve Liongard environments: $($_.Exception.Message)"
        return @()
    }

    # The /environments endpoint returns a bare JSON array; the envelope-unwrap
    # branches below are a defensive fallback and will not fire under normal operation.
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

    # Pass 1: exact case-insensitive match.
    $exact = $environments |
        Where-Object {
            $name = Get-LiongardEnvironmentNameValue -Environment $_
            [string]::Equals($name, $InputName, [System.StringComparison]::InvariantCultureIgnoreCase)
        } |
        Select-Object -First 1

    if ($exact) {
        $script:EnvironmentResolutionReason = 'ExactMatch'
        $exactName = Get-LiongardEnvironmentNameValue -Environment $exact
        if (-not [string]::IsNullOrWhiteSpace($exactName)) { return $exactName }
    }

    # Pre-compute normalized candidates for the remaining passes.
    $normalizedCandidates = @()
    foreach ($env in $environments) {
        $name       = Get-LiongardEnvironmentNameValue -Environment $env
        $normalized = Normalize-EnvironmentName -Value $name
        $normalizedCandidates += [pscustomobject]@{
            Name       = $name
            Normalized = $normalized
            Data       = $env
        }
    }

    # Pass 2: full normalized match.
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

    # Pass 3: prefix match (either side starts with the other).
    $prefixMatches = @(
        $normalizedCandidates | Where-Object {
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
        Write-Warning ("Multiple Liongard environments partially match provided name '{0}'; candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
        return $null
    }

    # Pass 4: substring contains match. Both sides must meet the minimum length to
    # avoid spurious hits from short environment names (e.g. "IT" matching "SMITH IT SERVICES").
    $containsMinLength = 6
    if ($inputNormalized.Length -ge $containsMinLength) {
        $containsMatches = @(
            $normalizedCandidates | Where-Object {
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
            Write-Warning ("Multiple Liongard environments partially match provided name '{0}' (contains); candidates: {1}. Skipping automatic mapping." -f $InputName, $sample)
            return $null
        }
    }

    $script:EnvironmentResolutionReason = 'NoMatch'
    $knownNames  = ($normalizedCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | Select-Object -ExpandProperty Name)
    $sampleNames = ($knownNames | Select-Object -First 5) -join '; '
    Write-Warning ("No Liongard environment matched provided name '{0}' (normalized '{1}'). Known environments: {2}" -f $InputName, $inputNormalized, $sampleNames)
    return $null
}

function Resolve-InstancePrefix {
    # Normalizes the instance input so partners can supply a short prefix, full host, or URL.
    param([string]$Value)

    $sanitized = $Value.Trim()
    if ($sanitized -match '^https?://') {
        $uri       = [Uri]$sanitized
        $sanitized = $uri.Host
    }

    if ($sanitized -match '\.app\.liongard\.com$') {
        return ($sanitized -split '\.')[0]
    }

    return $sanitized
}

function Get-LiongardInstaller {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MinimumBytes = 1048576,
        [int]$MaxAttempts  = 3
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

# ================================
# Main
# ================================

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
# Windows PowerShell 5.1 renders a progress bar for Invoke-WebRequest that slows large
# downloads dramatically; suppress it.
$ProgressPreference = 'SilentlyContinue'

Start-LiongardTranscript -TargetFolder $Folder

# Validate all required configuration values.
Assert-ConfigurationValue -Name 'InstancePrefix'   -Value $InstancePrefix
Assert-ConfigurationValue -Name 'ApiTokenKey'      -Value $ApiTokenKey
Assert-ConfigurationValue -Name 'ApiTokenSecret'   -Value $ApiTokenSecret
Assert-ConfigurationValue -Name 'AgentTokenKey'    -Value $AgentTokenKey
Assert-ConfigurationValue -Name 'AgentTokenSecret' -Value $AgentTokenSecret
if ($IncludeEnvironmentValue) {
    Assert-ConfigurationValue -Name 'Environment' -Value $Environment
}

# Catch placeholder-style wildcard characters that Assert-ConfigurationValue does not cover.
if ($InstancePrefix -match '[?*\[\]]') {
    Write-Error "InstancePrefix '$InstancePrefix' contains a placeholder character. Provide a valid instance prefix (e.g. us1, eu2)."
    Stop-LiongardTranscript
    exit 1
}

Write-ConfigurationSnapshot

$instancePrefix = Resolve-InstancePrefix -Value $InstancePrefix
$liongardHost   = "$instancePrefix.app.liongard.com"
Write-Host "Liongard instance host: $liongardHost"

$localHostname = $env:COMPUTERNAME
Write-Host "Local hostname: $localHostname"

$headers = Get-LiongardAuthHeader -ApiTokenKey $ApiTokenKey -ApiTokenSecret $ApiTokenSecret

# Resolve the environment name against the Liongard API to catch casing or
# punctuation differences before they are baked into the agent record.
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
        $reasonLabel   = if ($script:EnvironmentResolutionReason) { $script:EnvironmentResolutionReason } else { 'Unknown' }

        if ($reasonLabel -eq 'NoEnvironmentsReturned') {
            Write-Warning ("Environment lookup API returned no environments for host '{0}'. Continuing with the supplied LIONGARDENVIRONMENT value '{1}' without API confirmation." -f $liongardHost, $Environment)
        }
        else {
            Write-Error ("Environment '{0}' (normalized '{1}') could not be resolved in Liongard. Reason: {2}. Aborting installation because LIONGARDENVIRONMENT is required." -f $Environment, $normalizedEnv, $reasonLabel)
            Stop-LiongardTranscript
            exit 1
        }
    }
}

# Prepare the download directory.
Write-Host "Checking if folder [$Folder] exists..."
if (-not (Test-Path -Path $Folder)) {
    Write-Host "Creating directory at [$Folder]..."
    New-Item -Path $Folder -ItemType Directory -Force | Out-Null
}

if (-not (Test-Path -Path $Folder)) {
    Write-Error "Failed to create directory [$Folder]. Check permissions and rerun the script."
    Stop-LiongardTranscript
    exit 1
}

$installerPath = Join-Path -Path $Folder -ChildPath 'LiongardAgent-lts.msi'
if (-not (Get-LiongardInstaller -Uri $InstallerUrl -DestinationPath $installerPath)) {
    Write-Error "Failed to download installer from [$InstallerUrl] after multiple attempts. Aborting."
    Stop-LiongardTranscript
    exit 1
}

# Classify the existing install. Stale leftovers (folder only, orphaned service, uninstall
# entry without binaries) are cleaned up first so the new install cannot reuse an old
# appsettings-override.config or stored credentials. A Healthy install is never cleaned
# up; it goes through the normal version gate / upgrade path.
$installState = Get-LiongardInstallState
Write-LiongardInstallState -State $installState

if ($installState.State -eq 'Stale') {
    $staleCleanup = Invoke-LiongardStaleCleanup -State $installState -LogFolder $Folder
    if ($staleCleanup.Issues.Count -gt 0) {
        Write-Warning ("Stale-install cleanup finished with issues: {0}. Continuing with a fresh installation." -f ($staleCleanup.Issues -join ', '))
    }
}
elseif ($installState.State -eq 'Healthy') {
    # Version gate: proceed only when the downloaded MSI is strictly newer.
    $installedVersion = Get-InstalledAgentVersion
    $msiVersion       = Get-MsiProductVersion -Path $installerPath

    if ($installedVersion -and $msiVersion) {
        Write-Host ("Installed agent version: {0} | MSI version: {1}" -f $installedVersion, $msiVersion)

        if ($msiVersion -le $installedVersion) {
            Write-Host ("Liongard Agent {0} is already installed and the downloaded MSI ({1}) is not a newer version. Skipping installation." -f $installedVersion, $msiVersion)
            Write-LiongardIdentityStatus
            Stop-LiongardTranscript
            exit 0
        }

        Write-Host ("Newer version detected. Proceeding with upgrade: {0} -> {1}." -f $installedVersion, $msiVersion)
    }
    else {
        Write-Warning ("Unable to compare versions (installed: {0}, MSI: {1}). Proceeding with installation." -f $installedVersion, $msiVersion)
    }
}

Write-Host "Installing the Liongard Agent..."

$logPath = Join-Path -Path $Folder -ChildPath 'AgentInstall.log'
if (Test-Path -LiteralPath $logPath) {
    Write-Host "Removing existing installer log [$logPath] to capture fresh results..."
    try { Remove-LiongardPathSafe -LiteralPath $logPath } catch { Write-Warning "Unable to remove [$logPath]: $($_.Exception.Message)" }
}

$msiArguments = @(
    "/i", "`"$installerPath`"",
    "LIONGARDURL=$liongardHost",
    "LIONGARDACCESSKEY=$AgentTokenKey",
    "LIONGARDACCESSSECRET=$AgentTokenSecret",
    "LIONGARDAGENTNAME=`"$localHostname`""
)

if ($IncludeEnvironmentValue -and -not [string]::IsNullOrWhiteSpace($Environment)) {
    $msiArguments += "LIONGARDENVIRONMENT=`"$Environment`""
}

if (-not [string]::IsNullOrWhiteSpace($AgentDescription)) {
    $msiArguments += "LIONGARDDESCRIPTION=`"$AgentDescription`""
}

$msiArguments += @("/qn", "/norestart", "/L*V", "`"$logPath`"")

$process  = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArguments -Wait -PassThru
$exitCode = if ($process) { $process.ExitCode } else { $LASTEXITCODE }
Write-Host "Installation command completed. Evaluating results..."

$summary = Read-MsiLogSummary -Path $logPath -MaxWaitSeconds 60
if ($summary.Found) {
    $resultText = Get-MsiResultText -Code $summary.Code
    if ($summary.InvalidMsg) {
        Write-Host ("MSI status: {0} ({1})`nReason: {2}" -f $summary.Code, $resultText, $summary.InvalidMsg)
    }
    else {
        Write-Host ("MSI status: {0} ({1})`nLog line: {2}" -f $summary.Code, $resultText, $summary.Line)
    }
}
else {
    if (Test-Path -LiteralPath $logPath) {
        Write-Host "MSI log available at [$logPath], but no summary pattern was found."
    }
    else {
        Write-Warning "MSI log file [$logPath] was not found."
    }
}

$msiExitCode        = if ($summary.Found) { $summary.Code } else { $exitCode }
$installerSucceeded = ($msiExitCode -eq 0 -or $msiExitCode -eq 3010)

# Post-install validation: roaragent.exe Running (retried ~60s) and the updater task registered.
$validation = $null
if ($installerSucceeded) {
    $validation = Test-LiongardPostInstall -TimeoutSeconds 60
}

if ($installerSucceeded -and $validation.Healthy) {
    Write-Host "Liongard Agent installation verified successfully (process=$exitCode, msi=$msiExitCode)."
    Write-LiongardIdentityStatus
    Write-Host "Exiting script..."
    Stop-LiongardTranscript
    exit 0
}

Write-Warning "Liongard Agent installation failed or post-install validation did not pass. Exit code: $exitCode | MSI status: $msiExitCode"
if ($summary.InvalidMsg) {
    Write-Warning "MSI reported: $($summary.InvalidMsg)"
}
if ($validation -and -not $validation.Healthy) {
    Write-Warning ("Post-install validation failed: service '{0}' status [{1}], updater task present [{2}]." -f $script:LiongardServiceName, $validation.ServiceStatus, $validation.TaskPresent)
}
Write-LiongardIdentityStatus

$exitValue = if (-not $installerSucceeded -and $null -ne $msiExitCode) { $msiExitCode } else { 1 }
Stop-LiongardTranscript
exit $exitValue
