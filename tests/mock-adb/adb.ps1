# Mock adb for Pester tests. Put this folder first on PATH.
# Never talks to a device. Logs every call to $env:MOCK_ADB_LOG (one line per call).
#
# Env knobs:
#   MOCK_ADB_FIXTURES        folder with canned output (default: ../fixtures)
#   MOCK_ADB_LOG             file that receives one line per call
#   MOCK_ADB_STATE           device (default) | unauthorized | offline
#   MOCK_ADB_TARGET          address shown by `adb devices` (default 192.168.1.50:5555)
#   MOCK_ADB_CONNECT         ok (default) | 10060 | 10061
#   MOCK_ADB_CRLF            1 = add \r to every output line (old adb on Windows)
#   MOCK_ADB_FAIL_UNINSTALL  comma list of packages whose `pm uninstall` fails
#   MOCK_ADB_FAIL_DISABLE    comma list of packages whose `pm disable-user` fails too
#   MOCK_ADB_MEMINFO         meminfo fixture file name (default meminfo-before.txt)
#   MOCK_ADB_USERS           users fixture file name (default users.txt)
#   MOCK_ADB_CURRENT_USER    value for `am get-current-user` (default 0)
#   MOCK_ADB_SETTINGS        settings fixture (lines `<ns> <key>=<value>`); missing keys print null
#   MOCK_ADB_APPOPS          appops fixture file name (default appops-record-audio.txt)
$ErrorActionPreference = 'Stop'
$a = @($args | ForEach-Object { "$_" })
$fx = $env:MOCK_ADB_FIXTURES
if (-not $fx) { $fx = Join-Path $PSScriptRoot '..\fixtures' }
if ($env:MOCK_ADB_LOG) { Add-Content -LiteralPath $env:MOCK_ADB_LOG -Value ($a -join ' ') }

function Write-Line([string[]]$Lines) {
    foreach ($l in $Lines) {
        if ($env:MOCK_ADB_CRLF -eq '1') { "$l`r" } else { $l }
    }
}
function Get-Fixture([string]$Name) { Get-Content -LiteralPath (Join-Path $fx $Name) }
function Test-InList([string]$Pkg, [string]$List) { $List -and (($List -split ',') -contains $Pkg) }

# Drop global options: -s <serial>
$i = 0
while ($i -lt $a.Count -and $a[$i] -eq '-s') { $i += 2 }
$rest = @($a | Select-Object -Skip $i)
$verb = if ($rest.Count) { $rest[0] } else { '' }

switch ($verb) {
    'version' { Write-Line 'Android Debug Bridge version 1.0.41 (mock)'; exit 0 }
    'connect' {
        switch ($env:MOCK_ADB_CONNECT) {
            '10060' { Write-Line "failed to connect to '$($rest[1])': A connection attempt failed (10060)"; exit 1 }
            '10061' { Write-Line "failed to connect to '$($rest[1])': No connection could be made because the target machine actively refused it. (10061)"; exit 1 }
            default { Write-Line "connected to $($rest[1])"; exit 0 }
        }
    }
    'get-state' {
        $s = if ($env:MOCK_ADB_STATE) { $env:MOCK_ADB_STATE } else { 'device' }
        if ($s -eq 'device') { Write-Line 'device'; exit 0 }
        [Console]::Error.WriteLine("error: device $s"); exit 1
    }
    'devices' {
        $s = if ($env:MOCK_ADB_STATE) { $env:MOCK_ADB_STATE } else { 'device' }
        $t = if ($env:MOCK_ADB_TARGET) { $env:MOCK_ADB_TARGET } else { '192.168.1.50:5555' }
        Write-Line @('List of devices attached', "$t`t$s", ''); exit 0
    }
    'reboot' { exit 0 }
    'shell' { }
    default { [Console]::Error.WriteLine("mock adb: unsupported: $($a -join ' ')"); exit 1 }
}

# adb shell: the device sees one command line
$cmd = (@($rest | Select-Object -Skip 1)) -join ' '
$w = @($cmd -split '\s+' | Where-Object { $_ })

if ($cmd -match '^pm list users') { Write-Line (Get-Fixture $(if ($env:MOCK_ADB_USERS) { $env:MOCK_ADB_USERS } else { 'users.txt' })); exit 0 }
if ($cmd -match '^am get-current-user') { Write-Line $(if ($env:MOCK_ADB_CURRENT_USER) { $env:MOCK_ADB_CURRENT_USER } else { '0' }); exit 0 }
if ($cmd -match '^pm list packages') { Write-Line (Get-Fixture 'packages.txt'); exit 0 }
if ($cmd -match '^dumpsys meminfo') { Write-Line (Get-Fixture $(if ($env:MOCK_ADB_MEMINFO) { $env:MOCK_ADB_MEMINFO } else { 'meminfo-before.txt' })); exit 0 }
if ($cmd -match '^dumpsys appops') { Write-Line (Get-Fixture $(if ($env:MOCK_ADB_APPOPS) { $env:MOCK_ADB_APPOPS } else { 'appops-record-audio.txt' })); exit 0 }
if ($cmd -match '^getprop ro\.product\.name') { Write-Line 'G07_4K_GB_NF'; exit 0 }
if ($cmd -match '^getprop ro\.product\.device') { Write-Line 'mock_device'; exit 0 }
if ($cmd -match '^getprop ro\.build\.fingerprint') { Write-Line 'TCL/mock/mock:11/RP1A.200622.001/AR17:user/release-keys'; exit 0 }
if ($cmd -match '^settings get (\w+) (\w+)') {
    $key = "$($Matches[1]) $($Matches[2])="; $val = 'null'
    if ($env:MOCK_ADB_SETTINGS) {
        $hit = @(Get-Fixture $env:MOCK_ADB_SETTINGS | Where-Object { $_.StartsWith($key) } | Select-Object -First 1)
        if ($hit.Count) { $val = $hit[0].Substring($key.Length) }
    }
    Write-Line $val; exit 0
}
if ($cmd -match '^settings (put|delete) ') { exit 0 }
if ($cmd -match '^pm uninstall') {
    $pkg = $w[-1]
    if (Test-InList $pkg $env:MOCK_ADB_FAIL_UNINSTALL) { Write-Line 'Failure [DELETE_FAILED_INTERNAL_ERROR]'; exit 0 }
    Write-Line 'Success'; exit 0
}
if ($cmd -match '^pm disable-user') {
    $pkg = $w[-1]
    if (Test-InList $pkg $env:MOCK_ADB_FAIL_DISABLE) { Write-Line "Error: java.lang.SecurityException: Cannot disable a protected package: $pkg"; exit 255 }
    Write-Line "Package $pkg new state: disabled-user"; exit 0
}
if ($cmd -match '^(cmd package|pm) install-existing') { Write-Line "Package $($w[-1]) installed for user: 0"; exit 0 }
if ($cmd -match '^pm enable') { Write-Line "Package $($w[-1]) new state: enabled"; exit 0 }
exit 0
