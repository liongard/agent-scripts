# Runs every tests/Test-*.ps1 file and exits non-zero if any of them fails.
# Usage: pwsh -NoProfile -File tests/Run-Tests.ps1
$failed = @()
foreach ($test in Get-ChildItem -Path $PSScriptRoot -Filter 'Test-*.ps1' | Sort-Object Name) {
    Write-Output "=== $($test.Name)"
    & pwsh -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $test.Name }
}
if ($failed.Count) { Write-Output "FAILED: $($failed -join ', ')"; exit 1 }
Write-Output 'All tests passed.'
