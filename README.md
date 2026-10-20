# Liongard Agent Deployment Scripts

> **DRAFT – internal.** Not yet reviewed for public release. Do not share outside Liongard.

## Overview

These standalone scripts install, upgrade and uninstall the Liongard Agent, and you can run them from an RMM. Each script is a single self-contained file. Edit the configuration block at the top, then deploy.

## Script matrix

| Script | OS | Installer | Variant | Credentials needed |
|---|---|---|---|---|
| `windows/LGAgentInstall-MSI-Simple.ps1` | Windows | MSI | Simple | Agent install token only |
| `windows/LGAgentCleanInstall-MSI-Simple.ps1` | Windows | MSI | Simple + cleanup | Agent install token only |
| `windows/LGAgentInstall-MSI-Advanced.ps1` | Windows | MSI | Advanced | Liongard API token **and** agent install token |
| `windows/LGAgentInstall-EXE-Simple.ps1` | Windows | EXE bundle (Agent + VC++ + Npcap) | Simple | Agent install token only |
| `windows/LGAgentInstall-EXE-Advanced.ps1` | Windows | EXE bundle (Agent + VC++ + Npcap) | Advanced | Liongard API token **and** agent install token |
| `windows/LGAgentUninstall.ps1` | Windows | — | Uninstall | None. You need an API token only when `$RemoveAgentFromPlatform = $true` |
| `linux/LGAgentInstall-Linux.sh` | Linux | `.run` / `.deb` / `.rpm` / `.sh` | Advanced | Liongard API token **and** agent install token |
| `macos/LGAgentInstall-macOS.sh` | macOS | `.pkg` (`Liongard-lts.pkg`, supplied alongside the script) | Simple | Agent install token only (`ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`). See [macos/README.md](macos/README.md) |

- **Simple** scripts make no Liongard API calls. They pass the environment name to the installer exactly as written.
- **MSI Simple + cleanup** (`LGAgentCleanInstall-MSI-Simple.ps1`) is for endpoints with an old, broken, incomplete or corrupt agent. Before it installs, it removes the previous install: the service, uninstall entries, Windows Installer registration, the updater task and the install folder. It never cleans up a healthy agent; it only upgrades one when the MSI is newer. The identity key `HKLM\SOFTWARE\WOW6432Node\Liongard` is never modified, so the reinstalled agent registers as the same agent. It takes `$LiongardUrl` (for example `us9.app.liongard.com` or `us9`) instead of `$InstancePrefix`. Set `$CleanupPreviousAgents = $false` to make it behave like MSI Simple.
- **Advanced** scripts use the API to resolve the environment name, check for existing agents and write richer logs. The EXE Advanced script also writes a JSON summary.
- Pick **EXE** when the host will run the network discovery inspector, because it needs Npcap and VC++. Otherwise use **MSI**.

## Quick start

1. Pick a script from the matrix.
2. Fill in the configuration block at the top of the script. See the next section.
3. Deploy it from your RMM:
   - Windows: run as **SYSTEM** in Windows PowerShell 5.1.
   - Linux: run as **root**, e.g. `sudo bash LGAgentInstall-Linux.sh`.
   - macOS: run as **root** with `Liongard-lts.pkg` in the same folder, e.g. `sudo ./LGAgentInstall-macOS.sh`. See [macos/README.md](macos/README.md).
4. Check the exit code and the logs.

## Configuration

Fill in all **required** values. A script stops with an error if a required value is still a `REPLACE_WITH_*` placeholder.

### Required

| Setting | Simple (MSI/EXE) | Advanced (MSI/EXE) | Uninstall | Linux |
|---|---|---|---|---|
| Instance prefix (`us1`, `eu1`, …) | `$InstancePrefix` | `$InstancePrefix` | only if removing from platform | `INSTANCE_PREFIX` |
| Agent install token key/secret | `$AgentTokenKey`, `$AgentTokenSecret` | same | — | `AGENT_TOKEN_KEY`, `AGENT_TOKEN_SECRET` |
| API token key/secret | — | `$ApiTokenKey`, `$ApiTokenSecret` | only if removing from platform | `API_TOKEN_KEY`, `API_TOKEN_SECRET` |
| Environment name | `$Environment` | `$Environment` | — | `ENVIRONMENT` |

You can skip the environment name if you set `$IncludeEnvironmentValue = $false` (`INCLUDE_ENVIRONMENT_VALUE=false` on Linux).

### Optional

