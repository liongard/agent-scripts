# Windows

Eight PowerShell scripts that install, repair or remove the Liongard Agent on Windows, and save or restore its identity. For other platforms, and for what you need before you start, see the [main README](../README.md).

## Scripts

| Script | What it does | Use it when |
|---|---|---|
| `LGAgentInstall-MSI-Simple.ps1` | Installs the agent from the MSI, or upgrades it when the MSI is newer. No Liongard API calls. Never removes an agent. | Standard installs and upgrades. |
| `LGAgentInstall-EXE-Simple.ps1` | Installs the EXE bundle (agent, Visual C++ and Npcap), or upgrades it when the bundle is newer. No Liongard API calls. | The host will run the network discovery inspector. |
| `LGAgentInstall-MSI-Advanced.ps1` | Like MSI Simple, but first checks the environment name through the Liongard API, and writes a full transcript log. | You want the environment name checked before the agent registers. |
| `LGAgentInstall-EXE-Advanced.ps1` | Like EXE Simple, plus the API environment check, a proxy check, per-component validation, a transcript log and a JSON run summary. | Network discovery hosts where you want the extra checks and logs. |
| `LGAgentCleanInstall-MSI-Simple.ps1` | Saves the agent identity, removes an old, broken, stopped, incomplete or corrupt agent install, then installs from the MSI. A healthy agent is never cleaned up; it's upgraded only when the MSI is newer. It also reinstalls an agent the platform no longer accepts (for example, one deleted in the Liongard UI) as the same agent. | The agent was uninstalled but is still listed, or left its service, folder, Windows Installer entries or updater task behind, or the agent was deleted in the Liongard UI but is still installed. |
| `LGAgentUninstall-Simple.ps1` | Saves the agent identity, then removes the agent and its leftovers. Keeps the platform record. No API calls. | Removing the agent. |
| `LGAgentUninstall-Advanced.ps1` | Like Uninstall Simple, then optionally deletes the agent's record from the Liongard platform. Renamed from `LGAgentUninstall.ps1`. | Decommissioning an endpoint for good. |
| `LGAgentIdentity.ps1` | Saves the agent identity to a folder (`-Action Backup`), writes it back before a reinstall (`-Action Restore -From <folder>`), or shows it (`-Action Show`). It never saves a key or secret. | Rebuilding or reimaging a host that must come back as the same agent. |

Every install script checks for an existing agent first:

- **Healthy** (uninstall entry, `roaragent.exe` service **Running**, and its binary): it upgrades only when the installer is newer. Otherwise it exits `0` without changes. If either version can't be read, it exits `5` and changes nothing.
- **Stale** (a stopped agent, or leftovers of an earlier install): Install Simple and Advanced change nothing and exit `8`. Clean Install saves the identity, removes the leftovers, then installs; it exits `9` when the service or the uninstall entry survives the cleanup.
- **NotInstalled:** it installs. Clean Install saves any identity left behind first.

Before this release, Install Simple counted a stopped agent as Healthy, and Install Simple and Advanced cleaned up a Stale agent themselves.

No install or uninstall script modifies the agent identity key `HKLM\SOFTWARE\WOW6432Node\Liongard`, so a reinstalled agent registers as the same agent. Only `LGAgentIdentity.ps1 -Action Restore` writes it.

## Requirements

- Windows PowerShell 5.1, 64-bit.
- Run as **SYSTEM** or an elevated administrator. The scripts stop if they aren't. The agent's Credential Manager entries are cleaned up only when the script runs as SYSTEM.
- HTTPS access to `agents.static.liongard.com` for the installer, and to your instance (`<prefix>.app.liongard.com`) for the API calls of the Advanced scripts and of Uninstall with `$RemoveAgentFromPlatform = $true`.
- An agent install token for every install script. An API token for the Advanced scripts, and for the uninstall script when `$RemoveAgentFromPlatform = $true`.

## Settings

Set these in the configuration block at the top of the script. A script stops with an error if a required value is still blank or a `REPLACE_WITH_*` placeholder.

### Required

