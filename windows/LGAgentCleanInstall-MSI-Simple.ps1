<#
.SYNOPSIS
    Cleans up a broken or partly removed Liongard Agent, then installs from the MSI, without Liongard API calls.

.DESCRIPTION
    For endpoints with an old, broken, incomplete or corrupt agent. A healthy agent is never cleaned up; it is upgraded only when the MSI is newer.
    Set your values in the "Partner configuration" block below. Exit codes, logs and
    troubleshooting are in the README under .LINK.
    - Healthy (installed, running, accepted by the platform): upgrades only when the MSI is newer, else exits 0.
    - Stale (broken, stopped, incomplete, or refused by the platform: its last 3 heartbeats were HTTP 401, for
      example after it was deleted in the Liongard UI; network errors never count): saves the agent identity,
      removes the agent locally, then installs. Exits 9 when the service or uninstall entry survives the cleanup.
    - Not installed: saves any identity left behind, then installs.
    - Waits up to 2 minutes for a running agent update (exits 11 if it keeps running) and tries one start of a stopped agent.
    - Downloads the MSI before it removes anything.
    - Never modifies the agent identity key, so the reinstalled agent registers as the same agent.
    - Downloads the MSI to a folder only SYSTEM and Administrators can access, and deletes it afterwards.
    - Passes the environment name to the installer exactly as written.
    - Confirms the agent service is running and the updater task exists.

.NOTES
    Requires:     Windows PowerShell 5.1 (64-bit), run as SYSTEM or an elevated administrator.
                  Liongard agent install token (key and secret).
    Author:       Liongard Partner Support
    Last updated: 2026-10-23

.LINK
    https://github.com/liongard/agent-scripts/blob/main/windows/README.md
#>

#requires -Version 5.1

# ---- Partner configuration ----
$LiongardUrl             = "REPLACE_WITH_LIONGARD_URL"        # Full address, e.g. us9.app.liongard.com (short form "us9" also accepted)
$AgentTokenKey           = "REPLACE_WITH_AGENT_TOKEN_KEY"
$AgentTokenSecret        = "REPLACE_WITH_AGENT_TOKEN_SECRET"
$Environment             = "REPLACE_WITH_ENVIRONMENT_NAME"    # Passed straight through as LIONGARDENVIRONMENT
$AgentDescription        = ""                                 # Optional LIONGARDDESCRIPTION
$AgentName               = ""                                 # Optional LIONGARDAGENTNAME; blank uses $env:COMPUTERNAME
$ProxyUrl                = ""                                 # Optional PROXYURL, e.g. http://proxy:8080; credentials in it are masked in logs
$DeviceGuid              = ""                                 # Optional DEVICEGUID: seeds the identity on a fresh install only (MSI 5.2.0+)
$ResetDeviceGuid         = $false                             # $true passes RESETDEVICEGUID=1: fresh install gets a new identity (MSI 5.5.0+)
$AutoUpdate              = $null                              # $true / $false passes AUTOUPDATE=1/0; $null omits it (MSI default 1)
$InstallLocation         = ""                                 # Optional INSTALLLOCATION; blank uses the MSI default folder
$ServiceAccount          = ""                                 # Optional LIONGARDAGENTSERVICEACCOUNT (DOMAIN\user); blank runs as LocalSystem
$ServiceAccountPassword  = ""                                 # LIONGARDAGENTSERVICEPASSWORD; required with $ServiceAccount, masked in logs
$IncludeEnvironmentValue = $true
$Folder                  = $env:ProgramData               # Parent folder; the script works in <Folder>\LiongardDeploy (SYSTEM/Administrators only)
$InstallerUrl            = "https://agents.static.liongard.com/LiongardAgent-lts.msi"
$CleanupPreviousAgents   = $true                              # Deprecated: must stay $true; $false exits 2. Use LGAgentInstall-MSI-Simple.ps1 to install without cleanup.

# ---- Install-state rules ----
$Roots      = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:ProgramW6432 | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'LiongardInc' } | Sort-Object -Unique)
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
# Identical in every windows/LGAgent*.ps1 script except LGAgentIdentity.ps1;
# tests/Test-SharedBlocks.ps1 checks it.
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

# BEGIN SHARED BLOCK: Liongard identity functions
# Identical in LGAgentUninstall-Simple, -Advanced and LGAgentCleanInstall-MSI-Simple; each defines Write-LiongardLog.

$script:LiongardIdentityRoots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:ProgramW6432 | Where-Object { $_ } | ForEach-Object { Join-Path $_ 'LiongardInc' } | Sort-Object -Unique)

