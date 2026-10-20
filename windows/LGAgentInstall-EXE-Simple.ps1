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
    Last updated: 2026-10-10
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
$Folder                  = "C:\Liongard"
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
        $proc = Start-Process msiexec.exe -ArgumentList '/x', $p.Code, '/qn', '/norestart', '/L*V', "`"$Folder\StaleUninstall_$($p.Code.Trim('{}')).log`"" -Wait -PassThru -WindowStyle Hidden
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
    if ($Code -and $LogPath -and (Test-Path -LiteralPath $LogPath)) {
        Write-LGLog "Installer log: $LogPath (last 20 lines, access key/secret masked):"
        Get-Content -LiteralPath $LogPath -Tail 20 | ForEach-Object { '  ' + ($_ -replace '(?i)(ACCESS(KEY|SECRET)\S*\s*[=:]\s*)("[^"]*"|\S+)', '$1****') } | Write-Host
    }
    $k = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry32').OpenSubKey('SOFTWARE\Liongard\LiongardAgent')
    $machineId = [bool]($k -and (($k.GetSubKeyNames() -contains 'MachineID') -or ($k.GetValueNames() -contains 'MachineID')))
    Write-LGLog "Identity key HKLM\SOFTWARE\WOW6432Node\Liongard preserved (not modified by this script). MachineID present: $machineId"
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
foreach ($name in 'InstancePrefix', 'AgentTokenKey', 'AgentTokenSecret') { if ((Get-Variable $name -ValueOnly) -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 1 "Configuration value [$name] must be set." } }
if ($IncludeEnvironmentValue -and $Environment -match '^(REPLACE_WITH_|\s*$)') { Exit-LG 1 'Configuration value [Environment] must be set.' }
if ($InstancePrefix -match '[?*\[\]]') { Exit-LG 1 "InstancePrefix '$InstancePrefix' contains a placeholder character." }
$LGHost = ($InstancePrefix.Trim() -replace '^https?://', '' -replace '/.*$', '' -replace '\.app\.liongard\.com$', '') + '.app.liongard.com'
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$exe = Join-Path $Folder 'LiongardAgent-lts.exe'; $log = Join-Path $Folder 'AgentInstall.log'
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
if (Test-Path -LiteralPath $log) { Remove-LGPath $log }
Write-LGLog "Installing Liongard Agent bundle for $LGHost (InstallNpcap=$InstallNpcap) ..."
$code = Start-LGInstaller -Path $exe -Arguments $exeArgs
Write-LGLog "Installer exit code: $code"
if ($code -ne 0 -and $code -ne 3010) { Exit-LG $code "Installer returned $code." $log }
if (-not (Test-LGInstall)) { Exit-LG 1 'Post-install validation failed (service not Running or updater task missing).' $log }
if ($EnableNetworkDiscovery) { Enable-LGNetworkDiscovery }
Exit-LG 0 "Liongard Agent installed and validated (installer exit $code)."
