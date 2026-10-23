## Summary

<!-- What changed and why. -->

## Scripts affected

- [ ] windows/LGAgentInstall-MSI-Simple.ps1
- [ ] windows/LGAgentCleanInstall-MSI-Simple.ps1
- [ ] windows/LGAgentInstall-MSI-Advanced.ps1
- [ ] windows/LGAgentInstall-EXE-Simple.ps1
- [ ] windows/LGAgentInstall-EXE-Advanced.ps1
- [ ] windows/LGAgentUninstall-Simple.ps1
- [ ] windows/LGAgentUninstall-Advanced.ps1
- [ ] windows/LGAgentIdentity.ps1
- [ ] linux/LGAgentInstall-Linux-Simple.sh
- [ ] linux/LGAgentInstall-Linux-Advanced.sh
- [ ] linux/LGAgentCleanInstall-Linux-Simple.sh
- [ ] linux/LGAgentUninstall-Linux-Simple.sh
- [ ] linux/LGAgentUninstall-Linux-Advanced.sh
- [ ] linux/LGAgentIdentity-Linux.sh
- [ ] macos/LGAgentInstall-macOS-Simple.sh
- [ ] macos/LGAgentInstall-macOS-Advanced.sh
- [ ] macos/LGAgentCleanInstall-macOS-Simple.sh
- [ ] macos/LGAgentUninstall-macOS-Simple.sh
- [ ] macos/LGAgentUninstall-macOS-Advanced.sh
- [ ] macos/LGAgentIdentity-macOS.sh

## Testing

<!-- OS / version, RMM, run context (SYSTEM / root), result. -->

## Checklist

- [ ] No real credentials. The config blocks contain only `REPLACE_WITH_*` placeholders.
- [ ] Scripts are still standalone: no imports, dot-sourcing or `source`.
- [ ] If a shared block changed, every copy is identical (`pwsh tests/Test-SharedBlocks.ps1`) and the other platforms are updated to match.
- [ ] Behavior change: CHANGELOG entry added and version/`Last updated` bumped.
- [ ] Commits are signed off (`git commit -s`).
