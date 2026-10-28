<#
.SYNOPSIS
    Removes the Liongard Agent from a Windows endpoint.

.DESCRIPTION
    Uninstalls the Liongard Agent and removes what it leaves behind.
    Set your values in the "Partner configuration" block below. Exit codes, logs and
    troubleshooting are in the README under .LINK.
    - Uninstalls the agent and removes its services, processes, folders and uninstall entries.
    - Leaves the agent's Credential Manager entries in place; that cleanup is disabled until the dev team confirms it is safe (#8).
    - Never modifies the agent identity key, so a later reinstall re-attaches to the same platform record.
    - Keeps the agent's record on the Liongard platform by default; set $RemoveAgentFromPlatform = $true to delete it through the API.
      The record is deleted only when exactly one agent has the same environment ($Environment) and hostname.
    - Writes a full transcript log of the run.

.NOTES
    Requires:     Windows PowerShell 5.1 (64-bit), run as SYSTEM or an elevated administrator.
                  Liongard API token only when $RemoveAgentFromPlatform = $true.
    Author:       Liongard Partner Support
    Last updated: 2026-10-21

.LINK
    https://github.com/liongard/agent-scripts/blob/main/windows/README.md
#>

#requires -Version 5.1

# ================================
# Partner Configuration - Update these values
# ================================
$RemoveAgentFromPlatform    = $false                            # Set to $true to delete the matching agent record via API
$InstancePrefix             = "REPLACE_WITH_INSTANCE_PREFIX"   # Example: us1, us2, us3, eu1, etc.
$ApiTokenKey                = "REPLACE_WITH_API_TOKEN_KEY"     # Liongard API token key (required for remote deletion)
$ApiTokenSecret             = "REPLACE_WITH_API_TOKEN_SECRET"  # Liongard API token secret (required for remote deletion)
$Environment                = ""                               # Environment the agent is registered in; used to pick the record to delete. Leave blank for an agent with no environment
$MinimumRemoteDeletionScore = 50                               # DEPRECATED: ignored, and a WARN is logged if changed. Will be removed in a later release
$LogFolder                  = $env:ProgramData                 # Parent folder; the transcript goes to <LogFolder>\LiongardDeploy (SYSTEM/Administrators only)

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
# and LGAgentUninstall-Advanced. Edit one copy, then copy it to the other scripts.
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
    # Disabled until dev confirms that a fresh install always issues new credentials (#8, dev Q1).
    # The cleanup below is kept unchanged; it runs again once this early return is removed.
    Write-LiongardStateLog INFO 'Credential Manager cleanup is disabled until dev confirms that a fresh install always issues new credentials (#8). No entries were changed.'
    return [pscustomobject]@{ Status = 'Disabled'; Found = 0; Removed = 0; Failed = 0 }

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

    # 4. Stored credentials. Currently disabled (Status 'Disabled', never an issue); see #8.
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
# LGAgentInstall-EXE-Simple, LGAgentInstall-EXE-Advanced, LGAgentUninstall-Advanced and
# LGAgentCleanInstall-MSI-Simple.
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
# user:pass@ in proxy values (any scheme or none). The last @ before the host is the separator, so a
# raw @ in the password is masked too; the password stops at /, whitespace, comma, semicolon or ".
$script:LiongardProxyCredentialPattern = '(?<user>[^:/@\s,;="]+):[^/\s,;"]*@'
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
    # The one masking rule for every script: masks proxy credentials (user:****@host),
    # ACCESSKEY/ACCESSSECRET-style values, then any literal key or secret registered for this run.
    param(
        [AllowNull()][string]$Text,
        [string[]]$Secret = $script:LiongardDeploy.Secrets
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = ($Text -replace $script:LiongardProxyCredentialPattern, '${user}:****@') -replace $script:LiongardSecretPattern, '$1****'
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

function Get-LiongardServiceNames {
    # Returns common service name variants used by Liongard Agent.
    return @(
        'roaragent',
        'roaragent.exe',
        'LiongardAgentSVC',
        'LiongardAgent',
        'Liongard Agent'
    )
}

function Test-LiongardAgentInstalled {
    # Checks the uninstall registry hives and service list to determine whether
    # the Liongard Agent is present on this endpoint.
    # Products are found by DisplayName in both registry views (the ProductCode changes
    # per version; the legacy code is only a fallback inside Get-LiongardInstalledProduct).
    if (@(Get-LiongardInstalledProduct).Count -gt 0) { return $true }

    $serviceNames = Get-LiongardServiceNames
    foreach ($svcName in $serviceNames) {
        $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($service) { return $true }
    }

    return $false
}

$script:TranscriptStarted = $false
$script:TranscriptPath    = $null

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
    $script:TranscriptPath = Join-Path -Path $TargetFolder -ChildPath ("LGAgentUninstall_{0}.log" -f $timestamp)
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
    # Also the end-of-run hook: applies log retention and, after the transcript closes, prints
    # the log paths.
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
            $script:TranscriptPath    = $null
        }
    }

    Write-LiongardDeployLogList
}

