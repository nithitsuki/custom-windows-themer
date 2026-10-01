# Regression test: the post-apply watchdog must bring explorer back even when
# Winlogon does not (e.g. shell-restart throttling, or the recurring explorer
# crash). It does nothing while explorer is up, so a healthy desktop is unused.

param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_load-themer.ps1') -Root $Root

Write-Host "-- watchdog: explorer must recover within the watch window"
$toKill = Get-Process explorer -ErrorAction SilentlyContinue
if (-not $toKill) { throw 'no explorer to kill' }

Start-ExplorerWatchdog 45   # watch for 45s (in the real script this is ~180s)
$toKill | Stop-Process -Force
Write-Host "   killed explorer; watchdog running - waiting for recovery..."

$deadline = (Get-Date).AddSeconds(60)
$recovered = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Get-Process explorer -ErrorAction SilentlyContinue) { $recovered = $true; break }
}
if (-not $recovered) { throw 'FAIL: explorer did not come back within 60s of the watchdog starting' }

# stability check
Start-Sleep -Seconds 5
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
    throw 'FAIL: explorer vanished again right after recovery'
}
Write-Host "PASS: explorer recovered and stayed alive"