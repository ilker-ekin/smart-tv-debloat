<#
.SYNOPSIS
    Debloat and speed up an Android TV / Google TV over ADB (verified on TCL). No root, fully reversible.

.DESCRIPTION
    Removes preinstalled packages for one Android user with `pm uninstall -k --user N`
    (the APK stays on /system, so a factory reset or the restore file brings it back).
    Falls back to `pm disable-user` when uninstall is refused. Every change appends its
    undo command to reports\restore-<timestamp>.ps1.

    Package list: ..\packages.tsv (generated from packages.yaml). PowerShell 5.1 has no
    built-in YAML parser and we don't want users to install a module, so both scripts
    read the same generated TSV; CI keeps it in sync with the YAML.

    Works on Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\tv-debloat.ps1 192.168.1.50 -DryRun
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\tv-debloat.ps1 192.168.1.50 -Tier 1 -Yes
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\tv-debloat.ps1 192.168.1.50 -Measure after
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\tv-debloat.ps1 -Restore reports\restore-20260101-120000.ps1
#>
[CmdletBinding()]
param(
    # TV address, e.g. 192.168.1.50 (port defaults to 5555)
    [Parameter(Position = 0)] [string] $Ip,
    [int] $Port = 5555,
    # Show the package catalog (and what's installed, if -Ip is given). Changes nothing.
    [switch] $List,
    # Show what would happen. Makes no changes on the TV and writes no files.
    [switch] $DryRun,
    # Offer tiers 1..N (default 3 = all)
    [ValidateRange(1, 3)] [int] $Tier = 3,
    # Don't ask for tiers 1-2 and tweaks. Tier 3 ALWAYS asks.
    [switch] $Yes,
    # Packages to leave alone, comma separated
    [string[]] $Keep = @(),
    # Android user id. Default: the TV's current user.
    [int] $User = -1,
    # Only take a measurement: 'before' or 'after' (after prints a diff vs the latest before)
    [ValidateSet('before', 'after')] [string] $Measure,
    # Replay an undo file written by an earlier run
    [string] $Restore,
    # Run the read-only privacy audit
    [switch] $Privacy,
    [switch] $Help,
    # Advanced: alternative package list and reports folder (used by tests)
    [string] $PackagesFile,
    [string] $ReportsDir = 'reports'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# PS 5.1 leaves $PSScriptRoot empty inside param() defaults, so resolve here.
if (-not $PackagesFile) { $PackagesFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\packages.tsv' }

# Enforced in code: these are refused even if someone adds them to packages.yaml.
# Kept in sync with packages.yaml by `python tools/packages.py check` (CI).
# BEGIN DENYLIST
$Denylist = @(
    'com.google.android.apps.tv.launcherx'
    'com.google.android.tungsten.setupwraith'
    'com.google.android.gms'
    'com.google.android.gsf'
    'com.android.vending'
    'com.google.android.webview'
    'com.google.android.apps.mediashell'
    'com.android.providers.tv'
    'com.tcl.tv'
    'com.tcl.tvinput'
    'com.tcl.system.server'
    'com.tcl.settings'
    'com.tcl.dashboard'
    'com.tcl.partnercustomizer'
    'com.tcl.providers.config'
    'com.tcl.keyhelp'
    'com.tcl.autopair'
    'com.tcl.micmanager'
    'com.tcl.ui_mediaCenter'
    'com.tcl.miracast'
    'com.tcl.ttvs'
    'com.tcl.suspension'
    'com.tcl.factory.view'
    'com.tcl.initsetup'
    'com.tcl.useragreement'
    'com.tvos'
    'com.android.systemui'
    'com.android.tv.settings'
)
# END DENYLIST

$AnimationKeys = @('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale')
$Script:Target = $null
$Script:RestoreFile = $null
$Script:Summary = [ordered]@{ removed = @(); disabled = @(); skipped = @(); failed = @(); refused = @() }

function Say([string]$Msg, [string]$Color = '') {
    if ($Color) { Write-Host $Msg -ForegroundColor $Color } else { Write-Host $Msg }
}
function Fail([string]$Msg, [int]$Code = 1) {
    Write-Host "ERROR: $Msg" -ForegroundColor Red
    exit $Code
}

function Invoke-Adb {
    # Returns output lines with CR stripped (old adb on Windows emits CRLF).
    # `$null |` gives adb an empty stdin so it can never swallow the script's input
    # (the cmd paste bug from the walkthrough, and our own Read-Host answers).
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $AdbArgs)
    $all = @()
    if ($Script:Target) { $all += @('-s', $Script:Target) }
    $all += $AdbArgs
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # PS 5.1 turns native stderr into errors
    try {
        $out = $null | & adb @all 2>&1
        $Script:AdbExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    @($out | ForEach-Object { "$_".TrimEnd("`r") })
}
function Invoke-TvShell { param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Cmd) Invoke-Adb shell @Cmd }

function Read-YesNo([string]$Question) {
    try { $a = Read-Host "$Question [y/N]" } catch { $a = '' }
    return ("$a".Trim() -match '^(y|yes)$')
}

function Show-Help {
    Get-Help -Detailed $PSCommandPath | Out-Host
    Say 'Flags (bash script equivalents in brackets):'
    Say '  -List [--list]   -DryRun [--dry-run]   -Tier N [--tier N]   -Yes [--yes]'
    Say '  -Keep a,b [--keep a,b]   -User N [--user N]   -Port N [--port N]'
    Say '  -Measure before|after [--measure]   -Restore FILE [--restore]   -Privacy [--privacy]'
}

function Read-Catalog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Fail "package list not found: $Path" }
    $lines = Get-Content -LiteralPath $Path | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -and -not $_.StartsWith('#') }
    $rows = @($lines | ConvertFrom-Csv -Delimiter "`t")
    [pscustomobject]@{
        Packages = @($rows | Where-Object { $_.kind -eq 'pkg' })
        Deny     = @($rows | Where-Object { $_.kind -eq 'deny' } | ForEach-Object { $_.package })
    }
}