function Write-UninstallLog {
    param(
        [ValidateSet('INFO','STEP','OK','WARN','ERROR')]
        [string]$Level,
        [string]$Message
    )

    $line = "[Uninstall][$Level] $Message"
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
        Write-UninstallLog INFO "Mounted registry drive '${Name}:' at $Root for enumeration."
    }
    catch {
        Write-UninstallLog WARN "Failed to mount registry drive '${Name}:' ($Root): $($_.Exception.Message)"
    }
}

function Get-UninstallEntries {
    param(
        [string[]]$Names,
        [pscustomobject[]]$ProductCodes
    )

    $tokens    = $Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() }
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
        Write-UninstallLog WARN "Unable to enumerate HKU hives: $($_.Exception.Message)"
    }

    $found = @()
    foreach ($root in $roots) {
        $path = $root.Path
        if (-not (Test-Path $path)) { continue }

        try {
            $keys = Get-ChildItem -Path $path -ErrorAction Stop
        }
        catch {
            Write-UninstallLog WARN "Skipping uninstall root '$path' due to access error: $($_.Exception.Message)"
            continue
        }

        foreach ($k in $keys) {
            try {
                $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
            }
            catch {
                Write-UninstallLog WARN "Skipping uninstall key due to read error: $($_.Exception.Message)"
                continue
            }

            $display       = Get-ObjectPropertyValue -Object $props -Name 'DisplayName'
            $keyName       = $k.PSChildName
            $haystack      = @($display, $keyName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
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
        $code        = $pc.Code
        $candidatePaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$code",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$code"
        )

        foreach ($kp in $candidatePaths) {
            try {
                if (-not (Test-Path -LiteralPath $kp)) { continue }
                $item         = Get-Item -LiteralPath $kp -ErrorAction Stop
                $props        = Get-ItemProperty -LiteralPath $kp -ErrorAction Stop
                $display      = Get-ObjectPropertyValue -Object $props -Name 'DisplayName'
                $friendlyName = if ($display) { $display } elseif ($pc.Name) { $pc.Name } else { "$code (MSI)" }
                $scope        = if ($kp -like 'HKLM:\*') { 'Machine (known)' } else { 'User (known)' }

                if (-not $seenPaths.Add($item.PSPath)) { continue }

                Write-UninstallLog INFO "Including known uninstall entry fallback: $friendlyName -> $kp"

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
                Write-UninstallLog WARN "Failed to evaluate known uninstall key '$kp': $($_.Exception.Message)"
            }
        }
    }

    return $found
}

