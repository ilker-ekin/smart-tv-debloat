# Pester 5+ tests for scripts/tv-debloat.ps1. Never touches a real TV:
# tests/mock-adb is put first on PATH and every adb call is logged.
#   Invoke-Pester tests/tv-debloat.Tests.ps1 -Output Detailed

BeforeAll {
    $Repo = Split-Path -Parent $PSScriptRoot
    $Script = Join-Path $Repo 'scripts\tv-debloat.ps1'
    $MockDir = Join-Path $Repo 'tests\mock-adb'
    $Mutating = '(pm uninstall|pm disable-user|pm enable|install-existing|settings put|settings delete|reboot)'

    # Runs the script in a child Windows PowerShell / pwsh with the mock adb.
    # $Stdin: answers for the y/N prompts, one per line. Returns output, exit code, adb log.
    function Invoke-Debloat {
        param([string[]]$ScriptArgs, [hashtable]$MockEnv = @{}, [string]$Stdin = '', [string]$ScriptPath = $Script)
        $work = Join-Path ([IO.Path]::GetTempPath()) ("tcl-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work | Out-Null
        $log = Join-Path $work 'adb.log'
        $saved = @{}
        $vars = @{ PATH = "$MockDir;$env:PATH"; MOCK_ADB_LOG = $log } + $MockEnv
        foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
        $exe = (Get-Process -Id $PID).Path
        Push-Location $work
        try {
            $out = $Stdin | & $exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ScriptArgs 2>&1
            $code = $LASTEXITCODE
        } finally {
            Pop-Location
            foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        [pscustomobject]@{
            Out  = ($out | ForEach-Object { "$_" }) -join "`n"
            Code = $code
            Log  = @(if (Test-Path $log) { Get-Content $log })
            Dir  = $work
            Restore = @(Get-ChildItem (Join-Path $work 'reports') -Filter 'restore-*.ps1' -ErrorAction SilentlyContinue)
        }
    }
}

Describe 'dry run' {
    It 'makes zero mutating adb calls and writes no files' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-DryRun', '-Yes') -Stdin "y`ny`ny"
        $r.Code | Should -Be 0
        @($r.Log | Where-Object { $_ -match $Mutating }) | Should -BeNullOrEmpty
        $r.Log | Should -Not -BeNullOrEmpty   # it did talk to the (mock) TV
        Test-Path (Join-Path $r.Dir 'reports') | Should -BeFalse
        $r.Out | Should -Match 'would remove com.tcl.guard'
    }
}

Describe 'denylist' {
    It 'refuses a denylisted package even if the package list offers it' {
        $tsv = Join-Path ([IO.Path]::GetTempPath()) "evil-$([guid]::NewGuid().ToString('N')).tsv"
        Set-Content $tsv -Encoding UTF8 -Value @(
            "kind`tpackage`ttier`trisk`tname`tbreaks`tverified_on`tdescription"
            "pkg`tcom.tcl.tv`t1`tsafe`tLive TV`t`t`t"
            "pkg`tcom.google.android.apps.tv.launcherx`t1`tsafe`tHome`t`t`t"
            "pkg`tcom.tcl.guard`t1`tsafe`tTCL Guard`t`t`t"
        )   # note: no 'deny' rows, so only the hardcoded list can catch these
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Yes', '-PackagesFile', $tsv)
        $r.Out | Should -Match 'REFUSED com\.tcl\.tv'
        $r.Out | Should -Match 'REFUSED com\.google\.android\.apps\.tv\.launcherx'
        @($r.Log | Where-Object { $_ -match 'uninstall.*(com\.tcl\.tv$|launcherx)' }) | Should -BeNullOrEmpty
        @($r.Log | Where-Object { $_ -match 'uninstall.*com\.tcl\.guard' }).Count | Should -Be 1
    }
}

Describe 'CRLF output from adb' {
    It 'still detects installed packages and parses meminfo' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Tier', '1', '-Yes') -MockEnv @{ MOCK_ADB_CRLF = '1' }
        $r.Code | Should -Be 0
        @($r.Log | Where-Object { $_ -match 'uninstall.*com\.tcl\.guard$' }).Count | Should -Be 1
        $before = Get-ChildItem (Join-Path $r.Dir 'reports') -Filter '*-before.txt' | Get-Content
        $before | Should -Contain 'metric Free RAM: 656576K'
        $before | Should -Contain 'metric Truly free: 161364K'
        $before | Should -Contain 'com.tcl.guard'
        ($before -join '') | Should -Not -Match "`r"
    }
}