function Connect-Tv {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        Fail "'adb' was not found. Unzip Platform Tools to C:\platform-tools and run this from there, or open a NEW window after installing with winget (PATH only updates in new windows)."
    }
    if (-not $Ip) { Fail 'give the TV address, e.g. tv-debloat.ps1 192.168.1.50' 2 }
    $Script:Target = $null
    $addr = if ($Ip -match ':\d+$') { $Ip } else { "${Ip}:$Port" }
    $out = (Invoke-Adb connect $addr) -join ' '
    if ($out -match '10060') { Fail "timeout reaching $addr (10060). Check the IP for typos (e.g. 192.16.x instead of 192.168.x) and that PC and TV are on the same network." 3 }
    if ($out -match '10061|refused') { Fail "$addr refused the connection (10061). Turn on Network debugging / USB debugging on the TV, and check the port." 3 }
    if ($out -match 'failed|cannot|unable') { Fail "could not connect to ${addr}: $out" 3 }
    # `adb devices` prints the state on stdout ("<addr>\tunauthorized"); `get-state`
    # reports problems on stderr only, which is easy to lose across shells.
    $state = ''
    foreach ($l in (Invoke-Adb devices)) { if ($l -match ('^' + [regex]::Escape($addr) + '\s+(\S+)')) { $state = $Matches[1] } }
    $Script:Target = $addr
    if ($state -match 'unauthorized') { Fail 'the TV has not accepted this PC yet. Pick "Always allow" on the TV prompt, then run again.' 3 }
    if ($state -notmatch '^\s*device\s*$') { Fail "TV not ready (state: $state)." 3 }
    Say "Connected to $addr" Green
}

function Resolve-User {
    $users = @(Invoke-TvShell pm list users | ForEach-Object { if ($_ -match 'UserInfo\{(\d+):') { [int]$Matches[1] } })
    $current = (Invoke-TvShell am get-current-user | Select-Object -First 1)
    $u = if ($User -ge 0) { $User } elseif ("$current" -match '^\s*(\d+)\s*$') { [int]$Matches[1] } else { 0 }
    if ($users.Count -gt 1) {
        Say "WARNING: this TV has $($users.Count) Android users ($($users -join ', ')). Changes apply to user $u only." Yellow
        $others = @($users | Where-Object { $_ -ne $u })
        Say "         Apps stay installed for user(s) $($others -join ', '). Re-run with -User <id> to debloat those too." Yellow
    }
    if ($users.Count -and ($users -notcontains $u)) { Fail "user $u does not exist on this TV (users: $($users -join ', '))." 2 }
    $u
}

function Get-Installed([int]$U) {
    @(Invoke-TvShell pm list packages '--user' $U | ForEach-Object { if ($_ -match '^package:(.+)$') { $Matches[1].Trim() } })
}

function Get-Metric {
    $mem = Invoke-TvShell dumpsys meminfo
    $m = [ordered]@{}
    foreach ($l in $mem) {
        if ($l -match '^\s*Free RAM:\s*([\d,]+)K') { $m['Free RAM'] = [long]($Matches[1] -replace ',', '') }
        if ($l -match '\+\s*([\d,]+)K free\)') { $m['Truly free'] = [long]($Matches[1] -replace ',', '') }
        if ($l -match '^\s*Used RAM:\s*([\d,]+)K') { $m['Used RAM'] = [long]($Matches[1] -replace ',', '') }
    }
    $m
}