| Setting | Scripts | Notes |
|---|---|---|
| `$InstancePrefix` | MSI and EXE Simple and Advanced. Uninstall Advanced only when `$RemoveAgentFromPlatform = $true` | Your instance prefix, for example `us1` or `eu1`. |
| `$LiongardUrl` | Clean install | Your instance address, for example `us9.app.liongard.com`. The short form `us9` also works. |
| `$AgentTokenKey`, `$AgentTokenSecret` | All install scripts | Agent install token. |
| `$ApiTokenKey`, `$ApiTokenSecret` | MSI and EXE Advanced. Uninstall Advanced only when `$RemoveAgentFromPlatform = $true` | Liongard API token. |
| `$Environment` | All install scripts, unless `$IncludeEnvironmentValue = $false` | The Simple and Clean install scripts pass it to the installer exactly as written, so it must match the name in Liongard. The Advanced scripts look it up: exact, case-insensitive, normalized, then prefix or contains with 6+ normalized characters on both sides. No match, several matches or a failed lookup exits `4`. |

### Optional

| Setting | Scripts | Default | What it does |
|---|---|---|---|
| `$AgentDescription` | All install scripts | `""` | Agent description, passed to the installer when set. |
| `$AgentName` | All install scripts | `""` | Agent name (`LIONGARDAGENTNAME` for the MSI, `LiongardAgentName` for the EXE). Blank uses `$env:COMPUTERNAME`. |
| `$DeviceGuid` | All install scripts | `""` | Agent identity to use on a fresh install (`DEVICEGUID` / `DeviceGuid`). An existing identity always wins. Must be a GUID. MSI 5.2.0 or later, EXE bundle 5.3.0 or later; older installers ignore it. |
| `$ResetDeviceGuid` | All install scripts | `$false` | `$true` passes `RESETDEVICEGUID=1` / `ResetDeviceGuid=1`, so a fresh install gets a new identity instead of the saved one. 5.5.0 or later; older installers ignore it. |
| `$InstallLocation` | All install scripts | `""` | Install folder (`INSTALLLOCATION` / `InstallLocation`). Blank uses `C:\Program Files (x86)\LiongardInc\LiongardAgent`. |
| `$IncludeEnvironmentValue` | All install scripts | `$true` | `$false` registers the agent without an environment, and `$Environment` isn't needed. |
| `$Folder` | All install scripts | `$env:ProgramData` | Parent of the working folder. See [Logs and files](#logs-and-files). |
| `$InstallerUrl` | All install scripts | The `-lts` MSI or EXE on `agents.static.liongard.com` | Installer download address. |
| `$EnableNetworkDiscovery` | EXE Simple and Advanced | `$false` | `$true` turns on network discovery in `network_discovery.yml` after the install, or when the agent is already up to date. |
| `$InstallNpcap` | EXE Simple and Advanced | `$true` | Passed to the bundle as `InstallEnhancedNetworkDiscovery=1` or `0` (bundle 5.3.1 or later) and as `InstallNpcap=1` or `0` (5.3.0 and older). |
| `$EulaAccepted` | EXE Simple and Advanced | `$true` | Passed to the bundle as `EulaAcceptCheckbox=1` or `0` (bundle 5.4.0 or later) and as `EulaAccepted=1` or `0` (5.3.x and older). |
| `$SuppressRestart` | EXE Simple and Advanced | `$true` | Adds `/norestart`. |
| `$PassiveMode` | EXE Simple and Advanced | `$false` | `$true` runs the bundle with `/passive` (progress UI) instead of `/quiet`. |
| `$ProxyUrl` | All install scripts | `""` | Proxy for the agent, for example `http://proxy:8080` (`PROXYURL` for the MSI, `ProxyUrl` for the EXE). Credentials in it are masked in the logs. |
| `$ClearProxyEnvironmentForInstaller` | EXE Simple and Advanced | `$true` | Removes inherited `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` from the installer's environment. `$ProxyUrl`, if set, is applied again. |
| `$AutoUpdate` | All install scripts | `$null` | `$true` or `$false` passes `AUTOUPDATE=1` or `0`. `$null` leaves it out, and the installer default is on. |
| `$ServiceAccount`, `$ServiceAccountPassword` | MSI Simple, MSI Advanced, Clean install | `""` | Runs the agent service as this account (`DOMAIN\user`) instead of LocalSystem (`LIONGARDAGENTSERVICEACCOUNT`, `LIONGARDAGENTSERVICEPASSWORD`). Set both or neither. The password is masked in the logs. The EXE bundle doesn't pass these to the MSI. |
| `$InstallerFileName` | EXE Advanced | `LiongardAgent-lts.exe` | Name of the downloaded bundle. A file name only, with no folder. |
| `$AutoUpdateArgumentName` | EXE Advanced | `AUTOUPDATE` | Property name used for `$AutoUpdate`. |
| `$InstallerLogPath` | EXE Advanced | `""` | Deprecated and ignored. Installer logs always go to the working folder. |
| `$CleanupPreviousAgents` | Clean install | `$true` | Deprecated. Must stay `$true`; `$false` exits `2`. Use MSI Simple to install without cleanup. |
| `$RemoveAgentFromPlatform` | Uninstall Advanced | `$false` | `$true` also deletes the agent's record from Liongard, after the local uninstall succeeds. See [Removing the platform record](#removing-the-platform-record). |
| `$Environment` | Uninstall Advanced | `""` | The environment the agent is in. A MachineGuid or hostname match must be in this environment. Blank matches only an agent with no environment. |
| `$LogFolder` | Uninstall Simple and Advanced | `$env:ProgramData` | Same as `$Folder`, for the uninstall scripts. |

## Running through an RMM or MDM

- **Run as SYSTEM.** Not as the logged-on user.
- **Use 64-bit Windows PowerShell 5.1.** Some RMMs start 32-bit PowerShell by default. The scripts read both registry views, but 64-bit is the tested setup.
- **Passing values with RMM variables:** set the value in the configuration block from the variable your RMM provides. For example, if your RMM exposes a site variable as an environment variable:

  ```powershell
  $Environment = $env:LiongardEnvironment
  ```

  Use your RMM's secure or secret variable type for tokens. Native support for `LIONGARD_*` environment variables is planned in [#10](https://github.com/liongard/agent-scripts/issues/10).
- **Timeouts:** allow several minutes. The script downloads the installer, may clean up an earlier install, and then waits for the service to start. The EXE bundle with Npcap takes longer than the MSI. If your RMM stops a script early, the run may end before validation, and the RMM won't see the real exit code.
- **Check the exit code**, not just the RMM's "completed" status. See [Exit codes](#exit-codes).

### Notes for specific tools

- **NinjaOne:** set the script to run as **System**. Script variables are passed to the script as environment variables, so you can read them with `$env:<name>`.
- **Datto RMM:** components run as SYSTEM. Component variables are passed to the script as environment variables (`$env:<name>`).
- **ConnectWise Automate:** PowerShell may start as 32-bit. Run the script with `%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe` to get 64-bit PowerShell.
- **Microsoft Intune** (platform scripts): set **Run this script using the logged on credentials** to **No** (runs as SYSTEM), and **Run script in 64 bit PowerShell Host** to **Yes**. Intune doesn't pass parameters to platform scripts, so fill in the values in the configuration block before you upload.
- **N-able, ConnectWise Asio, Kaseya:** follow the general guidance above: run as SYSTEM in 64-bit PowerShell, and pass values through the configuration block.

## Exit codes

Every Windows script uses the same table as Linux and macOS.

| Code | Meaning |
|---|---|
| `0` | Installed and validated, already up to date, or the agent is removed (and the platform record deleted, or no record qualified). msiexec or bundle `3010` (and `1641` in Clean install) count as success and log a reboot note. |
| `1` | Unexpected error. |
| `2` | A setting is missing, a `REPLACE_WITH_*` placeholder, or invalid (including `$CleanupPreviousAgents = $false`). |
| `3` | The `LiongardDeploy` folder check failed, or the script isn't running as SYSTEM or an elevated administrator. |
| `4` | Environment check failed (Advanced): no match, several matches, or the lookup failed. |
| `5` | Installer download failed, or the installed and installer versions can't be compared. Nothing was changed. |
| `6` | The installer failed. msiexec's or the bundle's own code is in the log (and in the EXE Advanced JSON summary). |
| `7` | The installer finished, but the service isn't Running or the updater task is missing. |
| `8` | The agent is Stale (Install Simple and Advanced). Nothing was changed. Run Clean install. |
| `9` | The agent is still detected after the uninstall, or after Clean install's cleanup. |
| `10` | Uninstall Advanced removed the agent, but not the platform record. |
| `11` | Busy: another Windows Installer operation is running (`1618`), or an agent update kept running for 2 minutes (Clean install). |
| `12` | The agent identity couldn't be saved. Nothing was removed. |

Changed from earlier versions: msiexec and bundle failure codes are now `6` (their own code is logged), `1618` is `11`, configuration errors are `2` instead of `1`, a deploy-folder failure is `3`, a failed platform removal is `10` instead of `2`, an agent still detected after uninstall is `9` instead of `1`, and an identity backup failure is `12`.

## Removing the platform record

Both uninstall scripts save the agent identity to `LiongardDeploy\liongard-identity-<computer>-<timestamp>\` before they remove anything, in the format `LGAgentIdentity.ps1 -Action Restore` reads. It holds the identity and the AgentID, never a key or secret. If the agent's settings file exists but no identity can be read, the script stops with `12` before it removes anything.

The local removal uninstalls every Liongard Agent MSI and bundle entry, removes the services, the updater task, stored credentials and both `LiongardInc` folders (from `${env:ProgramFiles(x86)}`, `$env:ProgramFiles` and `$env:ProgramW6432`). It never touches the identity key.

With `$RemoveAgentFromPlatform = $true`, Uninstall Advanced checks the API settings first, removes the agent locally, and then looks for the record:

1. **AgentID** from `appsettings-override.config` (found through `INSTALLLOCATION` in both registry views, then the `LiongardInc` folders). The record must match a local name or `$Environment`, and its MachineGuid, when set, must match a local identifier. A MachineGuid that matches only the Windows MachineGuid also needs a local name match.
2. **MachineGuid:** the AgentGuid (`HKLM\SOFTWARE\WOW6432Node\Liongard\LiongardAgent\MachineID`, both registry views) as an agent identifier, and the Windows MachineGuid (both registry views) as an OS identifier. Each is queried in its raw registry form (case and braces kept), in lowercase, and as the bare GUID in lower and upper case, with `=` and `like`. The trimmed value is compared on the client. The record must be in `$Environment`; an OS-only match also needs a local name match.
3. **Hostname:** `$env:COMPUTERNAME`, the DNS host name and the FQDN against the record's Hostname, Name and FQDN, in `$Environment`. A record whose MachineGuid is set and matches no local identifier is skipped.

Placeholder identifiers (`local`, `uninitialized`, all zeros, no hex digit) are never used. Every candidate is logged with its signals. Nothing is deleted when more than one record qualifies. A failed lookup or delete exits `10`. Each delete is confirmed with a lookup, because the API can time out after the record is gone. The Linux and macOS Uninstall Advanced scripts use the same rules.

## Logs and files

### Working folder

Every script works in a `LiongardDeploy` subfolder of `$Folder` (`$LogFolder` for Uninstall). With the default, that's `C:\ProgramData\LiongardDeploy`. The scripts never change the permissions of `$Folder` itself, and they never touch `C:\ProgramData\Liongard`, which belongs to the agent.

On every run, before anything is written, each script:

- Stops if `$Folder` or `LiongardDeploy` is a file or a reparse point (symlink, junction or mount point), if `LiongardDeploy` contains a reparse point, or if `LiongardDeploy` already exists and isn't owned by SYSTEM or Administrators.
- Turns off inheritance on `LiongardDeploy`, removes every existing permission entry, grants Full Control only to SYSTEM and Administrators, and sets the owner to Administrators.

Installers are downloaded to `LiongardDeploy\Deploy\<guid>\` and deleted at the end of the run, whether it succeeds or fails.

The scripts also clean up the old `C:\Liongard` folder. They delete only agent installers and the scripts' own logs and summaries from its top level, and they remove the folder only if it's then empty.

### Log files

All logs are written to `LiongardDeploy`. Log names carry a timestamp, and the scripts keep the 5 most recent runs of each log type. Every run ends by printing the full path of each log it wrote.

| Script | Files |
|---|---|
| All install scripts | `AgentInstall_<timestamp>.log` (installer log; the EXE bundle also writes `AgentInstall_<timestamp>_*.log` per package), `StaleUninstall_<ProductCode>_<timestamp>.log` |
| MSI and EXE Simple, MSI Advanced, Clean install | `LGAgentScript_<timestamp>.log` (script log or transcript) |
| EXE Advanced | `LGAgentScript_EXE_<timestamp>.log` (transcript), `LGAgentSummary_<timestamp>.json` |
| Uninstall Simple and Advanced | `LGAgentUninstall_<timestamp>.log`, and the identity backup folder `liongard-identity-<computer>-<timestamp>\` (not removed by log retention) |

The script output itself goes to the console, so your RMM's script output shows the same steps.

After the installer exits, the scripts redact the installer logs in place, whether the install succeeded or failed. They mask the access key and secret, any `ACCESSKEY` or `ACCESSSECRET` property, and proxy credentials (`user:****@host`). If a log can't be redacted, the script deletes it and says so. Logs can still contain other sensitive details, so check them before you share them.

## Troubleshooting

| Message or symptom | What to do |
|---|---|
| `Configuration value [<name>] must be set` or `must be provided` | A required setting is still blank or a `REPLACE_WITH_*` placeholder. Fill it in. |
| `InstancePrefix '<value>' contains a placeholder character` | Replace the prefix with your real one, for example `us1`. |
| `Run this script as SYSTEM or from an elevated administrator session` | Your RMM ran the script as a user. Set it to run as SYSTEM. |
| `The existing deploy folder [...] is owned by ...` | The folder was created by another account. As an administrator, delete it (`rmdir /s /q "C:\ProgramData\LiongardDeploy"`) and run the script again. |
| `... is a reparse point` or `... is a file, not a folder` | `$Folder` or `LiongardDeploy` is a link or a file. Remove it, or set `$Folder` to a different local folder. |
| `Folder [...] must be an absolute local path` or `is inside the agent's own folder` | Set `$Folder` to a local path such as `C:\ProgramData`, outside `C:\ProgramData\Liongard`. |
| Installer download failed | Check HTTPS access to `agents.static.liongard.com` from the endpoint. For a proxy, set `$ProxyUrl` (EXE scripts). |
| `The environment check failed` (Advanced, exit `4`) | Read the candidate or known-environment lines. Check the name and that the environment exists, or set `$IncludeEnvironmentValue = $false`. |
| `The installed agent is broken or not running (Stale)` (exit `8`) | Run `LGAgentCleanInstall-MSI-Simple.ps1`. |
| Environment problems (Simple, Clean install) | These scripts pass `$Environment` exactly as written and don't check it. Make sure it matches the name in Liongard exactly. Handling of a missing environment is tracked in [#9](https://github.com/liongard/agent-scripts/issues/9). |
| Exit code `11` | Another Windows Installer operation (`1618`) or an agent update was running. Run the script again later. |
| `An agent update is still in progress after waiting 2 minutes` (Clean install) | The agent updates itself once a day, around midnight local time. Nothing was changed. Run the script again later. |
| Exit code `1638` (EXE) | A newer agent is already installed. The bundle doesn't downgrade. |
| `Post-install validation failed` | The installer finished, but the `roaragent.exe` service isn't running or the updater task is missing. Check `AgentInstall_<timestamp>.log`, then run the Clean install script. |
| An agent that keeps failing to install or upgrade | Run `LGAgentCleanInstall-MSI-Simple.ps1`, which removes broken installs before installing. |
| The RMM reports success, but the agent isn't installed | Check that your RMM records the script's exit code, and read the log paths printed at the end of the run. |

For anything else, contact Liongard Partner Support with the logs from `LiongardDeploy`.