Describe 'multiple Android users' {
    It 'warns when the TV has more than one user' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-DryRun', '-Tier', '1', '-Yes')
        $r.Out | Should -Match 'WARNING: this TV has 2 Android users \(0, 10\)'
    }
    It 'does not warn with a single user' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-DryRun', '-Tier', '1', '-Yes') -MockEnv @{ MOCK_ADB_USERS = 'users-single.txt' }
        $r.Out | Should -Not -Match 'WARNING: this TV has'
    }
    It 'defaults to the current user and honours -User' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Tier', '1', '-Yes') -MockEnv @{ MOCK_ADB_CURRENT_USER = '10' }
        @($r.Log | Where-Object { $_ -match 'pm uninstall -k --user 10 com\.tcl\.guard' }).Count | Should -Be 1
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Tier', '1', '-Yes', '-User', '0') -MockEnv @{ MOCK_ADB_CURRENT_USER = '10' }
        @($r.Log | Where-Object { $_ -match 'pm uninstall -k --user 0 com\.tcl\.guard' }).Count | Should -Be 1
    }
    It 'rejects a user id that does not exist' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Tier', '1', '-Yes', '-User', '7')
        $r.Code | Should -Be 2
        @($r.Log | Where-Object { $_ -match $Mutating }) | Should -BeNullOrEmpty
    }
}

Describe 'restore file' {
    BeforeAll {
        $script:R = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Tier', '1', '-Yes') -MockEnv @{
            MOCK_ADB_FAIL_UNINSTALL = 'com.tcl.esticker,com.tcl.browser'
            MOCK_ADB_FAIL_DISABLE   = 'com.tcl.browser'
        }
        $script:Lines = @(Get-Content $script:R.Restore[0].FullName)
    }
    It 'writes exactly one restore file' { $script:R.Restore.Count | Should -Be 1 }
    It 'records install-existing for uninstalled packages' {
        $script:Lines | Should -Contain 'adb -s 192.168.1.50:5555 shell cmd package install-existing --user 0 com.tcl.guard'
    }
    It 'falls back to disable-user and records pm enable' {
        @($script:R.Log | Where-Object { $_ -match 'disable-user --user 0 com\.tcl\.esticker' }).Count | Should -Be 1
        $script:Lines | Should -Contain 'adb -s 192.168.1.50:5555 shell pm enable --user 0 com.tcl.esticker'
    }
    It 'reports a package that could be neither removed nor disabled as failed' {
        ($script:Lines -join "`n") | Should -Not -Match 'com\.tcl\.browser'
        $script:R.Out | Should -Match 'failed: com\.tcl\.browser'
        $script:R.Code | Should -Be 1
    }
    It 'records how to undo the animation tweak' {
        $script:Lines | Should -Contain 'adb -s 192.168.1.50:5555 shell settings delete global window_animation_scale'
    }
    It 'skips packages that are not installed' {
        @($script:R.Log | Where-Object { $_ -match 'uninstall.*com\.tcl\.smartalexa' }) | Should -BeNullOrEmpty
    }
}

