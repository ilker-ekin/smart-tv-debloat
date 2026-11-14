<#
.SYNOPSIS
    Read-only privacy audit of an Android TV / Google TV over ADB (verified on TCL). Changes NOTHING on the TV.

.DESCRIPTION
    Same 11 sections as privacy-audit.bat, plus a "Findings" summary on top.
    Writes reports\<timestamp>-privacy.txt (git-ignored: it describes your TV; don't publish it).
    See docs\PRIVACY.md for how to read each section.

    Every adb call is a read (getprop, settings get, dumpsys, pm list, cmd appops query-op).
    Output is filtered on the PC, not with grep on the TV, so no nested quotes are needed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\privacy-audit.ps1 192.168.1.50
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Ip,
    [int] $Port = 5555,
    [string] $ReportsDir = 'reports',
    [switch] $Help
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Packages expected to have microphone access on an Android / Google TV (voice search).
$ExpectedMic = @(
    'com.google.android.katniss'          # Google Assistant / voice search
    'com.google.android.tv.assistant'
    'com.tcl.assistant'
    'com.tcl.micmanager'                  # remote mic routing
    'com.google.android.youtube.tv'       # YouTube voice search
)

$Script:Target = $null
function Fail([string]$Msg, [int]$Code = 1) { Write-Host "ERROR: $Msg" -ForegroundColor Red; exit $Code }

function Invoke-Adb {
    # `$null |`: adb gets an empty stdin and can never swallow the console's input.
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $AdbArgs)
    $all = @(); if ($Script:Target) { $all += @('-s', $Script:Target) }; $all += $AdbArgs
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = $null | & adb @all 2>&1 } finally { $ErrorActionPreference = $old }
    @($out | ForEach-Object { "$_".TrimEnd("`r") })
}
function Invoke-TvShell { param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Cmd) Invoke-Adb shell @Cmd }
function Get-Setting([string]$Ns, [string]$Key) { ((Invoke-TvShell settings get $Ns $Key) -join '').Trim() }
function Test-Unset([string]$Value) { $Value -eq '' -or $Value -eq 'null' }

function Connect-Tv {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Fail "'adb' was not found. See docs\WALKTHROUGH.md (Install ADB)." }
    if (-not $Ip) { Fail 'give the TV address, e.g. privacy-audit.ps1 192.168.1.50' 2 }
    $addr = if ($Ip -match ':\d+$') { $Ip } else { "${Ip}:$Port" }
    $out = (Invoke-Adb connect $addr) -join ' '
    if ($out -match '10060') { Fail "timeout reaching $addr (10060). Check the IP for typos and that PC and TV are on the same network." 3 }
    if ($out -match '10061|refused') { Fail "$addr refused the connection (10061). Turn on Network debugging / USB debugging on the TV." 3 }
    if ($out -match 'failed|cannot|unable') { Fail "could not connect to ${addr}: $out" 3 }
    $state = ''
    foreach ($l in (Invoke-Adb devices)) { if ($l -match ('^' + [regex]::Escape($addr) + '\s+(\S+)')) { $state = $Matches[1] } }
    $Script:Target = $addr
    if ($state -eq 'unauthorized') { Fail 'the TV has not accepted this PC yet. Pick "Always allow" on the TV prompt, then run again.' 3 }
    if ($state -ne 'device') { Fail "TV not ready (state: $state)." 3 }
}

function ConvertTo-Ago([string]$Rel) {
    # appops prints the time since the last access as e.g. "-225d21h26m3s120ms".
    # It means "225 days, 21 hours, 26 minutes ago". It is the LAST access, not a recording.
    $parts = @()
    if ($Rel -match '(\d+)d') { $parts += "$($Matches[1]) day$(if ($Matches[1] -ne '1') { 's' })" }
    if ($Rel -match '(\d+)h') { $parts += "$($Matches[1]) hour$(if ($Matches[1] -ne '1') { 's' })" }
    if ($parts.Count -lt 2 -and $Rel -match '(\d+)m(?!s)') { $parts += "$($Matches[1]) min" }
    if (-not $parts.Count) { return 'less than a minute ago' }
    ($parts -join ', ') + ' ago'
}

