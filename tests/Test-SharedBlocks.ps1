# Checks that every shared block is byte-identical in each script that carries it, and sits in the expected scripts.
# Usage: pwsh -NoProfile -File tests/Test-SharedBlocks.ps1
$root = Split-Path $PSScriptRoot -Parent
$expected = [ordered]@{
    'Liongard deploy-folder functions'      = 'LGAgentCleanInstall-MSI-Simple.ps1', 'LGAgentInstall-EXE-Advanced.ps1', 'LGAgentInstall-EXE-Simple.ps1', 'LGAgentInstall-MSI-Advanced.ps1', 'LGAgentInstall-MSI-Simple.ps1', 'LGAgentUninstall-Advanced.ps1', 'LGAgentUninstall-Simple.ps1'
    'Liongard install-state functions'      = 'LGAgentInstall-EXE-Advanced.ps1', 'LGAgentInstall-MSI-Advanced.ps1', 'LGAgentUninstall-Advanced.ps1', 'LGAgentUninstall-Simple.ps1'
    'Liongard identity functions'           = 'LGAgentCleanInstall-MSI-Simple.ps1', 'LGAgentUninstall-Advanced.ps1', 'LGAgentUninstall-Simple.ps1'
    'Liongard local uninstall functions'    = 'LGAgentUninstall-Advanced.ps1', 'LGAgentUninstall-Simple.ps1'
    'Liongard environment check functions'  = 'LGAgentInstall-EXE-Advanced.ps1', 'LGAgentInstall-MSI-Advanced.ps1'
    'Liongard shell common functions'       = 'LGAgentCleanInstall-Linux-Simple.sh', 'LGAgentCleanInstall-macOS-Simple.sh', 'LGAgentInstall-Linux-Advanced.sh', 'LGAgentInstall-Linux-Simple.sh', 'LGAgentInstall-macOS-Advanced.sh', 'LGAgentInstall-macOS-Simple.sh', 'LGAgentUninstall-Linux-Advanced.sh', 'LGAgentUninstall-Linux-Simple.sh', 'LGAgentUninstall-macOS-Advanced.sh', 'LGAgentUninstall-macOS-Simple.sh'
    'Liongard environment check'            = 'LGAgentInstall-Linux-Advanced.sh', 'LGAgentInstall-macOS-Advanced.sh'
    'Liongard platform record removal'      = 'LGAgentUninstall-Linux-Advanced.sh', 'LGAgentUninstall-macOS-Advanced.sh'
    'Liongard Linux agent functions'        = 'LGAgentCleanInstall-Linux-Simple.sh', 'LGAgentInstall-Linux-Advanced.sh', 'LGAgentInstall-Linux-Simple.sh', 'LGAgentUninstall-Linux-Advanced.sh', 'LGAgentUninstall-Linux-Simple.sh'
    'Liongard macOS agent functions'        = 'LGAgentCleanInstall-macOS-Simple.sh', 'LGAgentInstall-macOS-Advanced.sh', 'LGAgentInstall-macOS-Simple.sh', 'LGAgentUninstall-macOS-Advanced.sh', 'LGAgentUninstall-macOS-Simple.sh'
}

$files = @(Get-ChildItem -Path (Join-Path $root 'windows'), (Join-Path $root 'linux'), (Join-Path $root 'macos') -File | Where-Object { $_.Extension -in '.ps1', '.sh' })
$found = @{}
$fail = 0
foreach ($file in $files) {
    $lines = [IO.File]::ReadAllText($file.FullName) -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^# BEGIN SHARED BLOCK: (.+?)\r?$') { continue }
        $name = $Matches[1]
        $end = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j].TrimEnd("`r") -eq "# END SHARED BLOCK: $name") { $end = $j; break } }
        if ($end -lt 0) { Write-Output "FAIL  $($file.Name): block [$name] has no matching END marker"; $fail++; continue }
        if (-not $found.ContainsKey($name)) { $found[$name] = @{} }
        if ($found[$name].ContainsKey($file.Name)) { Write-Output "FAIL  $($file.Name): block [$name] appears twice"; $fail++ }
        $found[$name][$file.Name] = ($lines[$i..$end] -join "`n")
        $i = $end
    }
}

foreach ($name in @($found.Keys) + @($expected.Keys) | Sort-Object -Unique) {
    if (-not $expected.Contains($name)) { Write-Output "FAIL  block [$name] is not in the expected map"; $fail++; continue }
    $copies = if ($found.ContainsKey($name)) { $found[$name] } else { @{} }
    $want = @($expected[$name] | Sort-Object)
    $have = @($copies.Keys | Sort-Object)
    if (($want -join ',') -ne ($have -join ',')) {
        Write-Output "FAIL  block [$name] is in [$($have -join ', ')], expected [$($want -join ', ')]"; $fail++; continue
    }
    $reference = $copies[$have[0]]
    $diff = @($have | Where-Object { $copies[$_] -cne $reference })
    if ($diff.Count) { Write-Output "FAIL  block [$name] differs from $($have[0]) in: $($diff -join ', ')"; $fail++ }
    else { Write-Output "ok    block [$name] is identical in $($have.Count) scripts" }
}

if ($fail) { Write-Output "$fail failed"; exit 1 }
Write-Output 'All shared blocks match.'
