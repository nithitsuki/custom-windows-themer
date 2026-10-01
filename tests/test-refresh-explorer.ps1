# Regression test: the shell-refresh machinery must NEVER kill explorer.
# Live checks (run in the interactive session):
#   1. Update-PerUserSettings / Restart-StartMenuHost must not kill explorer
#      (same PID before and after).
#   2. Refresh-Shell (the function apply/restore call) must NOT restart or kill
#      explorer at all - the theme is applied via a live broadcast. Killing the
#      shell is what triggered the recurring explorer.exe crash on this machine.
#   3. Restart-ExplorerSafe (the opt-in hard restart) must still RECOVER from a
#      dead explorer and leave it running and stable seconds later.
#
# RED first: Refresh-Shell still force-kills explorer, so step 2 fails.

param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_load-themer.ps1') -Root $Root

function Get-ExplorerPid {
    (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).Id
}
function Assert-ExplorerRunning([string]$IfAbsent) {
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        throw "FAIL: $IfAbsent - explorer is NOT running"
    }
}

Write-Host "-- 1) live refresh primitives must not kill explorer"
$beforePid = Get-ExplorerPid
if (-not $beforePid) { throw 'explorer not running before the test - cannot continue' }
Write-Host "   explorer before: PID $beforePid"
Update-PerUserSettings
Restart-StartMenuHost
Start-Sleep -Seconds 2
$afterPid = Get-ExplorerPid
if (-not $afterPid) { throw 'FAIL: the live refresh killed explorer' }
if ($afterPid -ne $beforePid) {
    throw "FAIL: PID changed ($beforePid -> $afterPid) - live refresh must not restart explorer"
}
Write-Host "   PASS: PID unchanged ($afterPid)"

Write-Host "-- 2) Refresh-Shell must NOT restart explorer (the regression)"
Stop-ExplorerWatchdog
$before2 = Get-ExplorerPid
if (-not $before2) { throw 'explorer gone before Refresh-Shell' }
Refresh-Shell
$after2Pid = Get-ExplorerPid
if (-not $after2Pid) { throw 'FAIL: Refresh-Shell left explorer dead' }
if ($after2Pid -ne $before2) {
    throw "FAIL: Refresh-Shell restarted explorer ($before2 -> $after2Pid) - the theme must not kill the shell"
}
Write-Host "   PASS: Refresh-Shell kept explorer alive on the same PID ($after2Pid)"
Start-Sleep -Seconds 5
Assert-ExplorerRunning '5s after Refresh-Shell'

Write-Host "-- 3) opt-in guarded restart must recover explorer when asked"
Stop-ExplorerWatchdog
$toKill = Get-Process explorer -ErrorAction SilentlyContinue
if (-not $toKill) { throw 'no explorer to kill' }
$toKill | Stop-Process -Force
Write-Host "   killed explorer - running Restart-ExplorerSafe..."
Start-Sleep -Seconds 1
$ok = Restart-ExplorerSafe
if (-not $ok) { throw 'FAIL: Restart-ExplorerSafe returned false (no guarantee)' }
Start-Sleep -Seconds 6
Assert-ExplorerRunning '6s after Restart-ExplorerSafe'

Write-Host "PASS: Refresh-Shell is non-destructive; Restart-ExplorerSafe still recovers when forced"