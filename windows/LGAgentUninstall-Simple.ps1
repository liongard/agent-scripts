<#
.SYNOPSIS
    Removes the Liongard Agent from a Windows endpoint (local removal only).

.DESCRIPTION
    Uninstalls the Liongard Agent and removes what it leaves behind on this endpoint.
    There are no required settings. Exit codes, logs and troubleshooting are in the README
    under .LINK.
    - Removes the updater task, the EXE bundle or MSI install, processes, services, uninstall entries, orphaned Windows Installer registrations (msiexec /x) and the LiongardInc folders, then reports anything that's left.
    - Makes no Liongard API calls and keeps the agent's record on the platform. To delete the record too, use LGAgentUninstall-Advanced.ps1.
    - Leaves the agent's Credential Manager entries in place; that cleanup is disabled until the dev team confirms it is safe (#8).
    - Never modifies the agent identity key, so a later reinstall re-attaches to the same platform record.
    - Writes a transcript to <LogFolder>\LiongardDeploy only when that folder already exists and is owned by SYSTEM or Administrators; otherwise the output goes to the console only.

.NOTES
    Requires:     Windows PowerShell 5.1, run as SYSTEM or an elevated administrator. No tokens.
    Author:       Liongard Partner Support
    Last updated: 2026-10-23

.LINK
    https://github.com/liongard/agent-scripts/blob/main/windows/README.md
#>

#requires -Version 5.1

# ================================
# Partner Configuration (optional)
# ================================
$LogFolder = $env:ProgramData   # Parent folder; the transcript goes to <LogFolder>\LiongardDeploy only if that folder already exists

$script:ServiceNames      = @('roaragent.exe', 'roaragent', 'LiongardAgentSVC', 'LiongardAgent', 'Liongard Agent')
$script:DisplayNames      = @('Liongard Agent', 'RoarAgent', 'Roar Agent')
$script:LegacyProductCode = '{1D89F069-B48B-4191-8810-2364C29EC039}'   # Fallback only; the ProductCode changes per version.
$script:UpdaterTaskName   = '\Liongard\LiongardAgentUpdater'
$script:InstallRoots      = @('C:\Program Files (x86)\LiongardInc', 'C:\Program Files\LiongardInc')
$script:UninstallSubKey   = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$script:OkExitCodes       = @(0, 1605, 1641, 3010)   # success, not installed, success with restart
$script:TranscriptPath    = $null

function Write-UninstallLog {
    # Write-Host on purpose: RMM consoles capture the host stream, and output here must not
    # leak into function return values.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param(
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN')][string]$Level,
        [string]$Message,
        [string]$Tag = 'Uninstall'
    )

    $line = "[$Tag][$Level] $Message"
    if ($Level -eq 'WARN') { Write-Warning $line } else { Write-Host $line }
}