Describe '-Restore' {
    It 'replays only known undo commands and ignores anything else' {
        $f = Join-Path ([IO.Path]::GetTempPath()) "restore-$([guid]::NewGuid().ToString('N')).ps1"
        Set-Content $f -Encoding UTF8 -Value @(
            '# comment'
            'adb -s 192.168.1.50:5555 shell cmd package install-existing --user 0 com.tcl.guard'
            'adb -s 192.168.1.50:5555 shell pm enable --user 0 com.tcl.esticker'
            'adb -s 192.168.1.50:5555 shell rm -rf /sdcard'
            'Remove-Item C:\ -Recurse'
        )
        $r = Invoke-Debloat -ScriptArgs @('-Restore', $f)
        $r.Code | Should -Be 0
        @($r.Log | Where-Object { $_ -match 'install-existing --user 0 com\.tcl\.guard' }).Count | Should -Be 1
        @($r.Log | Where-Object { $_ -match 'pm enable --user 0 com\.tcl\.esticker' }).Count | Should -Be 1
        @($r.Log | Where-Object { $_ -match 'rm -rf' }) | Should -BeNullOrEmpty
    }
}

Describe 'prompts' {
    It 'always asks for tier 3, even with -Yes' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Yes') -Stdin "n`nn`nn`nn"
        @($r.Log | Where-Object { $_ -match 'uninstall.*com\.google\.android\.katniss' }) | Should -BeNullOrEmpty
        @($r.Log | Where-Object { $_ -match 'uninstall.*com\.tcl\.guard' }).Count | Should -Be 1
    }
    It 'treats no answer (closed stdin) as No' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Tier', '1')
        @($r.Log | Where-Object { $_ -match 'pm uninstall' }) | Should -BeNullOrEmpty
    }
    It 'reads several answers in a row (adb never swallows them)' {
        # Tier 3 installed in the fixture: katniss, disneyplus. Answer yes to both.
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Yes') -Stdin "y`ny`ny`ny"
        @($r.Log | Where-Object { $_ -match 'uninstall.*(katniss|disneyplus)' }).Count | Should -Be 2
    }
    It 'honours -Keep, including a single comma-separated string from cmd' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Tier', '1', '-Yes', '-Keep', 'com.tcl.guard,com.tcl.browser')
        @($r.Log | Where-Object { $_ -match 'uninstall.*(com\.tcl\.guard|com\.tcl\.browser)' }) | Should -BeNullOrEmpty
        @($r.Log | Where-Object { $_ -match 'uninstall.*com\.tcl\.esticker' }).Count | Should -Be 1
    }
}

Describe 'connection errors' {
    It 'explains 10060 (wrong IP)' {
        $r = Invoke-Debloat -ScriptArgs @('192.16.1.50') -MockEnv @{ MOCK_ADB_CONNECT = '10060' }
        $r.Code | Should -Be 3
        $r.Out | Should -Match 'typos'
    }
    It 'explains 10061 (debugging off)' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50') -MockEnv @{ MOCK_ADB_CONNECT = '10061' }
        $r.Code | Should -Be 3
        $r.Out | Should -Match 'Network debugging'
    }
    It 'explains unauthorized' {
        $r = Invoke-Debloat -ScriptArgs @('192.168.1.50') -MockEnv @{ MOCK_ADB_STATE = 'unauthorized' }
        $r.Code | Should -Be 3
        $r.Out | Should -Match 'Always allow'
    }
}

Describe '-Measure' {
    It 'writes a before snapshot and, after, prints a diff table' {
        $work = Join-Path ([IO.Path]::GetTempPath()) ("tcl-measure-" + [guid]::NewGuid().ToString('N'))
        $b = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Measure', 'before', '-ReportsDir', $work)
        $b.Code | Should -Be 0
        @($b.Log | Where-Object { $_ -match $Mutating }) | Should -BeNullOrEmpty
        Start-Sleep -Milliseconds 1100   # distinct timestamp
        $a = Invoke-Debloat -ScriptArgs @('192.168.1.50', '-Measure', 'after', '-ReportsDir', $work) -MockEnv @{ MOCK_ADB_MEMINFO = 'meminfo-synthetic-after.txt' }
        $a.Out | Should -Match 'Free RAM\s+656,576K\s+900,000K\s+\+243,424K'
        $a.Out | Should -Match 'Truly free\s+161,364K\s+250,000K\s+\+88,636K'
    }
}

Describe '-List' {
    It 'shows the catalog without a TV' {
        $r = Invoke-Debloat -ScriptArgs @('-List')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'com\.tcl\.guard'
        $r.Log | Should -BeNullOrEmpty
    }
}

