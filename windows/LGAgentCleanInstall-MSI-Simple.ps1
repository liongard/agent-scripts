#requires -Version 5.1
<#
    Liongard Agent MSI clean install - simplified RMM script (Windows PowerShell 5.1, runs as SYSTEM).
    Cleans up previous, outdated, incomplete or corrupt Liongard Agent installs before installing,
    for example an agent uninstalled through an RMM or Programs and Features that is still listed
    or left its service, folder, installer cache entries or updater task behind.
    A healthy install is never cleaned up: it is upgraded only when the MSI is newer.
    No Liongard API calls: the Environment value is passed through to the MSI as-is.
    Check the GitHub repo (https://github.com/liongard/agent-scripts) for updates to this script.

    Based on LGAgentInstall-MSI-Simple.ps1 plus the cleanup steps of LGAgentUninstall.ps1
    (uninstall entries, Windows Installer cache, updater task). The agent identity key
    HKLM\SOFTWARE\WOW6432Node\Liongard is never modified, so a reinstall registers as the same agent.

    Exit codes: 0 = installed and validated, or already up to date; non-zero = failure
    (the msiexec exit code when msiexec itself failed, otherwise 1).
    An agent update runs once a day around midnight local time; a deployment that overlaps it exits 1 without changes and succeeds on the next run.
    Last updated: 2026-10-16
#>

# ---- Partner configuration ----
$LiongardUrl             = "REPLACE_WITH_LIONGARD_URL"        # Full address, e.g. us9.app.liongard.com (short form "us9" also accepted)
$AgentTokenKey           = "REPLACE_WITH_AGENT_TOKEN_KEY"
$AgentTokenSecret        = "REPLACE_WITH_AGENT_TOKEN_SECRET"
$Environment             = "REPLACE_WITH_ENVIRONMENT_NAME"    # Passed straight through as LIONGARDENVIRONMENT
$AgentDescription        = ""                                 # Optional LIONGARDDESCRIPTION
$IncludeEnvironmentValue = $true
$Folder                  = "C:\Liongard"
$InstallerUrl            = "https://agents.static.liongard.com/LiongardAgent-lts.msi"
$CleanupPreviousAgents   = $true                              # Removes outdated, broken, incomplete or corrupt Liongard Agent installs before installing. Set to $false to skip.

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
function Get-LGState {   # (b) Healthy = entry + service + binary + Running + MSI registration; NotInstalled = no remnant at all; Updating = mid-update; else Stale.
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
    $missing = @(([ordered]@{ 'no Programs and Features entry' = $p.Count; 'service not registered' = $s.Exists; "service binary missing [$($s.Binary)]" = $s.BinaryExists
                              "service not running$(if ($tried) { ' after a 30-second start attempt' }) (status: $(if ($s.Status) { $s.Status } else { 'none' }))" = ($s.Status -eq 'Running')
                              "not registered with Windows Installer [$($codes -join ', ')]" = $registered }).GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
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
        try { $svc = Get-Service $Service -ErrorAction Stop; if ($svc.Status -ne 'Stopped') { Stop-Service $Service -Force -ErrorAction Stop; $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) } } catch { Write-LGLog "WARN: service stop: $($_.Exception.Message)" }
        $null = & sc.exe delete $Service 2>&1; Write-LGLog "sc.exe delete $Service exit $LASTEXITCODE (0, 1060 and 1072 are fine)"
    }
    # All uninstall attempts run before any HKCR\Installer key is removed: MSI uninstall entries, codes unpacked from the cache, then EXE bundles.
    foreach ($code in @(@($State.Products | Where-Object Code | ForEach-Object Code) + @($State.Cache | ForEach-Object Code) | Sort-Object -Unique)) {
        try { $proc = Start-Process msiexec.exe -ArgumentList '/x', $code, '/qn', '/norestart', '/L*V', "`"$Folder\StaleUninstall_$($code.Trim('{}')).log`"" -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
              Write-LGLog "msiexec /x $code exit $($proc.ExitCode) (failure tolerated)" } catch { Write-LGLog "WARN: msiexec /x ${code}: $($_.Exception.Message)" }
    }
    foreach ($p in @($State.Products | Where-Object Bundle)) {
        if ($p.Quiet -notmatch '^\s*"([^"]+)"\s*(.*)$' -and $p.Quiet -notmatch '^\s*(\S+?\.exe)\s*(.*)$') { Write-LGLog "WARN: bundle $($p.Key) has no usable QuietUninstallString; only its key will be removed."; continue }
        $run = @{ FilePath = $Matches[1] }; if ($Matches[2]) { $run.ArgumentList = $Matches[2] }
        try { $proc = Start-Process @run -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop; Write-LGLog "Bundle quiet uninstall $($p.Key) exit $($proc.ExitCode) (failure tolerated)" }
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
    foreach ($c in $cache) { try { Remove-LGRegKey -Hive 'ClassesRoot' -View 'Registry64' -SubKey "Installer\Products\$($c.Packed)"; Write-LGLog "Removed installer cache entry $($c.Packed) ($($c.Code))" } catch { Write-LGLog "WARN: could not remove installer cache entry $($c.Packed): $($_.Exception.Message)" } }
    if (Test-LGTask) { $null = & schtasks.exe /delete /tn $Task /f 2>&1; Write-LGLog "schtasks /delete $Task exit $LASTEXITCODE$(if ($LASTEXITCODE) { ' (WARN: task may remain)' })" }   # (c)
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
    $taskOk = Test-LGTask
    Write-LGLog "Validation: service $Service status='$status'; task $Task present=$taskOk"
    ($status -eq 'Running') -and $taskOk
}
function Exit-LG([int]$Code, [string]$Message, [string]$LogPath) {
    Write-LGLog $(if ($Code) { "FAILED: $Message" } else { $Message })
    if ($Code -and $LogPath -and (Test-Path -LiteralPath $LogPath)) {
        Write-LGLog "Installer log: $LogPath (last 20 lines, access key/secret masked):"
        Get-Content -LiteralPath $LogPath -Tail 20 | ForEach-Object { '  ' + ($_ -replace '(?i)(ACCESS(KEY|SECRET)\S*\s*[=:]\s*)("[^"]*"|\S+)', '$1****') } | Write-Host
    }
    $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry32').OpenSubKey('SOFTWARE\Liongard\LiongardAgent')
    $machineId = [bool]($k -and (($k.GetSubKeyNames() -contains 'MachineID') -or ($k.GetValueNames() -contains 'MachineID')))
    Write-LGLog "Identity key HKLM\SOFTWARE\WOW6432Node\Liongard preserved (not modified by this script). MachineID present: $machineId"
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
foreach ($name in 'LiongardUrl', 'AgentTokenKey', 'AgentTokenSecret') { if ((Get-Variable $name -ValueOnly) -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 1 "Configuration value [$name] must be set." } }
if ($IncludeEnvironmentValue -and $Environment -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 1 'Configuration value [Environment] must be set.' }
$prefix = $LiongardUrl.Trim() -replace '^https?://', '' -replace '/.*$', '' -replace '\.app\.liongard\.com$', ''   # us9, us9.app.liongard.com, https://us9.app.liongard.com/ -> us9
if ($prefix -notmatch '^[A-Za-z0-9-]+$') { Exit-LG 1 "LiongardUrl '$LiongardUrl' is not a Liongard address such as us9.app.liongard.com or us9." }
$LGHost = "$prefix.app.liongard.com"
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$msi = Join-Path $Folder 'LiongardAgent-lts.msi'; $log = Join-Path $Folder 'AgentInstall.log'
foreach ($i in 1..3) {
    try { if (Test-Path -LiteralPath $msi) { Remove-LGPath $msi }; Invoke-WebRequest -Uri $InstallerUrl -OutFile $msi -UseBasicParsing -ErrorAction Stop; if ((Get-Item -LiteralPath $msi).Length -ge 1MB) { break } }
    catch { Write-LGLog "WARN: download attempt $i failed: $($_.Exception.Message)" }
    if ($i -eq 3) { Exit-LG 1 "Installer download from $InstallerUrl failed." }
}

$state = Get-LGState
if ($state.State -eq 'Updating') { Exit-LG 1 'An agent update is still in progress after waiting 2 minutes. Nothing was changed; run the script again later.' }
if ($state.State -eq 'Stale' -and $CleanupPreviousAgents) { Invoke-LGStaleCleanup $state }
elseif ($state.State -eq 'Stale') { Write-LGLog "WARN: previous install is incomplete or broken ($($state.Reason)) but CleanupPreviousAgents is `$false. Attempting the install anyway." }
elseif ($state.State -eq 'Healthy') {   # Normal upgrade path: install only when the MSI is strictly newer.
    $installed = ConvertTo-LGVersion (@($state.Products | Where-Object { -not $_.Bundle }) | Select-Object -First 1).Version
    $new = Get-LGMsiVersion $msi
    if ($installed -and $new -and $new -le $installed) { Exit-LG 0 "Liongard Agent $installed is installed and the MSI ($new) is not newer. Nothing to do." }
    Write-LGLog "Proceeding with install/upgrade: installed=$installed msi=$new"
}

$msiArgs = @('/i', "`"$msi`"", "LIONGARDURL=$LGHost", "LIONGARDACCESSKEY=$AgentTokenKey", "LIONGARDACCESSSECRET=$AgentTokenSecret", "LIONGARDAGENTNAME=`"$env:COMPUTERNAME`"")
if ($IncludeEnvironmentValue -and $Environment) { $msiArgs += "LIONGARDENVIRONMENT=`"$Environment`"" }
if ($AgentDescription) { $msiArgs += "LIONGARDDESCRIPTION=`"$AgentDescription`"" }
$msiArgs += '/qn', '/norestart', '/L*V', "`"$log`""
if (Test-Path -LiteralPath $log) { Remove-LGPath $log }
Write-LGLog "Installing Liongard Agent for $LGHost ..."
$code = (Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru).ExitCode
Write-LGLog "msiexec exit code: $code"
if ($code -ne 0 -and $code -ne 3010) { Exit-LG $code "msiexec returned $code." $log }
if (-not (Test-LGInstall)) { Exit-LG 1 'Post-install validation failed (service not Running or updater task missing).' $log }
try { Remove-LGPath $log; Write-LGLog "Deleted $log after a successful install (it can contain the access secret; it is kept only on failure)." }
catch { Write-LGLog "WARN: could not delete ${log}: $($_.Exception.Message)" }
Exit-LG 0 "Liongard Agent installed and validated (msiexec exit $code)."
