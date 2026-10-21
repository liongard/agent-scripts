# Windows

Six PowerShell scripts that install, repair or remove the Liongard Agent on Windows. For other platforms, and for what you need before you start, see the [main README](../README.md).

## Scripts

| Script | What it does | Use it when |
|---|---|---|
| `LGAgentInstall-MSI-Simple.ps1` | Installs the agent from the MSI, or upgrades it when the MSI is newer. No Liongard API calls. | Standard installs and upgrades. |
| `LGAgentInstall-EXE-Simple.ps1` | Installs the EXE bundle (agent, Visual C++ and Npcap), or upgrades it when the bundle is newer. No Liongard API calls. | The host will run the network discovery inspector. |
| `LGAgentInstall-MSI-Advanced.ps1` | Like MSI Simple, but first matches the environment name through the Liongard API, and writes a full transcript log. | You want the environment name checked before the agent registers. |
| `LGAgentInstall-EXE-Advanced.ps1` | Like EXE Simple, plus the API environment check, a proxy check, per-component validation, a transcript log and a JSON run summary. | Network discovery hosts where you want the extra checks and logs. |
| `LGAgentCleanInstall-MSI-Simple.ps1` | Removes an old, broken, incomplete or corrupt agent install, then installs from the MSI. A healthy agent is never cleaned up; it's upgraded only when the MSI is newer. It also reinstalls an agent the platform no longer accepts (for example, one deleted in the Liongard UI). | The agent was uninstalled but is still listed, or left its service, folder, Windows Installer entries or updater task behind. |
| `LGAgentUninstall.ps1` | Removes the agent and its leftovers. It can also delete the agent's record from the Liongard platform. | Decommissioning an endpoint. |

Every install script checks for an existing agent first:

- **Healthy** (installed, service running, updater task present): it upgrades only when the installer is newer. Otherwise it exits `0` without changes.
- **Stale** (leftovers of an earlier install): it removes the leftovers, then installs.
- **NotInstalled:** it installs.

No script modifies the agent identity key `HKLM\SOFTWARE\WOW6432Node\Liongard`, so a reinstalled agent registers as the same agent.

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
| `$InstancePrefix` | MSI and EXE Simple and Advanced. Uninstall only when `$RemoveAgentFromPlatform = $true` | Your instance prefix, for example `us1` or `eu1`. |
| `$LiongardUrl` | Clean install | Your instance address, for example `us9.app.liongard.com`. The short form `us9` also works. |
| `$AgentTokenKey`, `$AgentTokenSecret` | All install scripts | Agent install token. |
| `$ApiTokenKey`, `$ApiTokenSecret` | MSI and EXE Advanced. Uninstall only when `$RemoveAgentFromPlatform = $true` | Liongard API token. |
| `$Environment` | All install scripts, unless `$IncludeEnvironmentValue = $false` | The Simple and Clean install scripts pass it to the installer exactly as written, so it must match the name in Liongard. The Advanced scripts look it up and correct casing or punctuation, and stop if no environment matches. |

### Optional

