# Shared-block consistency check for the Windows scripts (#13).
# Usage: pwsh -NoProfile -File tests/Test-SharedBlocks.ps1 [-WindowsFolder <path>]
# Each script is standalone, so the shared blocks are copied into every script that needs them.
# This extracts each block from every windows/*.ps1, checks that it is in exactly the expected
# scripts (once each), and compares the copies with each other. Only line endings are normalized.
param([string]$WindowsFolder = (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows'))

$blocks = @(
    @{
        Name     = 'deploy-folder functions'
        Begin    = '# BEGIN SHARED BLOCK: Liongard deploy-folder functions'
        End      = @('# END SHARED BLOCK: Liongard deploy-folder functions')
        Expected = 'LGAgentCleanInstall-MSI-Simple.ps1', 'LGAgentInstall-EXE-Advanced.ps1', 'LGAgentInstall-EXE-Simple.ps1',
                   'LGAgentInstall-MSI-Advanced.ps1', 'LGAgentInstall-MSI-Simple.ps1', 'LGAgentUninstall.ps1'
    },
    @{
        # The end marker is bare today; the named form is accepted too.
        Name     = 'install-state functions'
        Begin    = '# BEGIN SHARED BLOCK: Liongard install-state functions'
        End      = @('# END SHARED BLOCK', '# END SHARED BLOCK: Liongard install-state functions')
        Expected = 'LGAgentInstall-EXE-Advanced.ps1', 'LGAgentInstall-MSI-Advanced.ps1', 'LGAgentUninstall.ps1'
    }
)

$fail = 0
$scripts = @(Get-ChildItem -Path $WindowsFolder -Filter '*.ps1' | Sort-Object Name)
if (-not $scripts.Count) { Write-Output "FAIL  no .ps1 files in $WindowsFolder"; exit 1 }
# Split on any line ending, so CRLF and LF copies compare equal.
$lines = @{}
foreach ($file in $scripts) { $lines[$file.Name] = [regex]::Split((Get-Content -LiteralPath $file.FullName -Raw), '\r?\n') }

foreach ($block in $blocks) {
    Write-Output "--- $($block.Name)"
    $copies = [ordered]@{}
    foreach ($file in $scripts) {
        $text  = $lines[$file.Name]
        $begin = @(for ($i = 0; $i -lt $text.Count; $i++) { if ($text[$i].StartsWith($block.Begin, [StringComparison]::Ordinal)) { $i } })
        $isExpected = $block.Expected -contains $file.Name
        if (-not $begin.Count) {
            if ($isExpected) { $fail++; Write-Output "FAIL  $($file.Name): block missing" }
            continue
        }
        if (-not $isExpected) { $fail++; Write-Output "FAIL  $($file.Name): block found in a script that isn't expected to have it (line $($begin[0] + 1))" }
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
    # Compare every copy with the first one, and group the scripts whose copies match.
    $names = @($copies.Keys)
    $ref = $copies[$names[0]]
    $differs = @()
    foreach ($name in $names[1..($names.Count - 1)]) {
        $copy = $copies[$name]
        $count = [Math]::Max($ref.Lines.Count, $copy.Lines.Count)
        $diff = @(for ($i = 0; $i -lt $count; $i++) { if ($i -ge $ref.Lines.Count -or $i -ge $copy.Lines.Count -or $ref.Lines[$i] -cne $copy.Lines[$i]) { $i } })
        if (-not $diff.Count) { continue }
        $differs += $name
        $fail++
        $i = $diff[0]
        $a = if ($i -lt $ref.Lines.Count)  { $ref.Lines[$i] }  else { '<end of block>' }
        $b = if ($i -lt $copy.Lines.Count) { $copy.Lines[$i] } else { '<end of block>' }
        Write-Output ("FAIL  {0} differs from {1}: {2} line(s) differ; first at block line {3} ({1}:{4}, {0}:{5})" -f $name, $names[0], $diff.Count, ($i + 1), ($ref.Start + $i), ($copy.Start + $i))
        Write-Output ("        {0}: {1}" -f $names[0], $a.Trim())
        Write-Output ("        {0}: {1}" -f $name, $b.Trim())
        if ($diff.Count -gt 1) { Write-Output ("        other differing block lines: {0}" -f (($diff[1..([Math]::Min(9, $diff.Count - 1))] | ForEach-Object { $_ + 1 }) -join ', ')) }
    }
    if ($differs.Count) {
        $groups = $copies.Keys | Group-Object { $copies[$_].Lines -join "`n" }
        Write-Output "        groups of identical copies:"
        foreach ($g in $groups) { Write-Output ("          {0}" -f ($g.Group -join ', ')) }
    }
    else { Write-Output ("ok    identical in {0} scripts ({1} lines): {2}" -f $copies.Count, $ref.Lines.Count, ($names -join ', ')) }
}

Write-Output ("{0} failure(s)" -f $fail)
exit $fail
