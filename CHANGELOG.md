# Changelog

All notable changes to these scripts are documented here.

## Unreleased – initial import (Windows scripts dated 2026-10-10, Linux script dated 2026-06-24)

- Imported the Windows MSI/EXE Simple and Advanced install scripts and the Windows uninstall script, all dated 2026-10-10.
- Imported the Linux install script, dated 2026-06-24.
- Renamed the files to drop the date suffix. The script contents are unchanged.
- Imported the macOS install script from the docs site (https://resources.static.liongard.com/scripts/liongard_agent_install.sh) on 2026-10-14 as `macos/LGAgentInstall-macOS.sh`, unchanged. SHA-256: `79ba683e2995fcc72cb8128a013ace81a16d5698bded123767e7436ed9dc44dc`.
- All scripts (#14): fixed stale filenames in script comments, replaced the author line with "Liongard Partner Support", made EXE Advanced `exit 0` on success, and corrected the README settings and Quick start.
- EXE Advanced (#5): the JSON summary and installer-log hints no longer include unmasked proxy credentials; `user:pass@` is masked for any scheme or none.