function Get-LiongardRegistryString {
    param(
        [string]$SubPath,
        [string]$Name,
        [Microsoft.Win32.RegistryView]$View
    )

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    try {
        $key = $base.OpenSubKey($SubPath, $false)
        if ($null -eq $key) { return $null }
        try {
            $value = $key.GetValue($Name)
            if ($null -eq $value) { return $null }
            return [string]$value
        }
        finally { $key.Close() }
    }
    finally { $base.Close() }
}

function ConvertTo-LiongardIdKey {
    # Match key: whitespace (including a trailing newline) and enclosing braces removed, lowercase.
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    return (($Value -replace '\s', '') -replace '^\{(.*)\}$', '$1').ToLowerInvariant()
}

function Test-LiongardJunkId {
    # Never a match key: empty, local, uninitialized, all-zero, or no hex digit.
    param([AllowNull()][string]$Value)

    $key = ConvertTo-LiongardIdKey -Value $Value
    if ($key -in '', 'local', 'uninitialized') { return $true }
    if (($key -replace '[0{}-]', '') -eq '') { return $true }
    return ($key -notmatch '[0-9a-f]')
}

function Add-LiongardIdentifier {
    # Adds an Agent or Os identifier unless it is junk or its key is already listed in either list.
    param(
        $Identity,
        [ValidateSet('Agent', 'Os')][string]$Kind,
        [string]$Source,
        [AllowNull()][string]$Value
    )

    if ($null -eq $Value) { return }
    $Value = $Value.Trim()
    if (Test-LiongardJunkId -Value $Value) { return }
    $key = ConvertTo-LiongardIdKey -Value $Value
    foreach ($entry in @($Identity.Agent.ToArray()) + @($Identity.Os.ToArray())) { if ($entry.Key -eq $key) { return } }
    $Identity.$Kind.Add([pscustomobject]@{ Source = $Source; Value = $Value; Key = $key })
}

function New-LiongardIdentity {
    return [pscustomobject]@{
        AgentId      = ''
        AgentName    = ''
        Url          = ''
        AgentVersion = ''
        Value        = $null
        Source       = $null
        SettingsPath = $null
        Agent        = New-Object System.Collections.Generic.List[object]
        Os           = New-Object System.Collections.Generic.List[object]
    }
}

