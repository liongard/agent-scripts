# Masking tests for EXE Advanced's proxy-credential helpers (#5).
# Usage: pwsh -NoProfile -File tests/Test-ProxyMasking.ps1 [-Script <path to LGAgentInstall-EXE-Advanced.ps1>]
# Loads the functions from the script's AST, so the tests always run against the real code.
# The keys, secrets and passwords below are fake test values.
param([string]$Script = (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'windows') 'LGAgentInstall-EXE-Advanced.ps1'))

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script), [ref]$null, [ref]$null)
foreach ($name in 'Hide-ProxyCredential', 'Mask-ProxyValue', 'Hide-LiongardSecretText', 'Hide-LiongardLogSecret') {
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Function $name not found in $Script" }
    Invoke-Expression $fn.Extent.Text
}
$pattern = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:LiongardSecretPattern' }, $true) | Select-Object -First 1
Invoke-Expression $pattern.Extent.Text
$script:LiongardDeploy = @{ Secrets = @('SuperSecret99', 'AKID1234') }

$cases = @(
    # Input, expected output of Hide-ProxyCredential
    @('http://user:pass@proxy:8080',                     'http://user:****@proxy:8080'),
    @('https://user:pass@proxy:8443',                    'https://user:****@proxy:8443'),
    @('socks5://user:pass@proxy:1080',                   'socks5://user:****@proxy:1080'),
    @('user:pass@proxy:3128',                            'user:****@proxy:3128'),
    @('http://proxy:8080',                               'http://proxy:8080'),
    @('proxy:8080',                                      'proxy:8080'),
    @('',                                                ''),
    @('socks5://a:b@h:1, https://c:d@e:2',               'socks5://a:****@h:1, https://c:****@e:2'),
    @('http://a:b@h:1;https://c:d@e:2',                  'http://a:****@h:1;https://c:****@e:2'),
    @('http://u:p%40ss@proxy:8080',                      'http://u:****@proxy:8080'),
    # Raw @ in the password: the last @ before the host is the separator.
    @('http://u:p@ss@proxy:8080',                        'http://u:****@proxy:8080'),
    @('u:p@ss@proxy:8080',                               'u:****@proxy:8080'),
    @('http://u:a@b@c@proxy:8080',                       'http://u:****@proxy:8080'),
    @('http://u:@@proxy:8080',                           'http://u:****@proxy:8080'),
    @('http://u:p@ss@h:1, https://v:q@r@e:2',            'http://u:****@h:1, https://v:****@e:2'),
    @('http://u:p@ss@proxy:8080/path@x',                 'http://u:****@proxy:8080/path@x'),
    @('Its value is ''http://bob:pw@1@proxy:8080''.',    'Its value is ''http://bob:****@proxy:8080''.'),
    @('PROXYURL = http://bob:p@ss@proxy:8080 rest',      'PROXYURL = http://bob:****@proxy:8080 rest'),
    # Not credentials: must stay unchanged.
    @('Contact: admin@example.com',                      'Contact: admin@example.com'),
    @('Time 10:30 at host',                              'Time 10:30 at host')
)

$fail = 0
foreach ($c in $cases) {
    $got = Hide-ProxyCredential -Text $c[0]
    if ($got -cne $c[1]) { $fail++; Write-Output ("FAIL  [{0}] -> [{1}], expected [{2}]" -f $c[0], $got, $c[1]) }
    else { Write-Output ("ok    [{0}] -> [{1}]" -f $c[0], $got) }
}

# The password text must never survive, wherever it is used.
foreach ($value in 'http://u:p@ss@proxy:8080', 'http://u:QaPass123@proxy:8080', 'http://u:Qa@Pass@123@proxy:8080') {
    $password = ($value -replace '^[a-z0-9]+://', '') -replace '^[^:]+:', '' -replace '@[^@]*$', ''
    foreach ($out in (Mask-ProxyValue -Value $value), (Hide-LiongardLogSecret -Line "PROXYURL = $value")) {
        if ($out.Contains($password)) { $fail++; Write-Output "FAIL  password [$password] survives in [$out]" }
        else { Write-Output "ok    no password in [$out]" }
    }
}
if ((Mask-ProxyValue -Value '') -ne '<empty>') { $fail++; Write-Output 'FAIL  Mask-ProxyValue empty' } else { Write-Output 'ok    Mask-ProxyValue empty' }
$line = Hide-LiongardLogSecret -Line 'LIONGARDACCESSSECRET=SuperSecret99 PROXYURL=http://u:p@ss@h:1'
if ($line -ne 'LIONGARDACCESSSECRET=**** PROXYURL=http://u:****@h:1') { $fail++; Write-Output "FAIL  log line [$line]" } else { Write-Output "ok    log line [$line]" }

Write-Output ("{0} failure(s)" -f $fail)
exit $fail
