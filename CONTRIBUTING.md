# Contributing

## Ground rules

- **Keep scripts standalone.** Each script is a single file that partners paste into an RMM. Don't use module imports, `Import-Module`, dot-sourcing (`. .\file.ps1`) or `source`. Anything shared must be copied into each script. Keep the "Liongard install-state functions" shared block identical across the Advanced install scripts and `LGAgentUninstall-Advanced.ps1`, and update the Simple scripts whenever that block changes. Keep the "Liongard deploy-folder functions" shared block identical in the six Windows scripts that have it (all except `LGAgentUninstall-Simple.ps1`). The blocking `shared-blocks` CI job (`tests/Test-SharedBlocks.ps1`) fails if a copy differs, is missing or duplicated, or turns up in another script; run it locally before you push.
- **Never commit real credentials.** The configuration blocks must contain only `REPLACE_WITH_*` placeholders. This includes tokens, keys, secrets, instance-specific URLs and customer data in logs or examples. If you commit a secret by accident, rotate it right away. Removing it from history is not enough.
- **Line endings.** `.ps1` and `.sh` files use LF. `.gitattributes` enforces this, so don't override it or convert the scripts to CRLF.

## Sign-off (DCO)

Every commit must carry a Developer Certificate of Origin sign-off:

```
git commit -s -m "Describe the change"
```

This adds a `Signed-off-by: Your Name <you@liongard.com>` line, which certifies the [DCO](https://developercertificate.org/).

## Behavior changes

If a change affects what a script does on an endpoint:

1. Add an entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
2. Bump the version or `Last updated` date in the script header.
3. Describe how you tested it (OS, RMM, run as SYSTEM or root) in the pull request.

Changes that only touch comments or docs don't need a version bump.

## Security

Report vulnerabilities privately to security.ops@liongard.com. See [SECURITY.md](SECURITY.md).