function Get-AgentEntry {
    # Reads Liongard Agent uninstall entries from the 64-bit and 32-bit registry views, so it
    # works from a 32-bit PowerShell host too. Bundle entries are returned first.
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        # On 32-bit Windows both views are the same hive.
        if ($view -eq [Microsoft.Win32.RegistryView]::Registry32 -and -not [Environment]::Is64BitOperatingSystem) { continue }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $root = $base.OpenSubKey($script:UninstallSubKey)
            if (-not $root) { continue }
            foreach ($name in $root.GetSubKeyNames()) {
                $key = $root.OpenSubKey($name)
                if (-not $key) { continue }
                $displayName = [string]$key.GetValue('DisplayName')
                if ($script:DisplayNames -contains $displayName -or $name -eq $script:LegacyProductCode) {
                    $uninstall = [string]$key.GetValue('UninstallString')
                    $isBundle  = $null -ne $key.GetValue('BundleUpgradeCode') -or $null -ne $key.GetValue('BundleProviderKey')
                    $code      = $null
                    if (-not $isBundle -and $name -match '^\{[0-9A-Fa-f\-]{36}\}$') { $code = $name }
                    elseif (-not $isBundle -and $uninstall -match '(?i)msiexec.*?(?<code>\{[0-9A-F\-]{36}\})') { $code = $Matches['code'] }
                    $entries.Add([pscustomobject]@{
                        View        = $view
                        Name        = $name
                        DisplayName = $displayName
                        ProductCode = $code
                        IsBundle    = $isBundle
                        IsRegistration = $false
                        Command     = @([string]$key.GetValue('QuietUninstallString'), $uninstall) | Where-Object { $_ } | Select-Object -First 1
                        Label       = "'$displayName' ($view $name)"
                    })
                }
                $key.Close()
            }
            $root.Close()
        }
        finally { $base.Close() }
    }
    # Windows Installer registrations with no uninstall entry (deleted by hand or by a failed
    # uninstall). HKCR\Installer is shared by both views, so Registry64 serves a 32-bit host too.
    $classes = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::ClassesRoot, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $products = $classes.OpenSubKey('Installer\Products')
        foreach ($packed in @(if ($products) { $products.GetSubKeyNames() })) {
            $key = if ($packed -match '^[0-9A-Fa-f]{32}$') { $products.OpenSubKey($packed) }
            if (-not $key) { continue }
            $name = [string]$key.GetValue('ProductName')
            $key.Close()
            if ($script:DisplayNames -notcontains $name) { continue }
            # Packed form: the first three GUID groups reversed, then each byte's two hex digits swapped.
            $hex  = -join (@($packed[7..0]) + @($packed[11..8]) + @($packed[15..12]) + @(16..31 | ForEach-Object { $packed[$_ -bxor 1] }))
            $code = ('{' + $hex.Insert(20, '-').Insert(16, '-').Insert(12, '-').Insert(8, '-') + '}').ToUpper()
            if (@($entries | Where-Object { $_.ProductCode -eq $code }).Count) { continue }
            $entries.Add([pscustomobject]@{ View = 'Installer'; Name = $packed; DisplayName = $name; ProductCode = $code; IsBundle = $false; IsRegistration = $true; Command = $null; Label = "'$name' (Windows Installer $code)" })
        }
        if ($products) { $products.Close() }
    }
    finally { $classes.Close() }
    return @($entries | Sort-Object { -not $_.IsBundle })
}

function Get-AgentService {
    # Exact Name match: Get-Service -Name also matches display names, which listed one service twice.
    return @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $script:ServiceNames -contains $_.Name })
}

function Invoke-AgentEntryKeyRemoval {
    # Deletes one uninstall entry key. Only keys under ...\CurrentVersion\Uninstall are ever
    # deleted here, never the identity key HKLM\SOFTWARE\WOW6432Node\Liongard.
    param([Parameter(Mandatory)][pscustomobject]$Entry)

    if ($Entry.Name -notmatch '^[^\\]+$') { throw "Refusing to delete unexpected key name [$($Entry.Name)]." }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $Entry.View)
    try {
        $root = $base.OpenSubKey($script:UninstallSubKey, $true)
        if ($root) {
            $root.DeleteSubKeyTree($Entry.Name, $false)
            $root.Close()
        }
    }
    finally { $base.Close() }
}

function Invoke-AgentProcessStop {
    # Stops processes running from a LiongardInc folder (agent, updater, node.exe/prowl.exe).
    # Win32_Process shows 64-bit process paths to a 32-bit host too.
    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $exe = $_.ExecutablePath
        $exe -and @($script:InstallRoots | Where-Object { $exe.StartsWith($_ + '\', $ignoreCase) }).Count -gt 0
    })
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-UninstallLog INFO ("Stopped process {0} (PID {1})." -f $process.Name, $process.ProcessId)
        }
        catch { Write-UninstallLog WARN ("Could not stop process {0} (PID {1}): {2}" -f $process.Name, $process.ProcessId, $_.Exception.Message) }
    }
    if ($processes.Count -gt 0) { Start-Sleep -Seconds 2 }
}

