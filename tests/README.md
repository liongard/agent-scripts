# Tests

The PowerShell tests check the scripts' masking of keys, secrets and proxy credentials, the install-state rules, the environment check, the uninstall script's identity collection and platform-record removal, and that every shared block is identical. They load the functions straight from the scripts in `windows/`, so they always test the code as it is. They need nothing beyond PowerShell 7 (`pwsh`), and they run on Windows, macOS or Linux. All keys, secrets and passwords in the tests are fake, and no test calls a real Liongard API.

| File | What it tests |
|---|---|
| `Test-LogRedaction.ps1` | The shared `Hide-LiongardSecretText` and `Protect-LiongardInstallerLog` in every Windows script that has the deploy-folder shared block. Covers installer-log lines with `ProxyUrl=` values (raw `@` included), access key and secret properties and literal secrets, and redacts real UTF-16 and UTF-8 log files in place. |
| `Test-RemoteDeletion.ps1` | `Get-LiongardAgentIdentity` against a mocked registry (both views, `INSTALLLOCATION`, environment-derived folders) and `Remove-LiongardPlatformRecord` in `LGAgentUninstall-Advanced.ps1` against a mocked API with `=` and `like`: the AgentID, MachineGuid and hostname order, defects (a) to (g), the single-match rule, failed lookups and deletes, and a delete that times out. Same cases as `test-remote-deletion.sh`, plus the Windows-only (d) and (f). |
| `Test-InstallState.ps1` | Healthy, Stale and NotInstalled in the shared install-state block and in MSI and EXE Simple, that Simple exits `8` for Stale before downloading and has no cleanup code, and `Resolve-LiongardEnvironment` (exact, case-insensitive, normalized, prefix, contains, short names, ambiguous, failed lookup). |
| `Test-SharedBlocks.ps1` | Every `# BEGIN SHARED BLOCK` in `windows/`, `linux/` and `macos/` is byte-identical in each script that carries it, and sits in exactly the expected scripts. |
| `Test-ProxyMasking.ps1` | `Hide-ProxyCredential`, `Mask-ProxyValue` and `Hide-LiongardLogSecret` in `LGAgentInstall-EXE-Advanced.ps1`. Covers every proxy scheme, multi-entry values, URL-encoded and raw `@` in passwords, and text that must stay unchanged. |

## Shell tests

| File | What it tests | Run with |
|---|---|---|
| `test-remote-deletion.sh` | The shared platform-record removal block in `linux/LGAgentUninstall-Linux-Advanced.sh` and `macos/LGAgentUninstall-macOS-Advanced.sh`: that both copies are identical, and defects (a), (b), (c), (e) and (g) against a mocked API with `=` and `like`. | `bash tests/test-remote-deletion.sh` (bash 3.2 or later, `jq`) |
| `test-install-state.sh` | The Linux and macOS install-state decisions with fake `systemctl`, `launchctl`, installers and files: Healthy, Stale and NotInstalled, the 401 rule, and the exit code of every Install Simple, Advanced, Clean Install and Uninstall Simple path. No root needed. | `bash tests/test-install-state.sh` (bash 3.2 or later, `curl`) |
| `test-identity-backup.sh` | The identity backup the Linux and macOS scripts write before removal: agent and OS identifiers, no secret written, folder and file modes, the Clean Install identity seed, and that `LGAgentIdentity-*` accepts the backup. | `bash tests/test-identity-backup.sh linux` (needs `sha256sum`; the restore check needs bash 4+) or `bash tests/test-identity-backup.sh macos` (the restore check needs zsh) |
| `identity/test-LGAgentIdentity-Linux.sh` | `linux/LGAgentIdentity-Linux.sh` against a fake root. | `bash tests/identity/test-LGAgentIdentity-Linux.sh` |
| `identity/test-LGAgentIdentity-macOS.sh` | `macos/LGAgentIdentity-macOS.sh` against a fake root. | `zsh tests/identity/test-LGAgentIdentity-macOS.sh` |
| `identity/test-LGAgentIdentity-Windows.ps1` | `windows/LGAgentIdentity.ps1` against a test key under `HKCU:\Software\LiongardIdentityTest`. Windows only, so it lives outside `Run-Tests.ps1`. | `powershell -File tests\identity\test-LGAgentIdentity-Windows.ps1` |

CI doesn't run the shell tests or the `identity/` tests yet.

## Run them locally

From the repo root:

```
pwsh -NoProfile -File tests/Run-Tests.ps1
```

To run one file, for example against a modified copy of a script:

```
pwsh -NoProfile -File tests/Test-ProxyMasking.ps1 -Script ./windows/LGAgentInstall-EXE-Advanced.ps1
```

Each file prints one `ok` or `FAIL` line per case and exits with the number of failures. `Run-Tests.ps1` exits `1` if any file fails.

## CI

The `tests` job in `.github/workflows/lint.yml` runs `tests/Run-Tests.ps1`, and the `shared-blocks` job runs `tests/Test-SharedBlocks.ps1`, on every push and pull request. Unlike the lint jobs, both are blocking, so a failing test fails the check.

Shared blocks are kept identical by hand: edit one copy, then copy it to the other scripts listed in the block's header comment. `Test-SharedBlocks.ps1` holds the expected script list for each block.

## Adding a test

Add a `tests/Test-<Name>.ps1` file that exits `0` when every case passes and non-zero otherwise. `Run-Tests.ps1` picks it up automatically.
