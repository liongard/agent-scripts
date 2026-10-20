#requires -Version 5.1
<#
    Liongard Agent EXE bundle install - simplified RMM script (Windows PowerShell 5.1, runs as SYSTEM).
    The bundle installs the agent MSI, the Visual C++ redistributable and (optionally) Npcap, and this
    script can enable network discovery in network_discovery.yml afterwards.
    No Liongard API calls: the Environment value is passed through to the installer as-is.

    REFERENCE BEHAVIOR: the "Liongard install-state functions" shared block in
    LGAgentInstall-MSI-Advanced.ps1, LGAgentInstall-EXE-Advanced.ps1 and LGAgentUninstall.ps1.
    This script re-implements the same rules compactly (product detection by DisplayName,
    Healthy/Stale/NotInstalled classification, stale cleanup, Credential Manager cleanup,
    identity-key guard, post-install validation). Update it whenever that block changes.

    Exit codes: 0 = installed and validated, or already up to date; non-zero = failure
    (the installer exit code when the installer itself failed, otherwise 1).
    Last updated: 2026-10-20
#>

# ---- Partner configuration ----
$InstancePrefix          = "REPLACE_WITH_INSTANCE_PREFIX"     # e.g. us1, us2, eu1
$AgentTokenKey           = "REPLACE_WITH_AGENT_TOKEN_KEY"
$AgentTokenSecret        = "REPLACE_WITH_AGENT_TOKEN_SECRET"
$Environment             = "REPLACE_WITH_ENVIRONMENT_NAME"    # Passed straight through as LiongardEnvironment
$AgentDescription        = ""                                 # Optional LiongardDescription
$IncludeEnvironmentValue = $true
$EnableNetworkDiscovery  = $false                             # Flip 'enabled' to true in network_discovery.yml after install
$InstallNpcap            = $true
$EulaAccepted            = $true
$SuppressRestart         = $true
$PassiveMode             = $false
$ProxyUrl                = ""
$ClearProxyEnvironmentForInstaller = $true                  # Strip inherited HTTP(S)_PROXY/ALL_PROXY/NO_PROXY from the installer process (ProxyUrl, if set, is re-applied)
$AutoUpdate              = $null                              # $true / $false to pass AUTOUPDATE=1/0; $null to omit
$Folder                  = $env:ProgramData               # Parent folder; the script works in <Folder>\LiongardDeploy (SYSTEM/Administrators only)
$InstallerUrl            = "https://agents.static.liongard.com/LiongardAgent-lts.exe"

# ---- Install-state rules (compact equivalent of the advanced scripts' shared block) ----
$Roots      = 'C:\Program Files (x86)\LiongardInc', 'C:\Program Files\LiongardInc'
$Service    = 'roaragent.exe'
$Task       = '\Liongard\LiongardAgentUpdater'
$LegacyCode = '{1D89F069-B48B-4191-8810-2364C29EC039}'   # Fallback only; the ProductCode changes per version.
$Protected  = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Liongard', 'HKEY_LOCAL_MACHINE\SOFTWARE\Liongard'   # Agent identity: never modified.
$CredSource = @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class LGCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CRED { public int Flags, Type; public IntPtr Target, Comment; public int WriteLow, WriteHigh, BlobSize; public IntPtr Blob; public int Persist, AttrCount; public IntPtr Attrs, Alias, User; }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredEnumerateW(string filter, int flags, out int count, out IntPtr creds);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDeleteW(string target, int type, int flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);
    public static string[] Find(string user) {   // Generic (type 1) entries whose UserName equals user exactly; secrets are never read.
        List<string> list = new List<string>(); int n; IntPtr buf;
        if (!CredEnumerateW(null, 0, out n, out buf)) { int e = Marshal.GetLastWin32Error(); if (e == 1168) return list.ToArray(); throw new System.ComponentModel.Win32Exception(e); }
        try { for (int i = 0; i < n; i++) {
            CRED c = (CRED)Marshal.PtrToStructure(Marshal.ReadIntPtr(buf, i * IntPtr.Size), typeof(CRED));
            string t = c.Target == IntPtr.Zero ? null : Marshal.PtrToStringUni(c.Target);
            if (c.Type == 1 && c.User != IntPtr.Zero && Marshal.PtrToStringUni(c.User) == user && !string.IsNullOrEmpty(t)) list.Add(t); } }
        finally { CredFree(buf); }
        return list.ToArray(); }
    public static int Delete(string target) { return CredDeleteW(target, 1, 0) ? 0 : Marshal.GetLastWin32Error(); }
}
'@

