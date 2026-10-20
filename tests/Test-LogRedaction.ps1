# Installer-log redaction tests for the "Liongard deploy-folder functions" shared block.
# Usage: pwsh -NoProfile -File tests/Test-LogRedaction.ps1
# Loads the shared block from every Windows script that has it and runs the same cases against each
# copy: Hide-LiongardSecretText on installer-log lines (ProxyUrl= values, raw @ included, access
# key/secret properties, literal secrets), then Protect-LiongardInstallerLog on real UTF-16 and UTF-8
# log files. The keys, secrets and passwords below are fake test values.
param([string]$WindowsFolder = (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows'))

$secret = 'SuperSecret99'
$key    = 'AKID1234'

$lineCases = @(
    # Input line, expected line
    @('MSI (s) (A4:B8) [10:00:01:234]: Command Line: LIONGARDACCESSSECRET=SuperSecret99 ProxyUrl="http://qauser:Qa@Pass@123@proxy.example.test:8080" ',
      'MSI (s) (A4:B8) [10:00:01:234]: Command Line: LIONGARDACCESSSECRET=**** ProxyUrl="http://qauser:****@proxy.example.test:8080" '),
    @('[1A2C:3B4D][2026-10-20T10:00:00]i000: Setting string variable ''ProxyUrl'' to value ''http://qauser:p@ss@proxy:8080''',
      '[1A2C:3B4D][2026-10-20T10:00:00]i000: Setting string variable ''ProxyUrl'' to value ''http://qauser:****@proxy:8080'''),
    @('PROPERTY CHANGE: Adding PROXYURL property. Its value is ''http://qauser:QaPass123@proxy:8080''.',
      'PROPERTY CHANGE: Adding PROXYURL property. Its value is ''http://qauser:****@proxy:8080''.'),
    @('ProxyUrl=u:p@ss@proxy:3128',                                  'ProxyUrl=u:****@proxy:3128'),
    @('ProxyUrl=https://u:p%40ss@proxy:8443',                         'ProxyUrl=https://u:****@proxy:8443'),
    @('HTTPS_PROXY=http://a:b@c@h:1;http://d:e@f:2',                  'HTTPS_PROXY=http://a:****@h:1;http://d:****@f:2'),
    @('ProxyUrl=socks5://u:x@y@proxy:1080/path@z',                    'ProxyUrl=socks5://u:****@proxy:1080/path@z'),
    @('Property(S): LIONGARDACCESSKEY = AKID1234',                    'Property(S): LIONGARDACCESSKEY = ****'),
    @('literal SuperSecret99 and AKID1234 in text',                   'literal **** and **** in text'),
    # Must stay unchanged.
    @('MSI (s) (A4:B8) [10:00:01:234]: Product: Liongard Agent -- Installation completed successfully.',
      'MSI (s) (A4:B8) [10:00:01:234]: Product: Liongard Agent -- Installation completed successfully.'),
    @('ProxyUrl=http://proxy.example.test:8080',                     'ProxyUrl=http://proxy.example.test:8080'),
    @('Folder: C:\Program Files (x86)\LiongardInc\LiongardAgent',      'Folder: C:\Program Files (x86)\LiongardInc\LiongardAgent'),
    @('Contact: support@example.test',                                'Contact: support@example.test')
)

$logText = @"
=== Verbose logging started: 10/20/2026  10:00:00  Build type: SHIP UNICODE ===
MSI (s) (A4:B8) [10:00:01:234]: Command Line: LIONGARDACCESSKEY=AKID1234 LIONGARDACCESSSECRET=SuperSecret99 ProxyUrl="http://qauser:Qa@Pass@123@proxy.example.test:8080"
PROPERTY CHANGE: Adding PROXYURL property. Its value is 'http://qauser:Qa@Pass@123@proxy.example.test:8080'.
MSI (s) (A4:B8) [10:00:09:999]: Product: Liongard Agent -- Installation completed successfully.
"@
$mustNotSurvive = 'SuperSecret99', 'AKID1234', 'Qa@Pass@123', 'Pass@123', '123@proxy'

$fail = 0
$scripts = @(Get-ChildItem -Path $WindowsFolder -Filter '*.ps1' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '# BEGIN SHARED BLOCK: Liongard deploy-folder functions' } | Sort-Object Name)
if ($scripts.Count -lt 6) { Write-Output "FAIL  expected the shared block in 6 scripts, found $($scripts.Count)"; $fail++ }
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("lg-redaction-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null

try {
    foreach ($file in $scripts) {
        $text  = Get-Content -LiteralPath $file.FullName -Raw
        $start = $text.IndexOf('# BEGIN SHARED BLOCK: Liongard deploy-folder functions')
        $endMarker = '# END SHARED BLOCK: Liongard deploy-folder functions'
        $end   = $text.IndexOf($endMarker, $start) + $endMarker.Length
        Invoke-Expression $text.Substring($start, $end - $start)
        $script:LiongardDeploy.Secrets = @($key, $secret)
        Write-Output "--- $($file.Name)"

        foreach ($c in $lineCases) {
            $got = Hide-LiongardSecretText -Text $c[0]
            if ($got -cne $c[1]) { $fail++; Write-Output ("FAIL  [{0}] -> [{1}], expected [{2}]" -f $c[0], $got, $c[1]) }
            else { Write-Output ("ok    {0}" -f $got) }
        }

        foreach ($enc in @(
            @{ Name = 'UTF-16LE with BOM'; Encoding = (New-Object System.Text.UnicodeEncoding($false, $true)) },
            @{ Name = 'UTF-8 without BOM'; Encoding = (New-Object System.Text.UTF8Encoding($false)) })) {
            $log = Join-Path $work ("AgentInstall_{0}_{1}.log" -f $file.BaseName, ($enc.Name -replace '\W', ''))
            [System.IO.File]::WriteAllText($log, $logText, $enc.Encoding)
            Protect-LiongardInstallerLog -Path $log 6>$null | Out-Null
            if (-not (Test-Path -LiteralPath $log)) { $fail++; Write-Output "FAIL  $($enc.Name): log was deleted instead of redacted"; continue }
            $after = [System.IO.File]::ReadAllText($log)
            $left  = @($mustNotSurvive | Where-Object { $after.Contains($_) })
            if ($left.Count) { $fail++; Write-Output "FAIL  $($enc.Name): still contains $($left -join ', ')" }
            elseif (-not $after.Contains('ProxyUrl="http://qauser:****@proxy.example.test:8080"') -or -not $after.Contains('Installation completed successfully.')) { $fail++; Write-Output "FAIL  $($enc.Name): unexpected content: $after" }
            else { Write-Output "ok    Protect-LiongardInstallerLog ($($enc.Name))" }
        }
    }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ("{0} failure(s)" -f $fail)
exit $fail