| Setting | Scripts | Default | What it does |
|---|---|---|---|
| `$AgentDescription` | All install scripts | `""` | Agent description, passed to the installer when set. |
| `$IncludeEnvironmentValue` | All install scripts | `$true` | `$false` registers the agent without an environment, and `$Environment` isn't needed. |
| `$Folder` | All install scripts | `$env:ProgramData` | Parent of the working folder. See [Logs and files](#logs-and-files). |
| `$InstallerUrl` | All install scripts | The `-lts` MSI or EXE on `agents.static.liongard.com` | Installer download address. |
| `$EnableNetworkDiscovery` | EXE Simple and Advanced | `$false` | `$true` turns on network discovery in `network_discovery.yml` after the install, or when the agent is already up to date. |
| `$InstallNpcap` | EXE Simple and Advanced | `$true` | Passed to the bundle as `InstallNpcap=1` or `0`. |
| `$EulaAccepted` | EXE Simple and Advanced | `$true` | Passed to the bundle as `EulaAccepted=1` or `0`. |
| `$SuppressRestart` | EXE Simple and Advanced | `$true` | Adds `/norestart`. |
| `$PassiveMode` | EXE Simple and Advanced | `$false` | `$true` runs the bundle with `/passive` (progress UI) instead of `/quiet`. |
| `$ProxyUrl` | EXE Simple and Advanced | `""` | Proxy for the installer, for example `http://proxy:8080`. Credentials in it are masked in the logs. |
| `$ClearProxyEnvironmentForInstaller` | EXE Simple and Advanced | `$true` | Removes inherited `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` from the installer's environment. `$ProxyUrl`, if set, is applied again. |
| `$AutoUpdate` | EXE Simple and Advanced | `$null` | `$true` or `$false` passes `AUTOUPDATE=1` or `0`. `$null` leaves it out. |
| `$InstallerFileName` | EXE Advanced | `LiongardAgent-lts.exe` | Name of the downloaded bundle. A file name only, with no folder. |
| `$AutoUpdateArgumentName` | EXE Advanced | `AUTOUPDATE` | Property name used for `$AutoUpdate`. |
| `$InstallerLogPath` | EXE Advanced | `""` | Deprecated and ignored. Installer logs always go to the working folder. |
| `$CleanupPreviousAgents` | Clean install | `$true` | Removes broken, incomplete or corrupt installs before installing. `$false` makes the script behave like MSI Simple. |
| `$RemoveAgentFromPlatform` | Uninstall | `$false` | `$true` also deletes the matching agent record from Liongard, after the local uninstall succeeds. Matching is being tightened in [#6](https://github.com/liongard/agent-scripts/issues/6), so leave it off unless you need it. |
| `$MinimumRemoteDeletionScore` | Uninstall | `50` | Minimum match score a platform record needs before it's deleted. |
| `$LogFolder` | Uninstall | `$env:ProgramData` | Same as `$Folder`, for the uninstall script. |

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

Current behavior. Standard exit codes across all scripts are planned in [#11](https://github.com/liongard/agent-scripts/issues/11).

| Script | `0` | Non-zero |
|---|---|---|
| MSI Simple | Installed and validated, or already up to date. msiexec `3010` counts as success. | msiexec's own code when msiexec fails. `1` for any other failure. |
| EXE Simple | Installed and validated, or already up to date. Installer `3010` counts as success. | The installer's own code when it fails. `1` for any other failure. |
| MSI Advanced | Installed and validated, or already up to date. msiexec `3010` counts as success. | msiexec's own code when msiexec fails. `1` for any other failure, including an environment that can't be matched. |
| EXE Advanced | Installed and validated, or already up to date. Installer `3010` counts as success. | `1` for any failure. The installer's code is in the log and the JSON summary. |
| Clean install | Installed and validated, or already up to date. msiexec `3010` and `1641` count as success and log a reboot WARN. | `1618`: another Windows Installer operation was running; run again later. msiexec's own code when msiexec fails. `1` for any other failure. Cleanup problems are logged as WARN and don't change the exit code. |
| Uninstall | The agent is no longer detected. Problems with the optional platform removal are logged as warnings. | `1` when the agent is still detected afterwards, or the script fails. |

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
| MSI Advanced | `LGAgentScript_<timestamp>.log` (transcript) |
| EXE Advanced | `LGAgentScript_EXE_<timestamp>.log` (transcript), `LGAgentSummary_<timestamp>.json` |
| Uninstall | `LGAgentUninstall_<timestamp>.log` |

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
| `Environment '<name>' ... could not be resolved in Liongard` (Advanced) | Check the name and that the environment exists in your instance, or set `$IncludeEnvironmentValue = $false`. |
| Environment problems (Simple, Clean install) | These scripts pass `$Environment` exactly as written and don't check it. Make sure it matches the name in Liongard exactly. Handling of a missing environment is tracked in [#9](https://github.com/liongard/agent-scripts/issues/9). |
| Exit code `1618` | Another Windows Installer operation was running. Run the script again later. |
| `An agent update is still in progress after waiting 2 minutes` (Clean install) | The agent updates itself once a day, around midnight local time. Nothing was changed. Run the script again later. |
| Exit code `1638` (EXE) | A newer agent is already installed. The bundle doesn't downgrade. |
| `Post-install validation failed` | The installer finished, but the `roaragent.exe` service isn't running or the updater task is missing. Check `AgentInstall_<timestamp>.log`, then run the Clean install script. |
| An agent that keeps failing to install or upgrade | Run `LGAgentCleanInstall-MSI-Simple.ps1`, which removes broken installs before installing. |
| The RMM reports success, but the agent isn't installed | Check that your RMM records the script's exit code, and read the log paths printed at the end of the run. |

For anything else, contact Liongard Partner Support with the logs from `LiongardDeploy`.
