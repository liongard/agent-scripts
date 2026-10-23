# Changelog

All notable changes to these scripts are documented here.

## Unreleased

### All scripts

- CI: a new blocking `shared-blocks` job runs `tests/Test-SharedBlocks.ps1`, which fails if a copy of the deploy-folder or install-state shared block differs from the others, is missing or duplicated, or is in an unexpected Windows script, or if an expected script is not there (#13).
- Docs: the main README is now an overview with a "Which script do I use?" table, and `windows/README.md`, `linux/README.md` and `macos/README.md` hold the settings, RMM and MDM guidance, exit codes, logs and troubleshooting. Every script header now uses one short layout (synopsis, description, notes, link). In the Windows scripts the help block comes before `#requires -Version 5.1`, so `Get-Help` reads it. No behavior changes (#39).
- Fixed stale filenames in script comments, replaced the author line with "Liongard Partner Support", made EXE Advanced `exit 0` on success, and corrected the README settings and Quick start (#14).

### Windows

- Renamed `LGAgentUninstall.ps1` to `LGAgentUninstall-Advanced.ps1`. No behavior change. Its log is still `LGAgentUninstall_<timestamp>.log` (#53).
- Added `windows/LGAgentUninstall-Simple.ps1`: local removal only, with no Liongard API calls and no required settings. It deletes the `\Liongard\LiongardAgentUpdater` task, runs the EXE bundle's quiet uninstall (`/norestart`) and `msiexec /x` for MSI entries, stops processes, deletes the services, removes leftover uninstall entries in both registry views and both `LiongardInc` folders, runs `msiexec /x` for a Windows Installer registration (`HKCR\Installer\Products`) that has no uninstall entry, then lists anything that's left (services matched by exact name, each listed once). The identity key is never modified, and Credential Manager cleanup stays disabled (#8). It writes `LGAgentUninstall_<timestamp>.log` only to an existing `LiongardDeploy` folder that isn't a reparse point and is owned by SYSTEM or Administrators; otherwise the console only. Exit codes: `0` removed or nothing installed, `1` still detected or failed (#53).
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

- Added `linux/LGAgentUninstall-Linux.sh`: local removal only, with no Liongard API calls and no settings. It stops and removes the agent and updater services and timer, any installed `.deb` or `.rpm` package (`remove`, not `purge`), processes, unit files, binaries and install folders, then lists anything that's left. It reuses the install script's pre-uninstall lists, with three fixes: packages are found by their installed state instead of the installer URL, `rc` packages don't count as installed, and processes running from `/opt/liongard` are stopped. It never touches `/etc/liongard-agent` (identity) and leaves `/etc/liongard` with a WARN until the dev team confirms what it holds. stdout and stderr only. Exit codes: `0` removed or nothing installed, `1` still detected or not root (#54).
- (#2) The installer now downloads to a private `mktemp -d` folder that is deleted on exit; the log moves to `LOG_DIRECTORY` (default `/var/log/liongard-agent`), and `DOWNLOAD_DIRECTORY` is deprecated (ignored with a warning, to be removed in a later release).
- (#7) The API token no longer appears in the process list; curl reads the auth header from a stdin config, and wget from a 0600 temp file (via `WGETRC`) that is removed on exit.
- (#31) The installer is picked by CPU architecture. The new `LINUX_ARCHITECTURE` setting (`auto`, `x64` or `arm64`; default `auto`) maps `uname -m` `x86_64` and `aarch64` to the x64 and arm64 LTS installers and stops with exit 3 on any other machine type. `INSTALLER_URL` now defaults to empty; when set, it is used as-is.

### macOS

- Added `macos/LGAgentUninstall-macOS.sh`: local removal only, with no Liongard API calls and no settings. It runs the package's `/Library/Liongard/uninstall.sh` when present (a root-owned file, with neither it nor `/Library/Liongard` writable by the group or other users), then always stops and removes both LaunchDaemons (`com.liongard.liongard-agent` and `-updater`), leftover processes, `/Library/Liongard` and both package receipts, removes leftover `/tmp/liongard_*` settings files and `/tmp/temporary-liongard-values.txt`, and lists anything that's left. It never touches `/etc/liongard-agent` (identity). Exit codes: `0` removed or nothing installed, `1` still detected or not root (#55).
- `LGAgentInstall-macOS.sh` now downloads the package itself (`LiongardAgent-lts.pkg` for Intel, `LiongardAgent-lts-arm64.pkg` for Apple Silicon), picked by `sysctl -n hw.optional.arm64` or the new `MAC_ARCHITECTURE` setting, or installs a staged package from the new `PKG_PATH` setting. It checks the download size and the package's Liongard signature and architecture, installs Rosetta 2 only when the Intel package is used on Apple Silicon, checks the installer exit code, verifies the agent's LaunchDaemon afterward, and exits 0 without changes if the agent is already installed and running. The new optional `AGENT_DESCRIPTION` setting is written to `/tmp/liongard_description` only when set, and all six handoff files are deleted before every run (#20).
- `LGAgentInstall-macOS.sh` now requires root and sets `umask 077`. Before writing, it refuses to run if any of the five `/tmp/liongard_*` handoff files is a symlink or isn't owned by root, and otherwise deletes them. Each value is written to a `mktemp` file set to `root:wheel` and `600`, then moved into place with `mv -f`. All five files are deleted on exit, including on INT and TERM, and the script exits with the installer's status (#19). The script no longer matches the docs-site copy.

### Tests and CI

- Added `tests/` with the proxy-masking tests for EXE Advanced (`Test-ProxyMasking.ps1`), a runner (`Run-Tests.ps1`) and a README. A new blocking `tests` job in the lint workflow runs them on every push and pull request.

## Initial import (Windows scripts dated 2026-10-10, Linux script dated 2026-06-24)

- Imported the Windows MSI/EXE Simple and Advanced install scripts and the Windows uninstall script, all dated 2026-10-10.
- Imported the Linux install script, dated 2026-06-24.
- Renamed the files to drop the date suffix. The script contents are unchanged.
- Imported the macOS install script from the docs site (https://resources.static.liongard.com/scripts/liongard_agent_install.sh) on 2026-10-14 as `macos/LGAgentInstall-macOS.sh`, unchanged. SHA-256: `79ba683e2995fcc72cb8128a013ace81a16d5698bded123767e7436ed9dc44dc`.
