# Changelog

All notable changes to these scripts are documented here.

## Unreleased

### All scripts

- Fixed stale filenames in script comments, replaced the author line with "Liongard Partner Support", made EXE Advanced `exit 0` on success, and corrected the README settings and Quick start (#14).

### Windows

- Added `windows/LGAgentCleanInstall-MSI-Simple.ps1`: MSI Simple plus cleanup of previous, outdated, incomplete or corrupt agent installs before a fresh install. It detects broken installs, including a missing Windows Installer cached package. Cleanup is controlled by `$CleanupPreviousAgents`, and setting it to `$false` gives MSI Simple behavior. The agent identity key is never modified. Exit codes: 0 on success (3010/1641 log a reboot WARN), 1618 when another Windows Installer operation is in progress, and otherwise the msiexec code or 1.
- All five Windows scripts now work in `<Folder>\LiongardDeploy` (default `C:\ProgramData\LiongardDeploy`) instead of `C:\Liongard` (#1). Before the first write on every run, they create or check that folder and lock it down to SYSTEM and Administrators. They refuse to continue if the folder or `$Folder` is a file or reparse point, or if an existing `LiongardDeploy` isn't owned by SYSTEM or Administrators. The scripts now require SYSTEM or an elevated administrator. `$Folder`/`$LogFolder` default to `$env:ProgramData`, and the scripts never touch `$env:ProgramData\Liongard`.
- Installers are downloaded to `LiongardDeploy\Deploy\<guid>\` and deleted at the end of every run.
- After the installer exits, whether the install succeeded or failed, the scripts redact the installer log (and the EXE bundle's per-package logs) in place. They mask `ACCESSKEY`/`ACCESSSECRET` values and the literal key and secret. If redaction fails, the log is deleted (#4). Stale-uninstall logs are redacted the same way. All scripts share one masking function.
- Logs are timestamped (`AgentInstall_<timestamp>.log`, `StaleUninstall_<ProductCode>_<timestamp>.log`), the scripts keep the 5 most recent runs of each log type, and every run ends by printing the full log paths. The EXE Advanced JSON summary is written to `LiongardDeploy`.
- Each run removes the old installers and script logs from the top level of `C:\Liongard`, then removes the folder if it's empty.
- EXE Advanced: `$InstallerLogPath` is deprecated and ignored, and `$InstallerFileName` must be a file name only.
- The new code is in a "Liongard deploy-folder functions" shared block that is identical in all five scripts.
- EXE Advanced (#5): the JSON summary and installer-log hints no longer include unmasked proxy credentials; `user:pass@` is masked for any scheme or none.

### Linux

- (#2) The installer now downloads to a private `mktemp -d` folder that is deleted on exit; the log moves to `LOG_DIRECTORY` (default `/var/log/liongard-agent`), and `DOWNLOAD_DIRECTORY` is deprecated (ignored with a warning, to be removed in a later release).
- (#7) The API token no longer appears in the process list; curl reads the auth header from a stdin config, and wget from a 0600 temp file (via `WGETRC`) that is removed on exit.
- (#31) The installer is picked by CPU architecture. The new `LINUX_ARCHITECTURE` setting (`auto`, `x64` or `arm64`; default `auto`) maps `uname -m` `x86_64` and `aarch64` to the x64 and arm64 LTS installers and stops with exit 3 on any other machine type. `INSTALLER_URL` now defaults to empty; when set, it is used as-is.

### macOS

- `LGAgentInstall-macOS.sh` now requires root and sets `umask 077`. Before writing, it refuses to run if any of the five `/tmp/liongard_*` handoff files is a symlink or isn't owned by root, and otherwise deletes them. Each value is written to a `mktemp` file set to `root:wheel` and `600`, then moved into place with `mv -f`. All five files are deleted on exit, including on INT and TERM, and the script exits with the installer's status (#19). The script no longer matches the docs-site copy.

## Initial import (Windows scripts dated 2026-10-10, Linux script dated 2026-06-24)

- Imported the Windows MSI/EXE Simple and Advanced install scripts and the Windows uninstall script, all dated 2026-10-10.
- Imported the Linux install script, dated 2026-06-24.
- Renamed the files to drop the date suffix. The script contents are unchanged.
- Imported the macOS install script from the docs site (https://resources.static.liongard.com/scripts/liongard_agent_install.sh) on 2026-10-14 as `macos/LGAgentInstall-macOS.sh`, unchanged. SHA-256: `79ba683e2995fcc72cb8128a013ace81a16d5698bded123767e7436ed9dc44dc`.