function Get-LiongardAgentIdentity {
    # Collects every local identifier before removal, with the same reads as LGAgentIdentity.ps1. Agent
    # identifiers: AgentGuid. OS identifiers: the Windows MachineGuid (agents before 5.3.0 registered it).
    param([bool]$AgentPresent)

    $identity = New-LiongardIdentity
    $views    = [Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64
    $parsed   = [guid]::Empty
    foreach ($view in $views) {
        $raw = Get-LiongardRegistryString 'SOFTWARE\Liongard\LiongardAgent\MachineID' 'AgentGuid' $view
        if ($raw -and [guid]::TryParse($raw.Trim(), [ref]$parsed)) {
            Add-LiongardIdentifier -Identity $identity -Kind Agent -Source "agent_guid ($view)" -Value $raw
            if (-not $identity.Value) { $identity.Value = $parsed.ToString(); $identity.Source = 'agent_guid' }
        }
        elseif ($raw) { Write-LiongardLog WARN "Ignoring the AgentGuid value '$raw' ($view): it is not a valid GUID (the agent ignores it too)." }
    }
    $windowsGuid = $null
    foreach ($view in [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32) {
        try { $raw = Get-LiongardRegistryString 'SOFTWARE\Microsoft\Cryptography' 'MachineGuid' $view } catch { $raw = $null }
        if ($raw -and [guid]::TryParse($raw.Trim(), [ref]$parsed)) {
            Add-LiongardIdentifier -Identity $identity -Kind Os -Source "windows_machine_guid ($view)" -Value $raw
            if (-not $windowsGuid) { $windowsGuid = $parsed.ToString() }
        }
    }

    $candidates = @()
    foreach ($view in $views) {
        $location = Get-LiongardRegistryString 'SOFTWARE\Liongard\RoarAgent' 'INSTALLLOCATION' $view
        if ($location) { $candidates += (Join-Path $location.Trim() 'appsettings-override.config') }
        if (-not $identity.AgentVersion) { $identity.AgentVersion = [string](Get-LiongardRegistryString 'SOFTWARE\Liongard\RoarAgent' 'ProductVersion' $view) }
    }
    foreach ($root in $script:LiongardIdentityRoots) { $candidates += (Join-Path $root 'LiongardAgent\appsettings-override.config') }
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $identity.SettingsPath = $path
        try {
            # Reads only the named non-secret keys.
            [xml]$doc = Get-Content -LiteralPath $path -Raw
            foreach ($node in $doc.SelectNodes('//add[@key]')) {
                switch ($node.GetAttribute('key')) {
                    'AGENT_ID'   { $identity.AgentId = $node.GetAttribute('value').Trim() }
                    'AGENT_NAME' { $identity.AgentName = $node.GetAttribute('value') -replace '[\r\n]', ' ' }
                    'URL'        { $identity.Url = $node.GetAttribute('value') -replace '[\r\n]', ' ' }
                }
            }
        }
        catch { Write-LiongardLog WARN "Unable to read [$path]: $($_.Exception.Message)" }
        break
    }

    if (-not $identity.Value -and $windowsGuid -and ($identity.SettingsPath -or $AgentPresent)) {
        $identity.Value  = $windowsGuid
        $identity.Source = 'windows_machine_guid'
    }

    Write-LiongardLog INFO ("Local AgentID: {0}" -f $(if ($identity.AgentId) { $identity.AgentId } else { 'none' }))
    Write-LiongardLog INFO ("Agent identifiers: {0}" -f (($identity.Agent | ForEach-Object { "$($_.Source)=$($_.Value)" }) -join ' '))
    Write-LiongardLog INFO ("OS identifiers: {0}" -f (($identity.Os | ForEach-Object { "$($_.Source)=$($_.Value)" }) -join ' '))
    return $identity
}

function Save-LiongardIdentityBackup {
    # Writes the identity (never a secret) in the LGAgentIdentity.ps1 backup format, so
    # LGAgentIdentity.ps1 -Action Restore -From <folder> can use it. Throws on failure.
    param(
        $Identity,
        [string]$Root
    )

    if (-not $Identity.Value) {
        if ($Identity.SettingsPath) { throw "$($Identity.SettingsPath) exists but no agent identity could be resolved, so it can't be saved. Nothing was removed." }
        Write-LiongardLog INFO 'No agent identity found on this computer; nothing to save.'
        return $null
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
    $dest  = Join-Path $Root "liongard-identity-$($env:COMPUTERNAME)-$stamp"
    if (Test-Path -LiteralPath $dest) { throw "$dest already exists. Nothing was removed." }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try {
        New-Item -ItemType Directory -Path $dest -ErrorAction Stop | Out-Null
        $guidFile = Join-Path $dest 'machine-guid.txt'
        [System.IO.File]::WriteAllText($guidFile, $Identity.Value + "`n", $utf8)
        $hash  = (Get-FileHash -LiteralPath $guidFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines = @(
            'format_version=1',
            'os=windows',
            "hostname=$($env:COMPUTERNAME)",
            "created_utc=$stamp",
            "identity_source=$($Identity.Source)",
            "agent_id=$($Identity.AgentId)",
            "agent_name=$($Identity.AgentName)",
            "url=$($Identity.Url)",
            "agent_version=$($Identity.AgentVersion)",
            "sha256_machine_guid=$hash"
        )
        [System.IO.File]::WriteAllText((Join-Path $dest 'manifest.txt'), (($lines -join "`n") + "`n"), $utf8)
    }
    catch {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        throw "Could not write the agent identity backup to ${dest}: $($_.Exception.Message). Nothing was removed."
    }
    Write-LiongardLog OK ("Agent identity saved to {0} (identity {1}, source {2}, AgentID {3}). It holds no key or secret." -f $dest, $Identity.Value, $Identity.Source, $(if ($Identity.AgentId) { $Identity.AgentId } else { 'unknown' }))
    return $dest
}

# END SHARED BLOCK: Liongard identity functions

function Write-LGLog([string]$Message) {   # Console plus the masked script log in the deploy folder.
    $line = "[LGAgent] $(Hide-LiongardSecretText -Text $Message)"
    Write-Host $line
    if ($script:LGScriptLog) {
        try { [IO.File]::AppendAllText($script:LGScriptLog, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $line`r`n") }
        catch { Write-Host "[LGAgent] WARN: script log [$script:LGScriptLog] not writable: $($_.Exception.Message)"; $script:LGScriptLog = $null }
    }
}
function Write-LiongardLog([string]$Level, [string]$Message) { Write-LGLog "$(if ($Level -ne 'INFO') { "${Level}: " })$Message" }
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
            [pscustomobject]@{ Key = $name; Code = $code; Version = [string]$k.GetValue('DisplayVersion'); Location = [string]$k.GetValue('InstallLocation'); Bundle = $bundle
                               Quiet = [string]$k.GetValue('QuietUninstallString'); View = $view; SubKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$name" }
        }
    }
}
function ConvertTo-LGPackedGuid([string]$Guid) {   # {GUID} <-> Windows Installer packed form (32 hex); the transform is its own inverse.
    $h = $Guid -replace '[{}-]', ''; if ($h -notmatch '^[0-9A-Fa-f]{32}$') { return $null }
    (-join (@($h[7..0]) + @($h[11..8]) + @($h[15..12]) + @(16..31 | ForEach-Object { $h[$_ -bxor 1] }))).ToUpper()
}
function Get-LGInstallerCache {   # HKCR\Installer\Products entries whose ProductName is exactly 'Liongard Agent' (MSI error 1612 when orphaned).
    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey('ClassesRoot', 'Registry64').OpenSubKey('Installer\Products')
    foreach ($name in @(if ($root) { $root.GetSubKeyNames() })) {
        $k = $root.OpenSubKey($name); $u = ConvertTo-LGPackedGuid $name
        if ($k -and $u -and [string]$k.GetValue('ProductName') -eq 'Liongard Agent') { [pscustomobject]@{ Packed = $name; Code = '{' + $u.Insert(20, '-').Insert(16, '-').Insert(12, '-').Insert(8, '-') + '}' } }
    }
}
function Test-LGCachedPackage([string]$Code) {   # Windows Installer's cached copy of the MSI (LocalPackage); without it /x and upgrades fail (1612/1603).
    $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$(ConvertTo-LGPackedGuid $Code)\InstallProperties")
    $lp = if ($k) { [string]$k.GetValue('LocalPackage') } else { '' }
    [bool]($lp -and (Test-Path -LiteralPath $lp -PathType Leaf))
}
function Test-LGTask { $null = & schtasks.exe /query /tn $Task 2>&1; $LASTEXITCODE -eq 0 }   # schtasks: Get-ScheduledTask has hung on endpoints.
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
function Test-LGUpdating {   # Agent self-update in progress: updater process, or the updater task Running (Task Scheduler COM; 4 = TASK_STATE_RUNNING).
    if (Get-Process LiongardAgentUpdater -ErrorAction SilentlyContinue) { return $true }
    try { $ts = New-Object -ComObject Schedule.Service; $ts.Connect(); $ts.GetFolder('\').GetTask($Task).State -eq 4 } catch { $false }
}
function Test-LGHeartbeatRejected($Folders) {   # Platform refuses this agent (e.g. deleted in the UI): its last 3 heartbeat results in AgentSVCLog.txt are all HTTP 401. Network errors have no status code and never match; a missing or unreadable log counts as not rejected.
    foreach ($dir in @($Folders)) {
        $log = Join-Path $dir 'AgentSVCLog.txt'
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { continue }
        try { $lines = @(Get-Content -LiteralPath $log -Tail 500 -ErrorAction Stop) } catch { continue }
        $hb = @($lines | Where-Object { $_ -match '"caller":"http/heartbeat\.go' } | Select-Object -Last 3)
        if ($hb.Count -eq 3 -and @($hb | Where-Object { $_ -match '"status_code":401\b' }).Count -eq 3) { return $true }
    }
    $false
}
function Get-LGState {   # (b) Healthy = entry + service + binary + Running + MSI registration + heartbeats not rejected (401); NotInstalled = no remnant at all; Updating = mid-update; else Stale.
    if ((Get-LGServiceInfo).Status -ne 'Running' -and (Test-LGUpdating)) {   # Never classify (or clean up) an install that is mid-update.
        Write-LGLog 'Agent service is not running and an agent update is in progress; waiting up to 2 minutes.'
        $deadline = (Get-Date).AddMinutes(2); do { Start-Sleep -Seconds 10 } while ((Test-LGUpdating) -and (Get-Date) -lt $deadline)
    }
    $p = @(Get-LGProduct | Sort-Object Key -Unique); $s = Get-LGServiceInfo; $f = @(Get-LGFolder $p)
    $r = @($Roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container }); $c = @(Get-LGInstallerCache); $t = Test-LGTask; $tried = $false
    if ($p.Count -and $s.BinaryExists -and $s.Status -ne 'Running') {   # A stopped agent gets one start attempt (30 s to reach Running) before it counts as broken.
        $tried = $true
        try { $svc = Get-Service $Service -ErrorAction Stop; if ($svc.Status -ne 'StartPending') { $svc.Start() }; $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30)); Write-LGLog "Started stopped service $Service." }
        catch { Write-LGLog "WARN: $Service did not reach Running within 30 seconds: $($_.Exception.Message)" }
        $s = Get-LGServiceInfo
    }
    $codes = @($p | Where-Object Code | ForEach-Object Code)   # EXE bundle entries have no code; their hidden MSI entry does.
    $hkcr = [Microsoft.Win32.RegistryKey]::OpenBaseKey('ClassesRoot', 'Registry64')   # Looked up by code, so a different cached ProductName never fails a healthy install.
    $registered = (-not $codes.Count) -or @($codes | Where-Object { $hkcr.OpenSubKey("Installer\Products\$(ConvertTo-LGPackedGuid $_)") }).Count
    $uncached = @($codes | Where-Object { -not (Test-LGCachedPackage $_) })   # Registered but un-upgradable: an upgrade would fail on every run.
    $missing = @(([ordered]@{ 'no Programs and Features entry' = $p.Count; 'service not registered' = $s.Exists; "service binary missing [$($s.Binary)]" = $s.BinaryExists
                              "service not running$(if ($tried) { ' after a 30-second start attempt' }) (status: $(if ($s.Status) { $s.Status } else { 'none' }))" = ($s.Status -eq 'Running')
                              "not registered with Windows Installer [$($codes -join ', ')]" = $registered
                              "Windows Installer cached package missing [$($uncached -join ', ')]" = (-not $uncached.Count)
                              'platform rejected the last 3 heartbeats (HTTP 401 in AgentSVCLog.txt)' = (-not (Test-LGHeartbeatRejected $f)) }).GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
    $found = @(([ordered]@{ 'uninstall entry' = $p.Count; 'service' = $s.Exists; 'install folder' = $f.Count; 'LiongardInc folder' = $r.Count; 'installer cache entry' = $c.Count; 'updater task' = $t }).GetEnumerator() | Where-Object { $_.Value } | ForEach-Object Key)
    $state = if (-not $missing.Count) { 'Healthy' } elseif (-not $found.Count) { 'NotInstalled' } elseif (Test-LGUpdating) { 'Updating' } else { 'Stale' }
    $reason = "found [$($found -join ', ')]; healthy check failed: $($missing -join '; ')"
    Write-LGLog "Install state: $state"
    if ($state -in 'Stale', 'Updating') { Write-LGLog "  remnants found: $($found -join ', ')"; $missing | ForEach-Object { Write-LGLog "  healthy check failed: $_" } }
    Write-LGLog ("  entries: {0}" -f $(if ($p.Count) { ($p | ForEach-Object { "$($_.Key) v$($_.Version) code=$($_.Code) bundle=$($_.Bundle)" }) -join '; ' } else { 'none' }))
    Write-LGLog "  service: exists=$($s.Exists) status=$($s.Status) binary=$($s.Binary) binaryExists=$($s.BinaryExists)"
    Write-LGLog "  folders: $(@($f) + @($r) -join '; ')"
    Write-LGLog "  installer cache: $(@($c | ForEach-Object { "$($_.Packed) $($_.Code)" }) -join '; '); updater task present: $t"
    [pscustomobject]@{ State = $state; Products = $p; Service = $s; Cache = $c; Reason = $reason }
}
function Assert-LGNotProtected([string]$Path) {   # (e) Refuse the identity key, its children, or any parent of it.
    $p = $Path.Trim() -replace '^(?i)(Microsoft\.PowerShell\.Core\\)?Registry::', ''
    if (-not ($p -match '^(?i)(HKEY_LOCAL_MACHINE|HKLM|HKEY_CLASSES_ROOT|HKCR|HKEY_CURRENT_USER|HKCU|HKEY_USERS|HKU):?(\\(.*))?$')) { return }
    $hive = @{ HKLM = 'HKEY_LOCAL_MACHINE'; HKCR = 'HKEY_CLASSES_ROOT'; HKCU = 'HKEY_CURRENT_USER'; HKU = 'HKEY_USERS' }[$Matches[1]]
    $n = ("$(if ($hive) { $hive } else { $Matches[1].ToUpper() })\$($Matches[3])" -replace '\\+', '\').TrimEnd('\')
    foreach ($x in $Protected) { if ($n.Equals($x, 'OrdinalIgnoreCase') -or $n.StartsWith("$x\", 'OrdinalIgnoreCase') -or $x.StartsWith("$n\", 'OrdinalIgnoreCase')) { throw "Refusing to modify protected Liongard identity path [$Path]." } }
}
function Remove-LGPath([string]$Path) { Assert-LGNotProtected $Path; Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
function Remove-LGRegKey([string]$Hive, [string]$View, [string]$SubKey) {   # Explicit view, so a 32-bit RMM host still reaches 64-bit keys.
    Assert-LGNotProtected "$(@{ LocalMachine = 'HKLM'; ClassesRoot = 'HKCR' }[$Hive])\$SubKey"
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View).DeleteSubKeyTree($SubKey, $false)
}
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
        try { $svc = Get-Service $Service -ErrorAction Stop; if ($svc.Status -ne 'Stopped') { if ($svc.Status -ne 'StopPending') { $svc.Stop() }; $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) } } catch { Write-LGLog "WARN: service stop: $($_.Exception.Message)" }   # Not Stop-Service: it blocks with no time limit.
        $null = & sc.exe delete $Service 2>&1; Write-LGLog "sc.exe delete $Service exit $LASTEXITCODE (0, 1060 and 1072 are fine)"
        $deadline = (Get-Date).AddSeconds(30); while ((Get-LGServiceInfo).Exists -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }   # A service still marked for deletion fails the install (1603).
        if ((Get-LGServiceInfo).Exists) { Write-LGLog "WARN: $Service is still registered 30 seconds after sc.exe delete (marked for deletion?); the install can fail until it is gone or the machine restarts." }
    }
    # All uninstall attempts run before any HKCR\Installer key is removed: MSI uninstall entries, codes unpacked from the cache, then EXE bundles.
    foreach ($code in @(@($State.Products | Where-Object Code | ForEach-Object Code) + @($State.Cache | ForEach-Object Code) | Sort-Object -Unique)) {
        $staleLog = Join-Path $script:LiongardDeploy.Root ("StaleUninstall_{0}_{1}.log" -f $code.Trim('{}'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Register-LiongardDeployLog -Label 'Stale uninstall log' -Path $staleLog -Redact
        $proc = $null; try { $proc = Start-Process msiexec.exe -ArgumentList '/x', $code, '/qn', '/norestart', '/L*V', "`"$staleLog`"" -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
              Write-LGLog "msiexec /x $code exit $($proc.ExitCode) (failure tolerated)" } catch { Write-LGLog "WARN: msiexec /x ${code}: $($_.Exception.Message)" }
        if ($proc.ExitCode -eq 1618) { Exit-LG 11 "msiexec /x $code returned 1618: another Windows Installer operation is in progress. Cleanup stopped before any installer registration was removed; run the script again later." }
    }
    foreach ($p in @($State.Products | Where-Object Bundle)) {
        if ($p.Quiet -notmatch '^\s*"([^"]+)"\s*(.*)$' -and $p.Quiet -notmatch '^\s*(\S+?\.exe)\s*(.*)$') { Write-LGLog "WARN: bundle $($p.Key) has no usable QuietUninstallString; only its key will be removed."; continue }
        $file, $arg = $Matches[1], $Matches[2]; if ($arg -notmatch '(?i)(^|\s)[/-]norestart\b') { $arg = "$arg /norestart".Trim() }   # Burn must never reboot the endpoint.
        try { $proc = Start-Process -FilePath $file -ArgumentList $arg -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop; Write-LGLog "Bundle quiet uninstall $($p.Key) exit $($proc.ExitCode) (failure tolerated)" }
        catch { Write-LGLog "WARN: bundle quiet uninstall $($p.Key): $($_.Exception.Message)" }
    }
    foreach ($p in @(Get-LGProduct)) {   # (a) Leftover Programs and Features entries, in whichever registry view still holds them.
        try { Remove-LGRegKey -Hive 'LocalMachine' -View $p.View -SubKey $p.SubKey; Write-LGLog "Removed leftover uninstall entry $($p.Key) ($($p.View))" } catch { Write-LGLog "WARN: could not remove uninstall entry $($p.Key): $($_.Exception.Message)" }
    }
    $cache = @(Get-LGInstallerCache); $packed = @($cache | ForEach-Object Packed)   # (b) Only UpgradeCodes values that point at the matched products.
    $up = [Microsoft.Win32.RegistryKey]::OpenBaseKey('ClassesRoot', 'Registry64').OpenSubKey('Installer\UpgradeCodes')
    foreach ($name in @(if ($up -and $packed.Count) { $up.GetSubKeyNames() })) {
        $k = $up.OpenSubKey($name); $hits = @(if ($k) { $k.GetValueNames() | Where-Object { $packed -contains $_ } }); if (-not $hits.Count) { continue }
        try { if ($hits.Count -eq $k.ValueCount -and $k.SubKeyCount -eq 0) { Remove-LGRegKey -Hive 'ClassesRoot' -View 'Registry64' -SubKey "Installer\UpgradeCodes\$name" }
              else { Assert-LGNotProtected "HKCR\Installer\UpgradeCodes\$name"; $w = [Microsoft.Win32.RegistryKey]::OpenBaseKey('ClassesRoot', 'Registry64').OpenSubKey("Installer\UpgradeCodes\$name", $true); $hits | ForEach-Object { $w.DeleteValue($_, $false) } }
              Write-LGLog "Removed installer upgrade entry $name -> $($hits -join ', ')" } catch { Write-LGLog "WARN: could not clean upgrade entry ${name}: $($_.Exception.Message)" }
    }
    foreach ($c in $cache) {   # Products, Features and the per-machine UserData registration, so a same-ProductCode reinstall is not seen as installed.
        try { Remove-LGRegKey -Hive 'ClassesRoot' -View 'Registry64' -SubKey "Installer\Products\$($c.Packed)"; Remove-LGRegKey -Hive 'ClassesRoot' -View 'Registry64' -SubKey "Installer\Features\$($c.Packed)"
              Remove-LGRegKey -Hive 'LocalMachine' -View 'Registry64' -SubKey "SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$($c.Packed)"
              Write-LGLog "Removed installer cache entry $($c.Packed) ($($c.Code))" } catch { Write-LGLog "WARN: could not remove installer cache entry $($c.Packed): $($_.Exception.Message)" }
    }
    if (Test-LGTask) { $null = & schtasks.exe /delete /tn $Task /f 2>&1; Write-LGLog "schtasks /delete $Task exit $LASTEXITCODE$(if ($LASTEXITCODE) { ' (WARN: task may remain)' })" }   # (c)
    Stop-LGProcess; Remove-LGStaleFolder $State.Products
    Remove-LGStoredCredential
}
function Remove-LGStaleFolder($Products) {   # Rename (or, failing that, delete) each install folder.
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    foreach ($f in @(Get-LGFolder $Products)) {
        try { Assert-LGNotProtected $f; Rename-Item -LiteralPath $f -NewName "$(Split-Path $f -Leaf).stale-$stamp" -ErrorAction Stop; Write-LGLog "Renamed $f to *.stale-$stamp" }
        catch { Write-LGLog "WARN: rename of $f failed ($($_.Exception.Message)); deleting instead."; try { Remove-LGPath $f; Write-LGLog "Deleted $f" } catch { Write-LGLog "WARN: could not delete ${f}: $($_.Exception.Message)" } }
    }
}
function Test-LGInstall {   # (f) Service Running (retry ~60s) and updater task registered.
    $deadline = (Get-Date).AddSeconds(60)
    do { $status = "$((Get-Service $Service -ErrorAction SilentlyContinue).Status)"; if ($status -eq 'Running') { break }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline)
    $taskOk = Test-LGTask
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
function Get-LGMsiVersion([string]$Path) {   # ProductVersion via Windows Installer COM; COM objects are released.
    $wi = $db = $view = $rec = $null; $call = { param($o, $m, $a, $t = 'InvokeMethod') $o.GetType().InvokeMember($m, $t, $null, $o, $a) }
    try { $wi = New-Object -ComObject WindowsInstaller.Installer; $db = & $call $wi 'OpenDatabase' @($Path, 0)
          $view = & $call $db 'OpenView' @("SELECT Value FROM Property WHERE Property = 'ProductVersion'"); [void](& $call $view 'Execute' $null)
          $rec = & $call $view 'Fetch' $null; if ($rec) { ConvertTo-LGVersion (& $call $rec 'StringData' @(1) 'GetProperty') } }
    catch { Write-LGLog "WARN: could not read MSI ProductVersion: $($_.Exception.Message)" }
    finally { if ($view) { try { [void](& $call $view 'Close' $null) } catch { Write-LGLog 'WARN: MSI view close failed.' } }; foreach ($o in $rec, $view, $db, $wi) { if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } } }
}

# ---- Main ----
trap { Exit-LG 1 "Unexpected error: $($_.Exception.Message)" }
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [void](Initialize-LiongardDeployFolder -Folder $Folder -Secret $AgentTokenKey, $AgentTokenSecret, $ServiceAccountPassword) } catch { Exit-LG 3 "Deploy folder check failed: $($_.Exception.Message)" }
$script:LGScriptLog = Get-LiongardDeployLogPath -Prefix 'LGAgentScript'; Register-LiongardDeployLog -Label 'Script log' -Path $script:LGScriptLog
if ($CleanupPreviousAgents -ne $true) { Exit-LG 2 'CleanupPreviousAgents is deprecated and must stay $true. Use LGAgentInstall-MSI-Simple.ps1 to install without cleanup.' }
foreach ($name in 'LiongardUrl', 'AgentTokenKey', 'AgentTokenSecret') { if ((Get-Variable $name -ValueOnly) -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 2 "Configuration value [$name] must be set." } }
if ($IncludeEnvironmentValue -and $Environment -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 2 'Configuration value [Environment] must be set.' }
$parsedGuid = [guid]::Empty
if ($DeviceGuid -and -not [guid]::TryParse($DeviceGuid, [ref]$parsedGuid)) { Exit-LG 2 "DeviceGuid '$DeviceGuid' is not a valid GUID." }
if ([bool]$ServiceAccount -ne [bool]$ServiceAccountPassword) { Exit-LG 2 'Set both ServiceAccount and ServiceAccountPassword, or neither.' }
$prefix = $LiongardUrl.Trim() -replace '^https?://', '' -replace '/.*$', '' -replace '\.app\.liongard\.com$', ''   # us9, us9.app.liongard.com, https://us9.app.liongard.com/ -> us9
if ($prefix -notmatch '^[A-Za-z0-9-]+$') { Exit-LG 2 "LiongardUrl '$LiongardUrl' is not a Liongard address such as us9.app.liongard.com or us9." }
$LGHost = "$prefix.app.liongard.com"
Invoke-LiongardLegacyCleanup
$msi = Join-Path (Initialize-LiongardDeployStage) 'LiongardAgent-lts.msi'; $log = Get-LiongardDeployLogPath -Prefix 'AgentInstall'
foreach ($i in 1..3) {
    try { if (Test-Path -LiteralPath $msi) { Remove-Item -LiteralPath $msi -Force -ErrorAction Stop }; Invoke-WebRequest -Uri $InstallerUrl -OutFile $msi -UseBasicParsing -ErrorAction Stop; if ((Get-Item -LiteralPath $msi).Length -ge 1MB) { break } }
    catch { Write-LGLog "WARN: download attempt $i failed: $($_.Exception.Message)" }
    if ($i -eq 3) { Exit-LG 5 "Installer download from $InstallerUrl failed. Nothing was changed." }
}

$state = Get-LGState
if ($state.State -eq 'Updating') { Exit-LG 11 'An agent update is still in progress after waiting 2 minutes. Nothing was changed; run the script again later.' }
if ($state.State -eq 'Healthy') {   # Normal upgrade path: install only when the MSI is strictly newer.
    $installed = ConvertTo-LGVersion (@($state.Products | Where-Object { -not $_.Bundle }) | Select-Object -First 1).Version
    $new = Get-LGMsiVersion $msi
    if (-not $installed -or -not $new) { Exit-LG 5 "The versions can't be compared (installed '$installed', MSI '$new'), so the agent was not upgraded. Nothing was changed." }
    if ($new -le $installed) { Exit-LG 0 "Liongard Agent $installed is installed and running, and the MSI ($new) is not newer. Nothing to do." }
    Write-LGLog "Proceeding with upgrade: installed=$installed msi=$new"
}
else {   # Stale or NotInstalled: the identity is saved first, so the reinstall re-attaches to the same record.
    $identity = Get-LiongardAgentIdentity -AgentPresent ([bool]$state.Products.Count)
    try { [void](Save-LiongardIdentityBackup -Identity $identity -Root $script:LiongardDeploy.Root) }
    catch { Exit-LG 12 $_.Exception.Message }
    if ($state.State -eq 'Stale') {
        Invoke-LGStaleCleanup $state
        $left = @(@(Get-LGProduct | ForEach-Object { "uninstall entry $($_.Key)" }) + @(if ((Get-LGServiceInfo).Exists) { "service $Service" }))
        if ($left.Count) { Exit-LG 9 "The broken agent could not be removed completely ($($left -join '; ')), so it was not reinstalled." }
    }
}

$msiArgs = @('/i', "`"$msi`"", "LIONGARDURL=$LGHost", "LIONGARDACCESSKEY=$AgentTokenKey", "LIONGARDACCESSSECRET=$AgentTokenSecret", "LIONGARDAGENTNAME=`"$(if ($AgentName) { $AgentName } else { $env:COMPUTERNAME })`"")
if ($IncludeEnvironmentValue -and $Environment) { $msiArgs += "LIONGARDENVIRONMENT=`"$Environment`"" }
if ($AgentDescription) { $msiArgs += "LIONGARDDESCRIPTION=`"$AgentDescription`"" }
if ($ProxyUrl) { $msiArgs += "PROXYURL=`"$ProxyUrl`"" }
if ($DeviceGuid) { $msiArgs += "DEVICEGUID=$DeviceGuid" }
if ($ResetDeviceGuid) { $msiArgs += 'RESETDEVICEGUID=1' }
if ($null -ne $AutoUpdate) { $msiArgs += "AUTOUPDATE=$([int][bool]$AutoUpdate)" }
if ($InstallLocation) { $msiArgs += "INSTALLLOCATION=`"$InstallLocation`"" }
if ($ServiceAccount) { $msiArgs += "LIONGARDAGENTSERVICEACCOUNT=`"$ServiceAccount`"", "LIONGARDAGENTSERVICEPASSWORD=`"$ServiceAccountPassword`"" }
$msiArgs += '/qn', '/norestart', '/L*V', "`"$log`""
Register-LiongardDeployLog -Label 'Installer log' -Path $log -Redact
Write-LGLog "Installing Liongard Agent for $LGHost ..."
$code = (Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru).ExitCode
Protect-LiongardInstallerLog -Path $log
Write-LGLog "msiexec exit code: $code"
if ($code -in 3010, 1641) { Write-LGLog "WARN: msiexec returned ${code}: a reboot is required to finish the install." }
if ($code -eq 1618) { Exit-LG 11 'msiexec returned 1618: another Windows Installer operation is in progress; run the script again later.' $log }
if ($code -notin 0, 3010, 1641) { Exit-LG 6 "msiexec returned $code.$(@{ 1603 = ' Fatal error during installation; see the installer log below.' }[$code])" $log }
if (-not (Test-LGInstall)) { Exit-LG 7 'Post-install validation failed (service not Running or updater task missing).' $log }
Exit-LG 0 "Liongard Agent installed and validated (msiexec exit $code)."
