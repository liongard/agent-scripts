# Tests

These tests check the scripts' masking of keys, secrets and proxy credentials. They load the functions straight from the scripts in `windows/`, so they always test the code as it is. They need nothing beyond PowerShell 7 (`pwsh`), and they run on Windows, macOS or Linux. All keys, secrets and passwords in the tests are fake.

| File | What it tests |
|---|---|
| `Test-LogRedaction.ps1` | The shared `Hide-LiongardSecretText` and `Protect-LiongardInstallerLog` in every Windows script that has the deploy-folder shared block. Covers installer-log lines with `ProxyUrl=` values (raw `@` included), access key and secret properties and literal secrets, and redacts real UTF-16 and UTF-8 log files in place. |
| `Test-ProxyMasking.ps1` | `Hide-ProxyCredential`, `Mask-ProxyValue` and `Hide-LiongardLogSecret` in `LGAgentInstall-EXE-Advanced.ps1`. Covers every proxy scheme, multi-entry values, URL-encoded and raw `@` in passwords, and text that must stay unchanged. |

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

The `tests` job in `.github/workflows/lint.yml` runs `tests/Run-Tests.ps1` on every push and pull request. Unlike the lint jobs, it's blocking, so a failing test fails the check.

## Adding a test

Add a `tests/Test-<Name>.ps1` file that exits `0` when every case passes and non-zero otherwise. `Run-Tests.ps1` picks it up automatically.
