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
- [ ] linux/LGAgentInstall-Linux.sh
- [ ] macos/LGAgentInstall-macOS.sh

## Testing

<!-- OS / version, RMM, run context (SYSTEM / root), result. -->

## Checklist

- [ ] No real credentials. The config blocks contain only `REPLACE_WITH_*` placeholders.
- [ ] Scripts are still standalone: no imports, dot-sourcing or `source`.
- [ ] If the shared install-state block changed, the copy is identical in every Advanced/Uninstall script and the Simple scripts are updated too.
- [ ] Behavior change: CHANGELOG entry added and version/`Last updated` bumped.
- [ ] Commits are signed off (`git commit -s`).
