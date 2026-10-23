# Changelog

All notable changes to these scripts are documented here.

## Unreleased

### Cross-platform parity

- **One script set per OS.** Windows, Linux and macOS each have Install Simple, Install Advanced, Clean Install, Uninstall Simple, Uninstall Advanced and Identity. Renames and new files:
  - `windows/LGAgentUninstall.ps1` → `windows/LGAgentUninstall-Advanced.ps1`; new `windows/LGAgentUninstall-Simple.ps1`.
  - `linux/LGAgentInstall-Linux.sh` is split into `LGAgentInstall-Linux-Simple.sh` and `LGAgentInstall-Linux-Advanced.sh` (git history follows the Advanced file); new `LGAgentCleanInstall-Linux-Simple.sh`, `LGAgentUninstall-Linux-Simple.sh` and `LGAgentUninstall-Linux-Advanced.sh`.
  - `macos/LGAgentInstall-macOS.sh` → `macos/LGAgentInstall-macOS-Simple.sh`; `macos/LGAgentUninstall-macOS.sh` → `macos/LGAgentUninstall-macOS-Advanced.sh`; new `LGAgentInstall-macOS-Advanced.sh`, `LGAgentCleanInstall-macOS-Simple.sh` and `LGAgentUninstall-macOS-Simple.sh`.
