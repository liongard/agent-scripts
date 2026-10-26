# Shared-block consistency check for the Windows scripts (#13).
# Usage: pwsh -NoProfile -File tests/Test-SharedBlocks.ps1 [-WindowsFolder <path>]
# Each script is standalone, so the shared blocks are copied into every script that needs them.
# This extracts each block from every windows/*.ps1, checks that it is in exactly the expected
# scripts (once each), and compares the copies with the majority copy. Only line endings are normalized.
param([string]$WindowsFolder = (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows'))

$blocks = @(
    @{
        Name     = 'deploy-folder functions'
        Begin    = '# BEGIN SHARED BLOCK: Liongard deploy-folder functions'
        End      = @('# END SHARED BLOCK: Liongard deploy-folder functions')
        Expected = 'LGAgentCleanInstall-MSI-Simple.ps1', 'LGAgentInstall-EXE-Advanced.ps1', 'LGAgentInstall-EXE-Simple.ps1',
                   'LGAgentInstall-MSI-Advanced.ps1', 'LGAgentInstall-MSI-Simple.ps1', 'LGAgentUninstall-Advanced.ps1'
    },
    @{
        # The end marker is bare today; the named form is accepted too.
        Name     = 'install-state functions'
        Begin    = '# BEGIN SHARED BLOCK: Liongard install-state functions'
        End      = @('# END SHARED BLOCK', '# END SHARED BLOCK: Liongard install-state functions')
        Expected = 'LGAgentInstall-EXE-Advanced.ps1', 'LGAgentInstall-MSI-Advanced.ps1', 'LGAgentUninstall-Advanced.ps1'
    }
)

$fail = 0
$listFail = $false
$scripts = @(Get-ChildItem -Path $WindowsFolder -Filter '*.ps1' | Sort-Object Name)
if (-not $scripts.Count) { Write-Output "FAIL  no .ps1 files in $WindowsFolder"; exit 1 }
# Split on any line ending, so CRLF and LF copies compare equal.
$lines = @{}
foreach ($file in $scripts) { $lines[$file.Name] = [regex]::Split((Get-Content -LiteralPath $file.FullName -Raw), '\r?\n') }

foreach ($block in $blocks) {
    Write-Output "--- $($block.Name)"
    $copies = [ordered]@{}
    # An expected script that was renamed or deleted would otherwise be skipped.
    foreach ($name in $block.Expected) {
        if (-not $lines.ContainsKey($name)) { $fail++; $listFail = $true; Write-Output "FAIL  ${name}: expected script not found in $WindowsFolder" }
    }
    foreach ($file in $scripts) {
        $text  = $lines[$file.Name]
        $begin = @(for ($i = 0; $i -lt $text.Count; $i++) { if ($text[$i].StartsWith($block.Begin, [StringComparison]::Ordinal)) { $i } })
        $isExpected = $block.Expected -contains $file.Name
        if (-not $begin.Count) {
            if ($isExpected) { $fail++; $listFail = $true; Write-Output "FAIL  $($file.Name): block missing" }
            continue
        }
        if (-not $isExpected) { $fail++; $listFail = $true; Write-Output "FAIL  $($file.Name): block found in a script that isn't expected to have it (line $($begin[0] + 1))" }
        if ($begin.Count -gt 1) { $fail++; Write-Output "FAIL  $($file.Name): block begins $($begin.Count) times (lines $(($begin | ForEach-Object { $_ + 1 }) -join ', '))"; continue }
        $end = -1
        for ($i = $begin[0] + 1; $i -lt $text.Count; $i++) { if ($text[$i].StartsWith('# END SHARED BLOCK', [StringComparison]::Ordinal)) { $end = $i; break } }
        # A block ends at the first following "# END SHARED BLOCK" line, which must be its own end marker.
        if ($end -lt 0 -or $block.End -cnotcontains $text[$end].TrimEnd()) {
            $fail++; Write-Output "FAIL  $($file.Name): no '$($block.End[0])' line after line $($begin[0] + 1)"; continue
        }
        if ($isExpected) { $copies[$file.Name] = @{ Start = $begin[0] + 1; Lines = @($text[$begin[0]..$end]) } }
    }

    if ($copies.Count -lt 2) { continue }
    # Group the scripts whose copies match, and compare every copy with the largest group,
    # so the message names the odd one out. On a tie the alphabetically first group wins.
    $names = @($copies.Keys)
    $groups = @($names | Group-Object { $copies[$_].Lines -join "`n" } |
        Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = { $_.Group[0] } })
    $refName = $groups[0].Group[0]
    $ref = $copies[$refName]
    $differs = @()
    foreach ($name in $names) {
        if ($groups[0].Group -contains $name) { continue }
        $copy = $copies[$name]
        $count = [Math]::Max($ref.Lines.Count, $copy.Lines.Count)
        $diff = @(for ($i = 0; $i -lt $count; $i++) { if ($i -ge $ref.Lines.Count -or $i -ge $copy.Lines.Count -or $ref.Lines[$i] -cne $copy.Lines[$i]) { $i } })
        if (-not $diff.Count) { continue }
        $differs += $name
        $fail++
        $i = $diff[0]
        $a = if ($i -lt $ref.Lines.Count)  { $ref.Lines[$i] }  else { '<end of block>' }
        $b = if ($i -lt $copy.Lines.Count) { $copy.Lines[$i] } else { '<end of block>' }
        Write-Output ("FAIL  {0} differs from {1}: {2} line(s) differ; first at block line {3} ({1}:{4}, {0}:{5})" -f $name, $refName, $diff.Count, ($i + 1), ($ref.Start + $i), ($copy.Start + $i))
        # Untrimmed, so a whitespace-only difference is still there to see.
        Write-Output ("        {0}: {1}" -f $refName, $a)
        Write-Output ("        {0}: {1}" -f $name, $b)
        if ($a.Trim() -ceq $b.Trim()) { Write-Output "        (whitespace-only difference)" }
        if ($diff.Count -gt 1) { Write-Output ("        other differing block lines: {0}" -f (($diff[1..([Math]::Min(9, $diff.Count - 1))] | ForEach-Object { $_ + 1 }) -join ', ')) }
    }
    if ($differs.Count) {
        Write-Output "        groups of identical copies (largest first):"
        foreach ($g in $groups) { Write-Output ("          {0}" -f ($g.Group -join ', ')) }
    }
    else { Write-Output ("ok    identical in {0} scripts ({1} lines): {2}" -f $copies.Count, $ref.Lines.Count, ($names -join ', ')) }
}

if ($listFail) { Write-Output "If you added, renamed or removed a Windows script, update that block's Expected list in tests/Test-SharedBlocks.ps1." }
Write-Output ("{0} failure(s)" -f $fail)
exit $fail