function Get-MicUse([string[]]$Appops) {
    # Parse `dumpsys appops --op RECORD_AUDIO`: one entry per package with a RECORD_AUDIO block.
    $res = @(); $pkg = $null; $cur = $null
    foreach ($l in $Appops) {
        if ($l -match '^\s*Package (\S+):') { $pkg = $Matches[1]; $cur = $null; continue }
        if ($pkg -and $l -match '^\s*RECORD_AUDIO \((\w+)\):') {
            $cur = [pscustomobject]@{ Package = $pkg; Mode = $Matches[1]; LastAccess = ''; Running = $false }
            $res += $cur; continue
        }
        if ($cur -and $l -match '^\s*Access:.*\((-[0-9dhms]+)\)') { if (-not $cur.LastAccess) { $cur.LastAccess = $Matches[1] } }
        if ($cur -and $l -match '^\s*Running') { $cur.Running = $true }
    }
    $res
}

if ($Help) { Get-Help -Detailed $PSCommandPath | Out-Host; exit 0 }
Connect-Tv

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$findings = New-Object System.Collections.Generic.List[string]
function Add-Finding([string]$Level, [string]$Area, [string]$Text) { $findings.Add(('{0,-6} {1,-14} {2}' -f $Level, $Area, $Text)) }

# ---- collect (all reads)
$appops = @(Invoke-TvShell dumpsys appops '--op' RECORD_AUDIO)   # @(): empty output stays an array
$mic = @(Get-MicUse $appops)
$audio = @(Invoke-TvShell dumpsys audio)
$pkgs = @(Invoke-TvShell pm list packages | ForEach-Object { $_ -replace '^package:', '' })
$users = @(Invoke-TvShell pm list users | Where-Object { $_ -match 'UserInfo\{' })
$s = [ordered]@{
    assistant           = Get-Setting secure assistant
    voice_interaction   = Get-Setting secure voice_interaction_service
    voice_recognition   = Get-Setting secure voice_recognition_service
    accessibility       = Get-Setting secure enabled_accessibility_services
    notif_listeners     = Get-Setting secure enabled_notification_listeners
    location_mode       = Get-Setting secure location_mode
    adb_enabled         = Get-Setting global adb_enabled
    adb_wifi_enabled    = Get-Setting global adb_wifi_enabled
}

# ---- findings
foreach ($m in $mic) {
    $when = if ($m.LastAccess) { 'last used ' + (ConvertTo-Ago $m.LastAccess) } else { 'no recorded use' }
    if ($m.Running) { Add-Finding 'REVIEW' 'microphone' "$($m.Package): appops reports the mic op as RUNNING now ($when)" }
    elseif ($ExpectedMic -contains $m.Package) { Add-Finding 'OK' 'microphone' "$($m.Package) (voice search, $($m.Mode)): $when" }
    else { Add-Finding 'REVIEW' 'microphone' "$($m.Package) is not a known voice app but has mic access ($($m.Mode)): $when" }
}
if (-not $mic.Count) { Add-Finding 'OK' 'microphone' 'no app has a RECORD_AUDIO history' }
Add-Finding 'INFO' 'recording now' 'check section 3 by hand: with nobody holding the mic button it should list no active recording'
Add-Finding 'INFO' 'remote mic' "the remote's mic is Bluetooth push-to-talk; ADB can't see its hardware, only audio Android receives"
if (Test-Unset $s.accessibility) { Add-Finding 'OK' 'accessibility' 'no accessibility services enabled' }
else { Add-Finding 'REVIEW' 'accessibility' "enabled: $($s.accessibility) (expected only if you set up e.g. Projectivy's launcher override)" }
if (Test-Unset $s.notif_listeners) { Add-Finding 'OK' 'notifications' 'no notification listeners' }
else { Add-Finding 'REVIEW' 'notifications' "listeners: $($s.notif_listeners)" }
if ($s.location_mode -eq '0') { Add-Finding 'OK' 'location' 'location is off' }
elseif (Test-Unset $s.location_mode) { Add-Finding 'INFO' 'location' 'location_mode not reported by this firmware' }
else { Add-Finding 'REVIEW' 'location' "location is on (mode $($s.location_mode)); a TV doesn't need it" }
if ($users.Count -gt 1) { Add-Finding 'INFO' 'users' "$($users.Count) Android users on this TV; apps removed for one user stay for the others" }
if ($s.adb_enabled -eq '1') { Add-Finding 'WARN' 'debugging' 'ADB is on (needed for this audit). Turn it OFF when you are done: anyone on your Wi-Fi gets full control' }