function Save-Snapshot([string]$Kind, [int]$U) {
    if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $ReportsDir "$ts-$Kind.txt"
    $metrics = Get-Metric
    $lines = @("# tv-debloat $Kind snapshot $ts", "model: $((Invoke-TvShell getprop ro.product.name) -join '')", "user: $U")
    foreach ($k in $metrics.Keys) { $lines += "metric ${k}: $($metrics[$k])K" }
    $lines += '# packages'
    $lines += (Get-Installed $U | Sort-Object)
    Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
    Say "Saved $Kind snapshot: $file"
    $file
}

function Read-SnapshotMetric([string]$File) {
    $m = [ordered]@{}
    foreach ($l in Get-Content -LiteralPath $File) { if ($l -match '^metric (.+): (\d+)K$') { $m[$Matches[1]] = [long]$Matches[2] } }
    $m
}

function Show-Diff([string]$BeforeFile, [string]$AfterFile) {
    $b = Read-SnapshotMetric $BeforeFile; $a = Read-SnapshotMetric $AfterFile
    $inv = [cultureinfo]::InvariantCulture   # same output as dumpsys, regardless of Windows locale
    $rows = foreach ($k in $b.Keys) {
        if (-not $a.Contains($k)) { continue }
        $d = $a[$k] - $b[$k]
        [pscustomobject]@{
            Metric = $k
            Before = $b[$k].ToString('N0', $inv) + 'K'
            After  = $a[$k].ToString('N0', $inv) + 'K'
            Change = $d.ToString('+#,0;-#,0;0', $inv) + 'K'
        }
    }
    Say "Before: $BeforeFile"; Say "After:  $AfterFile"
    $rows | Format-Table -AutoSize | Out-Host
}

function Add-Undo([string]$Line) { Add-Content -LiteralPath $Script:RestoreFile -Value $Line -Encoding UTF8 }

function Remove-Pkg($P, [int]$U) {
    $pkg = $P.package
    if ($DryRun) { Say "  [dry-run] would remove $pkg"; $Script:Summary.removed += $pkg; return }
    $res = (Invoke-TvShell pm uninstall '-k' '--user' $U $pkg) -join ' '
    if ($res -match 'Success') {
        Add-Undo "adb -s $Script:Target shell cmd package install-existing --user $U $pkg"
        $Script:Summary.removed += $pkg; Say "  removed $pkg" Green; return
    }
    Say "  uninstall refused ($res), trying disable-user" Yellow
    $res = (Invoke-TvShell pm disable-user '--user' $U $pkg) -join ' '
    if ($res -match 'new state: disabled') {
        Add-Undo "adb -s $Script:Target shell pm enable --user $U $pkg"
        $Script:Summary.disabled += $pkg; Say "  disabled $pkg" Green; return
    }
    $Script:Summary.failed += $pkg; Say "  FAILED $pkg ($res)" Red
}

function Set-AnimationTweak {
    $want = if ($Yes) { $true } else { Read-YesNo 'Apply animation scale 0.5 (snappier menus)?' }
    if (-not $want) { return }
    foreach ($k in $AnimationKeys) {
        if ($DryRun) { Say "  [dry-run] would set $k 0.5"; continue }
        $old = ((Invoke-TvShell settings get global $k) -join '').Trim()
        if ($old -match '^[\d.]+$') { Add-Undo "adb -s $Script:Target shell settings put global $k $old" }
        else { Add-Undo "adb -s $Script:Target shell settings delete global $k" }
        Invoke-TvShell settings put global $k 0.5 | Out-Null
    }
    if (-not $DryRun) { Say '  animation scale 0.5 set (reboot recommended)' Green }
}

function Invoke-Restore([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { Fail "restore file not found: $File" 2 }
    # Only replay lines we know we wrote; never execute arbitrary content from the file.
    $re = '^adb -s (\S+) shell ((cmd package install-existing|pm enable) --user \d+ [\w.]+|settings (put global \w+ [\d.]+|delete global \w+))$'
    $cmds = @(Get-Content -LiteralPath $File | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -match $re })
    if (-not $cmds.Count) { Fail "no restore commands found in $File" }
    $first = [regex]::Match($cmds[0], $re).Groups[1].Value
    if (-not $Ip) { $Script:Ip = $first }
    Connect-Tv
    $ok = 0; $bad = 0
    foreach ($c in $cmds) {
        $shellPart = ([regex]::Match($c, $re).Groups[2].Value) -split ' '
        if ($DryRun) { Say "  [dry-run] $($shellPart -join ' ')"; continue }
        $out = (Invoke-TvShell @shellPart) -join ' '
        if ($Script:AdbExit -eq 0 -and $out -notmatch 'Error|Failure') { $ok++; Say "  ok: $($shellPart -join ' ')" Green }
        else { $bad++; Say "  failed: $($shellPart -join ' ') ($out)" Red }
    }
    Say "Restore done: $ok ok, $bad failed. Reboot the TV: adb -s $Script:Target reboot"
    if ($bad) { exit 1 }
}