function Clean-LiongardInstallerRegistry {
    # Removes cached installer entries under HKCR\Installer that can cause MSI error 1612.
    $appName     = 'Liongard'
    $productPath = 'Registry::HKEY_CLASSES_ROOT\Installer\Products'
    $upgradePath = 'Registry::HKEY_CLASSES_ROOT\Installer\UpgradeCodes'
    $removedProducts = 0
    $removedUpgrades = 0

    Write-UninstallLog STEP "Checking for hidden installer cache entries for '$appName'..."

    if (Test-Path -LiteralPath $productPath) {
        try {
            Get-ChildItem -LiteralPath $productPath -ErrorAction Stop | ForEach-Object {
                $entryPath   = $_.PSPath
                $productName = (Get-ItemProperty -LiteralPath $entryPath -Name 'ProductName' -ErrorAction SilentlyContinue).ProductName
                if ($productName -and $productName -like "*$appName*") {
                    Write-UninstallLog INFO "Removing corrupted installer product entry: $entryPath | ProductName: $productName"
                    try {
                        Remove-LiongardPathSafe -LiteralPath $entryPath -Recurse
                        $removedProducts++
                    }
                    catch {
                        Write-UninstallLog WARN "Failed to remove installer product entry at ${entryPath}: $($_.Exception.Message)"
                    }
                }
            }
        }
        catch {
            Write-UninstallLog WARN "Failed to enumerate installer product cache: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $upgradePath) {
        try {
            Get-ChildItem -LiteralPath $upgradePath -ErrorAction Stop | ForEach-Object {
                $entryPath = $_.PSPath
                $values    = Get-ItemProperty -LiteralPath $entryPath -ErrorAction SilentlyContinue
                if ($values) {
                    $matchingValues = $values.PSObject.Properties.Value | Where-Object { $_ -is [string] -and $_ -like "*$appName*" }
                    if ($matchingValues -and $matchingValues.Count -gt 0) {
                        Write-UninstallLog INFO "Removing installer upgrade entry: $entryPath"
                        try {
                            Remove-LiongardPathSafe -LiteralPath $entryPath -Recurse
                            $removedUpgrades++
                        }
                        catch {
                            Write-UninstallLog WARN "Failed to remove installer upgrade entry at ${entryPath}: $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        catch {
            Write-UninstallLog WARN "Failed to enumerate installer upgrade cache: $($_.Exception.Message)"
        }
    }

    if ($removedProducts -gt 0 -or $removedUpgrades -gt 0) {
        Write-UninstallLog OK ("Removed {0} installer product entries and {1} upgrade entries related to '{2}'." -f $removedProducts, $removedUpgrades, $appName)
    }
    else {
        Write-UninstallLog INFO "No hidden installer cache entries found for '$appName'."
    }
}

function Remove-UninstallKey {
    param(
        [string]$KeyPath,
        [string]$Name
    )

    $label = if ([string]::IsNullOrWhiteSpace($Name)) { $KeyPath } else { $Name }

    if ([string]::IsNullOrWhiteSpace($KeyPath)) { return $false }

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        Write-UninstallLog INFO "Uninstall key already removed for '$label'."
        return $true
    }

    try {
        Write-UninstallLog INFO "Removing uninstall registry key for '$label': $KeyPath"
        Remove-LiongardPathSafe -LiteralPath $KeyPath -Recurse
        Write-UninstallLog OK "Removed uninstall registry key for '$label'."
        return $true
    }
    catch {
        Write-UninstallLog WARN "Failed to remove uninstall registry key for '$label': $($_.Exception.Message)"
        return $false
    }
}

function Run-Uninstall {
    param([Parameter(Mandatory)][pscustomobject]$Entry)

    $cmd = if ($Entry.Quiet) { $Entry.Quiet } else { $Entry.Normal }

    # MSI entries: always build 'msiexec /x {ProductCode}' ourselves instead of replaying the
    # registered UninstallString. Older builds and bundle-managed entries can register
    # 'MsiExec.exe /I{code}', which runs a repair rather than an uninstall.
    if ([string]::IsNullOrWhiteSpace($cmd) -or $cmd -match '(?i)msiexec') {
        $msiCode = $Entry.ProductCode
        if (-not $msiCode -and $cmd -match '(?<code>\{[0-9A-Fa-f\-]{36}\})') { $msiCode = $Matches['code'] }

        if (-not $msiCode) {
            Write-UninstallLog WARN "No uninstall string or ProductCode found for '$($Entry.Name)'."
            return 1
        }

        Write-UninstallLog INFO "Uninstall target: '$($Entry.Name)'. Registered command: $cmd"
        $exit = Invoke-MsiSilentUninstall -ProductCode $msiCode -Label $Entry.Name
        if ($null -eq $exit) { return 1 }
        return $exit
    }
    else {
        # TODO(M5): Pending developer confirmation on whether the EXE bundle marks VC++ and
        # Npcap as Permanent. If it does not, uninstalling the bundle entry here also removes
        # those shared components. Behavior is intentionally unchanged until confirmed.
        Write-UninstallLog INFO "Uninstall target: '$($Entry.Name)'. Raw command: $cmd"
        if ($cmd.StartsWith('"')) {
            $exe     = $cmd.Split('"')[1]
            $exeArgs = $cmd.Substring($exe.Length + 2).Trim()
        }
        else {
            $exe     = $cmd.Split(' ')[0]
            $exeArgs = $cmd.Substring($exe.Length).Trim()
        }

        if ($exeArgs -notmatch '(?i)(/quiet|/silent|/s)') { $exeArgs += ' /quiet' }
        if ($exeArgs -notmatch '(?i)(/norestart|/n)')     { $exeArgs += ' /norestart' }

        if (-not (Test-Path $exe)) {
            Write-UninstallLog WARN "Uninstall executable not found: $exe"
            return 1
        }

        Write-UninstallLog INFO "Executing EXE uninstall: `"$exe`" $exeArgs"
        $p = Start-Process $exe -ArgumentList $exeArgs -PassThru -Wait -WindowStyle Hidden
        Write-UninstallLog INFO "EXE exit code: $($p.ExitCode)"
        return $p.ExitCode
    }
}

function Invoke-MsiSilentUninstall {
    param(
        [Parameter(Mandatory)][string]$ProductCode,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($ProductCode)) { return $null }

    $friendly = if ([string]::IsNullOrWhiteSpace($Label)) { $ProductCode } else { $Label }
    $msiArgs  = "/x $ProductCode /qn /norestart"

    Write-UninstallLog INFO "Forcing MSI uninstall for '$friendly' via product code $ProductCode."
    try {
        $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -PassThru -Wait -WindowStyle Hidden
        $exit = $proc.ExitCode
    }
    catch {
        Write-UninstallLog WARN "Failed to launch MSI uninstall for '$friendly': $($_.Exception.Message)"
        return $null
    }

    switch ($exit) {
        0     { Write-UninstallLog OK   "MSI uninstall completed for '$friendly' (exit code 0)." }
        3010  { Write-UninstallLog WARN "MSI uninstall for '$friendly' completed with reboot required (3010)." }
        1605  { Write-UninstallLog INFO "MSI uninstall for '$friendly' returned 1605 (product not installed)." }
        default { Write-UninstallLog WARN "MSI uninstall for '$friendly' returned exit code $exit." }
    }

    return $exit
}

function Prepare-FolderRemoval {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $ErrorActionPreference = 'Continue'
    $prepared = $false

    Write-UninstallLog INFO "Resetting ownership, permissions and attributes on '$Path' before removal."

    # takeown is run without /D (its Y/N answer letter is language-dependent). stdin comes
    # from NUL so a prompt can never block an unattended run. /A assigns ownership to the
    # Administrators group.
    $null = & cmd.exe /d /c "takeown.exe /F `"$Path`" /R /A <NUL" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $prepared = $true
    }
    else {
        Write-UninstallLog WARN "takeown returned exit code $LASTEXITCODE for '$Path'."
    }

    # *S-1-5-32-544 is the language-neutral SID of BUILTIN\Administrators.
    $null = & icacls.exe $Path /grant:r '*S-1-5-32-544:F' /T /C /Q 2>&1
    if ($LASTEXITCODE -eq 0) {
        $prepared = $true
    }
    else {
        Write-UninstallLog WARN "icacls grant returned exit code $LASTEXITCODE for '$Path'."
    }

    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | ForEach-Object {
            try { $_.Attributes = 'Normal' } catch { }
        }
        $prepared = $true
    }
    catch {
        Write-UninstallLog WARN "Unable to normalize attributes under '$Path': $($_.Exception.Message)"
    }

    return $prepared
}

function Invoke-LiongardAgentUninstall {
    Write-UninstallLog STEP "Attempting Liongard Agent removal."

    $serviceNames = Get-LiongardServiceNames
    $root         = 'C:\Program Files (x86)\LiongardInc'
    $productCodes = @(
        [pscustomobject]@{
            Code = '{1D89F069-B48B-4191-8810-2364C29EC039}'
            Name = 'Liongard Agent'
        }
    )

    $issues = New-Object System.Collections.Generic.List[string]

    # Primary path: uninstall every registered Liongard Agent MSI by its own ProductCode.
    # The code changes per version, so it is discovered by DisplayName, never hardcoded.
    foreach ($product in @(Get-LiongardInstalledProduct | Where-Object { $_.ProductCode -and -not $_.IsBundle })) {
        Write-UninstallLog INFO ("Found Liongard Agent MSI {0} (version {1}) at {2}." -f $product.ProductCode, $product.DisplayVersion, $product.KeyPath)
        $exit = Invoke-MsiSilentUninstall -ProductCode $product.ProductCode -Label $product.DisplayName
        if ($null -eq $exit) {
            $issues.Add("msi:$($product.ProductCode)") | Out-Null
        }
        elseif ($exit -ne 0 -and $exit -ne 3010 -and $exit -ne 1605) {
            $issues.Add("msi:$($product.ProductCode)=$exit") | Out-Null
        }
    }

    # Secondary path: anything else still matching by name (bundle entries, older names).
    $searchNames = @('Liongard Agent','RoarAgent','Roar Agent','Liongard')
    $entries     = Get-UninstallEntries -Names $searchNames -ProductCodes $productCodes
    $entries     = @($entries | Where-Object { $_ })

    $productCodeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($pc in $productCodes) {
        if ($pc.Code) { [void]$productCodeSet.Add($pc.Code) }
    }

    if ($entries.Length -gt 0) {
        $entries | ForEach-Object { Write-UninstallLog INFO "Found entry: $($_.Name) (Scope: $($_.Scope)) -> Key: $($_.KeyName)" }
        foreach ($entry in $entries) {
            $exitCode = Run-Uninstall -Entry $entry
            if ($exitCode -ne 0 -and $exitCode -ne 3010 -and $exitCode -ne 1605) {
                # Keep the uninstall entry so the product stays visible and can be retried.
                $issues.Add("uninstall:$($entry.Name)=$exitCode") | Out-Null
                Write-UninstallLog WARN "Leaving the uninstall registry key for '$($entry.Name)' in place because its uninstall did not succeed."
            }
            else {
                $regCleaned = Remove-UninstallKey -KeyPath $entry.KeyPath -Name $entry.Name
                if (-not $regCleaned) {
                    $issues.Add("reg:$($entry.Name)") | Out-Null
                }
            }

            if ($entry.ProductCode) { [void]$productCodeSet.Add($entry.ProductCode) }
        }
    }
    else {
        Write-UninstallLog INFO "No uninstall registry entries located."
    }

    foreach ($pc in $productCodes) {
        if (-not $pc.Code) { continue }
        $exit = Invoke-MsiSilentUninstall -ProductCode $pc.Code -Label $pc.Name
        if ($null -eq $exit) {
            $issues.Add("msi:$($pc.Code)") | Out-Null
        }
        elseif ($exit -ne 0 -and $exit -ne 3010 -and $exit -ne 1605) {
            $issues.Add("msi:$($pc.Code)=$exit") | Out-Null
        }
    }

    # Purge the HKCR\Installer cache only when every MSI uninstall succeeded and no Liongard
    # Agent product is still registered. Purging earlier orphans a live MSI registration.
    $msiIssues         = @($issues | Where-Object { $_ -like 'msi:*' -or $_ -like 'uninstall:*' })
    $remainingProducts = @(Get-LiongardInstalledProduct)
    if ($msiIssues.Count -eq 0 -and $remainingProducts.Count -eq 0) {
        Clean-LiongardInstallerRegistry
    }
    else {
        Write-UninstallLog WARN ("Skipping installer cache cleanup: {0} MSI issue(s), {1} Liongard Agent product(s) still registered." -f $msiIssues.Count, $remainingProducts.Count)
    }

    # Credential Manager cleanup: currently disabled (#8); the call only logs that and returns 'Disabled'.
    $credentialResult = Remove-LiongardStoredCredentials
    if ($credentialResult.Status -eq 'Failed') {
        $issues.Add('credentials') | Out-Null
    }

    Write-UninstallLog STEP "Terminating remaining Liongard processes..."
    $null = Stop-LiongardProcesses

    foreach ($svcName in $serviceNames | Select-Object -Unique) {
        Write-UninstallLog STEP "Stopping and deleting service '$svcName'..."
        if (-not (Remove-LiongardServiceRegistration -Name $svcName)) {
            $issues.Add("svc:$svcName") | Out-Null
        }
    }

    # Catch anything that restarted while services were being removed.
    $null = Stop-LiongardProcesses

    Write-UninstallLog STEP "Removing residual folder: $root"
    try {
        if (Test-Path $root) {
            try {
                Remove-LiongardPathSafe -LiteralPath $root -Recurse
                Write-UninstallLog OK "Removed residual folder: $root"
            }
            catch {
                Write-UninstallLog WARN "Initial folder removal failed: $($_.Exception.Message). Trying permission reset."
                $prepared = Prepare-FolderRemoval -Path $root
                if ($prepared) {
                    Remove-LiongardPathSafe -LiteralPath $root -Recurse
                    Write-UninstallLog OK "Removed residual folder after permission reset: $root"
                }
                else {
                    throw
                }
            }
        }
        else {
            Write-UninstallLog INFO "Residual folder not found: $root"
        }
    }
    catch {
        Write-UninstallLog WARN "Folder cleanup failed for '$root': $($_.Exception.Message)"
        $issues.Add('path') | Out-Null
    }

    if ($issues.Count -eq 0) {
        Write-UninstallLog OK "Uninstall completed successfully."
    }
    else {
        Write-UninstallLog WARN ("Uninstall completed with issues: " + ($issues -join ', '))
    }

    return [pscustomobject]@{
        Success = ($issues.Count -eq 0)
        Issues  = $issues
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
        'User-Agent'     = 'LiongardAgentUninstall/1.0'
    }
}

function Resolve-InstancePrefix {
    # Normalizes the instance input so users can enter a prefix, full host, or URL.
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

function Get-LiongardAgentsFiltered {
    # Retrieves agents matching a specific conditions filter. Throws when the lookup fails, so a
    # failed lookup is never mistaken for "no agents".
    # The /agents endpoint returns a bare JSON array; no envelope unwrapping is needed.
    param(
        [string]$InstancePrefix,
        [hashtable]$Headers,
        [string]$Conditions
    )

    if (-not $Conditions) { return @() }

    $encoded = [Uri]::EscapeDataString($Conditions)
    $uri     = "https://$InstancePrefix.app.liongard.com/api/v1/agents?conditions=$encoded"
    Write-Host "Fetching filtered agents using conditions: $Conditions"

    $response = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop

    if ($null -eq $response) { return @() }
    if ($response -is [System.Array]) { return $response }
    return @($response)
}

function Get-LiongardAgentCandidate {
    # Looks up the agents whose Hostname or Name equals one of the local names. The API filter only
    # narrows the list; Find-LiongardAgentMatch checks every candidate again, exactly.
    # Returns $null when any lookup fails, so a partial list can never lead to a deletion.
    param(
        [string]$InstancePrefix,
        [hashtable]$Headers,
        [string[]]$Hostnames
    )

    $results = New-Object System.Collections.Generic.List[object]
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($hostname in $Hostnames) {
        if ([string]::IsNullOrWhiteSpace($hostname)) { continue }
        $escaped = $hostname -replace "'", "''"
        foreach ($field in 'Hostname', 'Name') {
            try {
                $agentMatches = @(Get-LiongardAgentsFiltered -InstancePrefix $InstancePrefix -Headers $Headers -Conditions "$field = '$escaped'")
            }
            catch {
                Write-Warning ("Agent lookup [{0} = '{1}'] failed: {2}" -f $field, $hostname, $_.Exception.Message)
                return $null
            }

            foreach ($agent in $agentMatches) {
                if (-not $agent) { continue }
                $agentId = Get-ObjectPropertyValue -Object $agent -Name 'ID'
                if ($agentId -and -not $seenIds.Add([string]$agentId)) { continue }
                $results.Add($agent)
            }
        }
    }

    return ,$results.ToArray()
}

function Get-AgentHostIdentifiers {
    # The agent's Hostname, Name and Data.FQDN values that are not blank. No truncated variants.
    param(
        [Parameter(Mandatory = $true)]
        $Agent
    )

    $data   = Get-ObjectPropertyValue -Object $Agent -Name 'Data'
    $values = @()
    foreach ($value in @((Get-ObjectPropertyValue -Object $Agent -Name 'Hostname'), (Get-ObjectPropertyValue -Object $Agent -Name 'Name'), (Get-ObjectPropertyValue -Object $data -Name 'FQDN'))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $values += [string]$value }
    }
    return $values
}

function Get-AgentEnvironmentInfo {
    # The agent's environment as Name and ID ($null when not set). The API returns an Environment
    # object with Name and ID, or null when the agent has no environment. EnvironmentName, a plain
    # Environment string and EnvironmentID are also read in case the shape differs.
    param($Agent)

    $name        = $null
    $id          = $null
    $environment = Get-ObjectPropertyValue -Object $Agent -Name 'Environment'
    if ($environment -is [string]) {
        $name = $environment
    }
    elseif ($null -ne $environment) {
        $name = Get-ObjectPropertyValue -Object $environment -Name 'Name'
        $id   = Get-ObjectPropertyValue -Object $environment -Name 'ID'
    }
    if ([string]::IsNullOrWhiteSpace([string]$name)) { $name = Get-ObjectPropertyValue -Object $Agent -Name 'EnvironmentName' }
    if ([string]::IsNullOrWhiteSpace([string]$id))   { $id   = Get-ObjectPropertyValue -Object $Agent -Name 'EnvironmentID' }

    $name = if ([string]::IsNullOrWhiteSpace([string]$name)) { $null } else { [string]$name }
    $id   = if ([string]::IsNullOrWhiteSpace([string]$id) -or "$id" -eq '0') { $null } else { [string]$id }
    return [pscustomobject]@{
        Name = $name
        ID   = $id
    }
}

function Get-LiongardEnvironmentId {
    # IDs of the environments whose name equals $Name (case-insensitive, whole string). Only needed
    # when an agent reports an environment ID without a name. Returns an empty set on failure.
    param(
        [string]$InstancePrefix,
        [hashtable]$Headers,
        [string]$Name
    )

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $uri = "https://$InstancePrefix.app.liongard.com/api/v1/environments"
    try {
        # Assigned first: in Windows PowerShell 5.1, @(Invoke-RestMethod ...) would wrap the JSON array.
        $environments = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop
    }
    catch {
        Write-Warning "Unable to retrieve Liongard environments: $($_.Exception.Message)"
        return ,$ids
    }

    foreach ($environment in @($environments)) {
        $environmentName = Get-ObjectPropertyValue -Object $environment -Name 'Name'
        $environmentId   = Get-ObjectPropertyValue -Object $environment -Name 'ID'
        if ($null -ne $environmentId -and [string]::Equals([string]$environmentName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $ids.Add([string]$environmentId) | Out-Null
        }
    }
    return ,$ids
}

function Find-LiongardAgentMatch {
    # Checks every candidate against the deletion rule: the agent is in the configured environment
    # (or neither has one) and its Hostname, Name or Data.FQDN equals a local name (case-insensitive,
    # whole string). Returns one row per candidate with Matched and Reason.
    param(
        [array]$Agents,
        [string[]]$LocalHostnames,
        [string]$Environment,
        [string]$InstancePrefix,
        [hashtable]$Headers
    )

    $nameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $LocalHostnames) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) { $nameSet.Add($entry) | Out-Null }
    }
    $wanted         = "$Environment".Trim()
    $environmentIds = $null

    $rows = @()
    foreach ($agent in $Agents) {
        if (-not $agent) { continue }

        $agentNames = @(Get-AgentHostIdentifiers -Agent $agent)
        $nameHits   = @($agentNames | Where-Object { $nameSet.Contains($_) })
        $envInfo    = Get-AgentEnvironmentInfo -Agent $agent
        $envLabel   = if ($envInfo.Name) { $envInfo.Name } elseif ($envInfo.ID) { "ID $($envInfo.ID)" } else { '(none)' }

        if (-not $wanted) {
            $envMatch = (-not $envInfo.Name -and -not $envInfo.ID)
        }
        elseif ($envInfo.Name) {
            $envMatch = [string]::Equals($envInfo.Name, $wanted, [System.StringComparison]::OrdinalIgnoreCase)
        }
        elseif ($envInfo.ID) {
            if ($null -eq $environmentIds) {
                $environmentIds = Get-LiongardEnvironmentId -InstancePrefix $InstancePrefix -Headers $Headers -Name $wanted
            }
            $envMatch = $environmentIds.Contains($envInfo.ID)
        }
        else {
            $envMatch = $false
        }

        $reasons = @()
        if ($nameHits.Count -eq 0) { $reasons += 'no Hostname, Name or FQDN equals a local name' }
        if (-not $envMatch) { $reasons += 'environment differs' }
        $reason = if ($reasons.Count -eq 0) { "hostname [$($nameHits[0])] and environment match" } else { $reasons -join '; ' }

        $rows += [pscustomobject]@{
            Agent       = $agent
            AgentId     = Get-ObjectPropertyValue -Object $agent -Name 'ID'
            Names       = $agentNames
            Environment = $envLabel
            Matched     = ($reasons.Count -eq 0)
            Reason      = $reason
        }
    }

    return $rows
}

function Remove-LiongardAgentRecord {
    param(
        [Parameter(Mandatory = $true)][string]$InstancePrefix,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)]$Agent
    )

    $agentId = Get-ObjectPropertyValue -Object $Agent -Name 'ID'
    if (-not $agentId) {
        Write-Warning "Agent deletion skipped because the ID field is missing."
        return $false
    }

    $uri = "https://$InstancePrefix.app.liongard.com/api/v1/agents/$agentId"
    try {
        # UseBasicParsing avoids the PowerShell 5.1 confirmation prompt when fetching web content.
        $response = Invoke-WebRequest -Uri $uri -Headers $Headers -Method Delete -UseBasicParsing -ErrorAction Stop
        $status   = [int]$response.StatusCode
        if ($status -eq 204 -or ($status -eq 200 -and ($response.Content.Trim()) -eq "$agentId")) {
            return $true
        }

        Write-Warning "Unexpected Liongard API response while deleting agent ${agentId}: HTTP $status"
        return $false
    }
    catch {
        Write-Warning "Liongard API agent delete failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-LiongardRemoteAgentRemoval {
    # Deletes the platform record only when exactly one candidate matches; otherwise logs every
    # candidate and why it did or didn't match, and skips the deletion.
    param(
        [string]$InstancePrefix,
        [hashtable]$Headers,
        [array]$Agents,
        [string[]]$LocalHostnames,
        [string]$Environment
    )

    $result = [pscustomobject]@{
        Deleted = $false
        AgentId = $null
    }

    if (-not $InstancePrefix -or -not $Headers) {
        Write-Warning "Skipping remote agent deletion because the Liongard API context is unavailable."
        return $result
    }

    $rows    = @(Find-LiongardAgentMatch -Agents $Agents -LocalHostnames $LocalHostnames -Environment $Environment -InstancePrefix $InstancePrefix -Headers $Headers)
    $matched = @($rows | Where-Object { $_.Matched })

    Write-Host ("Liongard agent candidates found: {0}" -f $rows.Count)
    foreach ($row in $rows) {
        Write-Host ("  Agent ID {0}: names [{1}], environment [{2}] -> {3}: {4}" -f $row.AgentId, ($row.Names -join ', '), $row.Environment, $(if ($row.Matched) { 'match' } else { 'no match' }), $row.Reason)
    }

    if ($matched.Count -ne 1) {
        Write-Warning ("Remote agent deletion skipped: {0} agent records match this environment and hostname, and exactly one is required. See the candidates above." -f $matched.Count)
        return $result
    }

    $agentId = $matched[0].AgentId
    if (-not $agentId) {
        Write-Warning "Matched Liongard agent record is missing an ID; remote deletion skipped."
        return $result
    }

    Write-Host ("Attempting to delete Liongard agent ID {0} ({1})." -f $agentId, $matched[0].Reason)
    $deleted = Remove-LiongardAgentRecord -InstancePrefix $InstancePrefix -Headers $Headers -Agent $matched[0].Agent
    if ($deleted) {
        Write-Host ("Remote Liongard agent ID {0} deleted successfully." -f $agentId)
        return [pscustomobject]@{
            Deleted = $true
            AgentId = $agentId
        }
    }

    Write-Warning ("Failed to delete Liongard agent ID {0} from the platform." -f $agentId)
    return $result
}