function Invoke-AgentEntryUninstall {
    # MSI entries: always 'msiexec /x {ProductCode}', never the registered string, which can be
    # 'MsiExec.exe /I{code}' (a repair). Bundle entries: the registered quiet uninstall, plus
    # /quiet and /norestart when missing. Returns $true when the uninstall succeeded.
    param([Parameter(Mandatory)][pscustomobject]$Entry)

    if ($Entry.ProductCode) {
        $exe     = 'msiexec.exe'
        $exeArgs = "/x $($Entry.ProductCode) /qn /norestart"
    }
    elseif ($Entry.Command) {
        $cmd = $Entry.Command.Trim()
        if ($cmd.StartsWith('"')) {
            $exe     = $cmd.Split('"')[1]
            $exeArgs = $cmd.Substring($exe.Length + 2).Trim()
        }
        else {
            $exe     = $cmd.Split(' ')[0]
            $exeArgs = $cmd.Substring($exe.Length).Trim()
        }
        if ($exeArgs -notmatch '(?i)(/quiet|/silent|/s\b)') { $exeArgs += ' /quiet' }
        if ($exeArgs -notmatch '(?i)/norestart') { $exeArgs += ' /norestart' }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            Write-UninstallLog WARN "Uninstaller for $($Entry.Label) not found: $exe. Treating the entry as orphaned."
            return $true
        }
    }
    else {
        Write-UninstallLog INFO "$($Entry.Label) has no uninstall command. Treating it as orphaned."
        return $true
    }

    Write-UninstallLog STEP "Uninstalling $($Entry.Label): $exe $exeArgs"
    try {
        $code = (Start-Process -FilePath $exe -ArgumentList $exeArgs -Wait -PassThru -WindowStyle Hidden).ExitCode
    }
    catch {
        Write-UninstallLog WARN "Could not start the uninstaller for $($Entry.Label): $($_.Exception.Message)"
        return $false
    }
    if ($script:OkExitCodes -notcontains $code) {
        Write-UninstallLog WARN "Uninstall of $($Entry.Label) returned exit code $code."
        return $false
    }
    if ($code -eq 3010 -or $code -eq 1641) { Write-UninstallLog WARN "Uninstall of $($Entry.Label) needs a restart (exit code $code)." }
    else { Write-UninstallLog OK "Uninstall of $($Entry.Label) returned exit code $code." }
    return $true
}