# ------------------------------------------------------------------ main
if ($Help) { Show-Help; exit 0 }

$keepList = @($Keep | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($Restore) { Invoke-Restore $Restore; exit 0 }

if ($Privacy) {
    $audit = Join-Path $PSScriptRoot 'privacy-audit.ps1'
    if (-not (Test-Path $audit)) { Fail "privacy-audit.ps1 not found next to this script." }
    & $audit -Ip $Ip -Port $Port
    exit $LASTEXITCODE
}

$catalog = Read-Catalog $PackagesFile
$deny = @($Denylist + $catalog.Deny | Sort-Object -Unique)

if ($List -and -not $Ip) {
    $catalog.Packages | Select-Object package, tier, risk, name, breaks | Format-Table -AutoSize | Out-Host
    exit 0
}

Connect-Tv
$u = Resolve-User

if ($Measure) {
    $file = Save-Snapshot $Measure $u
    if ($Measure -eq 'after') {
        $before = Get-ChildItem -Path $ReportsDir -Filter '*-before.txt' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($before) { Show-Diff $before.FullName $file } else { Say "No *-before.txt in $ReportsDir to compare against." Yellow }
    }
    exit 0
}

$installed = Get-Installed $u

if ($List) {
    $catalog.Packages | ForEach-Object {
        [pscustomobject]@{ Installed = $(if ($installed -contains $_.package) { 'yes' } else { '-' }); Package = $_.package; Tier = $_.tier; Risk = $_.risk; Name = $_.name }
    } | Format-Table -AutoSize | Out-Host
    exit 0
}

if ($DryRun) { Say 'DRY RUN: nothing will be changed on the TV and no files are written.' Cyan }
else {
    Save-Snapshot 'before' $u | Out-Null
    if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }
    $Script:RestoreFile = Join-Path $ReportsDir ("restore-{0}.ps1" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $Script:RestoreFile -Encoding UTF8 -Value @(
        '# Undo file written by tv-debloat.ps1. Replay with:'
        "#   powershell -ExecutionPolicy Bypass -File scripts\tv-debloat.ps1 -Restore $Script:RestoreFile"
        "# Target user: $u"
    )
}

foreach ($t in 1..$Tier) {
    $group = @($catalog.Packages | Where-Object { [int]$_.tier -eq $t })
    if (-not $group.Count) { continue }
    Say ''; Say "=== Tier $t ===" Cyan
    foreach ($p in $group) {
        $pkg = $p.package
        if ($deny -contains $pkg) { $Script:Summary.refused += $pkg; Say "  REFUSED $pkg (on the denylist)" Red; continue }
        if ($keepList -contains $pkg) { $Script:Summary.skipped += $pkg; Say "  keep    $pkg"; continue }
        if ($installed -notcontains $pkg) { $Script:Summary.skipped += $pkg; Write-Verbose "not installed: $pkg"; continue }
        $label = "$pkg  ($($p.name)$(if ($p.breaks) { "; breaks: $($p.breaks)" }))"
        $ask = (-not $Yes) -or ($t -eq 3)
        if ($ask -and -not (Read-YesNo "Remove ${label}?")) { $Script:Summary.skipped += $pkg; continue }
        if (-not $ask) { Say "  $label" }
        Remove-Pkg $p $u
    }
}

Say ''; Say '=== Tweaks ===' Cyan
Set-AnimationTweak

$s = $Script:Summary
Say ''; Say '=== Summary ===' Cyan
Say ("  {0,-9} {1}" -f $(if ($DryRun) { 'would rm' } else { 'removed' }), $s.removed.Count)
Say ("  {0,-9} {1}" -f 'disabled', $s.disabled.Count)
Say ("  {0,-9} {1}" -f 'skipped', $s.skipped.Count)
Say ("  {0,-9} {1}" -f 'failed', $s.failed.Count)
if ($s.refused.Count) { Say ("  {0,-9} {1} ({2})" -f 'refused', $s.refused.Count, ($s.refused -join ', ')) Red }
if ($s.failed.Count) { Say "  failed: $($s.failed -join ', ')" Red }
if (-not $DryRun) {
    Say "  undo:     powershell -ExecutionPolicy Bypass -File scripts\tv-debloat.ps1 -Restore $Script:RestoreFile"
    Say "  next:     adb -s $Script:Target reboot   then   -Measure after"
}
if ($s.failed.Count) { exit 1 }
exit 0