function Get-LocalHostnameVariants {
    # The names this computer can be registered under, compared whole (no truncated variants):
    # $env:COMPUTERNAME (the NetBIOS name, at most 15 characters; the install scripts register the
    # agent under it through LIONGARDAGENTNAME), the DNS host name and the FQDN. "localhost" is
    # never used.
    $names      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = @($env:COMPUTERNAME)

    try {
        $ipProperties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $candidates  += $ipProperties.HostName
        if (-not [string]::IsNullOrWhiteSpace($ipProperties.DomainName)) {
            $candidates += "$($ipProperties.HostName).$($ipProperties.DomainName)"
        }
    }
    catch { }

    try {
        $candidates += (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DNSHostName
    }
    catch { }

    foreach ($entry in $candidates) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $value = $entry.Trim().TrimEnd('.')
        if ($value -in 'localhost', 'localhost.localdomain') { continue }
        $names.Add($value) | Out-Null
    }

    return @($names)
}

# ================================
# Main
# ================================

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Any unhandled error still applies log retention and prints the log paths.
trap {
    Write-Error "Unexpected error: $($_.Exception.Message)" -ErrorAction Continue
    Stop-LiongardTranscript
    exit 1
}

# Lock down the deploy folder before anything (including the transcript) is written.
try {
    $deployFolder = Initialize-LiongardDeployFolder -Folder $LogFolder -Secret $ApiTokenKey, $ApiTokenSecret
}
catch {
    Write-Error "Deploy folder check failed: $($_.Exception.Message)" -ErrorAction Continue
    Stop-LiongardTranscript
    exit 1
}