- **All Windows installs:** `$AgentDescription`, `$IncludeEnvironmentValue`, `$Folder` (default `$env:ProgramData`, see [Working folder](#working-folder)), `$InstallerUrl`.
- **EXE (Simple and Advanced):** `$EnableNetworkDiscovery`, `$InstallNpcap`, `$EulaAccepted`, `$SuppressRestart`, `$PassiveMode`, `$ProxyUrl`, `$ClearProxyEnvironmentForInstaller`, `$AutoUpdate`.
- **EXE Advanced only:** `$InstallerFileName` (a file name only), `$AutoUpdateArgumentName`. `$InstallerLogPath` is deprecated and ignored.
- **Uninstall:** `$RemoveAgentFromPlatform`, `$MinimumRemoteDeletionScore`, `$LogFolder` (default `$env:ProgramData`, same rules as `$Folder`).
- **Linux (section B):** `INCLUDE_ENVIRONMENT_VALUE`, `ENABLE_ENVIRONMENT_MATCHING`, `ENABLE_PRE_UNINSTALL`, `REMOVE_AGENT_FROM_PLATFORM`, `AGENT_DESCRIPTION`, `LOG_DIRECTORY`, `LINUX_ARCHITECTURE` (`auto`, `x64` or `arm64`; `auto` picks the installer from `uname -m`), `INSTALLER_URL` (leave empty to use the LTS installer for the architecture), `INSTALLER_FILE_NAME`. `DOWNLOAD_DIRECTORY` is deprecated and no longer used: the installer now downloads to a private temporary folder that is deleted when the script exits. If it is set, the script logs a warning and carries on. It will be removed in a later release. Leave section C alone unless Liongard Support asks you to change it. Section C includes `MINIMUM_REMOTE_DELETION_SCORE` (default `50`), the minimum match score a platform record needs before `REMOVE_AGENT_FROM_PLATFORM=true` deletes it.

## Working folder

The Windows scripts always work in a dedicated `LiongardDeploy` subfolder of `$Folder` (`$LogFolder` for Uninstall). **Exception:** `LGAgentCleanInstall-MSI-Simple.ps1` doesn't use `LiongardDeploy` yet. It works directly in `$Folder` (default `C:\Liongard`) until it's aligned with the deploy-folder changes. With the default, that's `C:\ProgramData\LiongardDeploy`. The scripts never change the permissions of `$Folder` itself, and they never touch `C:\ProgramData\Liongard`, which belongs to the agent.

On every run, before anything is written, each script:

- Requires SYSTEM or an elevated administrator.
- Refuses to continue if `$Folder` or `LiongardDeploy` is a file or a reparse point (symlink, junction or mount point), if `LiongardDeploy` contains a reparse point, or if `LiongardDeploy` already exists and isn't owned by SYSTEM or Administrators. In that last case, delete the folder as an administrator (for example `rmdir /s /q "C:\ProgramData\LiongardDeploy"`) and rerun.
- Disables inheritance on `LiongardDeploy`, removes every existing permission entry, grants Full Control only to SYSTEM and Administrators, and sets the owner to Administrators.

Installers are downloaded to `LiongardDeploy\Deploy\<guid>\` and deleted at the end of the run, whether it succeeds or fails.

The scripts also clean up the old `C:\Liongard` folder. They delete only the agent installers and the script's own logs and summaries (`AgentInstall*.log`, `LGAgentSummary_*.json`, `LGAgentScript_*.log`, `LGAgentScript_EXE_*.log`, `StaleUninstall_*.log` and `LGAgentUninstall_*.log`) from its top level, and they remove the folder only if it's then empty.

## Logs

All Windows logs are written to `LiongardDeploy`. The exception is `LGAgentCleanInstall-MSI-Simple.ps1`, which writes `AgentInstall.log` and `StaleUninstall_<ProductCode>.log` to `$Folder` (default `C:\Liongard`) and deletes `AgentInstall.log` after a successful install. Each run's log names carry a timestamp, and the scripts keep the 5 most recent runs of each log type. Every run ends by printing the full path of each log it wrote.

| Script | Files |
|---|---|
| Windows install (all) | `AgentInstall_<timestamp>.log` (installer; the EXE bundle also writes `AgentInstall_<timestamp>_*.log` per package), `StaleUninstall_<ProductCode>_<timestamp>.log` |
| MSI Advanced | `LGAgentScript_<timestamp>.log` (transcript) |
| EXE Advanced | `LGAgentScript_EXE_<timestamp>.log`, `LGAgentSummary_<timestamp>.json` |
| Uninstall | `LGAgentUninstall_<timestamp>.log` |
| Linux | `LOG_DIRECTORY` (default `/var/log/liongard-agent`, created root-only): `LGAgentScript_<timestamp>.log` |

After the installer exits, the scripts redact the installer logs in place, whether the install succeeded or failed. They mask the access key and secret values and any `ACCESSKEY`/`ACCESSSECRET` property. If a log can't be redacted, the script deletes it and says so.

Logs can still contain sensitive details. Check them before sharing them.

## Support and security

- **Support:** Liongard Partner Support.
- **Security issues:** email **security.ops@liongard.com**. Don't open a GitHub issue. See [SECURITY.md](SECURITY.md).

Licensed under Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
