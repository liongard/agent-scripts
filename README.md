# Liongard Agent Deployment Scripts

> **DRAFT – internal.** Not yet reviewed for public release. Do not share outside Liongard.

## Overview

These standalone scripts install, upgrade and uninstall the Liongard Agent, and you can run them from an RMM. Each script is a single self-contained file. Edit the configuration block at the top, then deploy.

## Script matrix

| Script | OS | Installer | Variant | Credentials needed |
|---|---|---|---|---|
| `windows/LGAgentInstall-MSI-Simple.ps1` | Windows | MSI | Simple | Agent install token only |
| `windows/LGAgentInstall-MSI-Advanced.ps1` | Windows | MSI | Advanced | Liongard API token **and** agent install token |
| `windows/LGAgentInstall-EXE-Simple.ps1` | Windows | EXE bundle (Agent + VC++ + Npcap) | Simple | Agent install token only |
| `windows/LGAgentInstall-EXE-Advanced.ps1` | Windows | EXE bundle (Agent + VC++ + Npcap) | Advanced | Liongard API token **and** agent install token |
| `windows/LGAgentUninstall.ps1` | Windows | — | Uninstall | None. You need an API token only when `$RemoveAgentFromPlatform = $true` |
| `linux/LGAgentInstall-Linux.sh` | Linux | `.run` / `.deb` / `.rpm` / `.sh` | Advanced | Liongard API token **and** agent install token |
| `macos/LGAgentInstall-macOS.sh` | macOS | `.pkg` (`Liongard-lts.pkg`, supplied alongside the script) | Simple | Agent install token only (`ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`). See [macos/README.md](macos/README.md) |

- **Simple** scripts make no Liongard API calls. They pass the environment name to the installer exactly as written.
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

- **All Windows installs:** `$AgentDescription`, `$IncludeEnvironmentValue`, `$Folder` (default `C:\Liongard`), `$InstallerUrl`.
- **EXE (Simple and Advanced):** `$EnableNetworkDiscovery`, `$InstallNpcap`, `$EulaAccepted`, `$SuppressRestart`, `$PassiveMode`, `$ProxyUrl`, `$ClearProxyEnvironmentForInstaller`, `$AutoUpdate`.
- **EXE Advanced only:** `$InstallerFileName`, `$InstallerLogPath`, `$AutoUpdateArgumentName`.
- **Uninstall:** `$RemoveAgentFromPlatform`, `$MinimumRemoteDeletionScore`, `$LogFolder`.
- **Linux (section B):** `INCLUDE_ENVIRONMENT_VALUE`, `ENABLE_ENVIRONMENT_MATCHING`, `ENABLE_PRE_UNINSTALL`, `REMOVE_AGENT_FROM_PLATFORM`, `AGENT_DESCRIPTION`, `LOG_DIRECTORY`, `INSTALLER_URL`, `INSTALLER_FILE_NAME`. `DOWNLOAD_DIRECTORY` is deprecated and no longer used: the installer now downloads to a private temporary folder that is deleted when the script exits. If it is set, the script logs a warning and carries on. It will be removed in a later release. Leave section C alone unless Liongard Support asks you to change it. Section C includes `MINIMUM_REMOTE_DELETION_SCORE` (default `50`), the minimum match score a platform record needs before `REMOVE_AGENT_FROM_PLATFORM=true` deletes it.

## Logs

| Script | Location | Files |
|---|---|---|
| Windows install (all) | `$Folder` (default `C:\Liongard`) | `AgentInstall.log` (installer), `StaleUninstall_<ProductCode>.log` |
| MSI Advanced | `$Folder` | `LGAgentScript_<timestamp>.log` (transcript) |
| EXE Advanced | `$Folder` | `LGAgentScript_EXE_<timestamp>.log`, `LGAgentSummary_<timestamp>.json` |
| Uninstall | `$LogFolder` (default `C:\Liongard`) | `LGAgentUninstall_<timestamp>.log` |
| Linux | `LOG_DIRECTORY` (default `/var/log/liongard-agent`, created root-only) | `LGAgentScript_<timestamp>.log` |

Logs can contain sensitive details. Check them and remove any keys or secrets before sharing them.

## Support and security

- **Support:** Liongard Partner Support.
- **Security issues:** email **security.ops@liongard.com**. Don't open a GitHub issue. See [SECURITY.md](SECURITY.md).

Licensed under Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