# ====================================================================
# BEGIN SHARED BLOCK: Liongard deploy-folder functions
# Keep this block identical across LGAgentInstall-MSI-Simple, LGAgentInstall-MSI-Advanced,
# LGAgentInstall-EXE-Simple, LGAgentInstall-EXE-Advanced, LGAgentUninstall and
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

function Write-LGLog([string]$Message) { Write-Host "[LGAgent] $Message" }
function ConvertTo-LGVersion($Value) {   # Four-part version so 5.5.0 equals 5.5.0.0.
    if (-not ("$Value" -match '\d+(\.\d+){0,3}')) { return $null }
    $p = @($Matches[0].Split('.') | ForEach-Object { [int]$_ }); while ($p.Count -lt 4) { $p += 0 }
    New-Object Version($p[0], $p[1], $p[2], $p[3])
}
function Get-LGProduct {   # (a) Both uninstall views, DisplayName 'Liongard Agent' (legacy ProductCode as fallback).
    foreach ($view in 'Registry64', 'Registry32') {
        $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view).OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
        foreach ($name in @(if ($root) { $root.GetSubKeyNames() })) {
            $k = $root.OpenSubKey($name)
            if (-not $k -or ([string]$k.GetValue('DisplayName') -ne 'Liongard Agent' -and $name -ne $LegacyCode)) { continue }
            $bundle = ($null -ne $k.GetValue('BundleUpgradeCode')) -or ($null -ne $k.GetValue('BundleProviderKey'))
            $code = if ($bundle) { $null } elseif ($name -match '^\{[0-9A-Fa-f-]{36}\}$') { $name.ToUpper() } elseif ([string]$k.GetValue('UninstallString') -match '(?i)msiexec.*?(\{[0-9A-F-]{36}\})') { $Matches[1].ToUpper() }
            [pscustomobject]@{ Key = $name; Code = $code; Version = [string]$k.GetValue('DisplayVersion'); Location = [string]$k.GetValue('InstallLocation'); Bundle = $bundle }
        }
    }
}
function Get-LGServiceInfo {   # Registry registration (visible even when orphaned) plus live status.
    $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey("SYSTEM\CurrentControlSet\Services\$Service")
    $img = if ($k) { [Environment]::ExpandEnvironmentVariables([string]$k.GetValue('ImagePath')).Trim() -replace '^\\\?\?\\', '' } else { '' }
    $bin = if ($img -match '^"([^"]+)"') { $Matches[1] } elseif ($img.StartsWith('"')) { $img.Trim('"') } elseif ($img -match '^(.+?\.exe)(\s|$)') { $Matches[1] } else { $img }
    $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
    [pscustomobject]@{ Exists = [bool]($k -or $svc); Status = "$($svc.Status)"; Binary = $bin; BinaryExists = [bool]($bin -and (Test-Path -LiteralPath $bin -PathType Leaf)) }
}
function Get-LGFolder($Products) {   # <root>\LiongardAgent, plus an InstallLocation only when directly under a known root.
    $candidates = @($Roots | ForEach-Object { Join-Path $_ 'LiongardAgent' }) + @($Products | Where-Object Location | ForEach-Object { $_.Location.Trim().TrimEnd('\') } | Where-Object { $Roots -contains (Split-Path $_ -Parent) })
    $candidates | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
}
function Get-LGState {   # (b) Healthy = entry + service + binary; NotInstalled = none of them and no folder; else Stale.
    $p = @(Get-LGProduct | Sort-Object Key -Unique); $s = Get-LGServiceInfo; $f = @(Get-LGFolder $p)
    $r = @($Roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $state = if ($p.Count -and $s.Exists -and $s.BinaryExists) { 'Healthy' } elseif (-not ($p.Count -or $s.Exists -or $f.Count -or $r.Count)) { 'NotInstalled' } else { 'Stale' }
    Write-LGLog "Install state: $state"
    Write-LGLog ("  entries: {0}" -f $(if ($p.Count) { ($p | ForEach-Object { "$($_.Key) v$($_.Version) code=$($_.Code) bundle=$($_.Bundle)" }) -join '; ' } else { 'none' }))
    Write-LGLog "  service: exists=$($s.Exists) status=$($s.Status) binary=$($s.Binary) binaryExists=$($s.BinaryExists)"
    Write-LGLog "  folders: $(@($f) + @($r) -join '; ')"
    [pscustomobject]@{ State = $state; Products = $p; Service = $s }
}
function Assert-LGNotProtected([string]$Path) {   # (e) Refuse the identity key, its children, or any parent of it.
    $p = $Path.Trim() -replace '^(?i)(Microsoft\.PowerShell\.Core\\)?Registry::', ''
    if (-not ($p -match '^(?i)(HKEY_LOCAL_MACHINE|HKLM|HKEY_CLASSES_ROOT|HKCR|HKEY_CURRENT_USER|HKCU|HKEY_USERS|HKU):?(\\(.*))?$')) { return }
    $hive = @{ HKLM = 'HKEY_LOCAL_MACHINE'; HKCR = 'HKEY_CLASSES_ROOT'; HKCU = 'HKEY_CURRENT_USER'; HKU = 'HKEY_USERS' }[$Matches[1]]
    $n = ("$(if ($hive) { $hive } else { $Matches[1].ToUpper() })\$($Matches[3])" -replace '\\+', '\').TrimEnd('\')
    foreach ($x in $Protected) { if ($n.Equals($x, 'OrdinalIgnoreCase') -or $n.StartsWith("$x\", 'OrdinalIgnoreCase') -or $x.StartsWith("$n\", 'OrdinalIgnoreCase')) { throw "Refusing to modify protected Liongard identity path [$Path]." } }
}
function Remove-LGPath([string]$Path) { Assert-LGNotProtected $Path; Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
function Stop-LGProcess {   # Processes running from a Liongard root (agent, updater, node.exe/prowl.exe job children).
    try { $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $e = $_.ExecutablePath; $e -and @($Roots | Where-Object { $e.StartsWith("$_\", 'OrdinalIgnoreCase') }).Count }) }
    catch { $procs = @(Get-Process LiongardAgentSVC, LiongardAgent, LiongardAgentUpdater, roaragent -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id; Name = $_.ProcessName } }) }
    foreach ($proc in $procs) { try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; Write-LGLog "Stopped $($proc.Name) (PID $($proc.ProcessId))" } catch { Write-LGLog "WARN: could not stop $($proc.Name): $($_.Exception.Message)" } }
    if ($procs.Count) { Start-Sleep -Seconds 2 }
}
function Remove-LGStoredCredential {   # (d) TODO: pending developer confirmation that fresh installs always issue new credentials.
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ("$($id.User.Value)" -ne 'S-1-5-18') { Write-LGLog "WARN: not running as SYSTEM ($($id.Name)); agent credentials are not visible, cleanup skipped."; return }
    try { if (-not ('LGCred' -as [type])) { Add-Type -TypeDefinition $CredSource -ErrorAction Stop }; $store = 'LGCred' -as [type]; $targets = @($store::Find('LiongardAgent\AgentKey')) }
    catch { Write-LGLog "WARN: Credential Manager enumeration failed: $($_.Exception.Message)"; return }
    $failed = @($targets | Where-Object { $store::Delete($_) -notin 0, 1168 }).Count
    Write-LGLog "Credential Manager cleanup: found $($targets.Count), removed $($targets.Count - $failed), failed $failed (Generic, UserName 'LiongardAgent\AgentKey')."
}
function Invoke-LGStaleCleanup($State) {   # (c) Never for a Healthy install.
    if ($State.State -ne 'Stale') { throw "Stale cleanup refused for state '$($State.State)'." }
    Write-LGLog 'Stale install detected: cleaning up before a fresh install.'
    if ($State.Service.Exists) {
        Stop-LGProcess; Assert-LGNotProtected "HKLM:\SYSTEM\CurrentControlSet\Services\$Service"
        try { $svc = Get-Service $Service -ErrorAction Stop; if ($svc.Status -ne 'Stopped') { Stop-Service $Service -Force -ErrorAction Stop; $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) } } catch { Write-LGLog "WARN: service stop: $($_.Exception.Message)" }
        $null = & sc.exe delete $Service 2>&1; Write-LGLog "sc.exe delete $Service exit $LASTEXITCODE (0, 1060 and 1072 are fine)"
    }
    foreach ($p in @($State.Products | Where-Object Code)) {
        $staleLog = Join-Path $script:LiongardDeploy.Root ("StaleUninstall_{0}_{1}.log" -f $p.Code.Trim('{}'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Register-LiongardDeployLog -Label 'Stale uninstall log' -Path $staleLog -Redact
        $proc = Start-Process msiexec.exe -ArgumentList '/x', $p.Code, '/qn', '/norestart', '/L*V', "`"$staleLog`"" -Wait -PassThru -WindowStyle Hidden
        Write-LGLog "msiexec /x $($p.Code) exit $($proc.ExitCode) (failure tolerated)"
    }
    Stop-LGProcess; $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($f in @(Get-LGFolder $State.Products)) {
        try { Assert-LGNotProtected $f; Rename-Item -LiteralPath $f -NewName "$(Split-Path $f -Leaf).stale-$stamp" -ErrorAction Stop; Write-LGLog "Renamed $f to *.stale-$stamp" }
        catch { Write-LGLog "WARN: rename of $f failed ($($_.Exception.Message)); deleting instead."; try { Remove-LGPath $f; Write-LGLog "Deleted $f" } catch { Write-LGLog "WARN: could not delete ${f}: $($_.Exception.Message)" } }
    }
    Remove-LGStoredCredential
}
function Test-LGInstall {   # (f) Service Running (retry ~60s) and updater task registered.
    $deadline = (Get-Date).AddSeconds(60)
    do { $status = "$((Get-Service $Service -ErrorAction SilentlyContinue).Status)"; if ($status -eq 'Running') { break }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline)
    $null = & schtasks.exe /query /tn $Task 2>&1; $taskOk = ($LASTEXITCODE -eq 0)
    Write-LGLog "Validation: service $Service status='$status'; task $Task present=$taskOk"
    ($status -eq 'Running') -and $taskOk
}
function Exit-LG([int]$Code, [string]$Message, [string]$LogPath) {
    Write-LGLog $(if ($Code) { "FAILED: $Message" } else { $Message })
    Complete-LiongardDeployRun
    if ($Code -and $LogPath -and (Test-Path -LiteralPath $LogPath)) {
        Write-LGLog "Installer log: $LogPath (last 20 lines, access key/secret masked):"
        Get-Content -LiteralPath $LogPath -Tail 20 | ForEach-Object { '  ' + (Hide-LiongardSecretText -Text $_) } | Write-Host
    }
    $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry32').OpenSubKey('SOFTWARE\Liongard\LiongardAgent')
    $machineId = [bool]($k -and (($k.GetSubKeyNames() -contains 'MachineID') -or ($k.GetValueNames() -contains 'MachineID')))
    Write-LGLog "Identity key HKLM\SOFTWARE\WOW6432Node\Liongard preserved (not modified by this script). MachineID present: $machineId"
    Write-LiongardDeployLogList
    exit $Code
}
function Start-LGInstaller([string]$Path, [string[]]$Arguments) {   # Same behavior as the advanced script's Start-LiongardInstallerProcess.
    if (-not $ClearProxyEnvironmentForInstaller) { return (Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru).ExitCode }
    $psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName = $Path; Arguments = ($Arguments -join ' '); UseShellExecute = $false; CreateNoWindow = $true }
    foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy') { if ($psi.EnvironmentVariables.ContainsKey($v)) { $psi.EnvironmentVariables.Remove($v) } }
    if ($ProxyUrl) { $psi.EnvironmentVariables['HTTP_PROXY'] = $ProxyUrl; $psi.EnvironmentVariables['HTTPS_PROXY'] = $ProxyUrl }
    Write-LGLog "Installer proxy environment cleared$(if ($ProxyUrl) { ' (explicit ProxyUrl re-applied)' })."
    $proc = [System.Diagnostics.Process]::Start($psi); $proc.WaitForExit(); $proc.ExitCode
}
function Enable-LGNetworkDiscovery {   # Same rule as the advanced script: first 'enabled: true|false' line in network_discovery.yml.
    $yml = @($Roots | ForEach-Object { Join-Path $_ 'LiongardAgent\network_discovery.yml' } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    if (-not $yml) { Write-LGLog 'WARN: network_discovery.yml not found; network discovery not enabled.'; return }
    $text = [IO.File]::ReadAllText($yml)
    $m = [regex]::Match($text, '(?im)^([ \t]*enabled[ \t]*:[ \t]*)([\x22\x27]?)(true|false)\2([ \t]*(#[^\r\n]*)?\r?)$')
    if (-not $m.Success) { Write-LGLog "WARN: 'enabled' key not found in $yml; network discovery not enabled."; return }
    if ($m.Groups[3].Value -eq 'true') { Write-LGLog 'Network discovery already enabled.'; return }
    $line = $m.Groups[1].Value + $m.Groups[2].Value + 'true' + $m.Groups[2].Value + $m.Groups[4].Value
    try { [IO.File]::WriteAllText($yml, $text.Remove($m.Index, $m.Length).Insert($m.Index, $line), (New-Object Text.UTF8Encoding($false))); Write-LGLog "Network discovery enabled in $yml (takes effect on the agent's next reload)." }
    catch { Write-LGLog "WARN: could not update ${yml}: $($_.Exception.Message)" }
}

# ---- Main ----
trap { Exit-LG 1 "Unexpected error: $($_.Exception.Message)" }
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [void](Initialize-LiongardDeployFolder -Folder $Folder -Secret $AgentTokenKey, $AgentTokenSecret) } catch { Exit-LG 1 "Deploy folder check failed: $($_.Exception.Message)" }
foreach ($name in 'InstancePrefix', 'AgentTokenKey', 'AgentTokenSecret') { if ((Get-Variable $name -ValueOnly) -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 1 "Configuration value [$name] must be set." } }
if ($IncludeEnvironmentValue -and $Environment -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 1 'Configuration value [Environment] must be set.' }
if ($InstancePrefix -match '[?*\[\]]') { Exit-LG 1 "InstancePrefix '$InstancePrefix' contains a placeholder character." }
$LGHost = ($InstancePrefix.Trim() -replace '^https?://', '' -replace '/.*$', '' -replace '\.app\.liongard\.com$', '') + '.app.liongard.com'
Invoke-LiongardLegacyCleanup
$exe = Join-Path (Initialize-LiongardDeployStage) 'LiongardAgent-lts.exe'; $log = Get-LiongardDeployLogPath -Prefix 'AgentInstall'
foreach ($i in 1..3) {
    try { if (Test-Path -LiteralPath $exe) { Remove-LGPath $exe }; Invoke-WebRequest -Uri $InstallerUrl -OutFile $exe -UseBasicParsing -ErrorAction Stop; if ((Get-Item -LiteralPath $exe).Length -ge 1MB) { break } }
    catch { Write-LGLog "WARN: download attempt $i failed: $($_.Exception.Message)" }
    if ($i -eq 3) { Exit-LG 1 "Installer download from $InstallerUrl failed." }
}

$state = Get-LGState
if ($state.State -eq 'Stale') { Invoke-LGStaleCleanup $state }
elseif ($state.State -eq 'Healthy') {   # Normal upgrade path: install only when the bundle is strictly newer.
    $installed = ConvertTo-LGVersion (@($state.Products | Where-Object { -not $_.Bundle }) | Select-Object -First 1).Version
    $info = (Get-Item -LiteralPath $exe).VersionInfo
    $new = @($info.ProductVersion, $info.FileVersion | ForEach-Object { ConvertTo-LGVersion $_ } | Where-Object { $_ }) | Select-Object -First 1
    if ($installed -and $new -and $new -le $installed) {
        if ($EnableNetworkDiscovery) { Enable-LGNetworkDiscovery }
        Exit-LG 0 "Liongard Agent $installed is installed and the bundle ($new) is not newer. Nothing to install."
    }
    Write-LGLog "Proceeding with install/upgrade: installed=$installed bundle=$new"
}

$exeArgs = @($(if ($PassiveMode) { '/passive' } else { '/quiet' }))
if ($SuppressRestart) { $exeArgs += '/norestart' }
$exeArgs += '/log', "`"$log`"", "EulaAccepted=$([int]$EulaAccepted)", "InstallNpcap=$([int]$InstallNpcap)", "LiongardUrl=$LGHost",
            "LiongardAccessKey=$AgentTokenKey", "LiongardAccessSecret=$AgentTokenSecret", "LiongardAgentName=`"$env:COMPUTERNAME`""
if ($ProxyUrl) { $exeArgs += "ProxyUrl=`"$ProxyUrl`"" }
if ($IncludeEnvironmentValue -and $Environment) { $exeArgs += "LiongardEnvironment=`"$Environment`"" }
if ($AgentDescription) { $exeArgs += "LiongardDescription=`"$AgentDescription`"" }
if ($null -ne $AutoUpdate) { $exeArgs += "AUTOUPDATE=$([int][bool]$AutoUpdate)" }
Register-LiongardDeployLog -Label 'Installer log' -Path $log -Redact
Write-LGLog "Installing Liongard Agent bundle for $LGHost (InstallNpcap=$InstallNpcap) ..."
$code = Start-LGInstaller -Path $exe -Arguments $exeArgs
Protect-LiongardInstallerLog -Path $log
Write-LGLog "Installer exit code: $code"
if ($code -ne 0 -and $code -ne 3010) { Exit-LG $code "Installer returned $code." $log }
if (-not (Test-LGInstall)) { Exit-LG 1 'Post-install validation failed (service not Running or updater task missing).' $log }
if ($EnableNetworkDiscovery) { Enable-LGNetworkDiscovery }
Exit-LG 0 "Liongard Agent installed and validated (installer exit $code)."