Start-LiongardTranscript -TargetFolder $deployFolder
Invoke-LiongardLegacyCleanup

if ($MinimumRemoteDeletionScore -ne 50) {
    Write-Warning "`$MinimumRemoteDeletionScore is deprecated and ignored. Remote deletion now needs exactly one agent with the same environment and hostname."
}

$uninstallResult = Invoke-LiongardAgentUninstall
if (-not $uninstallResult.Success) {
    Write-Warning "Liongard Agent uninstall completed with issues: $($uninstallResult.Issues -join ', ')"
}

$agentInstalled = Test-LiongardAgentInstalled
if ($agentInstalled) {
    Write-Warning "Liongard Agent is still detected after uninstall attempt."
}

if ($RemoveAgentFromPlatform) {
    $blockingIssues = @()
    if ($uninstallResult -and $uninstallResult.Issues) {
        $blockingIssues = @($uninstallResult.Issues | Where-Object { $_ -notlike 'path*' -and $_ -ne 'credentials' })
    }

    if ($agentInstalled) {
        Write-Warning "Skipping remote agent deletion because the agent is still detected locally."
    }
    elseif ($blockingIssues.Count -gt 0) {
        Write-Warning ("Skipping remote agent deletion because uninstall reported blocking issues: {0}" -f ($blockingIssues -join ', '))
    }
    else {
        Assert-ConfigurationValue -Name 'InstancePrefix' -Value $InstancePrefix
        Assert-ConfigurationValue -Name 'ApiTokenKey'    -Value $ApiTokenKey
        Assert-ConfigurationValue -Name 'ApiTokenSecret' -Value $ApiTokenSecret

        $instancePrefix = Resolve-InstancePrefix -Value $InstancePrefix
        $headers        = Get-LiongardAuthHeader -ApiTokenKey $ApiTokenKey -ApiTokenSecret $ApiTokenSecret

        $localHostnames = Get-LocalHostnameVariants
        Write-Host ("Remote deletion matches environment [{0}] and hostname [{1}]." -f $(if ([string]::IsNullOrWhiteSpace($Environment)) { '(none)' } else { $Environment.Trim() }), ($localHostnames -join ', '))

        $agents = Get-LiongardAgentCandidate -InstancePrefix $instancePrefix -Headers $headers -Hostnames $localHostnames
        if ($null -eq $agents) {
            Write-Warning "Remote agent deletion skipped because the Liongard agent lookup failed."
        }
        else {
            Invoke-LiongardRemoteAgentRemoval -InstancePrefix $instancePrefix -Headers $headers -Agents $agents -LocalHostnames $localHostnames -Environment $Environment | Out-Null
        }
    }
}

Write-LiongardIdentityStatus
Stop-LiongardTranscript

if ($agentInstalled) {
    exit 1
}

exit 0