function Invoke-AgentFolderRemoval {
    # Removes a LiongardInc folder. If that fails, takes ownership for Administrators, grants
    # them Full Control and tries once more. takeown reads stdin from NUL so it can never prompt.
    param([Parameter(Mandatory)][string]$Path)

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-UninstallLog WARN "Removing [$Path] failed ($($_.Exception.Message)). Resetting ownership and permissions, then retrying."
        $null = & cmd.exe /d /c "takeown.exe /F `"$Path`" /R /A <NUL" 2>&1
        $null = & icacls.exe $Path /grant:r '*S-1-5-32-544:F' /T /C /Q 2>&1
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    Write-UninstallLog OK "Removed folder [$Path]."
}

function Test-UpdaterTask {
    # schtasks.exe, because Get-ScheduledTask has been observed to hang on endpoints.
    $null = & schtasks.exe /query /tn $script:UpdaterTaskName 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Get-AgentLeftover {
    # Everything that still marks this endpoint as having the agent.
    $left = New-Object System.Collections.Generic.List[string]
    foreach ($entry in Get-AgentEntry) { $left.Add("Uninstall entry $($entry.Label)") }
    foreach ($service in Get-AgentService) { $left.Add("Service '$($service.Name)'") }
    if (Test-UpdaterTask) { $left.Add("Scheduled task '$($script:UpdaterTaskName)'") }
    foreach ($root in $script:InstallRoots) {
        if (Test-Path -LiteralPath $root) { $left.Add("Folder [$root]") }
    }
    return @($left | Select-Object -Unique)
}

function Open-UninstallLog {
    # Uses <LogFolder>\LiongardDeploy only when an install script has already created it and it
    # can be trusted: a real folder (not a reparse point) owned by SYSTEM or Administrators.
    $root = if ($LogFolder) { Join-Path -Path $LogFolder -ChildPath 'LiongardDeploy' } else { $null }
    $reason = $null
    try {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { throw 'it does not exist' }
        $item   = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        $parent = Get-Item -LiteralPath $LogFolder -Force -ErrorAction Stop
        $owner  = (Get-Acl -LiteralPath $root).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if (-not $item.PSIsContainer) { $reason = 'it is not a folder' }
        elseif (($item.Attributes -bor $parent.Attributes) -band [System.IO.FileAttributes]::ReparsePoint) { $reason = 'it or its parent is a reparse point' }
        elseif (@('S-1-5-18', 'S-1-5-32-544') -notcontains $owner) { $reason = "it is owned by $owner, not SYSTEM or Administrators" }
    }
    catch { $reason = $_.Exception.Message }

    if ($reason) {
        Write-UninstallLog INFO "No log file written: [$root] can't be used because $reason. Output goes to the console only."
        return
    }
    $path = Join-Path -Path $root -ChildPath ("LGAgentUninstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        Start-Transcript -Path $path -Force | Out-Null
        $script:TranscriptPath = $path
    }
    catch { Write-UninstallLog WARN "Could not start the transcript at [$path]: $($_.Exception.Message)" }
}

function Close-UninstallLog {
    # Stops the transcript and keeps the newest 5 uninstall logs (the same rule the install
    # scripts apply to LGAgentUninstall_<timestamp>.log).
    if (-not $script:TranscriptPath) { return }
    try { Stop-Transcript | Out-Null }
    catch { Write-UninstallLog WARN "Could not stop the transcript: $($_.Exception.Message)" }
    Write-UninstallLog INFO "Log file: $($script:TranscriptPath)"
    $folder = Split-Path -Path $script:TranscriptPath -Parent
    Get-ChildItem -LiteralPath $folder -Filter 'LGAgentUninstall_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^LGAgentUninstall_\d{8}_\d{6}\.log$' } |
        Sort-Object Name -Descending | Select-Object -Skip 5 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $script:TranscriptPath = $null
}

function Write-IdentityStatus {
    # Logs that the identity key was preserved and whether MachineID exists. Never logs its value.
    # Same output as Write-LiongardIdentityStatus in the other Windows scripts.
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
            try { $machineIdPresent = ($agentKey.GetSubKeyNames() -contains 'MachineID') -or ($agentKey.GetValueNames() -contains 'MachineID') }
            finally { $agentKey.Close() }
        }
    }
    catch { Write-UninstallLog WARN "Unable to read the Liongard identity key: $($_.Exception.Message)" -Tag 'AgentState' }
    finally { if ($base) { $base.Close() } }

    Write-UninstallLog INFO ("Identity key HKLM\SOFTWARE\WOW6432Node\Liongard preserved (not modified by this script). Key present: {0} | MachineID present: {1}" -f $keyExists, $machineIdPresent) -Tag 'AgentState'
}

# ================================
# Main
# ================================

$ProgressPreference = 'SilentlyContinue'

trap {
    Write-Error "Unexpected error: $($_.Exception.Message)" -ErrorAction Continue
    Close-UninstallLog
    exit 1
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if ($identity.User.Value -ne 'S-1-5-18' -and -not $isAdmin) {
    Write-Error "Run this script as SYSTEM or from an elevated administrator session (current identity: $($identity.Name))." -ErrorAction Continue
    exit 1
}

Open-UninstallLog
Write-UninstallLog INFO 'Local removal only: no Liongard API calls, and the platform record is kept.'

$before = @(Get-AgentLeftover)
if ($before.Count -eq 0) {
    Write-UninstallLog OK 'No Liongard Agent found. Nothing to remove.'
    Write-IdentityStatus
    Close-UninstallLog
    exit 0
}
Write-UninstallLog INFO 'Found:'
foreach ($item in $before) { Write-UninstallLog INFO "  - $item" }

# 1. Updater task first, so it can't start an update while the agent is being removed.
if (Test-UpdaterTask) {
    $null = & schtasks.exe /delete /tn $script:UpdaterTaskName /f 2>&1
    if ($LASTEXITCODE -eq 0) { Write-UninstallLog OK "Deleted scheduled task '$($script:UpdaterTaskName)'." }
    else { Write-UninstallLog WARN "schtasks /delete returned $LASTEXITCODE for '$($script:UpdaterTaskName)'." }
}

# 2. Bundle entries, then MSI entries (re-read, since a bundle uninstall removes its MSI).
#    Keys whose uninstall failed are kept so the product stays visible and can be retried.
$failedKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($pass in @($true, $false)) {
    foreach ($entry in @(Get-AgentEntry | Where-Object { $_.IsBundle -eq $pass })) {
        if (-not (Invoke-AgentEntryUninstall -Entry $entry)) {
            [void]$failedKeys.Add("$($entry.View)\$($entry.Name)")
        }
    }
}

# 3. Processes and services.
Write-UninstallLog STEP 'Stopping Liongard processes and removing services.'
Invoke-AgentProcessStop
foreach ($service in Get-AgentService) {
    if ($service.Status -ne 'Stopped') {
        try { Stop-Service -Name $service.Name -Force -ErrorAction Stop }
        catch { Write-UninstallLog WARN "Service '$($service.Name)' did not stop cleanly: $($_.Exception.Message)" }
    }
    $null = & sc.exe delete $service.Name 2>&1
    if (@(0, 1060, 1072) -contains $LASTEXITCODE) { Write-UninstallLog OK "Deleted service '$($service.Name)'." }
    else { Write-UninstallLog WARN "sc.exe delete '$($service.Name)' returned $LASTEXITCODE." }
}
Invoke-AgentProcessStop

# 4. Leftover uninstall entries whose uninstall succeeded or that were orphaned.
foreach ($entry in @(Get-AgentEntry | Where-Object { -not $_.IsRegistration })) {
    if ($failedKeys.Contains("$($entry.View)\$($entry.Name)")) { continue }
    try {
        Invoke-AgentEntryKeyRemoval -Entry $entry
        Write-UninstallLog OK "Removed uninstall entry $($entry.Label)."
    }
    catch { Write-UninstallLog WARN "Could not remove uninstall entry $($entry.Label): $($_.Exception.Message)" }
}

# 5. Folders.
foreach ($root in $script:InstallRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try { Invoke-AgentFolderRemoval -Path $root }
    catch { Write-UninstallLog WARN "Could not remove [$root]: $($_.Exception.Message)" }
}

Write-UninstallLog INFO "Credential Manager cleanup is disabled until dev confirms that a fresh install always issues new credentials (#8). No entries were changed."

# 6. Verify.
$after = @(Get-AgentLeftover)
Write-IdentityStatus
if ($after.Count -eq 0) {
    Write-UninstallLog OK 'The Liongard Agent was removed. Nothing is left.'
    Close-UninstallLog
    exit 0
}

Write-UninstallLog WARN 'The Liongard Agent is still detected. Left on this endpoint:'
foreach ($item in $after) { Write-UninstallLog WARN "  - $item" }
if ($after -like '*(Windows Installer *') { Write-UninstallLog WARN 'To clear a Windows Installer registration that msiexec cannot remove, run LGAgentCleanInstall-MSI-Simple.ps1.' }
Close-UninstallLog
exit 1