- **Same install-state rules everywhere.** Healthy now requires the agent service to be running on every OS; Windows Install Simple used to count a stopped agent as Healthy. Install Simple and Advanced never remove an agent: a Stale agent exits `8` and points to Clean Install (Windows Simple and Advanced used to clean it up themselves; Linux removed any existing agent by default).
- **Validate before change.** Settings, the environment check and the download all run before anything is removed. If the installed or the installer version can't be read, the scripts exit `5` and change nothing (Windows used to install anyway).
- **Environment check (Advanced, every OS):** exact, then case-insensitive, then normalized, then prefix or contains with at least 6 normalized characters on both sides. A failed lookup now fails the run (exit `4`); Windows used to continue when the API returned no environments, and allowed a prefix match of any length.
- **Clean Install on every OS:** saves the identity before removing a Stale agent, so the reinstall re-attaches to the same record. On Linux and macOS, an identity that lived only in the agent config is written to `/etc/liongard-agent/.machine-guid` before the config is removed. The HTTP 401 heartbeat rule now applies on Linux and macOS too, from `agent.log`. Windows `$CleanupPreviousAgents = $false` is deprecated and exits `2`.
- **macOS Simple upgrades a running agent** when the package is newer (from PR #49): it reads the package version from the component `postinstall`, records the new `AGENT_VERSION` and restarts the agent.
- **Uninstall Advanced platform removal, every OS:** an AgentID match also needs a local name or the configured environment; the hostname step skips records whose MachineGuid matches no local identifier; record MachineGuids are trimmed and also looked up with `like`; Windows reads the AgentGuid, the Windows MachineGuid and `INSTALLLOCATION` from both registry views, queries the raw registry form as well as the normalized one, and derives its folders from `ProgramFiles(x86)`, `ProgramFiles` and `ProgramW6432`; placeholder identifiers (`local`, `uninitialized`, all zeros, no hex digit) are never used; an OS identifier (Windows MachineGuid, `/etc/machine-id`, IOPlatformUUID) also needs a local name match.
- **Every install script exposes every installer value**, and every required value starts as `REPLACE_WITH_*` and stops the script with `2` until set (Linux used `us?`; macOS used blanks). macOS drops the `DESCRIPTION` alias; use `AGENT_DESCRIPTION`.
- **Logs** go to a root-only or SYSTEM-only folder with secrets masked on every OS. Windows Install Simple and Clean install now also write `LGAgentScript_<timestamp>.log` in `LiongardDeploy`.
- **Linux:** removed `ENABLE_PRE_UNINSTALL`, `ENABLE_ENVIRONMENT_MATCHING`, `DOWNLOAD_DIRECTORY`, `MINIMUM_REMOTE_DELETION_SCORE`, `SERVICE_NAMES`, `DEVICE_ID_OVERRIDE_ARG_NAME`, `API_FAILURE_BEHAVIOR`, `MINIMUM_INSTALLER_BYTES`, `MAX_DOWNLOAD_ATTEMPTS` and the machine-ID collision `DEVICEID` override. Windows Uninstall removed `$MinimumRemoteDeletionScore`.
- **Shared blocks:** common code sits between `# BEGIN SHARED BLOCK: <name>` and `# END SHARED BLOCK: <name>` and is byte-identical in every script that carries it. A new blocking `shared-blocks` CI job runs `tests/Test-SharedBlocks.ps1` (idea from PR #43).

### Exit codes (every script, every OS)

`0` OK, `1` unexpected error, `2` invalid setting, `3` missing prerequisite or unsafe log/deploy folder, `4` environment check failed, `5` download, package or version check failed, `6` installer failed, `7` post-install validation failed, `8` Stale agent (nothing changed), `9` agent still detected after removal, `10` platform record not removed, `11` busy, `12` identity backup failed. Changed codes:

| Script | Before | Now |
|---|---|---|
| Windows install scripts | msiexec or bundle failure code | `6` (the installer's code is logged) |
| Windows install scripts | `1618` | `11` |
| Windows install scripts | `1` for a configuration error | `2` |
| Windows scripts | `1` for a deploy-folder failure | `3` |
| Windows install scripts | `1` for an environment that can't be matched | `4` |
| Windows install scripts | `1` for a failed download | `5` |
| Windows install scripts | `1` for failed validation | `7` |
| Windows Clean install | `1` for an update still running | `11` |
| Windows Uninstall | `1` for an agent still detected | `9` |
| Windows Uninstall | `1` for a failed identity backup | `12` |
| Windows Uninstall | `2` for a failed platform removal | `10` |
| Linux | `8` for an agent still detected | `9` |
| Linux | `9` for a failed platform removal | `10` |
| macOS install | `1` for config, download or validation failures | `2`, `5` or `7` |
| macOS install | the `installer` exit code | `6` |
| macOS uninstall | `1` for an agent still detected or a failed identity backup | `9` or `12` |
| macOS uninstall | `2` for a failed platform removal | `10` |

### All scripts

- Uninstall (Windows, macOS, and the Linux pre-uninstall) now saves the agent identity before it removes anything, and the optional platform removal finds the record by AgentID, then MachineGuid, then hostname. It deletes only when exactly one record in the environment matches, refuses an AgentID whose record has another MachineGuid, logs every candidate, confirms each delete with a lookup, and fails with a non-zero exit when a lookup or delete fails. `MINIMUM_REMOTE_DELETION_SCORE` / `$MinimumRemoteDeletionScore` is deprecated and ignored.
- Added the identity backup and restore scripts from liongard-agent as `windows/LGAgentIdentity.ps1`, `linux/LGAgentIdentity-Linux.sh` and `macos/LGAgentIdentity-macOS.sh`, with their tests in `tests/identity/`.
- Docs: the main README is now an overview with a "Which script do I use?" table, and `windows/README.md`, `linux/README.md` and `macos/README.md` hold the settings, RMM and MDM guidance, exit codes, logs and troubleshooting. Every script header now uses one short layout (synopsis, description, notes, link). In the Windows scripts the help block comes before `#requires -Version 5.1`, so `Get-Help` reads it. No behavior changes (#39).
- Fixed stale filenames in script comments, replaced the author line with "Liongard Partner Support", made EXE Advanced `exit 0` on success, and corrected the README settings and Quick start (#14).

### Windows

- MSI Simple, MSI Advanced and Clean install: new `$AgentName`, `$ProxyUrl`, `$DeviceGuid`, `$ResetDeviceGuid`, `$AutoUpdate`, `$InstallLocation`, `$ServiceAccount` and `$ServiceAccountPassword` settings, passed to the MSI as its public properties. EXE Simple and Advanced: new `$AgentName`, `$DeviceGuid`, `$ResetDeviceGuid` and `$InstallLocation`.
- EXE Simple and Advanced: the bundle now also gets `EulaAcceptCheckbox` and `InstallEnhancedNetworkDiscovery`, the names bundles 5.4.0 and 5.3.1 and later read. Before, those bundles ignored `$EulaAccepted` and `$InstallNpcap`.
- Uninstall: new `$Environment` setting and identity backup in `LiongardDeploy` (the platform-removal exit code is now `10`; see Exit codes above).
- Clean install: an agent the platform refuses (its last 3 heartbeats in `AgentSVCLog.txt` were HTTP 401, for example after it was deleted in the Liongard UI) is now Stale instead of Healthy, so it's cleaned up and reinstalled as the same agent. Network errors and a missing or unreadable log never count. Applies only with `$CleanupPreviousAgents = $true` (#51).
- Added `windows/LGAgentCleanInstall-MSI-Simple.ps1`: MSI Simple plus cleanup of previous, outdated, incomplete or corrupt agent installs before a fresh install. It detects broken installs, including a missing Windows Installer cached package. Cleanup is controlled by `$CleanupPreviousAgents`, and setting it to `$false` gives MSI Simple behavior. The agent identity key is never modified. Exit codes: 0 on success (3010/1641 log a reboot WARN), 1618 when another Windows Installer operation is in progress, and otherwise the msiexec code or 1.
- All five Windows scripts now work in `<Folder>\LiongardDeploy` (default `C:\ProgramData\LiongardDeploy`) instead of `C:\Liongard` (#1). Before the first write on every run, they create or check that folder and lock it down to SYSTEM and Administrators. They refuse to continue if the folder or `$Folder` is a file or reparse point, or if an existing `LiongardDeploy` isn't owned by SYSTEM or Administrators. The scripts now require SYSTEM or an elevated administrator. `$Folder`/`$LogFolder` default to `$env:ProgramData`, and the scripts never touch `$env:ProgramData\Liongard`.
- Installers are downloaded to `LiongardDeploy\Deploy\<guid>\` and deleted at the end of every run.
- After the installer exits, whether the install succeeded or failed, the scripts redact the installer log (and the EXE bundle's per-package logs) in place. They mask `ACCESSKEY`/`ACCESSSECRET` values and the literal key and secret. If redaction fails, the log is deleted (#4). Stale-uninstall logs are redacted the same way. All scripts share one masking function.
- Logs are timestamped (`AgentInstall_<timestamp>.log`, `StaleUninstall_<ProductCode>_<timestamp>.log`), the scripts keep the 5 most recent runs of each log type, and every run ends by printing the full log paths. The EXE Advanced JSON summary is written to `LiongardDeploy`.
- Each run removes the old installers and script logs from the top level of `C:\Liongard`, then removes the folder if it's empty.
- EXE Advanced: `$InstallerLogPath` is deprecated and ignored, and `$InstallerFileName` must be a file name only.
- The new code is in a "Liongard deploy-folder functions" shared block that is identical in all five scripts.
- Installer-log redaction (the shared `Hide-LiongardSecretText`, all six scripts) now also masks proxy credentials (`user:****@host`), so `ProxyUrl=` values passed to the EXE bundle no longer stay in `AgentInstall_*.log`. A raw `@` in the password is masked too. EXE Advanced's `Hide-ProxyCredential` uses the same shared pattern.
- `LGAgentCleanInstall-MSI-Simple.ps1` now uses the same deploy-folder shared block (six scripts in all): it works in `LiongardDeploy`, stages the installer in `Deploy\<guid>\`, writes timestamped installer and stale-uninstall logs, redacts them in place instead of deleting `AgentInstall.log` after a successful install, cleans up the legacy `C:\Liongard` folder and prints the log paths at the end of every run. `$Folder` defaults to `$env:ProgramData`.
- EXE Advanced (#5): the JSON summary and installer-log hints no longer include unmasked proxy credentials; `user:pass@` is masked for any scheme or none.
- EXE Advanced (#5): proxy-credential masking now treats the last `@` before the host as the separator, so a password containing a raw `@` (for example `http://u:p@ss@proxy:8080`) is fully masked.

### Linux

- New `AGENT_NAME`, `PROXY_URL`, `DEVICE_GUID` and `RESET_IDENTITY` settings (`-n`, `-p`, `-g`, `--reset-identity`). Platform removal moved to `LGAgentUninstall-Linux-Advanced.sh` (exit `10` on failure).
- (#2) The installer now downloads to a private `mktemp -d` folder that is deleted on exit; the log moves to `LOG_DIRECTORY` (default `/var/log/liongard-agent`), and `DOWNLOAD_DIRECTORY` is deprecated (ignored with a warning, to be removed in a later release).
- (#7) The API token no longer appears in the process list; curl reads the auth header from a stdin config, and wget from a 0600 temp file (via `WGETRC`) that is removed on exit.
- (#31) The installer is picked by CPU architecture. The new `LINUX_ARCHITECTURE` setting (`auto`, `x64` or `arm64`; default `auto`) maps `uname -m` `x86_64` and `aarch64` to the x64 and arm64 LTS installers and stops with exit 3 on any other machine type. `INSTALLER_URL` now defaults to empty; when set, it is used as-is.

### macOS

- Added the macOS uninstall script (now `macos/LGAgentUninstall-macOS-Advanced.sh`): saves the identity, removes the agent and its leftovers, and can remove the platform record.
- `LGAgentInstall-macOS.sh` now downloads the package itself (`LiongardAgent-lts.pkg` for Intel, `LiongardAgent-lts-arm64.pkg` for Apple Silicon), picked by `sysctl -n hw.optional.arm64` or the new `MAC_ARCHITECTURE` setting, or installs a staged package from the new `PKG_PATH` setting. It checks the download size and the package's Liongard signature and architecture, installs Rosetta 2 only when the Intel package is used on Apple Silicon, checks the installer exit code, verifies the agent's LaunchDaemon afterward, and exits 0 without changes if the agent is already installed and running. The new optional `AGENT_DESCRIPTION` setting is written to `/tmp/liongard_description` only when set, and all six handoff files are deleted before every run (#20).
- `LGAgentInstall-macOS.sh` now requires root and sets `umask 077`. Before writing, it refuses to run if any of the five `/tmp/liongard_*` handoff files is a symlink or isn't owned by root, and otherwise deletes them. Each value is written to a `mktemp` file set to `root:wheel` and `600`, then moved into place with `mv -f`. All five files are deleted on exit, including on INT and TERM, and the script exits with the installer's status (#19). The script no longer matches the docs-site copy.

### Tests and CI

- Added `Test-RemoteDeletion.ps1`, `Test-InstallState.ps1` and `Test-SharedBlocks.ps1` (run by `Run-Tests.ps1`), and the shell tests `test-remote-deletion.sh`, `test-install-state.sh` and `test-identity-backup.sh`. CI doesn't run the shell tests yet.
- Added `tests/` with the proxy-masking tests for EXE Advanced (`Test-ProxyMasking.ps1`), a runner (`Run-Tests.ps1`) and a README. A new blocking `tests` job in the lint workflow runs them on every push and pull request.

## Initial import (Windows scripts dated 2026-10-10, Linux script dated 2026-06-24)

- Imported the Windows MSI/EXE Simple and Advanced install scripts and the Windows uninstall script, all dated 2026-10-10.
- Imported the Linux install script, dated 2026-06-24.
- Renamed the files to drop the date suffix. The script contents are unchanged.
- Imported the macOS install script from the docs site (https://resources.static.liongard.com/scripts/liongard_agent_install.sh) on 2026-10-14 as `macos/LGAgentInstall-macOS.sh`, unchanged. SHA-256: `79ba683e2995fcc72cb8128a013ace81a16d5698bded123767e7436ed9dc44dc`.