# ---- report
$r = New-Object System.Collections.Generic.List[string]
function Add-Section([string]$Title, $Lines) {
    $r.Add(''); $r.Add("===== $Title =====")
    $l = @($Lines | Where-Object { "$_".Trim() })
    if ($l.Count) { foreach ($x in $l) { $r.Add("$x") } } else { $r.Add('(nothing)') }
}
$r.Add("Android TV privacy audit  $ts  (read-only: nothing on the TV was changed)")
$r.Add("Device: $((Invoke-TvShell getprop ro.product.name) -join '')")
$r.Add("Build:  $((Invoke-TvShell getprop ro.build.fingerprint) -join '')")
$r.Add(''); $r.Add('===== FINDINGS =====')
foreach ($f in $findings) { $r.Add($f) }
$r.Add('How to read times: "(-225d21h26m...)" = the LAST time the app used the mic, 225 days 21 hours ago.')
$r.Add('It is a timestamp of when the app last opened the mic, not a recording.')

Add-Section '1. Apps ALLOWED to use the microphone (RECORD_AUDIO app-op)' (@(Invoke-TvShell cmd appops query-op RECORD_AUDIO allow) + '--- foreground-only ---' + @(Invoke-TvShell cmd appops query-op RECORD_AUDIO foreground))
Add-Section '2. Recent microphone ACCESS history (who actually used it, and when)' ($appops | Where-Object { $_ -match 'Package|Access|Reject|Running' })
$recIdx = -1; for ($i = 0; $i -lt $audio.Count; $i++) { if ($audio[$i] -match 'RecordActivityMonitor') { $recIdx = $i; break } }
Add-Section '3. Is anything recording RIGHT NOW?' $(if ($recIdx -ge 0) { $audio[$recIdx..([Math]::Min($recIdx + 8, $audio.Count - 1))] } else { @('RecordActivityMonitor not found in dumpsys audio on this firmware') })
Add-Section '4. Voice assistant / hotword services' @(
    "assistant: $($s.assistant)"
    "voice_interaction_service: $($s.voice_interaction)"
    "voice_recognition_service: $($s.voice_recognition)"
    'hotword / always-on packages installed:'
    ($pkgs | Where-Object { $_ -match '(?i)hotword|alexa|katniss|assistant|micmanager|voice' })
)
Add-Section '5. Accessibility services (can read the screen)' @($s.accessibility)
Add-Section '6. Notification listeners' @($s.notif_listeners)
Add-Section '7. Device admins / device owner' (Invoke-TvShell dumpsys device_policy | Where-Object { $_ -match '(?i)admin|owner' })
Add-Section '8. Third-party apps and who installed them' (Invoke-TvShell pm list packages '-3' '-i')
Add-Section '9. Apps allowed to install other apps (unknown sources)' (Invoke-TvShell cmd appops query-op REQUEST_INSTALL_PACKAGES allow)
Add-Section '10. Location' (@("location_mode: $($s.location_mode)") + @(Invoke-TvShell cmd appops query-op COARSE_LOCATION allow))
Add-Section '11. Debugging left on? (turn OFF when done)' @("adb_enabled: $($s.adb_enabled)", "adb_wifi_enabled: $($s.adb_wifi_enabled)")
Add-Section 'Android users' $users

if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }
$file = Join-Path $ReportsDir "$ts-privacy.txt"
Set-Content -LiteralPath $file -Value $r -Encoding UTF8

foreach ($line in $r) {
    $c = switch -Regex ($line) { '^REVIEW' { 'Yellow' } '^WARN' { 'Yellow' } '^OK' { 'Green' } '^=====' { 'Cyan' } default { '' } }
    if ($c) { Write-Host $line -ForegroundColor $c } else { Write-Host $line }
}
Write-Host ''
Write-Host "Saved to $file. Nothing on the TV was changed. Don't publish this file." -ForegroundColor Green
exit 0
